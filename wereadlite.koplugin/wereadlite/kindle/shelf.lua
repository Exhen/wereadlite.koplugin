local Config = require("wereadlite.config")
local CookieStore = require("wereadlite.cookie_store")
local Http = require("wereadlite.async_http")
local Json = require("wereadlite.json")
local Log = require("wereadlite.log")
local Nuxt = require("wereadlite.kindle.nuxt")
local Settings = require("wereadlite.settings")

local Shelf = {
    user = nil,
    books = {},
    total = 0,
    next_idx = 0,
    kk_idx = -1,
    eof = false,
}

local function looks_like_login(html)
    html = tostring(html or "")
    if html:find("userInfo:", 1, true) then
        return false
    end
    return html:find("扫码登录", 1, true)
        or html:find("/web/login", 1, true)
        or html:find("getLoginUid", 1, true)
end

local function merge_reader_urls(books, urls)
    local map = {}
    for _, row in ipairs(urls or {}) do
        if type(row) == "table" and row.bId then
            map[tostring(row.bId)] = row.param
        end
    end
    for _, book in ipairs(books or {}) do
        book.reader_param = map[tostring(book.bookId or "")]
    end
end

function Shelf.parse_user_info(html)
    local block = tostring(html or ""):match("userInfo:(%b{})")
    if not block then
        return nil
    end
    local vid = tonumber(block:match("userVid:(%d+)"))
    local name = block:match('name:"([^"]*)"')
    local avatar = block:match('avatar:"([^"]*)"')
    local title = block:match('deepVTitle:"([^"]*)"')
    local medal = block:match("medalInfo:(%b{})") or ""
    if not vid then
        return nil
    end
    return {
        user_vid = vid,
        name = Nuxt.unescape(name or ""),
        avatar = Nuxt.unescape(avatar or ""),
        deep_v_title = Nuxt.unescape(title or ""),
        medal_id = medal:match('id:"([^"]*)"'),
        medal_level = tonumber(medal:match("levelIndex:(%d+)")),
        skey = tostring(html or ""):match('user:{vid:"%d+",skey:"([^"]*)"'),
    }
end

function Shelf.sync_session(html)
    local vid = tostring(html or ""):match('user:{vid:"(%d+)",skey:"[^"]*"')
    local skey = tostring(html or ""):match('user:{vid:"%d+",skey:"([^"]*)"')
    local sfs = tostring(html or ""):match('user:{vid:"%d+",skey:"[^"]*",sfs:(%d+)')
    if vid and vid ~= "" then
        CookieStore.set("wr_vid", vid, "nuxt")
    end
    if skey and skey ~= "" then
        CookieStore.set("wr_skey", skey, "nuxt")
    end
    if sfs and sfs ~= "" then
        CookieStore.set("wr_sfs", sfs, "nuxt")
    end
end

function Shelf.parse_books_html(html)
    local env = Nuxt.env(html)
    local books = {}
    for id_token, title, cover, secret_token in tostring(html or ""):gmatch(
        '{bookId:([%w_]+),title:"([^"]*)",cover:"([^"]*)",secret:([%w_]+)}'
    ) do
        local book_id = tostring(Nuxt.resolve(id_token, env) or "")
        if book_id ~= "" then
            books[#books + 1] = {
                bookId = book_id,
                title = Nuxt.unescape(title),
                cover = Nuxt.unescape(cover),
                secret = tonumber(Nuxt.resolve(secret_token, env)) or 0,
            }
        end
    end
    local urls = {}
    for id_token, param in tostring(html or ""):gmatch('{bId:([%w_]+),param:"([^"]*)"}') do
        urls[#urls + 1] = {
            bId = tostring(Nuxt.resolve(id_token, env) or ""),
            param = Nuxt.unescape(param),
        }
    end
    merge_reader_urls(books, urls)
    local total = tonumber(tostring(html or ""):match("totalCount:(%d+)")) or #books
    local kk_idx = tonumber(tostring(html or ""):match("kkIdx:(%-?%d+)")) or -1
    return books, total, kk_idx
end

function Shelf.reset()
    Shelf.user = nil
    Shelf.books = {}
    Shelf.total = 0
    Shelf.next_idx = 0
    Shelf.kk_idx = -1
    Shelf.eof = false
end

local function put_books(idx, books)
    idx = tonumber(idx) or 0
    for i, book in ipairs(books or {}) do
        local pos = idx + i
        if type(book) == "table" and not Shelf.books[pos] then
            Shelf.books[pos] = book
        end
    end
end

local function api_page_size()
    return math.max(1, tonumber(Config.API_PAGE_SIZE) or 20)
end

local function cap_last(last)
    last = math.max(1, tonumber(last) or 1)
    local total = tonumber(Shelf.total) or 0
    if total > 0 then
        last = math.min(last, total)
    end
    return last
end

function Shelf.range_loaded(first, last)
    first = math.max(1, tonumber(first) or 1)
    last = cap_last(last)
    if last < first then
        return true
    end
    for i = first, last do
        if type(Shelf.books[i]) ~= "table" then
            return false
        end
    end
    return true
end

function Shelf.loaded_count()
    local n = 0
    for _, book in pairs(Shelf.books or {}) do
        if type(book) == "table" then
            n = n + 1
        end
    end
    return n
end

function Shelf.has_books()
    for _, book in pairs(Shelf.books or {}) do
        if type(book) == "table" then
            return true
        end
    end
    return false
end

local function missing_api_idx(first, last)
    first = math.max(1, tonumber(first) or 1)
    last = cap_last(last)
    if last < first then
        return nil
    end
    local size = api_page_size()
    local idx = math.floor((first - 1) / size) * size
    local last_idx = math.floor((last - 1) / size) * size
    while idx <= last_idx do
        local from = math.max(first, idx + 1)
        local to = math.min(last, idx + size)
        for i = from, to do
            if type(Shelf.books[i]) ~= "table" then
                return idx
            end
        end
        idx = idx + size
    end
end

local function seed_from_html(html)
    local books, total, kk_idx = Shelf.parse_books_html(html)
    if not books or #books == 0 then
        return
    end
    Shelf.books = {}
    put_books(0, books)
    Shelf.total = total
    Shelf.kk_idx = kk_idx
    Shelf.next_idx = #books
    if Shelf.total > 0 and Shelf.range_loaded(1, Shelf.total) then
        Shelf.eof = true
    end
end

function Shelf.ensure_user(on_done)
    on_done = on_done or function() end
    if Shelf.user then
        on_done(Shelf.user)
        return
    end
    Log.dbg("shelf", "ensure_user", { url = Config.SHELF_URL })
    Http.request({
        url = Config.SHELF_URL,
        accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        referer = Config.SHELF_URL,
        origin = Config.ORIGIN,
        send_cookie = true,
        absorb_cookies = true,
        timeout = 15,
    }, function(res)
        local body = res and res.body or ""
        local status = res and res.status
        local err = res and res.err
        if not res or not res.ok then
            if looks_like_login(body or err) then
                Log.warn("shelf", "auth_expired", { source = "html" })
                on_done(nil, "auth_expired")
                return
            end
            Log.warn("shelf", "ensure_user", {
                status = status,
                err = err,
                code = res and res.code,
                bytes = #body,
                header = tostring(res and res.headers or ""):match("[^\r\n]+"),
            })
            on_done(nil, status or "http_error", err)
            return
        end
        if looks_like_login(body) then
            Log.warn("shelf", "auth_expired", { source = "html" })
            on_done(nil, "auth_expired")
            return
        end
        local user = Shelf.parse_user_info(body)
        if not user then
            Log.warn("shelf", "auth_expired", { source = "userInfo" })
            on_done(nil, "auth_expired", "userInfo missing")
            return
        end
        Shelf.sync_session(body)
        seed_from_html(body)
        Shelf.user = user
        Log.dbg("shelf", "user", {
            vid = user.user_vid,
            name = user.name,
            books = #Shelf.books,
            total = Shelf.total,
        })
        on_done(user)
    end)
end

local function api_error(data)
    if type(data) ~= "table" then
        return "http_error", "invalid shelf payload"
    end
    local inner = type(data.data) == "table" and data.data or {}
    local code = tonumber(data.errCode) or tonumber(inner.errcode) or tonumber(inner.errCode)
    local msg = inner.errmsg or inner.errMsg or data.errMsg or data.errCode
    if data.succ == 0 or (code and code ~= 0) then
        if code == -2010 or code == -2012 or code == -2013 or code == -12013 then
            return "auth_expired", tostring(msg or code)
        end
        return "http_error", tostring(msg or code or "shelfLoadMore fail")
    end
end

function Shelf.fetch_api_page(idx, on_done)
    on_done = on_done or function() end
    idx = tonumber(idx) or 0
    local url = string.format(
        "%s?idx=%d&kkIdx=%d&platform=desktop",
        Config.SHELF_MORE_URL,
        idx,
        tonumber(Shelf.kk_idx) or -1
    )
    Log.dbg("shelf", "api_page", { idx = idx, url = url })
    Http.request({
        url = url,
        accept = "*/*",
        referer = Config.SHELF_URL,
        origin = Config.ORIGIN,
        send_cookie = true,
        absorb_cookies = true,
        timeout = 15,
    }, function(res)
        if not res or not res.ok then
            Log.warn("shelf", "api_page", {
                idx = idx,
                status = res and res.status,
                err = res and res.err,
                code = res and res.code,
                bytes = res and res.body and #res.body or 0,
                header = tostring(res and res.headers or ""):match("[^\r\n]+"),
            })
            on_done(nil, (res and res.status) or "http_error", res and res.err)
            return
        end
        local data, decode_err = Json.decode(res.body)
        if not data then
            Log.warn("shelf", "json", { err = decode_err })
            on_done(nil, "http_error", decode_err)
            return
        end
        local err_status, err_msg = api_error(data)
        if err_status then
            Log.warn("shelf", "api", { status = err_status, err = err_msg })
            on_done(nil, err_status, err_msg)
            return
        end
        local books = data.books or {}
        merge_reader_urls(books, data.bookReaderUrls)
        on_done({
            books = books,
            total = tonumber(data.totalCount) or 0,
        })
    end)
end

function Shelf.books_needed(page)
    page = math.max(1, tonumber(page) or 1)
    local first = Settings.first_page_books()
    local per = Settings.page_books()
    local needed = first
    if page > 1 then
        needed = first + (page - 1) * per
    end
    local total = tonumber(Shelf.total) or 0
    if total > 0 then
        needed = math.min(needed, total)
    end
    return needed
end

function Shelf.page_slice(page)
    page = math.max(1, tonumber(page) or 1)
    local first_count = Settings.first_page_books()
    local per = Settings.page_books()
    local first, last
    if page == 1 then
        first, last = 1, first_count
    else
        first = first_count + (page - 2) * per + 1
        last = first + per - 1
    end
    last = cap_last(last)
    return first, last
end

function Shelf.ui_page_count()
    local total = tonumber(Shelf.total) or 0
    if total <= 0 then
        total = #Shelf.books
    end
    local first = Settings.first_page_books()
    local per = math.max(1, Settings.page_books())
    if total <= first then
        return 1
    end
    return 1 + math.ceil((total - first) / per)
end

function Shelf.needs_api_for_page(page)
    local first, last = Shelf.page_slice(page)
    if last < first then
        return false
    end
    return not Shelf.range_loaded(first, last)
end

function Shelf.ensure_range(first, last, on_done)
    on_done = on_done or function() end
    first = math.max(1, tonumber(first) or 1)
    last = cap_last(last)
    if last < first or Shelf.range_loaded(first, last) then
        on_done(Shelf.books)
        return
    end
    local idx = missing_api_idx(first, last)
    if idx == nil then
        on_done(Shelf.books)
        return
    end
    Log.dbg("shelf", "ensure_range", {
        first = first,
        last = last,
        idx = idx,
        total = Shelf.total,
    })
    Shelf.fetch_api_page(idx, function(page, status, err)
        if not page then
            on_done(Shelf.books, status, err)
            return
        end
        if tonumber(page.total) and page.total > 0 then
            Shelf.total = page.total
            last = cap_last(last)
        end
        local got = page.books or {}
        if #got == 0 then
            Shelf.eof = true
            on_done(Shelf.books)
            return
        end
        put_books(idx, got)
        local size = api_page_size()
        if #got < size then
            local end_pos = idx + #got
            if Shelf.total <= 0 or end_pos >= Shelf.total then
                Shelf.eof = true
            end
        end
        if Shelf.total > 0 and Shelf.range_loaded(1, Shelf.total) then
            Shelf.eof = true
        end
        if idx >= (Shelf.next_idx or 0) and idx == math.floor((Shelf.next_idx or 0) / size) * size then
            Shelf.next_idx = idx + size
        end
        Shelf.ensure_range(first, last, on_done)
    end)
end

function Shelf.ensure_books(needed, on_done)
    needed = tonumber(needed) or Settings.first_page_books()
    return Shelf.ensure_range(1, needed, on_done)
end

function Shelf.ensure_page(page, on_done)
    local first, last = Shelf.page_slice(page)
    return Shelf.ensure_range(first, last, on_done)
end

function Shelf.books_for_page(page)
    local first, last = Shelf.page_slice(page)
    local out = {}
    for i = first, last do
        local book = Shelf.books[i]
        if book then
            out[#out + 1] = book
        end
    end
    return out
end

return Shelf
