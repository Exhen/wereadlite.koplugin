local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Config = require("wereadlite.config")
local Http = require("wereadlite.async_http")
local Json = require("wereadlite.json")
local Log = require("wereadlite.log")
local Codec = require("wereadlite.kindle.codec")

local Bookmark = {}

local function plain_text(html)
    html = tostring(html or "")
    html = html:gsub("<script.-</script>", "")
    html = html:gsub("<style.-</style>", "")
    html = html:gsub("<[^>]+>", "")
    html = html:gsub("&nbsp;", " "):gsub("&#160;", " ")
    html = html:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    html = html:gsub("%s+", "")
    return html
end

local function normalize(text)
    text = tostring(text or "")
    text = text:gsub("\194\160", "")
    text = text:gsub("%s+", "")
    return text
end

local function utf8_len(text)
    text = tostring(text or "")
    local n, i = 0, 1
    while i <= #text do
        local b = text:byte(i)
        if not b then
            break
        elseif b < 128 then
            i = i + 1
        elseif b < 224 then
            i = i + 2
        elseif b < 240 then
            i = i + 3
        else
            i = i + 4
        end
        n = n + 1
    end
    return n
end

local function utf8_sub(text, from, to)
    text = tostring(text or "")
    from = math.max(1, tonumber(from) or 1)
    to = tonumber(to) or from
    local n, i, start_i = 0, 1, nil
    while i <= #text do
        n = n + 1
        local b = text:byte(i)
        local step = 1
        if b >= 240 then
            step = 4
        elseif b >= 224 then
            step = 3
        elseif b >= 192 then
            step = 2
        end
        if n == from then
            start_i = i
        end
        if n == to then
            if start_i then
                return text:sub(start_i, i + step - 1)
            end
            return ""
        end
        i = i + step
    end
    if start_i then
        return text:sub(start_i)
    end
    return ""
end

-- Build byte-index table for each UTF-8 char start (1-based char -> byte).
local function utf8_starts(text)
    text = tostring(text or "")
    local starts, i, n = { 1 }, 1, 0
    while i <= #text do
        n = n + 1
        starts[n] = i
        local b = text:byte(i)
        if b < 128 then
            i = i + 1
        elseif b < 224 then
            i = i + 2
        elseif b < 240 then
            i = i + 3
        else
            i = i + 4
        end
    end
    starts[n + 1] = #text + 1
    return starts, n
end

local function read_file(path)
    path = tostring(path or "")
    if path == "" then
        return ""
    end
    local file = io.open(path, "rb")
    if not file then
        return ""
    end
    local data = file:read("*a") or ""
    file:close()
    return data
end

local function read_plain(path)
    return plain_text(read_file(path))
end

local function remove_literal(text, needle)
    text = tostring(text or "")
    needle = tostring(needle or "")
    if text == "" or needle == "" then
        return text
    end
    local out, i = {}, 1
    while true do
        local at = text:find(needle, i, true)
        if not at then
            out[#out + 1] = text:sub(i)
            break
        end
        out[#out + 1] = text:sub(i, at - 1)
        i = at + #needle
    end
    return table.concat(out)
end

-- CreDocument in-page footnotes expose "[1]" / aside text in highlight
-- selections, but the encrypted chapter stream has empty footnote anchors.
local function footnote_bodies(html)
    local notes = {}
    for block in tostring(html or ""):gmatch('<aside[^>]*class="footnote"[^>]*>([%s%S]-)</aside>') do
        local text = normalize(plain_text(block))
        text = text:gsub("^%[%d+%]", "")
        if text ~= "" then
            notes[#notes + 1] = text
        end
    end
    return notes
end

local function scrub_selection(text, notes)
    text = normalize(text)
    -- Markers inserted by Codec.convert_footnotes, e.g. [1].
    text = text:gsub("%[%d+%]", "")
    for _, note in ipairs(notes or {}) do
        text = remove_literal(text, note)
    end
    return normalize(text)
end

local function chapter_html(path)
    local html = read_file(path)
    if html == "" then
        return ""
    end
    local ok, inner = pcall(function()
        return Codec.inner_by_id(html, "readerContent")
            or Codec.inner_by_id(html, "readerContentRenderContainer")
    end)
    if ok and inner and inner ~= "" then
        return inner
    end
    return html
end

local function strip_footnote_markup(html)
    html = tostring(html or "")
    html = html:gsub('<div[^>]*role="doc%-endnotes"[^>]*>([%s%S]-)</div>', "")
    html = html:gsub('<div[^>]*class="footnotes"[^>]*>([%s%S]-)</div>', "")
    html = html:gsub('<span[^>]*class="fn%-ref"[^>]*>([%s%S]-)</span>', "")
    html = html:gsub('<aside[^>]*class="footnote"[^>]*>([%s%S]-)</aside>', "")
    html = html:gsub('<span[^>]*data%-wr%-footernote[^>]*>([%s%S]-)</span>', "")
    return html
end

local function chapter_plain(path, should_decode)
    local html = strip_footnote_markup(chapter_html(path))
    local text = normalize(plain_text(html))
    if should_decode and text ~= "" and Codec.has_map() then
        local ok_dec, mapped = pcall(Codec.decode_text, text)
        if ok_dec and mapped and mapped ~= "" then
            text = normalize(mapped)
        end
    end
    return text
end

local function toast(text, timeout)
    UIManager:show(InfoMessage:new{
        text = tostring(text or ""),
        timeout = timeout or 1.5,
    })
end

local function refresh_session_then(callback)
    local Session = require("wereadlite.session")
    Session.refresh_async(function(user, status, err)
        if user then
            callback(true)
            return
        end
        Log.warn("bookmark", "session_refresh", { status = status, err = err })
        callback(false, status, err)
    end)
end

local function retry_auth_expired(err, retried, on_retry, on_fail)
    if err ~= "auth_expired" or retried then
        return false
    end
    refresh_session_then(function(ok)
        if ok then
            on_retry()
        else
            on_fail(true)
        end
    end)
    return true
end

local function chapter_hint(state)
    local base = math.max(0, tonumber(state and state.char_base) or 0)
    local offset = tonumber(state and state.chapter_offset) or 0
    if offset > 0 then
        -- find_range searches the loaded fragment; convert absolute offset to local.
        return math.max(0, offset - base)
    end
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok and ReaderUI and ReaderUI.instance
    local percent = ui and ui.view and ui.view.footer and tonumber(ui.view.footer.percent_finished)
    if percent then
        local chars = tonumber(state and state.loaded_chars) or 0
        if chars <= 0 then
            local enc = chapter_plain(state and state.html_enc_path, false)
            chars = utf8_len(enc)
        end
        return math.floor(percent * math.max(0, chars))
    end
    return 0
end

-- Find needle in haystack as UTF-8 chars; prefer match nearest to hint (0-based).
-- Returns start0, end0 (end exclusive), or nil.
local function find_range(haystack, needle, hint)
    haystack = tostring(haystack or "")
    needle = tostring(needle or "")
    if haystack == "" or needle == "" then
        return nil
    end
    local starts, total = utf8_starts(haystack)
    local needle_len = utf8_len(needle)
    if needle_len <= 0 or needle_len > total then
        return nil
    end
    local hint0 = math.max(0, tonumber(hint) or 0)
    local best_start, best_dist
    local pos = 1
    while true do
        local at = haystack:find(needle, pos, true)
        if not at then
            break
        end
        local lo, hi, char0 = 1, total, 0
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local s = starts[mid]
            if s == at then
                char0 = mid - 1
                break
            elseif s < at then
                char0 = mid - 1
                lo = mid + 1
            else
                hi = mid - 1
            end
        end
        local dist = math.abs(char0 - hint0)
        if not best_dist or dist < best_dist then
            best_dist = dist
            best_start = char0
        end
        pos = at + 1
    end
    if best_start == nil then
        return nil
    end
    return best_start, best_start + needle_len
end

local function book_version(state)
    local info = state and state.book_info
    local v = tonumber(state and state.book_version)
        or tonumber(info and info.version)
        or tonumber(info and info.bookVersion)
    return v or 0
end

function Bookmark.build_payload(item, state)
    state = state or {}
    item = item or {}
    local book_id = tostring(state.book_id or "")
    local cur = state.cur or {}
    local chapter_uid = tonumber(cur.uid) or tostring(cur.uid or "")
    local chapter_idx = tonumber(cur.idx) or 0
    local raw_selected = normalize(item.text)
    if book_id == "" or book_id == "nil" or raw_selected == "" then
        return nil, "missing book or text"
    end
    if chapter_uid == "" or chapter_uid == "nil" then
        return nil, "missing chapter"
    end

    local notes = footnote_bodies(read_file(state.html_path))
    local selected = scrub_selection(raw_selected, notes)
    if selected == "" then
        selected = raw_selected
    end
    if selected ~= raw_selected then
        Log.dbg("bookmark", "scrub_selection", {
            before = utf8_len(raw_selected),
            after = utf8_len(selected),
            notes = #notes,
        })
    end

    -- Locate against chapter body only (skip title/chrome and footnote markers).
    local enc = chapter_plain(state.html_enc_path, false)
    if enc == "" then
        enc = normalize(read_plain(state.html_enc_path))
    end
    if enc == "" then
        return nil, "missing chapter text"
    end
    local dec = chapter_plain(state.html_enc_path, true)
    if dec == "" then
        dec = enc
        if Codec.has_map() then
            local ok_dec, mapped = pcall(Codec.decode_text, enc)
            if ok_dec and mapped and mapped ~= "" then
                dec = normalize(mapped)
            end
        end
    end

    local hint = chapter_hint(state)
    local start0, end0 = find_range(dec, selected, hint)
    if not start0 and selected ~= raw_selected then
        start0, end0 = find_range(dec, raw_selected, hint)
    end
    if not start0 then
        start0, end0 = find_range(enc, selected, hint)
    end
    if not start0 and selected ~= raw_selected then
        start0, end0 = find_range(enc, raw_selected, hint)
    end
    if not start0 then
        -- Last resort: displayed chapter (already decoded) after scrubbing footnotes.
        local shown = chapter_plain(state.html_path, false)
        start0, end0 = find_range(shown, selected, hint)
        if start0 then
            -- Map displayed offsets back through decoded enc by re-finding the
            -- scrubbed needle; shown-only hits still use the enc needle range.
            local mapped_start, mapped_end = find_range(dec, selected, start0)
            if mapped_start then
                start0, end0 = mapped_start, mapped_end
            else
                start0, end0 = nil, nil
            end
        end
    end
    if not start0 then
        return nil, "locate failed"
    end

    -- Loaded HTML may be a mid-chapter window (e.g. sect 4-6). Local UTF-8
    -- indices must be shifted by char_base so WeRead gets absolute ranges.
    local char_base = math.max(0, tonumber(state.char_base) or 0)
    local abs_start = start0 + char_base
    local abs_end = end0 + char_base

    local mark = utf8_sub(enc, start0 + 1, end0)
    if mark == "" then
        mark = selected
    end
    if mark == "" then
        return nil, "empty markText"
    end

    local version = book_version(state)
    if version <= 0 then
        Log.warn("bookmark", "no_book_version", { book_id = book_id })
    end

    Log.dbg("bookmark", "range", {
        local_start = start0,
        local_end = end0,
        char_base = char_base,
        abs_start = abs_start,
        abs_end = abs_end,
    })

    return {
        bookId = book_id,
        chapterUid = chapter_uid,
        bookVersion = version,
        type = 1,
        style = 0,
        range = string.format("%d-%d", abs_start, abs_end),
        markText = mark,
        createTime = os.time(),
        chapterIdx = chapter_idx,
        v = 2,
    }
end

local function parse_response(body, action)
    local data = Json.decode(body or "")
    if type(data) ~= "table" then
        return nil, "bad json"
    end
    local succ = tonumber(data.succ) or tonumber(data.errCode) or 0
    if succ == 1 or data.succ == true then
        return data
    end
    if tonumber(data.sessionTimeout) == 1 or data.sessionTimeout == true then
        return nil, "auth_expired"
    end
    return nil, data.errMsg or data.errmsg or ((action or "bookmark") .. " failed")
end

function Bookmark.id_from_payload(payload)
    if type(payload) ~= "table" then
        return nil
    end
    local book_id = tostring(payload.bookId or "")
    local chapter = tostring(payload.chapterUid or "")
    local range = tostring(payload.range or "")
    if book_id == "" or chapter == "" or range == "" then
        return nil
    end
    return book_id .. "_" .. chapter .. "_" .. range
end

function Bookmark.add(payload, state, callback)
    callback = callback or function() end
    if type(payload) ~= "table" then
        callback(nil, "bad payload")
        return
    end
    local body, err = Json.encode(payload)
    if not body then
        callback(nil, err or "json encode failed")
        return
    end
    local referer = (state and state.url) or Config.READER_URL
    Log.info("bookmark", "add", {
        book_id = payload.bookId,
        chapter = payload.chapterUid,
        range = payload.range,
        chars = utf8_len(payload.markText),
    })
    if not Http.available() then
        callback(nil, "offline")
        return
    end
    Http.request({
        url = Config.ADD_BOOKMARK_URL,
        method = "POST",
        body = body,
        accept = "*/*",
        origin = Config.ORIGIN,
        referer = referer,
        timeout = 20,
    }, function(res)
        if not res or not res.ok then
            local status = (res and res.status) or "http_error"
            Log.warn("bookmark", "http_add", { status = status, err = res and res.err })
            callback(nil, status)
            return
        end
        local data, perr = parse_response(res.body, "addbookmark")
        if not data then
            Log.warn("bookmark", "api_add", { err = perr })
            callback(nil, perr)
            return
        end
        local bookmark_id = data.data and data.data.bookmarkId
        if not bookmark_id or bookmark_id == "" then
            bookmark_id = Bookmark.id_from_payload(payload)
        end
        Log.info("bookmark", "add_ok", {
            bookmark_id = bookmark_id,
            range = payload.range,
        })
        callback(data, nil, bookmark_id)
    end)
end

function Bookmark.remove(bookmark_id, state, callback)
    callback = callback or function() end
    bookmark_id = tostring(bookmark_id or "")
    if bookmark_id == "" then
        callback(nil, "missing bookmarkId")
        return
    end
    local body, err = Json.encode({ bookmarkId = bookmark_id })
    if not body then
        callback(nil, err or "json encode failed")
        return
    end
    local referer = (state and state.url) or Config.READER_URL
    Log.info("bookmark", "remove", { bookmark_id = bookmark_id })
    if not Http.available() then
        callback(nil, "offline")
        return
    end
    Http.request({
        url = Config.REMOVE_BOOKMARK_URL,
        method = "POST",
        body = body,
        accept = "*/*",
        origin = Config.ORIGIN,
        referer = referer,
        timeout = 20,
    }, function(res)
        if not res or not res.ok then
            local status = (res and res.status) or "http_error"
            Log.warn("bookmark", "http_remove", { status = status, err = res and res.err })
            callback(nil, status)
            return
        end
        local data, perr = parse_response(res.body, "removebookmark")
        if not data then
            Log.warn("bookmark", "api_remove", { err = perr })
            callback(nil, perr)
            return
        end
        Log.info("bookmark", "remove_ok", { bookmark_id = bookmark_id })
        callback(data)
    end)
end

local function attach_ids(item, payload, bookmark_id)
    if type(item) ~= "table" or type(payload) ~= "table" then
        return
    end
    item.wereadlite_bookmark_id = bookmark_id or Bookmark.id_from_payload(payload)
    item.wereadlite_range = payload.range
    item.wereadlite_chapter_uid = tostring(payload.chapterUid or "")
end

-- Sync a KOReader annotation item to WeRead (async, non-blocking).
function Bookmark.sync_highlight(item, state, opts)
    opts = opts or {}
    local payload, err = Bookmark.build_payload(item, state)
    if not payload then
        Log.warn("bookmark", "build", { err = err })
        if opts.notify ~= false then
            toast("划线定位失败")
        end
        return
    end
    local function fail(add_err, auth_failed)
        if auth_failed or add_err == "auth_expired" then
            toast("登录已过期，请重新登录", 2)
        elseif opts.notify ~= false then
            toast("划线同步失败")
        end
    end
    local function do_add(retried)
        Bookmark.add(payload, state, function(data, add_err, bookmark_id)
            if data then
                attach_ids(item, payload, bookmark_id)
                if opts.notify ~= false then
                    toast("已同步划线")
                end
                return
            end
            if retry_auth_expired(add_err, retried, function()
                do_add(true)
            end, fail) then
                return
            end
            fail(add_err, false)
        end)
    end
    do_add(false)
end

function Bookmark.resolve_id(item, state)
    if type(item) == "table" then
        local existing = tostring(item.wereadlite_bookmark_id or "")
        if existing ~= "" then
            return existing
        end
        local range = tostring(item.wereadlite_range or "")
        local chapter = tostring(item.wereadlite_chapter_uid or "")
        local book_id = tostring(state and state.book_id or "")
        if range ~= "" and chapter ~= "" and book_id ~= "" then
            return book_id .. "_" .. chapter .. "_" .. range
        end
    end
    local payload = select(1, Bookmark.build_payload(item, state))
    return Bookmark.id_from_payload(payload)
end

-- Remove a highlight from WeRead (async).
function Bookmark.sync_delete(item, state, opts)
    opts = opts or {}
    local bookmark_id = Bookmark.resolve_id(item, state)
    if not bookmark_id then
        Log.warn("bookmark", "delete_id", { err = "unresolved" })
        if opts.notify ~= false then
            toast("无法定位云端划线")
        end
        return
    end
    local function fail(rem_err, auth_failed)
        if auth_failed or rem_err == "auth_expired" then
            toast("登录已过期，请重新登录", 2)
        elseif opts.notify ~= false then
            toast("删除划线失败")
        end
    end
    local function do_remove(retried)
        Bookmark.remove(bookmark_id, state, function(data, rem_err)
            if data then
                if opts.notify ~= false then
                    toast("已删除划线")
                end
                return
            end
            if retry_auth_expired(rem_err, retried, function()
                do_remove(true)
            end, fail) then
                return
            end
            fail(rem_err, false)
        end)
    end
    do_remove(false)
end

return Bookmark
