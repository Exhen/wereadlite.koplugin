local Config = require("wereadlite.config")
local Log = require("wereadlite.log")
local Client = require("wereadlite.kindle.client")

local Codec = {}

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    local size = file:seek("end")
    file:close()
    return size and size > 1024
end

function Codec.b64decode(data)
    local s = tostring(data or ""):gsub("-", "+"):gsub("_", "/"):gsub("[^A-Za-z0-9%+/%=]", "")
    if #s % 4 ~= 0 then
        s = s .. string.rep("=", 4 - (#s % 4))
    end
    local out = {}
    local function value(ch)
        if ch == "=" or ch == "" then
            return 0
        end
        local i = alphabet:find(ch, 1, true)
        return i and (i - 1) or 0
    end
    for i = 1, #s, 4 do
        local c1, c2, c3, c4 = s:sub(i, i), s:sub(i + 1, i + 1), s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
        local n = value(c1) * 262144 + value(c2) * 4096 + value(c3) * 64 + value(c4)
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
        if c3 ~= "=" then
            out[#out + 1] = string.char(math.floor(n / 256) % 256)
        end
        if c4 ~= "=" then
            out[#out + 1] = string.char(n % 256)
        end
    end
    return table.concat(out)
end

local function positions(s)
    local n = #s
    if n < 4 then
        return {}
    elseif n < 11 then
        return { 0, 2 }
    end
    local take = math.min(4, math.floor((n + 9) / 10))
    local pieces = {}
    for i = n, n - take + 1, -1 do
        local x = s:byte(i)
        local b = ""
        repeat
            b = tostring(x % 2) .. b
            x = math.floor(x / 2)
        until x == 0
        pieces[#pieces + 1] = tostring(tonumber(b, 4) or 0)
    end
    local t = table.concat(pieces)
    local mod = n - take - 2
    local step = #tostring(mod)
    local out, i = {}, 1
    while #out < 10 and i + step - 1 < #t do
        out[#out + 1] = (tonumber(t:sub(i, i + step - 1)) or 0) % mod
        if i + 1 <= #t then
            out[#out + 1] = (tonumber(t:sub(i + 1, math.min(i + step, #t))) or 0) % mod
        end
        i = i + step
    end
    return out
end

local function unswap(s, p)
    local c = {}
    for i = 1, #s do
        c[i] = s:sub(i, i)
    end
    for i = #p, 1, -2 do
        local a = p[i] + 2
        local b = p[i - 1] + 2
        c[a], c[b] = c[b], c[a]
        a = a - 1
        b = b - 1
        c[a], c[b] = c[b], c[a]
    end
    return table.concat(c)
end

local function md5_hex(message)
    local ok, D = pcall(require, "ffi/MD5")
    if ok and D and type(D.sum) == "function" then
        return (D.sum(message):gsub(".", function(ch)
            return string.format("%02x", ch:byte())
        end))
    end
    ok, D = pcall(require, "md5")
    if ok and D then
        if type(D.sumhexa) == "function" then
            return D.sumhexa(message)
        end
        if type(D.hash) == "function" then
            return D.hash(message)
        end
    end
    return ""
end

function Codec.shard_body(raw)
    raw = tostring(raw or "")
    if #raw <= 32 then
        return ""
    end
    local sum, body = raw:sub(1, 32), raw:sub(33)
    local digest = md5_hex(body)
    if digest ~= "" and digest:upper() ~= sum:upper() then
        error("chapter checksum mismatch")
    end
    return body
end

function Codec.decode_parts(parts)
    local body = {}
    for _, v in ipairs(parts or {}) do
        body[#body + 1] = Codec.shard_body(v)
    end
    local s = table.concat(body)
    if s == "" then
        return ""
    end
    s = s:sub(2)
    return Codec.b64decode(unswap(s, positions(s)))
end

function Codec.looks_like_shards(text)
    text = tostring(text or "")
    return #text > 40 and text:match("^[%x]+") and #text:match("^[%x]+") == 32
end

local function utf8_replace(text, mapper)
    local out, i, n = {}, 1, #text
    while i <= n do
        local b = text:byte(i)
        local len = 1
        if b >= 240 then
            len = 4
        elseif b >= 224 then
            len = 3
        elseif b >= 192 then
            len = 2
        end
        local ch = text:sub(i, i + len - 1)
        out[#out + 1] = mapper(ch, b, len) or ch
        i = i + len
    end
    return table.concat(out)
end

-- fzys_map.bin: WRMP + ver/count (BE u16) + (from,to) BMP pairs.
-- Built from fzys_reversed.ttf vs FZYouSong GBK 509R outline matching;
-- current codepoint → visual character. Identity CJK is omitted.
local function load_map()
    if Codec._map then
        return Codec._map
    end
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    local root = src:match("(.+)/kindle/codec%.lua$")
    if not root then
        Codec._map = {}
        return Codec._map
    end
    local file = io.open(root .. "/kindle/fzys_map.bin", "rb")
    if not file then
        Codec._map = {}
        return Codec._map
    end
    local data = file:read("*a")
    file:close()
    local map = {}
    if data and #data >= 8 and data:sub(1, 4) == "WRMP" then
        local count = data:byte(7) * 256 + data:byte(8)
        local p = 9
        for _ = 1, count do
            if p + 3 > #data then
                break
            end
            local from = data:byte(p) * 256 + data:byte(p + 1)
            local to = data:byte(p + 2) * 256 + data:byte(p + 3)
            map[from] = to
            p = p + 4
        end
    end
    Codec._map = map
    return map
end

local function utf8_encode(cp)
    if cp < 128 then
        return string.char(cp)
    elseif cp < 2048 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    elseif cp < 65536 then
        return string.char(
            0xE0 + math.floor(cp / 4096),
            0x80 + math.floor(cp / 64) % 64,
            0x80 + cp % 64
        )
    end
    return ""
end

local function utf8_codepoint(ch)
    local b1, b2, b3 = ch:byte(1, 3)
    if not b1 then
        return nil
    end
    if b1 < 128 then
        return b1
    end
    if b1 < 224 and b2 then
        return (b1 - 192) * 64 + (b2 - 128)
    end
    if b1 < 240 and b2 and b3 then
        return (b1 - 224) * 4096 + (b2 - 128) * 64 + (b3 - 128)
    end
end

function Codec.has_map()
    return next(load_map()) ~= nil
end

function Codec.decode_text(text)
    local map = load_map()
    if not next(map) then
        return tostring(text or "")
    end
    return utf8_replace(tostring(text or ""), function(ch, b, len)
        if len ~= 3 then
            return ch
        end
        local cp = utf8_codepoint(ch)
        if not cp then
            return ch
        end
        local mapped = map[cp]
        if mapped then
            return utf8_encode(mapped)
        end
        return ch
    end)
end

local SKIP_DECODE_TAGS = {
    style = true,
    script = true,
    textarea = true,
}

local function tag_name_at(html, lt, gt)
    local open = html:sub(lt + 1, gt - 1)
    return (open:match("^%s*/?%s*([%a][%w:_%-]*)") or ""):lower()
end

local function is_closing_tag(html, lt, gt)
    return html:sub(lt + 1, gt - 1):match("^%s*/") ~= nil
end

local function is_self_closing(html, lt, gt)
    return html:sub(lt + 1, gt - 1):match("/%s*$") ~= nil
end

local function find_close_tag_end(html, start, name)
    local i, n = start, #html
    local needle = "</" .. name
    while i <= n do
        local lt = html:find("<", i, true)
        if not lt then
            return n
        end
        local head = html:sub(lt, math.min(n, lt + #needle + 8)):lower()
        if head:sub(1, #needle) == needle then
            return html:find(">", lt, true) or n
        end
        i = lt + 1
    end
    return n
end

function Codec.decode_html(html)
    html = tostring(html or "")
    if html == "" or not next(load_map()) then
        return html
    end
    local out, i, n = {}, 1, #html
    while i <= n do
        local lt = html:find("<", i, true)
        if not lt then
            out[#out + 1] = Codec.decode_text(html:sub(i))
            break
        end
        if lt > i then
            out[#out + 1] = Codec.decode_text(html:sub(i, lt - 1))
        end
        if html:sub(lt, lt + 3) == "<!--" then
            local stop = html:find("-->", lt + 4, true)
            local gt = stop and (stop + 2) or n
            out[#out + 1] = html:sub(lt, gt)
            i = gt + 1
        else
            local gt = html:find(">", lt + 1, true) or n
            out[#out + 1] = html:sub(lt, gt)
            local name = tag_name_at(html, lt, gt)
            if SKIP_DECODE_TAGS[name]
                and not is_closing_tag(html, lt, gt)
                and not is_self_closing(html, lt, gt) then
                local close_gt = find_close_tag_end(html, gt + 1, name)
                out[#out + 1] = html:sub(gt + 1, close_gt)
                i = close_gt + 1
            else
                i = gt + 1
            end
        end
    end
    return table.concat(out)
end

local FOOTNOTE_TAGS = {
    span = true, a = true, sup = true, sub = true, i = true, em = true,
    img = true, font = true, label = true,
}

local function xml_escape(text)
    return (tostring(text or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

local function decode_attr(value)
    value = tostring(value or "")
    value = value:gsub("&nbsp;", " "):gsub("&#160;", " ")
    value = value:gsub("&quot;", '"'):gsub("&#34;", '"')
    value = value:gsub("&apos;", "'"):gsub("&#39;", "'")
    value = value:gsub("&lt;", "<"):gsub("&gt;", ">")
    value = value:gsub("&#x(%x+);", function(hex)
        return utf8_encode(tonumber(hex, 16) or 0)
    end)
    value = value:gsub("&#(%d+);", function(n)
        return utf8_encode(tonumber(n) or 0)
    end)
    value = value:gsub("&amp;", "&")
    return value
end

local function strip_tags(html)
    html = tostring(html or ""):gsub("<[^>]+>", "")
    html = decode_attr(html)
    return (html:gsub("%s+", " "):match("^%s*(.-)%s*$")) or ""
end

local function tag_attr(attrs, name)
    attrs = tostring(attrs or "")
    local escaped = tostring(name or ""):gsub("([^%w])", "%%%1")
    return attrs:match("%s" .. escaped .. '%s*=%s*"([^"]*)"')
        or attrs:match("^%s*" .. escaped .. '%s*=%s*"([^"]*)"')
        or attrs:match("%s" .. escaped .. "%s*=%s*'([^']*)'")
        or attrs:match("^%s*" .. escaped .. "%s*=%s*'([^']*)'")
end

local function is_real_tag(html, pos, name, closing)
    local prefix = closing and 2 or 1
    local start = pos + prefix + #name
    local ch = html:sub(start, start)
    return ch == "" or ch == ">" or ch == "/" or ch:match("%s")
end

local function find_open_tag(html, inside)
    local pos = inside
    while pos >= 1 do
        if html:sub(pos, pos) == "<" then
            local name = html:sub(pos + 1):match("^([%w]+)")
            if name then
                return pos, name:lower()
            end
            return nil
        end
        pos = pos - 1
    end
end

local function find_element_end(html, lt, tag, gt)
    local open = html:sub(lt + 1, gt - 1)
    if tag == "img" or tag == "br" or tag == "hr" or open:match("/%s*$") then
        return gt, ""
    end
    local p, depth = gt + 1, 1
    local open_token, close_token = "<" .. tag, "</" .. tag
    while true do
        local nxt_open = html:find(open_token, p, true)
        local nxt_close = html:find(close_token, p, true)
        while nxt_open and not is_real_tag(html, nxt_open, tag, false) do
            nxt_open = html:find(open_token, nxt_open + 1, true)
        end
        while nxt_close and not is_real_tag(html, nxt_close, tag, true) do
            nxt_close = html:find(close_token, nxt_close + 1, true)
        end
        if not nxt_close then
            return #html, html:sub(gt + 1)
        end
        if nxt_open and nxt_open < nxt_close then
            depth = depth + 1
            p = nxt_open + #open_token
        else
            depth = depth - 1
            local close_gt = html:find(">", nxt_close, true) or (nxt_close + #close_token)
            if depth == 0 then
                return close_gt, html:sub(gt + 1, nxt_close - 1)
            end
            p = close_gt + 1
        end
    end
end

local function footnote_mark(idx, display)
    return '<span class="fn-ref"><a epub:type="noteref" role="doc-noteref" href="#wt_'
        .. idx .. '" id="wtref_' .. idx .. '">[' .. display .. "]</a></span>"
end

local function footnote_aside(idx, display, text)
    return '<aside epub:type="footnote" role="doc-footnote" id="wt_'
        .. idx .. '" class="footnote"><p><a href="#wtref_' .. idx
        .. '" class="fn-num">[' .. display .. "]</a> " .. text .. "</p></aside>\n"
end

local function push_note(notes, display, text)
    local idx = #notes + 1
    display = tostring(display or "")
    if display == "" then
        display = tostring(idx)
    end
    notes[idx] = { idx = idx, display = display, text = text }
    return footnote_mark(idx, xml_escape(display))
end

function Codec.convert_footnotes(html)
    html = tostring(html or "")
    if html == "" then
        return html
    end
    local notes, pieces, cursor = {}, {}, 1
    local search = 1
    while true do
        local at = html:find("data-wr-footernote", search, true)
        if not at then
            break
        end
        local lt, tag = find_open_tag(html, at)
        local gt = html:find(">", at, true)
        if not lt or not tag or not gt or gt < at then
            search = at + 1
        else
            local attrs = html:sub(lt + 1, gt - 1)
            local class = tag_attr(attrs, "class") or ""
            local note = Codec.decode_text(decode_attr(tag_attr(attrs, "data-wr-footernote") or ""))
            local allowed = FOOTNOTE_TAGS[tag] or class:find("js_readerFooterNote", 1, true)
                or class:find("qqreader-footnote", 1, true)
            local elem_end, inner = find_element_end(html, lt, tag, gt)
            if not allowed or note == "" then
                search = at + 1
            else
                pieces[#pieces + 1] = html:sub(cursor, lt - 1)
                pieces[#pieces + 1] = push_note(notes, strip_tags(inner), note)
                cursor = elem_end + 1
                search = cursor
            end
        end
    end
    pieces[#pieces + 1] = html:sub(cursor)
    html = table.concat(pieces)

    html = html:gsub("<[iI][mM][gG]([^>]*)/?>", function(attrs)
        local class = tag_attr(attrs, "class") or ""
        if not class:find("qqreader-footnote", 1, true) and not class:find("js_readerFooterNote", 1, true) then
            return "<img" .. attrs .. ">"
        end
        local note = decode_attr(tag_attr(attrs, "data-wr-footernote")
            or tag_attr(attrs, "alt")
            or tag_attr(attrs, "title")
            or "")
        if note == "" then
            return "<img" .. attrs .. ">"
        end
        return push_note(notes, "", note)
    end)

    if #notes == 0 then
        return html
    end
    local tail = { '\n<div class="footnotes" role="doc-endnotes">\n<hr/>\n' }
    for _, note in ipairs(notes) do
        tail[#tail + 1] = footnote_aside(note.idx, xml_escape(note.display), xml_escape(note.text))
    end
    tail[#tail + 1] = "</div>\n"
    return html .. table.concat(tail)
end

local function div_bounds_by_id(html, id)
    html = tostring(html or "")
    local needle = 'id="' .. id .. '"'
    local at = html:find(needle, 1, true)
    if not at then
        return nil
    end
    local open = html:sub(1, at):match(".*()<div")
    if not open then
        open = html:find("<div", math.max(1, at - 80), true)
    end
    if not open then
        return nil
    end
    local gt = html:find(">", at, true)
    if not gt then
        return nil
    end
    local p, depth = gt + 1, 1
    while depth > 0 do
        local nxt_open = html:find("<div", p, true)
        local nxt_close = html:find("</div>", p, true)
        if not nxt_close then
            return open, #html
        end
        if nxt_open and nxt_open < nxt_close then
            depth = depth + 1
            p = nxt_open + 4
        else
            depth = depth - 1
            if depth == 0 then
                return open, nxt_close + 5
            end
            p = nxt_close + 6
        end
    end
end

function Codec.inner_by_id(html, id)
    local open, close = div_bounds_by_id(html, id)
    if not open then
        return nil
    end
    local gt = html:find(">", open, true)
    if not gt or gt >= close then
        return nil
    end
    return html:sub(gt + 1, close - 6)
end

-- Plain-text chapter titles are not custom-font encoded; keep them out of decode_html.
local function carve_element_by_id(html, id)
    local open, close = div_bounds_by_id(html, id)
    if not open then
        return html, nil
    end
    return html:sub(1, open - 1), html:sub(open, close), html:sub(close + 1)
end

local function remove_css_property(css, name)
    return css:gsub(name .. "%s*:%s*[^;}]*;?", "")
end

local function strip_reader_typography(css)
    css = remove_css_property(css, "[fF][oO][nN][tT]%-[fF][aA][mM][iI][lL][yY]")
    css = remove_css_property(css, "[fF][oO][nN][tT]%-[sS][iI][zZ][eE]")
    css = remove_css_property(css, "[lL][iI][nN][eE]%-[hH][eE][iI][gG][hH][tT]")
    css = remove_css_property(css, "[lL][eE][tT][tT][eE][rR]%-[sS][pP][aA][cC][iI][nN][gG]")
    css = remove_css_property(css, "[wW][oO][rR][dD]%-[sS][pP][aA][cC][iI][nN][gG]")
    css = remove_css_property(css, "[tT][eE][xX][tT]%-[iI][nN][dD][eE][nN][tT]")
    return remove_css_property(css, "%f[%a][fF][oO][nN][tT]%f[^%w-]")
end

local function strip_inline_typography(html)
    return tostring(html or ""):gsub("<[^>]+>", function(tag)
        return strip_reader_typography(tag)
    end)
end

function Codec.reader_content(html, decode)
    local inner = Codec.inner_by_id(html, "readerContent")
        or Codec.inner_by_id(html, "readerContentRenderContainer")
    if not inner or inner == "" then
        error("readerContent missing")
    end
    local text = inner:gsub("<!%-%-.-%-%->", ""):gsub("<[^>]+>", ""):gsub("%s+", "")
    local has_image = inner:find("<[iI][mM][gG]%f[%s/>]") ~= nil
    if text == "" and not has_image then
        error("readerContent empty")
    end
    local title_head, title_block, title_tail
    if decode ~= false then
        title_head, title_block, title_tail = carve_element_by_id(inner, "readerChapterTitle")
        if title_block then
            inner = title_head .. title_tail
        end
    end
    if Codec.looks_like_shards(inner) then
        if decode ~= false then
            local ok, decoded = pcall(Codec.decode_parts, { inner })
            if ok and decoded and decoded ~= "" then
                inner = decoded
            end
        end
    elseif decode ~= false then
        inner = Codec.decode_html(inner)
        if title_block then
            inner = title_head .. title_block .. inner:sub(#title_head + 1)
        end
    end
    if decode == false then
        return strip_inline_typography(inner)
    end
    return strip_inline_typography(Codec.convert_footnotes(inner))
end

function Codec.reader_styles(html)
    local function rewrite_bleed(value)
        value = tostring(value or ""):lower()
        local out = { "page-break-inside:avoid" }
        local left = value:find("left", 1, true) ~= nil
        local right = value:find("right", 1, true) ~= nil
        if left then
            out[#out + 1] = "margin-left:-6.5% !important"
        end
        if right then
            out[#out + 1] = "margin-right:-6.5% !important"
        end
        if left and right then
            out[#out + 1] = "width:113% !important"
        elseif left or right then
            out[#out + 1] = "width:106.5% !important"
        end
        if value:find("top", 1, true) then
            out[#out + 1] = "margin-top:-6.5% !important"
        end
        if value:find("bottom", 1, true) then
            out[#out + 1] = "margin-bottom:-6.5% !important"
        end
        return table.concat(out, ";") .. ";"
    end

    local styles = {}
    for css in tostring(html or ""):gmatch("<[sS][tT][yY][lL][eE][^>]*>(.-)</[sS][tT][yY][lL][eE]%s*>") do
        css = css:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&#39;", "'")
        css = css:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        css = css:gsub("[qQ][rR][fF][uU][lL][lL][pP][aA][gG][eE]%s*:%s*[^;}]*;?",
            "page-break-before:always;page-break-after:always;page-break-inside:avoid;text-align:center;")
        css = css:gsub("[qQ][rR][bB][lL][eE][eE][dD]%s*:%s*([^;}]*);?", rewrite_bleed)

        -- Let KOReader's reader settings own typography and paragraph spacing.
        css = strip_reader_typography(css)
        styles[#styles + 1] = css
    end
    return table.concat(styles, "\n")
end

function Codec.font_path()
    local dir = require("wereadlite.paths").fonts_dir()
    return dir .. "/fzys_reversed.ttf"
end

function Codec.ensure_font()
    local path = Codec.font_path()
    if file_exists(path) then
        Codec.register_font(path)
        return path
    end
    Log.info("codec", "font_download", { url = Config.READER_FONT_URL })
    local body, status, err = Client.request({
        url = Config.READER_FONT_URL,
        accept = "*/*",
        referer = Config.READER_URL,
        timeout = 120,
    })
    if not body or status ~= "ok" or #body < 1024 then
        error("font download failed: " .. tostring(err or status))
    end
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then
        error("font write failed")
    end
    file:write(body)
    file:close()
    os.remove(path)
    os.rename(tmp, path)
    Codec.register_font(path)
    return path
end

function Codec.register_font(path)
    local ok_cre, cre = pcall(require, "libs/libkoreader-cre")
    if ok_cre and cre and type(cre.registerFont) == "function" then
        local ok, err = pcall(cre.registerFont, path)
        if not ok then
            Log.warn("codec", "register_font", { err = err })
        end
    end
end

function Codec.wrap_html(opts)
    opts = opts or {}
    local title = tostring(opts.title or ""):gsub("[<>&]", {
        ["<"] = "&lt;",
        [">"] = "&gt;",
        ["&"] = "&amp;",
    })
    local body = tostring(opts.body or "")
    local font_path = opts.font_path or ""
    local source_css = tostring(opts.source_css or "")
    local decoded = Codec.has_map()
    local font_css = ""
    if font_path ~= "" and not decoded then
        font_css = table.concat({
            '@font-face { font-family: "fzys"; src: url("',
            font_path,
            '"); }\n',
            '.readerContent, .readerContentRenderContainer, .randomFont, body {',
            ' font-family: "fzys", "FZYouSong GBK 509R", "方正悠宋 GBK 509R", serif; }',
        })
    end
    return table.concat({
        '<!DOCTYPE html>\n<html lang="zh-CN">\n<head>\n<meta charset="utf-8"/>\n<title>',
        title,
        '</title>\n<style>\n',
        source_css,
        '\nbody { margin: 6%; line-height: 1.7; }\nimg { max-width: 100%; height: auto; }\n',
        'h1, h2, .firstTitle { text-align: center; page-break-before: avoid !important; break-before: avoid !important; }\n',
        'body h1:first-child, body h2:first-child, body .firstTitle:first-child { margin-top: 0 !important; padding-top: 0 !important; }\n',
        '.frontCover:first-child, .qqreader-fullimg:first-child { page-break-before: avoid !important; }\n',
        '.fn-ref { font-size: 0.75em; vertical-align: super; line-height: 0; }\n',
        '.fn-ref a { text-decoration: none; }\n',
        'aside.footnote { -cr-hint: footnote-inpage; margin: 0.4em 0; font-size: 0.85em; text-indent: 0; }\n',
        'div.footnotes { margin-top: 1.5em; padding-top: 0.5em; border-top: 1px solid #ccc; }\n',
        '.fn-num { font-weight: bold; margin-right: 0.3em; text-decoration: none; color: inherit; }\n',
        'a.wereadlite-highlight, a.wereadlite-highlight:link, a.wereadlite-highlight:visited {',
        ' text-decoration: none !important; border-bottom: 1px dashed currentColor;',
        ' color: inherit !important; -cr-hint: presentational-hint; }\n',
        font_css,
        '\n</style>\n</head>\n<body>\n<!-- wereadlite -->\n',
        '<div id="readerContentRenderContainer" class="readerContentRenderContainer randomFont">\n',
        body,
        '\n</div>\n</body>\n</html>\n',
    })
end

return Codec
