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
local UIManager = require("ui/uimanager")

local Reader = {}
Reader._prefetch_job = nil
Reader._prefetch_url = nil
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

function Reader.html_path(book_id, uid, kind, section_start, section_end)
    local suffix = kind == "enc" and ".enc.html" or ".html"
    local name = tostring(uid or "chapter")
    -- Include the loaded section window so 触底续载 writes a new file instead of
    -- overwriting the open document (switchDocument would otherwise delete it).
    if section_start ~= nil and section_end ~= nil then
        name = string.format(
            "%s_%d-%d",
            name,
            math.max(0, tonumber(section_start) or 0),
            math.max(0, tonumber(section_end) or 0)
        )
    end
    return Reader.reading_dir(book_id) .. "/" .. name .. suffix
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

function Reader.has_more_sections(state)
    if not state then
        return false
    end
    local count = tonumber(state.section_count) or 0
    if count < 2 then
        return false
    end
    local last = tonumber(state.section_end)
    if last == nil then
        return false
    end
    return last < count - 1
end

-- URL + absolute start sect for loading the next segment window after section_end.
function Reader.continue_sections_request(state)
    if not Reader.has_more_sections(state) then
        return nil
    end
    local bc = query_bc(state and state.url)
    if is_bc(state.cur and state.cur.param) then
        bc = state.cur.param
    elseif is_bc(state.cur_param and state.cur_param.param) then
        bc = state.cur_param.param
    end
    if not is_bc(bc) then
        return nil
    end
    local next_start = (tonumber(state.section_end) or 0) + 1
    local count = math.max(1, tonumber(state.section_count) or 1)
    if next_start >= count then
        return nil
    end
    return Reader.url_for(bc, { sect = next_start }), next_start
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

-- Prefetch uses Reader.load with opts.background so downloads are async and
-- each stage yields via UIManager:nextTick. Same URL may later be adopted by
-- Reading.open_url instead of starting a second load.
function Reader.is_prefetching(url)
    url = tostring(url or "")
    local job = Reader._prefetch_job
    return url ~= ""
        and Reader._prefetch_url == url
        and type(job) == "table"
        and not job.cancelled
end

function Reader.adopt_prefetch(url, on_progress, on_ready)
    url = tostring(url or "")
    if not Reader.is_prefetching(url) then
        return false
    end
    local job = Reader._prefetch_job
    Reader._prefetch_job = nil
    Reader._prefetch_url = nil
    job.adopted = true
    if type(on_progress) == "function" then
        job.on_progress = on_progress
    end
    job.on_ready = function(state, status, err)
        if type(on_ready) == "function" then
            on_ready(state, status, err)
        end
    end
    Log.info("reader", "prefetch_adopted", { url = url })
    return true, job
end

function Reader.prefetch_next(state, book)
    local url = Reader.next_url(state)
    if not url then
        return
    end
    if Reader._prefetched[url] then
        Log.info("reader", "prefetch_already_cached", { url = url })
        return
    end
    local next_uid = state.next_param and tostring(state.next_param.uid or "") or ""
    if next_uid ~= "" then
        local existing = io.open(Reader.html_path(state.book_id, next_uid), "rb")
        if existing then
            existing:close()
            Log.info("reader", "prefetch_already_ready", { uid = next_uid })
            return
        end
    end
    if Reader.is_prefetching(url) then
        Log.dbg("reader", "prefetch_already_running", { url = url })
        return
    end
    Reader.cancel_prefetch()
    Log.info("reader", "prefetch_start", { url = url, mode = "background" })
    local prefetch_book = book or state.book_info or { bookId = state.book_id, title = state.book_title }
    local prefetch_opts = { background = true, prefetch = true }
    local job_ref
    local function on_prefetch_ready(prefetched, ready_status, ready_err)
        -- If adopted, on_ready was replaced; this callback is no longer invoked.
        if Reader._prefetch_url == url then
            Reader._prefetch_url = nil
        end
        if job_ref and Reader._prefetch_job == job_ref then
            Reader._prefetch_job = nil
        end
        if prefetched then
            Reader._prefetched[url] = prefetched
            Log.info("reader", "prefetch_done", { url = url, html = prefetched.html_path, mode = "background" })
        else
            Log.warn("reader", "prefetch_fail", { url = url, status = ready_status, err = ready_err })
        end
    end
    local called, result, status, err = pcall(
        Reader.load, url, prefetch_book, nil, on_prefetch_ready, prefetch_opts
    )
    if not called then
        Reader._prefetch_job = nil
        Reader._prefetch_url = nil
        Log.warn("reader", "prefetch_throw", { url = url, err = result })
        return
    end
    if status == "pending" then
        job_ref = err
        Reader._prefetch_job = err
        Reader._prefetch_url = url
        return
    end
    Reader._prefetch_job = nil
    Reader._prefetch_url = nil
    if result then
        Reader._prefetched[url] = result
        Log.info("reader", "prefetch_done", { url = url, html = result.html_path, mode = "background" })
    end
end

function Reader.cancel_prefetch()
    local job = Reader._prefetch_job
    local url = Reader._prefetch_url
    Reader._prefetch_job = nil
    Reader._prefetch_url = nil
    if job and type(job.cancel) == "function" then
        pcall(job.cancel, job)
        Log.dbg("reader", "prefetch_cancelled", { url = url })
    end
end

function Reader.clear_prefetched()
    Reader._prefetched = {}
end

-- WeRead encodes per-character offsets on <span wco="N">; API range matches those coords.
-- Inject underlines in O(N + M): one index scan, mark spans, single table.concat emit.
local UNDERLINE_LINK_OPEN = '<a class="wereadlite-highlight" style="color:inherit;-cr-hint:presentational-hint;text-decoration:none;border-bottom:1px dashed currentColor" href="wereadlite://review/'

-- Returns doc (document order) and by_wco (sorted by wco). Entries are shared tables:
-- { wco, open_gt, close_lt [, mark] }
local function build_wco_index(html)
    local doc = {}
    local p, n = 1, #html
    while p <= n do
        local span_start = html:find("<span", p, true)
        if not span_start then
            break
        end
        local open_end = span_start + 5
        local next_ch = html:sub(open_end, open_end)
        -- Only real <span ...> tags, not <spanish> / <spanfoo>.
        if next_ch ~= ">" and next_ch ~= "/" and not next_ch:match("%s") then
            p = open_end
        else
            local gt = html:find(">", span_start, true)
            if not gt then
                break
            end
            local open = html:sub(span_start + 1, gt - 1)
            local self_closing = open:match("/%s*$") ~= nil
            local wco = tonumber(open:match('wco%s*=%s*"(%d+)"'))
            local close_lt
            if self_closing then
                close_lt = nil
            else
                -- Match the corresponding </span>, not the first nested closer.
                local depth, q = 1, gt + 1
                while q <= n and depth > 0 do
                    local next_open = html:find("<span", q, true)
                    local next_close = html:find("</span>", q, true)
                    if not next_close then
                        break
                    end
                    if next_open and next_open < next_close then
                        local oe = next_open + 5
                        local ch = html:sub(oe, oe)
                        if ch == ">" or ch == "/" or ch:match("%s") then
                            local ogt = html:find(">", next_open, true) or next_open
                            local o = html:sub(next_open + 1, ogt - 1)
                            if not o:match("/%s*$") then
                                depth = depth + 1
                            end
                            q = ogt + 1
                        else
                            q = oe
                        end
                    else
                        depth = depth - 1
                        if depth == 0 then
                            close_lt = next_close
                        end
                        q = next_close + 7
                    end
                end
            end
            if wco and close_lt and close_lt > gt then
                local inner = html:sub(gt + 1, close_lt - 1)
                -- Parent spans (e.g. class="bold") wrap per-char children. Indexing
                -- them makes emit_wco_underlines output the first child twice.
                if not inner:find("<", 1, true) then
                    doc[#doc + 1] = {
                        wco = wco,
                        open_gt = gt,
                        close_lt = close_lt,
                    }
                end
            end
            p = gt + 1
        end
    end
    local by_wco = {}
    for i = 1, #doc do
        by_wco[i] = doc[i]
    end
    table.sort(by_wco, function(a, b)
        return a.wco < b.wco
    end)
    return doc, by_wco
end

local function wco_lower_bound(by_wco, start0)
    local lo, hi, idx = 1, #by_wco, #by_wco + 1
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if by_wco[mid].wco >= start0 then
            idx = mid
            hi = mid - 1
        else
            lo = mid + 1
        end
    end
    return idx
end

local function emit_wco_underlines(html, doc)
    local out = {}
    local cursor = 1
    local marked = 0
    for i = 1, #doc do
        local span = doc[i]
        if cursor <= span.open_gt then
            out[#out + 1] = html:sub(cursor, span.open_gt)
        end
        local text = html:sub(span.open_gt + 1, span.close_lt - 1)
        if span.mark then
            marked = marked + 1
            out[#out + 1] = UNDERLINE_LINK_OPEN
            out[#out + 1] = span.mark
            out[#out + 1] = '">'
            out[#out + 1] = text
            out[#out + 1] = "</a>"
        else
            out[#out + 1] = text
        end
        cursor = span.close_lt
    end
    if cursor <= #html then
        out[#out + 1] = html:sub(cursor)
    end
    return table.concat(out), marked
end

local function parse_range(range)
    range = tostring(range or "")
    local start0, end0 = range:match("^(%d+)%-(%d+)$")
    start0, end0 = tonumber(start0), tonumber(end0)
    if not start0 or not end0 or end0 <= start0 then
        return nil
    end
    return start0, end0
end

local function add_chapter_underlines(body, book_id, chapter_uid, underlines)
    local review_data, review_marks = {}, {}
    body = tostring(body or "")
    underlines = type(underlines) == "table" and underlines or {}
    local t0 = Log.now_ms and Log.now_ms() or nil
    Log.info("reader", "underlines_start", {
        book_id = book_id,
        chapter_uid = chapter_uid,
        body_bytes = #body,
        available = #underlines,
    })
    if #underlines == 0 then
        Log.warn("reader", "underlines_none", { count = 0 })
        return body, 0, review_data, review_marks
    end
    local pending = {}
    for _, item in ipairs(underlines) do
        local range = tostring(item.range or "")
        local start0, end0 = parse_range(range)
        if start0 then
            pending[#pending + 1] = {
                range = range,
                start0 = start0,
                end0 = end0,
                count = tonumber(item.count) or 0,
            }
        end
    end
    local t_index = Log.now_ms and Log.now_ms() or nil
    local doc, by_wco = build_wco_index(body)
    local t_mark = Log.now_ms and Log.now_ms() or nil
    Log.info("reader", "underlines_wco_index", {
        spans = #doc,
        index_ms = t_index and t_mark and math.floor(t_mark - t_index + 0.5) or nil,
    })

    local count = 0
    for _, item in ipairs(pending) do
        local idx = wco_lower_bound(by_wco, item.start0)
        if idx <= #by_wco and by_wco[idx].wco < item.end0 then
            count = count + 1
            local id = "wereadlite_review_" .. tostring(count)
            review_marks[#review_marks + 1] = {
                id = id,
                range = item.range,
                count = item.count,
            }
            local spans = 0
            for i = idx, #by_wco do
                local span = by_wco[i]
                if span.wco >= item.end0 then
                    break
                end
                span.mark = id
                spans = spans + 1
            end
            Log.dbg("reader", "underline_range", {
                index = count,
                range = item.range,
                wco_start = item.start0,
                wco_end = item.end0,
                spans = spans,
            })
        else
            Log.warn("reader", "underline_no_match", {
                range = item.range,
                start0 = item.start0,
                end0 = item.end0,
            })
        end
    end

    local marked_body, marked_spans = emit_wco_underlines(body, doc)
    local t_end = Log.now_ms and Log.now_ms() or nil
    Log.info("reader", "underlines_done", {
        injected = count,
        available = #underlines,
        marked_spans = marked_spans,
        emit_ms = t_mark and t_end and math.floor(t_end - t_mark + 0.5) or nil,
        total_ms = t0 and t_end and math.floor(t_end - t0 + 0.5) or nil,
    })
    return marked_body, count, review_data, review_marks
end

local FETCH_ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

local function load_background_mode(opts, on_ready)
    opts = type(opts) == "table" and opts or {}
    if opts.background == false then
        return false
    end
    if opts.background == true or opts.prefetch == true then
        return true
    end
    -- Default to async when a completion callback exists so Kobo never blocks
    -- the UI thread on LuaSocket/SSL (wantread / DNS stalls).
    return type(on_ready) == "function"
end

local function validate_fetch_body(body)
    body = tostring(body or "")
    if body == "" then
        return nil, "http_error", "empty response"
    end
    if body:find("扫码登录", 1, true) and not body:find("readerContent", 1, true) then
        Log.warn("reader", "fetch_login_page", { bytes = #body })
        return nil, "auth_expired"
    end
    return body
end

local function merge_book_meta(state, book)
    book = book or {}
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
end

local function resolve_bc(state, url)
    local bc = query_bc(url)
    if is_bc(state.cur and state.cur.param) then
        bc = state.cur.param
    elseif is_bc(state.cur_param and state.cur_param.param) then
        bc = state.cur_param.param
    end
    return bc
end

local function fetch_async(url, job, callback)
    url = tostring(url or "")
    if job and job.cancelled then
        return
    end
    local cached = read_prefetch(url)
    if cached then
        UIManager:nextTick(function()
            if not job or not job.cancelled then
                callback(cached, "ok")
            end
        end)
        return
    end
    Log.dbg("reader", "fetch_async", { url = url })
    job.active_http = AsyncHttp.request({
        url = url,
        timeout = 30,
        accept = FETCH_ACCEPT,
        referer = Config.READER_URL,
        user_agent = Config.KINDLE_UA,
        send_cookie = true,
        absorb_cookies = false,
    }, function(res)
        job.active_http = nil
        UIManager:nextTick(function()
            if job and job.cancelled then
                return
            end
            if not res or not res.ok or not res.body or #res.body == 0 then
                callback(nil, res and res.status or "http_error", res and res.err)
                return
            end
            if res.status == "auth_expired" then
                callback(nil, "auth_expired", res.err)
                return
            end
            local body, status, err = validate_fetch_body(res.body)
            callback(body, status, err)
        end)
    end)
end

-- Clamp a section download window around the current reading position.
-- force_start: load forward from that section (触底续载), instead of centering.
-- Keeps absolute WeRead wco / bookmark ranges valid via state.char_base.
local function section_window(section_count, cur_sect, max_segments, force_start)
    local count = math.max(1, tonumber(section_count) or 1)
    local max_n = math.max(1, tonumber(max_segments) or Settings.MAX_SEGMENTS_DEFAULT or 3)
    if force_start ~= nil then
        local start_sect = math.max(0, math.min(count - 1, tonumber(force_start) or 0))
        local last_sect = math.min(count - 1, start_sect + max_n - 1)
        return start_sect, last_sect
    end
    local cur = math.max(0, math.min(count - 1, tonumber(cur_sect) or 0))
    if count <= max_n then
        return 0, count - 1
    end
    local half = math.floor((max_n - 1) / 2)
    local start_sect = cur - half
    if start_sect < 0 then
        start_sect = 0
    end
    local last_sect = start_sect + max_n - 1
    if last_sect >= count then
        last_sect = count - 1
        start_sect = math.max(0, last_sect - max_n + 1)
    end
    return start_sect, last_sect
end

-- Absolute chapter char base of a partial HTML body (min wco), for bookmark/heartbeat.
local function body_char_base(html)
    local min_wco
    for wco in tostring(html or ""):gmatch('wco%s*=%s*"(%d+)"') do
        local n = tonumber(wco)
        if n and (not min_wco or n < min_wco) then
            min_wco = n
        end
    end
    return min_wco or 0
end

local function download_sections_sync(state, url, html, report, opts)
    opts = type(opts) == "table" and opts or {}
    local pages = {}
    local bc = resolve_bc(state, url)
    local section_count = tonumber(state.section_count) or 0
    if section_count < 1 then
        section_count = 1
    end
    local cur_sect = math.max(0, tonumber(state.section) or 0)
    local max_segments = Settings.max_segments_per_load()
    local force_start = opts.segment_start
    local start_sect, last_sect = section_window(section_count, cur_sect, max_segments, force_start)
    state.section_start = start_sect
    state.section_end = last_sect
    if is_bc(bc) then
        local total = last_sect - start_sect + 1
        -- First fetch already returned cur_sect body; reuse it instead of refetching.
        local seed_html = html
        local seed_sect = cur_sect
        local first_needs_net = not (seed_html and start_sect == seed_sect)
        if first_needs_net then
            report("segments", 0, total)
        end
        Log.dbg("reader", "sections", {
            cur = cur_sect,
            start = start_sect,
            last = last_sect,
            total = total,
            chapter_sections = section_count,
            max_segments = max_segments,
            offset = state.chapter_offset,
            reuse_seed = seed_html ~= nil,
            force_start = force_start,
        })
        for sect = start_sect, last_sect do
            local page
            if seed_html and sect == seed_sect then
                page = seed_html
                seed_html = nil
                Log.dbg("reader", "section_reuse", { sect = sect })
            else
                Log.dbg("reader", "section_fetch", { sect = sect })
                page = Reader.fetch(Reader.url_for(bc, { sect = sect }))
            end
            if not page then
                if sect == start_sect then
                    return nil, "http_error", "chapter section missing"
                end
                Log.warn("reader", "section_skip", { sect = sect })
                break
            end
            pages[#pages + 1] = page
            report("segments", #pages, total)
        end
    else
        pages[1] = html
        state.section_start = 0
        state.section_end = 0
        report("segments", 1, 1)
    end
    if #pages == 0 then
        return nil, "http_error", "chapter empty"
    end
    report("segments", #pages, #pages)
    return pages
end

local function download_sections_background(state, url, html, report, job, on_pages, on_fail, opts)
    opts = type(opts) == "table" and opts or {}
    local pages = {}
    local bc = resolve_bc(state, url)
    local section_count = tonumber(state.section_count) or 0
    if section_count < 1 then
        section_count = 1
    end
    local cur_sect = math.max(0, tonumber(state.section) or 0)
    local max_segments = Settings.max_segments_per_load()
    local force_start = opts.segment_start
    local start_sect, last_sect = section_window(section_count, cur_sect, max_segments, force_start)
    state.section_start = start_sect
    state.section_end = last_sect
    if not is_bc(bc) then
        pages[1] = html
        state.section_start = 0
        state.section_end = 0
        report("segments", 1, 1)
        UIManager:nextTick(function()
            if job.cancelled then
                return
            end
            on_pages(pages)
        end)
        return
    end
    local total = last_sect - start_sect + 1
    local seed_html = html
    local seed_sect = cur_sect
    local first_needs_net = not (seed_html and start_sect == seed_sect)
    if first_needs_net then
        report("segments", 0, total)
    end
    Log.dbg("reader", "sections_async", {
        cur = cur_sect,
        start = start_sect,
        last = last_sect,
        total = total,
        chapter_sections = section_count,
        max_segments = max_segments,
        offset = state.chapter_offset,
        reuse_seed = seed_html ~= nil,
        force_start = force_start,
    })
    local sect = start_sect
    local function fetch_next()
        if job.cancelled then
            return
        end
        if sect > last_sect then
            if #pages == 0 then
                on_fail("http_error", "chapter empty")
                return
            end
            report("segments", #pages, total)
            UIManager:nextTick(function()
                if not job.cancelled then
                    on_pages(pages)
                end
            end)
            return
        end
        local function accept_page(page, status, err)
            if job.cancelled then
                return
            end
            if not page then
                if sect == start_sect then
                    on_fail(status or "http_error", err or "chapter section missing")
                    return
                end
                Log.warn("reader", "section_skip", { sect = sect })
                sect = last_sect + 1
                UIManager:nextTick(fetch_next)
                return
            end
            pages[#pages + 1] = page
            report("segments", #pages, total)
            sect = sect + 1
            UIManager:nextTick(fetch_next)
        end
        if seed_html and sect == seed_sect then
            local page = seed_html
            seed_html = nil
            Log.dbg("reader", "section_reuse_async", { sect = sect })
            accept_page(page)
            return
        end
        local sect_url = Reader.url_for(bc, { sect = sect })
        Log.dbg("reader", "section_fetch_async", { sect = sect })
        fetch_async(sect_url, job, accept_page)
    end
    UIManager:nextTick(fetch_next)
end

local function assemble_chapter(state, pages, url, book, on_progress, on_ready, opts, job)
    opts = type(opts) == "table" and opts or {}
    local background = load_background_mode(opts)
    local function progress_cb()
        if job and type(job.on_progress) == "function" then
            return job.on_progress
        end
        return on_progress
    end
    local function ready_cb()
        if job and type(job.on_ready) == "function" then
            return job.on_ready
        end
        return on_ready
    end
    local function report(stage, done, total)
        local cb = progress_cb()
        if type(cb) == "function" then
            pcall(cb, stage, done, total)
        end
    end
    local function invoke_ready(...)
        local cb = ready_cb()
        if type(cb) == "function" then
            return cb(...)
        end
    end
    local function fail(status, err)
        invoke_ready(nil, status, err)
        return nil, status, err
    end
    if job and job.cancelled then
        return
    end

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

    local encrypted, decrypted, source_css = {}, {}, ""
    local cur_sect = math.max(0, tonumber(state.section) or 0)
    local section_count = tonumber(state.section_count) or 0
    if section_count < 1 then
        section_count = 1
    end

    local function after_decode()
        if job and job.cancelled then
            return
        end
        if state.need_pay then
            Log.info("reader", "need_pay_ignored", { book_id = state.book_id })
        end
        local chapter_title = (state.cur and state.cur.title) or state.book_title or ""
        local uid = (state.cur and state.cur.uid) or (state.cur_param and state.cur_param.uid) or "chapter"
        local dir = Reader.reading_dir(state.book_id)
        local path = Reader.html_path(state.book_id, uid, nil, state.section_start, state.section_end)
        local enc_path = Reader.html_path(state.book_id, uid, "enc", state.section_start, state.section_end)
        report("segments", #pages, #pages)

        local RESUME_ID = "wereadlite_resume"
        local start_sect = math.max(0, tonumber(state.section_start) or 0)
        -- pages[1] corresponds to start_sect; map absolute cur_sect into local page index.
        local local_sect = math.max(0, cur_sect - start_sect)
        local resume_index = math.min(#decrypted, math.max(1, local_sect + 1))
        if #decrypted > 0 and cur_sect > start_sect then
            decrypted[resume_index] = '<a id="' .. RESUME_ID .. '"></a>' .. decrypted[resume_index]
        end

        local body = table.concat(decrypted, "\n")
        local char_base = body_char_base(body)
        state.char_base = char_base
        local postprocess_started = Log.now_ms()
        local plain = body:gsub("<[^>]+>", ""):gsub("%s+", "")
        local chars = 0
        for _ in plain:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            chars = chars + 1
        end
        state.loaded_chars = chars
        local resume_percent = 0
        local offset = tonumber(state.chapter_offset) or 0
        -- Resume within the loaded window using absolute chapterOffset vs char_base.
        if offset > 0 and chars > 0 then
            local local_off = math.max(0, offset - char_base)
            resume_percent = math.max(0, math.min(100, (local_off / chars) * 100))
        elseif local_sect > 0 and #decrypted > 0 then
            resume_percent = math.max(0, math.min(100, (local_sect / #decrypted) * 100))
        end
        state.resume_anchor = (offset <= 0 and cur_sect > start_sect) and RESUME_ID or nil
        state.resume_percent = resume_percent
        Log.dbg("reader", "postprocess", {
            body_bytes = #body,
            chars = chars,
            char_base = char_base,
            section_start = start_sect,
            section_end = state.section_end,
            elapsed_ms = math.floor((Log.now_ms() - postprocess_started) + 0.5),
        })

        local encrypted_body = table.concat(encrypted, "\n")

        local function wrap_body(body_html, is_enc)
            return Codec.wrap_html({
                title = chapter_title,
                body = body_html,
                font_path = font_path,
                source_css = source_css,
                encrypted = is_enc and true or nil,
            })
        end

        local function finish_write(decrypted_html, encrypted_html)
            if job and job.cancelled then
                return
            end
            if not write_html(path, decrypted_html) then
                return fail("http_error", "write chapter html failed")
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
                section_start = state.section_start,
                section_end = state.section_end,
                char_base = state.char_base,
                resume_percent = resume_percent,
                resume_anchor = state.resume_anchor,
                chapter_offset = offset,
                background = background,
            })
            if type(ready_cb()) == "function" then
                invoke_ready(state)
            end
            return state
        end

        -- Images first, then underlines: progress stages stay monotonic and match UI copy.
        local function finalize_with_body(final_body)
            if job and job.cancelled then
                return
            end
            body = final_body or body
            local wrap_started = Log.now_ms()
            local decrypted_source = wrap_body(body, false)
            local encrypted_source = wrap_body(encrypted_body, true)
            Log.dbg("reader", "wrap", {
                css_bytes = #source_css,
                decrypted_bytes = #decrypted_source,
                elapsed_ms = math.floor((Log.now_ms() - wrap_started) + 0.5),
            })
            -- Image binaries were fetched in the images stage; only remap URLs here.
            local decrypted_html = Images.localize(decrypted_source, dir, nil, { fetch = false })
            local encrypted_html = Images.localize(encrypted_source, dir, nil, { fetch = false })
            return finish_write(decrypted_html, encrypted_html)
        end

        local function run_reviews()
            if job and job.cancelled then
                return
            end
            local function finish_reviews(marked_body, underline_count, review_data, review_marks)
                if job and job.cancelled then
                    return
                end
                state.review_data = review_data or {}
                state.review_marks = review_marks or {}
                report("reviews", 1, 1)
                Log.info("reader", "underlines_stage_done", { count = underline_count or 0 })
                if background then
                    UIManager:nextTick(function()
                        finalize_with_body(marked_body)
                    end)
                else
                    finalize_with_body(marked_body)
                end
            end
            if Settings.load_review_comments() then
                report("reviews", 0, 1)
                local chapter_uid = state.cur and state.cur.uid
                Log.info("reader", "underlines_stage_start", {
                    book_id = state.book_id,
                    chapter_uid = chapter_uid,
                })
                Skill.chapter_underlines_async(state.book_id, chapter_uid, function(underlines, status, err)
                    if job and job.cancelled then
                        return
                    end
                    if type(underlines) ~= "table" then
                        Log.warn("reader", "underlines_fetch_fail", { status = status, err = err })
                        underlines = {}
                    end
                    local marked_body, underline_count, review_data, review_marks = add_chapter_underlines(
                        body, state.book_id, chapter_uid, underlines
                    )
                    finish_reviews(marked_body, underline_count, review_data, review_marks)
                end)
                return
            end
            state.review_data = {}
            state.review_marks = {}
            Log.info("reader", "underlines_stage_skip", { reason = "disabled" })
            report("reviews", 1, 1)
            if background then
                UIManager:nextTick(function()
                    finalize_with_body(body)
                end)
            else
                return finalize_with_body(body)
            end
        end

        local function run_images()
            if job and job.cancelled then
                return
            end
            report("images", 0, 0)
            local decrypted_source = wrap_body(body, false)
            local function after_images()
                if background then
                    UIManager:nextTick(run_reviews)
                else
                    run_reviews()
                end
            end
            if type(ready_cb()) == "function" then
                local task = Images.localize_async(decrypted_source, dir, function(done, total)
                    report("images", done, total)
                end, function(_)
                    -- Only warming the image cache; final HTML is rebuilt after reviews.
                    after_images()
                end)
                if job then
                    job.image_task = task
                end
                return nil, "pending", task
            end
            Images.localize(decrypted_source, dir, function(done, total)
                report("images", done, total)
            end)
            return after_images()
        end

        if background then
            UIManager:nextTick(run_images)
            return nil, "pending"
        end
        run_images()
        return nil, "pending"
    end

    report("segments", #pages, #pages)
    if background then
        local index = 1
        local function decode_next()
            if job and job.cancelled then
                return
            end
            if index > #pages then
                UIManager:nextTick(after_decode)
                return
            end
            local page = pages[index]
            if source_css == "" then
                source_css = Codec.reader_styles(page)
            end
            local dec_part = collect_content(page, true)
            if not dec_part then
                if index == 1 then
                    fail(state.need_pay and "need_pay" or "http_error", state.need_pay and "本章需要购买" or "readerContent missing")
                    return
                end
                UIManager:nextTick(after_decode)
                return
            end
            decrypted[#decrypted + 1] = dec_part
            encrypted[#encrypted + 1] = collect_content(page, false) or ""
            Log.dbg("reader", "decode", { page = index, pages = #pages, bytes = #dec_part, background = true })
            index = index + 1
            UIManager:nextTick(decode_next)
        end
        UIManager:nextTick(decode_next)
        return
    end

    for i, page in ipairs(pages) do
        if source_css == "" then
            source_css = Codec.reader_styles(page)
        end
        local dec_part = collect_content(page, true)
        if not dec_part then
            if i == 1 then
                return fail(state.need_pay and "need_pay" or "http_error", state.need_pay and "本章需要购买" or "readerContent missing")
            end
            break
        end
        decrypted[#decrypted + 1] = dec_part
        encrypted[#encrypted + 1] = collect_content(page, false) or ""
        Log.dbg("reader", "decode", { page = i, pages = #pages, bytes = #dec_part })
    end
    return after_decode()
end

local function load_background(url, book, on_progress, on_ready, opts)
    local job = {
        cancelled = false,
        active_http = nil,
        image_task = nil,
        on_progress = on_progress,
        on_ready = on_ready,
        url = tostring(url or ""),
    }
    function job:cancel()
        if self.cancelled then
            return
        end
        self.cancelled = true
        if self.active_http then
            AsyncHttp.cancel(self.active_http)
            self.active_http = nil
        end
        if self.image_task and type(self.image_task.cancel) == "function" then
            pcall(self.image_task.cancel, self.image_task)
            self.image_task = nil
        end
        local ready = self.on_ready
        self.on_ready = nil
        if type(ready) == "function" then
            UIManager:nextTick(function()
                pcall(ready, nil, "cancelled", "cancelled")
            end)
        end
    end

    local function report(stage, done, total)
        if type(job.on_progress) == "function" then
            pcall(job.on_progress, stage, done, total)
        end
    end

    local function invoke_ready(state, status, err)
        if type(job.on_ready) == "function" then
            job.on_ready(state, status, err)
        end
    end

    Log.dbg("reader", "load_start", {
        url = url,
        book_id = book and book.bookId,
        title = book and book.title,
        background = true,
    })
    -- Stay on "获取书籍信息" until the first HTML response arrives.
    report("info", 0, 0)
    fetch_async(url, job, function(html, status, err)
        if job.cancelled then
            return
        end
        if not html then
            Log.warn("reader", "load_fetch", { url = url, status = status, err = err, background = true })
            invoke_ready(nil, status, err)
            return
        end
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
            background = true,
        })
        merge_book_meta(state, book)
        report("info", 1, 1)
        download_sections_background(state, url, html, report, job, function(pages)
            assemble_chapter(state, pages, url, book, nil, nil, opts, job)
        end, function(fail_status, fail_err)
            if not job.cancelled then
                invoke_ready(nil, fail_status, fail_err)
            end
        end, opts)
    end)
    return nil, "pending", job
end

function Reader.load(url, book, on_progress, on_ready, opts)
    opts = type(opts) == "table" and opts or {}
    if load_background_mode(opts, on_ready) then
        return load_background(url, book, on_progress, on_ready, opts)
    end

    book = book or {}
    local function report(stage, done, total)
        if type(on_progress) == "function" then
            pcall(on_progress, stage, done, total)
        end
    end
    report("info", 0, 0)
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
    merge_book_meta(state, book)
    report("info", 1, 1)
    local pages, pages_status, pages_err = download_sections_sync(state, url, html, report, opts)
    if not pages then
        return nil, pages_status, pages_err
    end
    return assemble_chapter(state, pages, url, book, on_progress, on_ready, opts, nil)
end

return Reader
