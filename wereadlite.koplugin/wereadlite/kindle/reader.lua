local Config = require("wereadlite.config")
local Log = require("wereadlite.log")
local Client = require("wereadlite.kindle.client")
local Codec = require("wereadlite.kindle.codec")
local Images = require("wereadlite.kindle.images")
local Json = require("wereadlite.json")
local Nuxt = require("wereadlite.kindle.nuxt")
local BookDb = require("wereadlite.book_db")
local Skill = require("wereadlite.skill")
local Settings = require("wereadlite.settings")
local AsyncHttp = require("wereadlite.async_http")
local Paths = require("wereadlite.paths")

local Reader = {}
Reader._prefetch_job = nil
Reader._prefetched = {}

function Reader.take_prefetched(url)
    url = tostring(url or "")
    local state = Reader._prefetched[url]
    if state then
        Reader._prefetched[url] = nil
        Log.info("reader", "prefetch_ready_hit", { url = url, html = state.html_path })
    end
    return state
end

local function prefetch_key(url)
    local h = 2166136261
    for i = 1, #tostring(url or "") do
        h = (h * 16777619 + tostring(url):byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

local function prefetch_path(url)
    local dir = Paths.cache_dir() .. "/chapter_prefetch"
    Paths.ensure(dir)
    return dir .. "/" .. prefetch_key(url) .. ".html"
end

local function read_prefetch(url)
    local path = prefetch_path(url)
    local file = io.open(path, "rb")
    if not file then return nil end
    local body = file:read("*a")
    file:close()
    if body and #body > 0 then
        os.remove(path)
        Log.info("reader", "prefetch_hit", { url = url, bytes = #body })
        return body
    end
    os.remove(path)
end

local function has_prefetch(url)
    local file = io.open(prefetch_path(url), "rb")
    if not file then return false end
    local size = file:seek("end") or 0
    file:close()
    return size > 0
end
Reader.review_data = {}
Reader.review_marks = {}

local function mkdir(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs then
        if lfs.attributes(path, "mode") ~= "directory" then
            lfs.mkdir(path)
        end
        return
    end
    os.execute(string.format("mkdir -p %q", path))
end

local function token_or_string(raw, env)
    raw = tostring(raw or "")
    if raw:sub(1, 1) == '"' then
        return Nuxt.unescape(raw:sub(2, -2))
    end
    return Nuxt.scalar(raw, env)
end

local function field(block, key, env)
    block = tostring(block or "")
    local quoted = block:match(key .. ':"([^"]*)"')
    if quoted then
        return Nuxt.unescape(quoted)
    end
    local tok = block:match(key .. ":([%w_]+)")
    if tok == nil or tok == "" then
        return ""
    end
    return Nuxt.scalar(tok, env)
end

local function as_number(value)
    return tonumber(value) or 0
end

local function as_text(value)
    if type(value) == "boolean" then
        return ""
    end
    return tostring(value or "")
end

local function is_bc(param)
    param = tostring(param or "")
    return #param >= 24 and param:find("^[%w%-_]+$") ~= nil
end

function Reader.url_for(param, extra)
    param = tostring(param or "")
    local url = Config.READER_URL .. "?bc=" .. param
    extra = extra or {}
    if extra.sect ~= nil and extra.sect ~= "" then
        url = url .. "&sect=" .. tostring(extra.sect)
    end
    if extra.anch then
        url = url .. "&anch=" .. tostring(extra.anch)
    end
    if extra.prev then
        url = url .. "&prev=1"
    end
    return url
end

local function lfs_mod()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok then
        return lfs
    end
end

local function remove_tree(path)
    path = tostring(path or "")
    if path == "" then
        return
    end
    local lfs = lfs_mod()
    local mode = lfs and lfs.attributes(path, "mode")
    if not mode then
        os.remove(path)
        os.execute(string.format("rm -rf %q", path))
        return
    end
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        os.remove(path)
        return
    end
    os.remove(path)
end

local function sidecar_dirs(html_path)
    html_path = tostring(html_path or "")
    local dirs, seen = {}, {}
    local function add(dir)
        dir = tostring(dir or "")
        if dir ~= "" and not seen[dir] then
            seen[dir] = true
            dirs[#dirs + 1] = dir
        end
    end
    local base = html_path:match("(.+)%.[^/%.]+$") or html_path
    add(base .. ".sdr")
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings and type(DocSettings.getSidecarDir) == "function" then
        add(DocSettings:getSidecarDir(html_path))
        add(DocSettings:getSidecarDir(html_path, "doc"))
    end
    return dirs
end

function Reader.clear_sidecars(html_path)
    for _, dir in ipairs(sidecar_dirs(html_path)) do
        remove_tree(dir)
    end
end

function Reader.reading_root()
    return require("wereadlite.paths").reading_dir()
end

function Reader.reading_dir(book_id)
    local dir = Reader.reading_root() .. "/" .. tostring(book_id or "book")
    mkdir(dir)
    return dir
end

function Reader.html_path(book_id, uid, kind)
    local suffix = kind == "enc" and ".enc.html" or ".html"
    return Reader.reading_dir(book_id) .. "/" .. tostring(uid or "chapter") .. suffix
end

local function html_pair(path)
    path = tostring(path or "")
    if path:find("%.enc%.html$") then
        return path, path:gsub("%.enc%.html$", ".html")
    end
    if path:find("%.html$") then
        return path:gsub("%.html$", ".enc.html"), path
    end
    return path, path
end

local function is_kept_html(full, keep_html)
    if keep_html == "" or full == keep_html then
        return full == keep_html
    end
    local enc, dec = html_pair(keep_html)
    return full == enc or full == dec
end

local function write_html(path, html)
    local file = io.open(path, "wb")
    if not file then
        return nil, "write chapter html failed"
    end
    file:write(html)
    file:close()
    return true
end

function Reader.remove_chapter(html_path)
    html_path = tostring(html_path or "")
    if html_path == "" then
        return
    end
    local enc, dec = html_pair(html_path)
    for _, path in ipairs({ enc, dec }) do
        os.remove(path)
        Reader.clear_sidecars(path)
    end
end

function Reader.cleanup_reading(keep_html)
    keep_html = tostring(keep_html or "")
    local root = Reader.reading_root()
    local lfs = lfs_mod()
    if not lfs or lfs.attributes(root, "mode") ~= "directory" then
        if keep_html == "" then
            remove_tree(root)
        end
        return
    end
    for book in lfs.dir(root) do
        if book ~= "." and book ~= ".." then
            local book_dir = root .. "/" .. book
            if lfs.attributes(book_dir, "mode") == "directory" then
                local keep_here = keep_html == book_dir
                    or keep_html:sub(1, #book_dir + 1) == book_dir .. "/"
                for name in lfs.dir(book_dir) do
                    if name ~= "." and name ~= ".." then
                        local full = book_dir .. "/" .. name
                        if name:find("%.html$") then
                            if not is_kept_html(full, keep_html) then
                                Reader.remove_chapter(full)
                            end
                        elseif name == "img" and keep_here then
                            -- keep cached chapter images for the open book
                        elseif name:find("%.sdr$") then
                            local html = book_dir .. "/" .. name:gsub("%.sdr$", ".html")
                            if not is_kept_html(html, keep_html) then
                                remove_tree(full)
                            end
                        elseif not is_kept_html(full, keep_html) then
                            remove_tree(full)
                        end
                    end
                end
                if not keep_here then
                    os.remove(book_dir)
                end
            elseif book_dir ~= keep_html then
                os.remove(book_dir)
            end
        end
    end
end

local function parse_url_params(html, env)
    local map = {}
    for block in tostring(html or ""):gmatch("{cUid:[^}]+}") do
        local uid = as_text(field(block, "cUid", env))
        local param = as_text(field(block, "param", env))
        if uid ~= "" and is_bc(param) then
            map[uid] = param
        end
    end
    return map
end

local function parse_chapters(html, env, params)
    local chapters, seen = {}, {}
    for block in tostring(html or ""):gmatch("{chapterUid:[^}]+}") do
        local uid = as_text(field(block, "chapterUid", env))
        if uid ~= "" and not seen[uid] then
            seen[uid] = true
            local param = params[uid]
            chapters[#chapters + 1] = {
                uid = uid,
                idx = as_number(field(block, "chapterIdx", env)),
                title = as_text(field(block, "title", env)),
                level = as_number(field(block, "level", env)),
                param = param,
                url = param and Reader.url_for(param) or nil,
            }
        end
    end
    table.sort(chapters, function(a, b)
        return (a.idx or 0) < (b.idx or 0)
    end)
    return chapters
end

local function parse_chapter_objects(html, env)
    local objects = {}
    html = tostring(html or "")
    for name, uid in html:gmatch("([%w_]+)%.chapterUid=([%w_]+)") do
        objects[name] = objects[name] or {}
        objects[name].uid = as_text(Nuxt.scalar(uid, env))
    end
    for name, idx in html:gmatch("([%w_]+)%.chapterIdx=([%w_]+)") do
        objects[name] = objects[name] or {}
        objects[name].idx = as_number(Nuxt.scalar(idx, env))
    end
    for name, quoted in html:gmatch('([%w_]+)%.title="([^"]*)"') do
        objects[name] = objects[name] or {}
        objects[name].title = Nuxt.unescape(quoted)
    end
    for name, tok in html:gmatch("([%w_]+)%.title=([%w_]+)") do
        objects[name] = objects[name] or {}
        if objects[name].title == nil or objects[name].title == "" then
            objects[name].title = as_text(Nuxt.scalar(tok, env))
        end
    end
    return objects
end

local function parse_named_chapter(html, key, env, objects)
    html = tostring(html or "")
    local literal = html:match(key .. ":(%b{})")
    if literal then
        local uid = as_text(Nuxt.scalar(literal:match("chapterUid:([%w_]+)"), env))
        if uid ~= "" then
            return {
                uid = uid,
                idx = as_number(field(literal, "chapterIdx", env)),
                title = as_text(field(literal, "title", env)),
            }
        end
    end
    local token = html:match(key .. ":([%w_]+)")
    if token and objects and objects[token] and objects[token].uid then
        return objects[token]
    end
end

local function parse_url_param(html, key, env)
    local block = tostring(html or ""):match(key .. ":(%b{})")
    if not block then
        return nil
    end
    local uid = as_text(field(block, "cUid", env))
    local param = as_text(field(block, "param", env))
    if uid == "" and not is_bc(param) then
        return nil
    end
    return { uid = uid, param = param }
end

-- Kindle uses isCurChapterNeedToPay to show a last-page buy tip, not to
-- withhold the current chapter body. Only treat real boolean true as paid.
local function as_need_pay(value)
    return value == true or value == "true" or value == "!0"
end

local function parse_need_pay(html, env)
    html = tostring(html or "")
    local start = html:find("window.__NUXT__", 1, true) or 1
    local region = html:sub(start)
    local raw = region:match("isCurChapterNeedToPay:([^,\n}]+)")
    if raw then
        raw = raw:match("^%s*(.-)%s*$") or ""
        if raw == "!0" or raw == "true" then
            return true
        end
        if raw == "!1" or raw == "false" or raw == "null" or raw == "undefined" then
            return false
        end
        if raw:sub(1, 1) == "!" then
            local inner = Nuxt.scalar(raw:sub(2):match("^[%w_]+") or "", env)
            if type(inner) == "boolean" then
                return not inner
            end
            return false
        end
        local tok = raw:match("^[%w_]+")
        if tok then
            return as_need_pay(Nuxt.scalar(tok, env))
        end
    end
    return as_need_pay(Nuxt.parse_field(region, "isCurChapterNeedToPay", env))
end

function Reader.parse(html)
    local env = Nuxt.env(html)
    local params = parse_url_params(html, env)
    local chapters = parse_chapters(html, env, params)
    local objects = parse_chapter_objects(html, env)
    local book_info = Nuxt.parse_field(html, "bookInfo", env)
    if type(book_info) ~= "table" then
        book_info = {}
    end
    local book_id = as_text(book_info.bookId or book_info.book_id)
    local title = as_text(book_info.title)
    if book_id == "" then
        local info = tostring(html or ""):match("bookInfo:(%b{})") or ""
        book_id = as_text(Nuxt.scalar(info:match("bookId:([%w_]+)"), env))
        if title == "" then
            local quoted = info:match('title:"([^"]+)"')
            title = quoted and Nuxt.unescape(quoted) or as_text(book_id)
        end
    elseif title == "" then
        title = as_text(book_id)
    end
    local cur = parse_named_chapter(html, "curChapter", env, objects)
        or parse_url_param(html, "curChapterUrlParam", env)
    local first = parse_named_chapter(html, "firstChapter", env, objects)
    local last = parse_named_chapter(html, "lastChapter", env, objects)
    local next_p = parse_url_param(html, "nextChapterUrlParam", env)
    local prev_p = parse_url_param(html, "prevChapterUrlParam", env)
    local cur_p = parse_url_param(html, "curChapterUrlParam", env)
    local section = as_number(Nuxt.scalar(html:match("curChapterSection:([%w_]+)"), env))
    local section_count = 0
    local sections = html:match("chapterSections:(%b[])")
    if sections then
        for _ in sections:gmatch("%b{}") do
            section_count = section_count + 1
        end
    end
    -- Saved reading position inside the chapter (WeRead chapterOffset).
    local chapter_offset = as_number(html:match("chapterOffset:(%d+)"))
    if not chapter_offset or chapter_offset == 0 then
        chapter_offset = as_number(Nuxt.scalar(html:match("chapterOffset:([%w_]+)"), env))
    end
    local count = as_number(Nuxt.scalar(html:match("chapterInfoCount:([%w_]+)"), env))
    local paid = parse_need_pay(html, env)
    return {
        book_id = book_id,
        book_title = title,
        book_info = book_info,
        chapters = chapters,
        params = params,
        cur = cur,
        first = first,
        last = last,
        next_param = next_p,
        prev_param = prev_p,
        cur_param = cur_p,
        section = section,
        section_count = section_count,
        chapter_offset = chapter_offset,
        chapter_count = count,
        need_pay = paid,
        book_version = as_number(book_info.version or book_info.bookVersion),
        token = tostring(html or ""):match('reader:{bookId:[%w_]+,token:"([^"]+)"') or "",
        env = env,
    }
end

local function query_bc(url)
    return tostring(url or ""):match("[?&]bc=([^&]+)")
end

function Reader.next_url(state)
    if not state then
        return nil
    end
    local param = state.next_param and state.next_param.param
    if is_bc(param) then
        return Reader.url_for(param)
    end
    local uid = state.next_param and tostring(state.next_param.uid or "")
    if uid ~= "" and is_bc(state.params and state.params[uid]) then
        return Reader.url_for(state.params[uid])
    end
    local cur_idx = state.cur and tonumber(state.cur.idx)
    if cur_idx then
        for _, chapter in ipairs(state.chapters or {}) do
            if (tonumber(chapter.idx) or 0) > cur_idx and is_bc(chapter.param) then
                return Reader.url_for(chapter.param)
            end
        end
    end
end

function Reader.is_last(state)
    if not state then
        return true
    end
    local cur = state.cur and tostring(state.cur.uid or "")
    local last = state.last and tostring(state.last.uid or "")
    if cur ~= "" and last ~= "" and cur == last then
        return true
    end
    return Reader.next_url(state) == nil
end

local function query_escape(value)
    return (tostring(value or ""):gsub("[^%w%-_%.~]", function(ch)
        return string.format("%%%02X", string.byte(ch))
    end))
end

local function catalog_api_error(data)
    if type(data) ~= "table" then
        return "http_error", "invalid catalog payload"
    end
    if tonumber(data.sessionTimeout) == 1 then
        return "auth_expired", "sessionTimeout"
    end
    if data.succ ~= nil and tonumber(data.succ) ~= 1 then
        return "http_error", tostring(data.errMsg or data.errmsg or "catalogLoadMore fail")
    end
end

local function chapters_from_catalog(infos, url_rows)
    local params = {}
    for _, row in ipairs(url_rows or {}) do
        if type(row) == "table" then
            local uid = as_text(row.cUid or row.chapterUid)
            local param = as_text(row.param)
            if uid ~= "" and is_bc(param) then
                params[uid] = param
            end
        end
    end
    local chapters = {}
    for _, info in ipairs(infos or {}) do
        if type(info) == "table" then
            local uid = as_text(info.chapterUid or info.uid)
            if uid ~= "" then
                local param = params[uid]
                chapters[#chapters + 1] = {
                    uid = uid,
                    idx = as_number(info.chapterIdx or info.idx),
                    title = as_text(info.title),
                    level = as_number(info.level),
                    param = param,
                    url = param and Reader.url_for(param) or nil,
                }
            end
        end
    end
    return chapters
end

function Reader.fetch_catalog_page(book_id, typ, range_start, range_end)
    local url = string.format(
        "%s?type=%s&bookId=%s&rangeStart=%s&rangeEnd=%s&platform=desktop",
        Config.CATALOG_MORE_URL,
        query_escape(typ),
        query_escape(book_id),
        query_escape(range_start or 0),
        query_escape(range_end or 0)
    )
    Log.dbg("reader", "catalog_fetch", {
        book_id = book_id,
        typ = typ,
        range_start = range_start,
        range_end = range_end,
        url = url,
    })
    local body, status, err = Client.request({
        url = url,
        accept = "application/json, */*;q=0.8",
        referer = Config.READER_URL,
        timeout = 20,
    })
    if not body then
        return nil, status or "http_error", err
    end
    local data, decode_err = Json.decode(body)
    if not data then
        return nil, "http_error", decode_err
    end
    local err_status, err_msg = catalog_api_error(data)
    if err_status then
        return nil, err_status, err_msg
    end
    local infos = data.chapterInfos or data.chapterInfo or {}
    local urls = data.readerUrlParmas or data.readerUrlParams or {}
    return chapters_from_catalog(infos, urls)
end

function Reader.expand_catalog(state)
    if not state then
        return {}
    end
    local existing = state.chapters or {}
    local book_id = as_text(state.book_id)
    local total = as_number(state.chapter_count)
    if book_id == "" or book_id == "nil" then
        return existing
    end
    if total > 0 and #existing >= total then
        return existing
    end
    local by_uid = {}
    local function absorb(list)
        for _, chapter in ipairs(list or {}) do
            local uid = as_text(chapter.uid)
            if uid ~= "" then
                local prev = by_uid[uid]
                if not prev then
                    by_uid[uid] = chapter
                else
                    if (not prev.param or prev.param == "") and is_bc(chapter.param) then
                        prev.param = chapter.param
                        prev.url = chapter.url or Reader.url_for(chapter.param)
                    end
                    if (not prev.title or prev.title == "") and chapter.title and chapter.title ~= "" then
                        prev.title = chapter.title
                    end
                    if (not prev.idx or prev.idx == 0) and chapter.idx then
                        prev.idx = chapter.idx
                    end
                    if (not prev.level or prev.level == 0) and chapter.level then
                        prev.level = chapter.level
                    end
                end
            end
        end
    end
    absorb(existing)
    local first, status, err = Reader.fetch_catalog_page(book_id, 3, 0, #existing)
    if not first then
        Log.warn("reader", "catalog_first", { status = status, err = err })
        return existing
    end
    absorb(first)
    local range_start, range_end = 0, #first
    local guard = 0
    local function count()
        local n = 0
        for _ in pairs(by_uid) do
            n = n + 1
        end
        return n
    end
    while guard < 40 and (total <= 0 or count() < total) do
        guard = guard + 1
        local more, more_status, more_err = Reader.fetch_catalog_page(book_id, 2, range_start, range_end)
        if not more or #more == 0 then
            if more_status then
                Log.warn("reader", "catalog_more", { status = more_status, err = more_err })
            end
            break
        end
        local before = count()
        absorb(more)
        if count() <= before then
            break
        end
        range_end = range_end + #more
    end
    local list = {}
    for _, chapter in pairs(by_uid) do
        list[#list + 1] = chapter
    end
    table.sort(list, function(a, b)
        return (a.idx or 0) < (b.idx or 0)
    end)
    Log.info("reader", "catalog_ready", { book_id = book_id, chapters = #list, total = total })
    return list
end

function Reader.fetch(url)
    local cached = read_prefetch(url)
    if cached then return cached end
    Log.dbg("reader", "fetch", { url = url })
    local body, status, err = Client.request({
        url = url,
        accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        referer = Config.READER_URL,
        timeout = 30,
    })
    if status == "auth_expired" then
        Log.warn("reader", "fetch_auth", { url = url })
        return nil, "auth_expired", err
    end
    if not body or status ~= "ok" then
        Log.warn("reader", "fetch_fail", { url = url, status = status, err = err })
        return nil, status or "http_error", err
    end
    if body:find("扫码登录", 1, true) and not body:find("readerContent", 1, true) then
        Log.warn("reader", "fetch_login_page", { url = url, bytes = #body })
        return nil, "auth_expired"
    end
    Log.dbg("reader", "fetch_ok", { url = url, bytes = #body })
    return body
end

function Reader.prefetch_next(state)
    local url = Reader.next_url(state)
    if not url then return end
    if has_prefetch(url) then
        return
    end
    if Reader._prefetch_job then
        AsyncHttp.cancel(Reader._prefetch_job)
        Reader._prefetch_job = nil
    end
    Log.info("reader", "prefetch_start", { url = url })
    Reader._prefetch_job = AsyncHttp.request({
        url = url,
        timeout = 30,
        accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        referer = Config.READER_URL,
        send_cookie = true,
        absorb_cookies = true,
    }, function(res)
        Reader._prefetch_job = nil
        if not res or not res.ok or not res.body or #res.body == 0 then
            Log.warn("reader", "prefetch_fail", { url = url, status = res and res.status, err = res and res.err })
            return
        end
        local path = prefetch_path(url)
        local file = io.open(path .. ".tmp", "wb")
        if file then
            file:write(res.body)
            file:close()
            os.rename(path .. ".tmp", path)
            Log.info("reader", "prefetch_done", { url = url, bytes = #res.body })

            -- The first response is only a probe.  The chapter loader also
            -- fetches each `sect` URL, so prefetch those bodies too.
            local ok_parse, probe = pcall(Reader.parse, res.body)
            local bc = url:match("[?&]bc=([^&]+)")
            if ok_parse and type(probe) == "table" then
                bc = (probe.cur and probe.cur.param) or bc
            end
            local total = ok_parse and tonumber(probe.section_count) or 1
            total = math.max(1, total or 1)
            if is_bc(bc) and total > 0 then
                local pending, active, done = {}, 0, 0
                for sect = 0, total - 1 do
                    local sect_url = Reader.url_for(bc, { sect = sect })
                    if not has_prefetch(sect_url) then pending[#pending + 1] = sect_url end
                end
                local pump
                pump = function()
                    while active < 2 and #pending > 0 do
                        local sect_url = table.remove(pending, 1)
                        active = active + 1
                        AsyncHttp.request({
                            url = sect_url,
                            timeout = 30,
                            accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                            referer = Config.READER_URL,
                            send_cookie = true,
                            absorb_cookies = true,
                        }, function(section_res)
                            active = active - 1
                            done = done + 1
                            if section_res and section_res.ok and section_res.body and #section_res.body > 0 then
                                local section_path = prefetch_path(sect_url)
                                local section_file = io.open(section_path .. ".tmp", "wb")
                                if section_file then
                                    section_file:write(section_res.body)
                                    section_file:close()
                                    os.rename(section_path .. ".tmp", section_path)
                                    Log.dbg("reader", "prefetch_section_done", { sect = sect, bytes = #section_res.body })
                                end
                            else
                                Log.warn("reader", "prefetch_section_fail", { url = sect_url })
                            end
                            if #pending > 0 then pump() end
                            if active == 0 and #pending == 0 then
                                Log.info("reader", "prefetch_sections_done", { total = done })
                            end
                        end)
                    end
                end
                pump()
            end
        end
    end)
end

-- Full prefetch implementation: reuse the exact Reader.load pipeline so the
-- next chapter is decoded, localized, annotated, and written as a ready HTML
-- document before the user opens it.  This later declaration intentionally
-- replaces the legacy raw-response prefetch above.
function Reader.prefetch_next(state, book)
    local url = Reader.next_url(state)
    if not url then return end
    local next_uid = state.next_param and tostring(state.next_param.uid or "") or ""
    if next_uid ~= "" then
        local existing = io.open(Reader.html_path(state.book_id, next_uid), "rb")
        if existing then
            existing:close()
            Log.info("reader", "prefetch_already_ready", { uid = next_uid })
            return
        end
    end
    if Reader._prefetch_job and type(Reader._prefetch_job.cancel) == "function" then
        pcall(Reader._prefetch_job.cancel, Reader._prefetch_job)
        Reader._prefetch_job = nil
    end
    Log.info("reader", "prefetch_start", { url = url, mode = "full" })
    local prefetch_book = book or state.book_info or { bookId = state.book_id, title = state.book_title }
    local called, result, status, err = pcall(Reader.load, url, prefetch_book, nil, function(prefetched, ready_status, ready_err)
        Reader._prefetch_job = nil
        if prefetched then
            Reader._prefetched[url] = prefetched
            Log.info("reader", "prefetch_done", { url = url, html = prefetched.html_path, mode = "full" })
        else
            Log.warn("reader", "prefetch_fail", { url = url, status = ready_status, err = ready_err })
        end
    end)
    if not called then
        Reader._prefetch_job = nil
        Log.warn("reader", "prefetch_throw", { url = url, err = result })
    elseif status == "pending" then
        Reader._prefetch_job = err
    elseif result then
        Reader._prefetch_job = nil
        Log.info("reader", "prefetch_done", { url = url, html = result.html_path, mode = "full" })
    end
end

local function html_escape(text)
    return tostring(text or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

local function html_entity(text)
    return tostring(text or ""):gsub("&nbsp;", " "):gsub("&quot;", '"')
        :gsub("&#39;", "'"):gsub("&apos;", "'"):gsub("&amp;", "&")
        :gsub("&#(%d+);", function(n) return string.char(tonumber(n) or 32) end)
        :gsub("&#x([%da-fA-F]+);", function(n) return string.char(tonumber(n, 16) or 32) end)
end

local function find_text_in_html(html, wanted)
    wanted = html_entity(wanted):gsub("%s+", " ")
    local plain, starts, ends = {}, {}, {}
    local p, n = 1, 0
    while p <= #html do
        local a, b = html:find("<[^>]*>", p)
        local stop = a or (#html + 1)
        if stop > p then
            local chunk = html_entity(html:sub(p, stop - 1))
            for i = 1, #chunk do
                local c = chunk:sub(i, i)
                if not c:match("%s") then
                    local width = #c
                    n = n + width
                    plain[n] = c
                    for j = n - width + 1, n do
                        starts[j], ends[j] = p + i - 1, p + i - 1
                    end
                elseif plain[n] ~= " " then
                    n = n + 1
                    plain[n], starts[n], ends[n] = " ", p + i - 1, p + i - 1
                end
            end
        end
        if not a then break end
        p = b + 1
    end
    local text = table.concat(plain)
    local at = text:find(wanted, 1, true)
    if not at then return nil end
    return starts[at], ends[at + #wanted - 1]
end

local function underline_html_range(html, start_at, finish_at, id)
    local out, cursor = {}, 1
    while cursor <= #html do
        local tag_start, tag_end = html:find("<[^>]*>", cursor)
        local text_end = tag_start and (tag_start - 1) or #html
        if text_end >= cursor then
            local left = math.max(cursor, start_at)
            local right = math.min(text_end, finish_at)
            if left <= right then
                out[#out + 1] = html:sub(cursor, left - 1)
                out[#out + 1] = '<span class="wereadlite-highlight" data-wereadlite-review="'
                    .. id .. '" style="text-decoration: underline;">'
                out[#out + 1] = html:sub(left, right)
                out[#out + 1] = "</span>"
                out[#out + 1] = html:sub(right + 1, text_end)
            else
                out[#out + 1] = html:sub(cursor, text_end)
            end
        end
        if not tag_start then break end
        out[#out + 1] = html:sub(tag_start, tag_end)
        cursor = tag_end + 1
    end
    return table.concat(out)
end

local function add_highlight_reviews(body, book_id, chapter_uid)
    Reader.review_data = {}
    Reader.review_marks = {}
    Log.info("reader", "highlight_reviews_start", { book_id = book_id, chapter_uid = chapter_uid, body_bytes = #tostring(body or "") })
    local ok, marks = pcall(Skill.chapter_highlights, book_id, chapter_uid)
    if not ok or type(marks) ~= "table" or #marks == 0 then
        Log.warn("reader", "highlight_reviews_none", { ok = ok, type = type(marks), count = type(marks) == "table" and #marks or 0 })
        return body, 0
    end
    local notes, count = {}, 0
    for _, mark in ipairs(marks) do
        local text = tostring(mark.text or "")
        if text ~= "" and type(mark.reviews) == "table" and #mark.reviews > 0 then
            local at, finish_at = find_text_in_html(body, text)
            if at then
                count = count + 1
                local id = "wereadlite_review_" .. tostring(count)
                Reader.review_data[id] = mark.reviews
                Reader.review_marks[#Reader.review_marks + 1] = { id = id, text = text, reviews = mark.reviews }
                local review_lines = {}
                for _, review in ipairs(mark.reviews) do
                    review_lines[#review_lines + 1] = "<p>" .. html_escape(type(review) == "table" and review.content or review) .. "</p>"
                end
                body = underline_html_range(body, at, finish_at, id)
                Log.dbg("reader", "highlight_range", { start = at, finish = finish_at, bytes = finish_at - at + 1 })
                notes[#notes + 1] = '<aside epub:type="footnote" id="' .. id .. '" class="wereadlite-review">'
                    .. table.concat(review_lines) .. "</aside>"
                Log.dbg("reader", "highlight_match", { index = count, text_bytes = #text, reviews = #mark.reviews, range = mark.range })
            else
                Log.warn("reader", "highlight_no_match", { text_bytes = #text, range = mark.range })
            end
        end
    end
    if count > 0 then
        body = body .. '<section class="wereadlite-reviews">' .. table.concat(notes) .. "</section>"
    end
    Log.info("reader", "highlight_reviews_done", { injected = count, available = #marks })
    return body, count
end

function Reader.load(url, book, on_progress, on_ready)
    book = book or {}
    local function report(stage, done, total)
        if type(on_progress) == "function" then
            pcall(on_progress, stage, done, total)
        end
    end
    report("download", 0, 1)
    Log.dbg("reader", "load_start", {
        url = url,
        book_id = book.bookId,
        title = book.title,
    })
    local html, status, err = Reader.fetch(url)
    if not html then
        Log.warn("reader", "load_fetch", { url = url, status = status, err = err })
        return nil, status, err
    end
    report("download", 1, 1)
    local state = Reader.parse(html)
    Log.dbg("reader", "parse", {
        book_id = state.book_id,
        title = state.book_title,
        uid = state.cur and state.cur.uid,
        idx = state.cur and state.cur.idx,
        chapters = #(state.chapters or {}),
        section = state.section,
        section_count = state.section_count,
        need_pay = state.need_pay,
        has_token = state.token ~= nil and state.token ~= "",
        bytes = #html,
    })
    if state.cur then
        local uid = tostring(state.cur.uid or "")
        if uid ~= "" then
            state.cur.param = state.cur.param or state.params[uid]
            for _, chapter in ipairs(state.chapters) do
                if chapter.uid == uid then
                    state.cur.title = state.cur.title ~= nil and state.cur.title ~= "" and state.cur.title or chapter.title
                    state.cur.idx = state.cur.idx or chapter.idx
                    break
                end
            end
        end
    end
    if book.bookId and (state.book_id == "" or state.book_id == "nil") then
        state.book_id = tostring(book.bookId)
    end
    if book.title and (state.book_title == "" or state.book_title == state.book_id) then
        state.book_title = book.title
    end
    if type(state.book_info) ~= "table" then
        state.book_info = {}
    end
    if state.book_id ~= "" and state.book_id ~= "nil" then
        state.book_info.bookId = state.book_info.bookId or state.book_id
        state.book_info.title = (as_text(state.book_info.title) ~= "" and state.book_info.title) or state.book_title
        if book.cover and as_text(state.book_info.cover) == "" then
            state.book_info.cover = book.cover
        end
        if book.author and as_text(state.book_info.author) == "" then
            state.book_info.author = book.author
        end
        if (not state.book_version or state.book_version == 0) then
            state.book_version = as_number(state.book_info.version or state.book_info.bookVersion)
        end
        pcall(BookDb.save, state.book_info)
    end
    local pages = {}
    local bc = query_bc(url)
    if is_bc(state.cur and state.cur.param) then
        bc = state.cur.param
    elseif is_bc(state.cur_param and state.cur_param.param) then
        bc = state.cur_param.param
    end
    -- Always re-fetch every section 0..N-1. The probe response is only for
    -- metadata (section count / resume offset); never reuse it as body.
    local cur_sect = math.max(0, tonumber(state.section) or 0)
    local section_count = tonumber(state.section_count) or 0
    if section_count < 1 then
        section_count = 1
    end
    local last_sect = section_count - 1
    if is_bc(bc) then
        local total = last_sect + 1
        report("download", 0, total)
        Log.dbg("reader", "sections", {
            cur = cur_sect,
            last = last_sect,
            total = total,
            offset = state.chapter_offset,
            refetch = true,
        })
        for sect = 0, last_sect do
            Log.dbg("reader", "section_fetch", { sect = sect })
            local page = Reader.fetch(Reader.url_for(bc, { sect = sect }))
            if not page then
                if sect == 0 then
                    return nil, "http_error", "chapter section 0 missing"
                end
                Log.warn("reader", "section_skip", { sect = sect })
                break
            end
            pages[#pages + 1] = page
            report("download", #pages, total)
        end
    else
        pages[1] = html
    end
    if #pages == 0 then
        return nil, "http_error", "chapter empty"
    end
    report("download", #pages, #pages)

    local font_path = ""
    if not Codec.has_map() then
        font_path = Codec.ensure_font()
    end
    local function collect_content(source, decode)
        local ok, part = pcall(Codec.reader_content, source, decode)
        if ok and part and part ~= "" then
            return part
        end
    end
    report("load", 0, #pages)
    local encrypted, decrypted = {}, {}
    local source_css = ""
    for i, page in ipairs(pages) do
        if source_css == "" then
            source_css = Codec.reader_styles(page)
        end
        local dec_part = collect_content(page, true)
        if not dec_part then
            if i == 1 then
                if state.need_pay then
                    return nil, "need_pay", "本章需要购买"
                end
                return nil, "http_error", "readerContent missing"
            end
            break
        end
        decrypted[#decrypted + 1] = dec_part
        encrypted[#encrypted + 1] = collect_content(page, false) or ""
        Log.dbg("reader", "decode", { page = i, pages = #pages, bytes = #dec_part })
        report("load", i, #pages)
    end
    if state.need_pay then
        Log.info("reader", "need_pay_ignored", { book_id = state.book_id })
    end
    local chapter_title = (state.cur and state.cur.title) or state.book_title or ""
    local uid = (state.cur and state.cur.uid) or (state.cur_param and state.cur_param.uid) or "chapter"
    local dir = Reader.reading_dir(state.book_id)
    local path = Reader.html_path(state.book_id, uid)
    local enc_path = Reader.html_path(state.book_id, uid, "enc")
    report("load", #pages, #pages)

    -- Mark resume point at the start of the saved section for CRE anchor jump.
    local RESUME_ID = "wereadlite_resume"
    local resume_index = math.min(#decrypted, math.max(1, cur_sect + 1))
    if #decrypted > 0 and cur_sect > 0 then
        decrypted[resume_index] = '<a id="' .. RESUME_ID .. '"></a>' .. decrypted[resume_index]
    end

    local body = table.concat(decrypted, "\n")
    local postprocess_started = Log.now_ms()
    local plain = body:gsub("<[^>]+>", ""):gsub("%s+", "")
    local chars = 0
    for _ in plain:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars = chars + 1
    end
    local resume_percent = 0
    local offset = tonumber(state.chapter_offset) or 0
    if offset > 0 and chars > 0 then
        resume_percent = math.max(0, math.min(100, (offset / chars) * 100))
    elseif cur_sect > 0 and section_count > 0 then
        resume_percent = math.max(0, math.min(100, (cur_sect / section_count) * 100))
    end
    -- chapterOffset is more precise than a section boundary. Keep the coarse
    -- anchor only as a fallback when the response has no character offset.
    state.resume_anchor = (offset <= 0 and cur_sect > 0) and RESUME_ID or nil
    state.resume_percent = resume_percent
    Log.dbg("reader", "postprocess", {
        body_bytes = #body,
        chars = chars,
        elapsed_ms = math.floor((Log.now_ms() - postprocess_started) + 0.5),
    })

    local wrap_started = Log.now_ms()
    local decrypted_source = Codec.wrap_html({
        title = chapter_title,
        body = body,
        font_path = font_path,
        source_css = source_css,
    })
    local encrypted_source = Codec.wrap_html({
        title = chapter_title,
        body = table.concat(encrypted, "\n"),
        font_path = font_path,
        source_css = source_css,
        encrypted = true,
    })
    Log.dbg("reader", "wrap", {
        css_bytes = #source_css,
        decrypted_bytes = #decrypted_source,
        elapsed_ms = math.floor((Log.now_ms() - wrap_started) + 0.5),
    })

    local function finish(decrypted_html)
        -- Highlights and reviews are a separate post-image stage.  Keeping
        -- this out of decode/wrap ensures image localization always finishes
        -- first and a Skill failure cannot interfere with image caching.
        if not Settings.load_review_comments() then
            Reader.review_data = {}
            Reader.review_marks = {}
            Log.info("reader", "reviews_stage_skip", { reason = "disabled" })
        else
        report("reviews", 0, 1)
        Log.info("reader", "reviews_stage_start", {
            book_id = state.book_id,
            chapter_uid = state.cur and state.cur.uid,
        })
        local marked_html, review_count = add_highlight_reviews(
            decrypted_html, state.book_id, state.cur and state.cur.uid
        )
        decrypted_html = marked_html
        report("reviews", 1, 1)
        Log.info("reader", "reviews_stage_done", { count = review_count })
        end
        -- Encrypted backup only remaps resources already cached above.
        local encrypted_html = Images.localize(encrypted_source, dir, nil, { fetch = false })
        if not write_html(path, decrypted_html) then
            return nil, "http_error", "write chapter html failed"
        end
        write_html(enc_path, encrypted_html)
        state.url = url
        state.html_path = path
        state.html_enc_path = enc_path
        state.chapter_title = chapter_title
        Log.info("reader", "chapter_ready", {
            book_id = state.book_id,
            uid = uid,
            title = chapter_title,
            html = path,
            sections = #pages,
            resume_percent = resume_percent,
            resume_anchor = state.resume_anchor,
            chapter_offset = offset,
        })
        return state
    end

    if type(on_ready) == "function" then
        local task = Images.localize_async(decrypted_source, dir, function(done, total)
            report("images", done, total)
        end, function(decrypted_html)
            local ready, ready_status, ready_err = finish(decrypted_html)
            on_ready(ready, ready_status, ready_err)
        end)
        return nil, "pending", task
    end

    local decrypted_html = Images.localize(decrypted_source, dir, function(done, total)
        report("images", done, total)
    end)
    return finish(decrypted_html)
end

return Reader
