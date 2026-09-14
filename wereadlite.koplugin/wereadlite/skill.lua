local Config = require("wereadlite.config")
local Client = require("wereadlite.kindle.client")
local Json = require("wereadlite.json")
local Log = require("wereadlite.log")
local Settings = require("wereadlite.settings")
local UIManager = require("ui/uimanager")

local Skill = {}

math.randomseed((os.time() % 2147483646) + 1)

local AUTH_CODES = {
    [-2010] = true,
    [-2012] = true,
    [401] = true,
}

local function as_table(value)
    return type(value) == "table" and value or {}
end

local function request_id()
    local alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local out = {}
    for i = 1, 21 do
        local n = math.random(#alphabet)
        out[i] = alphabet:sub(n, n)
    end
    return table.concat(out)
end

local function looks_like_html(text)
    text = tostring(text or "")
    local head = text:sub(1, 200):lower()
    return head:find("<!doctype html", 1, true) or head:find("<html", 1, true)
end

local function decode_json(text)
    text = tostring(text or "")
    if text == "" then
        return nil, "empty"
    end
    if looks_like_html(text) then
        return nil, "auth_expired"
    end
    local data, err = Json.decode(text)
    if type(data) ~= "table" then
        return nil, err or "invalid json"
    end
    return data
end

local function web_request(opts)
    opts = opts or {}
    opts.user_agent = opts.user_agent or Config.WEB_UA
    opts.referer = opts.referer or Config.SKILL_PAGE
    opts.origin = opts.origin or Config.ORIGIN
    opts.headers = opts.headers or {}
    if opts.headers["x-ssr-request-id"] == nil then
        opts.headers["x-ssr-request-id"] = request_id()
    end
    return Client.request(opts)
end

local function fetch_apikey(only_show)
    local url = Config.SKILL_APIKEY_URL
    if only_show then
        url = url .. "?only_show=1"
    end
    Log.info("skill", "apikey_get", { only_show = only_show and true or false })
    local text, status, err, code = web_request({
        url = url,
        accept = "application/json, */*",
    })
    if not text then
        if status == "auth_expired" or tonumber(code) == 401 then
            return nil, "auth_expired", err
        end
        return nil, status or "http_error", err
    end
    local data, decode_err = decode_json(text)
    if not data then
        if decode_err == "auth_expired" then
            return nil, "auth_expired", "login required"
        end
        return nil, "http_error", decode_err
    end
    return data
end

local apikey_waiters = {}
local apikey_fetching = false

local function notify_apikey_waiters(key, status, err)
    local waiters = apikey_waiters
    apikey_waiters = {}
    for i = 1, #waiters do
        waiters[i](key, status, err)
    end
end

local function fetch_apikey_async(only_show, callback)
    callback = type(callback) == "function" and callback or function() end
    local url = Config.SKILL_APIKEY_URL
    if only_show then
        url = url .. "?only_show=1"
    end
    Log.info("skill", "apikey_get_async", { only_show = only_show and true or false })
    local Http = require("wereadlite.async_http")
    Http.request({
        url = url,
        method = "GET",
        send_cookie = true,
        absorb_cookies = false,
        accept = "application/json, */*",
        user_agent = Config.WEB_UA,
        referer = Config.SKILL_PAGE,
        origin = Config.ORIGIN,
        headers = {
            ["x-ssr-request-id"] = request_id(),
        },
        timeout = 15,
    }, function(res)
        res = type(res) == "table" and res or {}
        if not res.ok then
            local status = res.status or "http_error"
            if status == "auth_expired" or tonumber(res.code) == 401 then
                callback(nil, "auth_expired", res.err)
                return
            end
            callback(nil, status, res.err)
            return
        end
        local data, decode_err = decode_json(res.body)
        if not data then
            if decode_err == "auth_expired" then
                callback(nil, "auth_expired", "login required")
                return
            end
            callback(nil, "http_error", decode_err)
            return
        end
        callback(data, "ok")
    end)
end

local function key_from(data)
    if type(data) ~= "table" then
        return nil
    end
    if data.isEmpty == true or data.isEmpty == 1 or data.isEmpty == "true" then
        return nil
    end
    local key = tostring(data.apikey or data.apiKey or data.api_key or "")
    if key:match("^wrk%-") then
        return key
    end
end

local function reader_url_from_deep_link(deep_link)
    deep_link = tostring(deep_link or "")
    local bc = deep_link:match("[?&]v=([%w_%-]+)")
    if bc and bc ~= "" then
        return Config.READER_URL .. "?bc=" .. bc
    end
end

function Skill.ensure_key(force)
    if not force then
        local cached = Settings.skill_apikey()
        if cached then
            return cached
        end
    end
    local data, status, err = fetch_apikey(true)
    if not data then
        Log.warn("skill", "apikey_show", { status = status })
        return nil, status, err
    end
    local key = key_from(data)
    if not key then
        data, status, err = fetch_apikey(false)
        if not data then
            Log.warn("skill", "apikey_create", { status = status })
            return nil, status, err
        end
        key = key_from(data)
    end
    if not key then
        return nil, "http_error", "未能获取 Skill API Key"
    end
    Settings.set_skill_apikey(key)
    Log.info("skill", "apikey_ready", { len = #key })
    return key
end

function Skill.ensure_key_async(callback, force)
    callback = type(callback) == "function" and callback or function() end
    if not force then
        local cached = Settings.skill_apikey()
        if cached then
            UIManager:nextTick(function()
                callback(cached, "ok")
            end)
            return
        end
    end
    if apikey_fetching then
        apikey_waiters[#apikey_waiters + 1] = callback
        return
    end
    apikey_fetching = true
    fetch_apikey_async(true, function(data, status, err)
        if not data then
            Log.warn("skill", "apikey_show", { status = status })
            apikey_fetching = false
            callback(nil, status, err)
            notify_apikey_waiters(nil, status, err)
            return
        end
        local key = key_from(data)
        if key then
            Settings.set_skill_apikey(key)
            Log.info("skill", "apikey_ready", { len = #key })
            apikey_fetching = false
            callback(key, "ok")
            notify_apikey_waiters(key, "ok")
            return
        end
        fetch_apikey_async(false, function(created, cstatus, cerr)
            if not created then
                Log.warn("skill", "apikey_create", { status = cstatus })
                apikey_fetching = false
                callback(nil, cstatus, cerr)
                notify_apikey_waiters(nil, cstatus, cerr)
                return
            end
            key = key_from(created)
            if not key then
                apikey_fetching = false
                callback(nil, "http_error", "未能获取 Skill API Key")
                notify_apikey_waiters(nil, "http_error", "未能获取 Skill API Key")
                return
            end
            Settings.set_skill_apikey(key)
            Log.info("skill", "apikey_ready", { len = #key })
            apikey_fetching = false
            callback(key, "ok")
            notify_apikey_waiters(key, "ok")
        end)
    end)
end

local function gateway_status(data)
    if type(data) ~= "table" then
        return nil
    end
    local code = tonumber(data.errcode or data.errCode or data.code)
    local msg = tostring(data.errmsg or data.errMsg or data.message or "")
    if not code or code == 0 then
        return nil
    end
    if AUTH_CODES[code] then
        return "auth_expired", msg ~= "" and msg or "API Key 已失效"
    end
    return "http_error", msg ~= "" and msg or ("errcode " .. tostring(code))
end

local function unwrap_payload(data)
    if type(data) ~= "table" then
        return {}
    end
    local inner = data.data
    if type(inner) == "string" then
        local decoded = Json.decode(inner)
        if type(decoded) == "table" then
            inner = decoded
        end
    end
    if type(inner) == "table" then
        if inner.results ~= nil or inner.totalReadTime ~= nil or inner.readDetail ~= nil
            or inner.readTimes ~= nil or inner.readLongest ~= nil then
            return inner
        end
        if data.results == nil and data.totalReadTime == nil then
            return inner
        end
    end
    return data
end

function Skill.call(api_name, params, retried)
    local key, status, err = Skill.ensure_key(retried)
    if not key then
        return nil, status, err
    end
    local body = {
        api_name = api_name,
        skill_version = Config.SKILL_VERSION,
    }
    for name, value in pairs(as_table(params)) do
        if value ~= nil then
            body[name] = value
        end
    end
    local encoded, encode_err = Json.encode(body)
    if not encoded then
        return nil, "http_error", encode_err or "json encode failed"
    end
    Log.info("skill", "call", { api_name = api_name })
    local text, req_status, req_err, code = web_request({
        url = Config.SKILL_GATEWAY_URL,
        method = "POST",
        body = encoded,
        send_cookie = false,
        accept = "application/json, */*",
        headers = {
            Authorization = "Bearer " .. key,
            ["Content-Type"] = "application/json",
        },
    })
    if not text then
        if req_status == "auth_expired" or tonumber(code) == 401 then
            if not retried then
                Settings.set_skill_apikey("")
                return Skill.call(api_name, params, true)
            end
            return nil, "auth_expired", req_err
        end
        return nil, req_status or "http_error", req_err
    end
    local data, decode_err = decode_json(text)
    if not data then
        if decode_err == "auth_expired" then
            if not retried then
                Settings.set_skill_apikey("")
                return Skill.call(api_name, params, true)
            end
            return nil, "auth_expired", decode_err
        end
        return nil, "http_error", decode_err
    end
    local gw_status, gw_err = gateway_status(data)
    if gw_status == "auth_expired" and not retried then
        Settings.set_skill_apikey("")
        return Skill.call(api_name, params, true)
    end
    if gw_status then
        return nil, gw_status, gw_err
    end
    local payload = unwrap_payload(data)
    if type(data.upgrade_info) == "table" then
        payload.upgrade_info = data.upgrade_info
        Log.warn("skill", "upgrade", {
            message = tostring(data.upgrade_info.message or ""),
        })
    end
    return payload
end

function Skill.call_async(api_name, params, callback, retried)
    callback = type(callback) == "function" and callback or function() end
    retried = retried and true or false
    Skill.ensure_key_async(function(key, status, err)
        if not key then
            callback(nil, status, err)
            return
        end
        local body = {
            api_name = api_name,
            skill_version = Config.SKILL_VERSION,
        }
        for name, value in pairs(as_table(params)) do
            if value ~= nil then
                body[name] = value
            end
        end
        local encoded, encode_err = Json.encode(body)
        if not encoded then
            callback(nil, "http_error", encode_err or "json encode failed")
            return
        end
        Log.info("skill", "call_async", { api_name = api_name })
        local Http = require("wereadlite.async_http")
        Http.request({
            url = Config.SKILL_GATEWAY_URL,
            method = "POST",
            body = encoded,
            send_cookie = false,
            accept = "application/json, */*",
            referer = Config.SKILL_PAGE,
            origin = Config.ORIGIN,
            user_agent = Config.WEB_UA,
            headers = {
                Authorization = "Bearer " .. key,
                ["Content-Type"] = "application/json",
                ["x-ssr-request-id"] = request_id(),
            },
            timeout = 15,
        }, function(res)
            res = type(res) == "table" and res or {}
            if not res.ok then
                if (res.status == "auth_expired" or tonumber(res.code) == 401) and not retried then
                    Settings.set_skill_apikey("")
                    Skill.call_async(api_name, params, callback, true)
                    return
                end
                callback(nil, res.status or "http_error", res.err)
                return
            end
            local data, decode_err = decode_json(res.body)
            if not data then
                if decode_err == "auth_expired" and not retried then
                    Settings.set_skill_apikey("")
                    Skill.call_async(api_name, params, callback, true)
                    return
                end
                callback(nil, "http_error", decode_err)
                return
            end
            local gw_status, gw_err = gateway_status(data)
            if gw_status == "auth_expired" and not retried then
                Settings.set_skill_apikey("")
                Skill.call_async(api_name, params, callback, true)
                return
            end
            if gw_status then
                callback(nil, gw_status, gw_err)
                return
            end
            local payload = unwrap_payload(data)
            if type(data.upgrade_info) == "table" then
                payload.upgrade_info = data.upgrade_info
                Log.warn("skill", "upgrade", {
                    message = tostring(data.upgrade_info.message or ""),
                })
            end
            callback(payload, "ok")
        end)
    end, retried)
end

local function add_book(books, seen, item)
    item = as_table(item)
    local info = as_table(item.bookInfo or item.book_info)
    if not next(info) then
        info = item
    end
    local title = tostring(info.title or "")
    if title == "" then
        return
    end
    local book_id = tostring(info.bookId or info.book_id or item.bookId or "")
    local key = book_id ~= "" and book_id or title
    if seen[key] then
        return
    end
    seen[key] = true
    local deep_link = tostring(info.deepLink or info.deeplink or "")
    books[#books + 1] = {
        bookId = book_id,
        title = title,
        author = tostring(info.author or ""),
        intro = tostring(info.intro or ""),
        cover = tostring(info.cover or ""),
        category = tostring(info.category or ""),
        publisher = tostring(info.publisher or ""),
        deepLink = deep_link,
        reader_url = reader_url_from_deep_link(deep_link),
        soldout = tonumber(info.soldout or item.soldout) or 0,
        rating = tonumber(item.newRating or info.newRating) or 0,
        rating_count = tonumber(item.newRatingCount or info.newRatingCount) or 0,
        reading_count = tonumber(item.readingCount or info.readingCount) or 0,
        total_words = tonumber(info.totalWords or info.total_words) or 0,
        isbn = tostring(info.isbn or ""),
        search_idx = tonumber(item.searchIdx or item.search_idx),
        group = item._group,
    }
end

local function parse_book_from_payload(payload)
    local books, seen = {}, {}
    add_book(books, seen, payload)
    if #books == 0 then
        add_book(books, seen, { bookInfo = payload.bookInfo or payload })
    end
    if #books == 0 then
        return nil
    end
    local book = books[1]
    if (not book.reader_param or book.reader_param == "") and book.reader_url and book.reader_url ~= "" then
        local bc = book.reader_url:match("[?&]v=([%w_%-]+)")
        if bc and bc ~= "" then
            book.reader_param = bc
        end
    end
    return book
end

local function enrich_reader_params(books)
    for _, book in ipairs(books or {}) do
        if (not book.reader_param or book.reader_param == "") and book.reader_url and book.reader_url ~= "" then
            local bc = book.reader_url:match("[?&]v=([%w_%-]+)")
            if bc and bc ~= "" then
                book.reader_param = bc
            end
        end
    end
end

local function parse_search_payload(payload, keyword)
    local books, seen = {}, {}
    for _, group in ipairs(as_table(payload.results)) do
        group = as_table(group)
        local group_title = tostring(group.title or "")
        for _, item in ipairs(as_table(group.books)) do
            if type(item) == "table" then
                item._group = group_title
                add_book(books, seen, item)
            end
        end
    end
    for _, item in ipairs(as_table(payload.books)) do
        add_book(books, seen, item)
    end
    local last_idx = 0
    for _, book in ipairs(books) do
        if book.search_idx and book.search_idx > last_idx then
            last_idx = book.search_idx
        end
    end
    return {
        keyword = keyword,
        books = books,
        has_more = tonumber(payload.hasMore or payload.has_more) == 1,
        max_idx = last_idx,
        upgrade_info = payload.upgrade_info,
    }
end

function Skill.search(keyword, opts)
    opts = opts or {}
    keyword = tostring(keyword or ""):match("^%s*(.-)%s*$") or ""
    if keyword == "" then
        return nil, "http_error", "请输入关键词"
    end
    local payload, status, err = Skill.call("/store/search", {
        keyword = keyword,
        scope = tonumber(opts.scope) or 10,
        count = tonumber(opts.count) or 10,
        maxIdx = tonumber(opts.max_idx) or 0,
    })
    if not payload then
        return nil, status, err
    end
    return parse_search_payload(payload, keyword)
end

function Skill.search_async(keyword, opts, callback)
    opts = opts or {}
    callback = type(callback) == "function" and callback or function() end
    keyword = tostring(keyword or ""):match("^%s*(.-)%s*$") or ""
    if keyword == "" then
        UIManager:nextTick(function()
            callback(nil, "http_error", "请输入关键词")
        end)
        return
    end
    Skill.call_async("/store/search", {
        keyword = keyword,
        scope = tonumber(opts.scope) or 10,
        count = tonumber(opts.count) or 10,
        maxIdx = tonumber(opts.max_idx) or 0,
    }, function(payload, status, err)
        if not payload then
            callback(nil, status, err)
            return
        end
        callback(parse_search_payload(payload, keyword), status, err)
    end)
end

local function parse_review_group(group)
    local list = {}
    group = as_table(group)
    for _, row in ipairs(group.pageReviews or {}) do
        local review = type(row.review) == "table" and row.review or row
        local content = tostring(review.content or "")
        if content ~= "" then
            local author = type(review.author) == "table" and review.author or {}
            list[#list + 1] = {
                content = content,
                username = tostring(author.name or author.nickName or author.nickname or "微信读书用户"),
                avatar = tostring(author.avatar or author.avatarUrl or author.headImgUrl or ""),
                id = tostring(row.reviewId or review.reviewId or (#list + 1)),
            }
        end
    end
    return list
end

local function parse_underlines_payload(payload, book_id, chapter_uid)
    if type(payload) ~= "table" or type(payload.underlines) ~= "table" then
        Log.warn("skill", "underlines_empty", { book_id = book_id, chapter_uid = chapter_uid, type = type(payload) })
        return {}
    end
    local out = {}
    for _, item in ipairs(payload.underlines) do
        item = as_table(item)
        local range = tostring(item.range or "")
        if range ~= "" then
            out[#out + 1] = {
                range = range,
                count = tonumber(item.count) or 0,
                score = tonumber(item.score) or 0,
                type = tonumber(item.type) or 0,
            }
        end
    end
    Log.info("skill", "chapter_underlines_done", { book_id = book_id, chapter_uid = chapter_uid, count = #out })
    return out
end

function Skill.chapter_underlines(book_id, chapter_uid)
    book_id = tostring(book_id or "")
    chapter_uid = tonumber(chapter_uid) or 0
    if book_id == "" or chapter_uid == 0 then
        return {}
    end
    Log.info("skill", "chapter_underlines_start", { book_id = book_id, chapter_uid = chapter_uid })
    local payload = Skill.call("/book/underlines", {
        bookId = book_id,
        chapterUid = chapter_uid,
        synckey = 0,
    })
    return parse_underlines_payload(payload, book_id, chapter_uid)
end

function Skill.chapter_underlines_async(book_id, chapter_uid, callback)
    book_id = tostring(book_id or "")
    chapter_uid = tonumber(chapter_uid) or 0
    callback = type(callback) == "function" and callback or function() end
    if book_id == "" or chapter_uid == 0 then
        UIManager:nextTick(function()
            callback({})
        end)
        return
    end
    Log.info("skill", "chapter_underlines_start", { book_id = book_id, chapter_uid = chapter_uid })
    Skill.call_async("/book/underlines", {
        bookId = book_id,
        chapterUid = chapter_uid,
        synckey = 0,
    }, function(payload, status, err)
        if not payload then
            Log.warn("skill", "underlines_empty", { book_id = book_id, chapter_uid = chapter_uid, status = status, err = err })
            callback({}, status, err)
            return
        end
        callback(parse_underlines_payload(payload, book_id, chapter_uid), status, err)
    end)
end

function Skill.fetch_range_reviews(book_id, chapter_uid, range)
    book_id = tostring(book_id or "")
    chapter_uid = tonumber(chapter_uid) or 0
    range = tostring(range or "")
    if book_id == "" or chapter_uid == 0 or range == "" then
        return {}
    end
    Log.info("skill", "readreviews_one", { book_id = book_id, chapter_uid = chapter_uid, range = range })
    local payload = Skill.call("/book/readreviews", {
        bookId = book_id,
        chapterUid = chapter_uid,
        reviews = {
            { range = range, maxIdx = 0, count = 20, synckey = 0 },
        },
    })
    if type(payload) ~= "table" or type(payload.reviews) ~= "table" then
        Log.warn("skill", "readreviews_one_empty", { range = range, type = type(payload) })
        return {}
    end
    for _, group in ipairs(payload.reviews) do
        if tostring(group.range or "") == range then
            local list = parse_review_group(group)
            Log.info("skill", "readreviews_one_ok", { range = range, reviews = #list })
            return list
        end
    end
    Log.info("skill", "readreviews_one_miss", { range = range })
    return {}
end

function Skill.fetch_range_reviews_async(book_id, chapter_uid, range, callback)
    book_id = tostring(book_id or "")
    chapter_uid = tonumber(chapter_uid) or 0
    range = tostring(range or "")
    callback = type(callback) == "function" and callback or function() end
    if book_id == "" or chapter_uid == 0 or range == "" then
        UIManager:nextTick(function()
            callback({})
        end)
        return
    end
    Log.info("skill", "readreviews_one", { book_id = book_id, chapter_uid = chapter_uid, range = range })
    Skill.call_async("/book/readreviews", {
        bookId = book_id,
        chapterUid = chapter_uid,
        reviews = {
            { range = range, maxIdx = 0, count = 20, synckey = 0 },
        },
    }, function(payload, status, err)
        if type(payload) ~= "table" or type(payload.reviews) ~= "table" then
            Log.warn("skill", "readreviews_one_empty", { range = range, type = type(payload) })
            callback({}, status, err)
            return
        end
        for _, group in ipairs(payload.reviews) do
            if tostring(group.range or "") == range then
                local list = parse_review_group(group)
                Log.info("skill", "readreviews_one_ok", { range = range, reviews = #list })
                callback(list, status, err)
                return
            end
        end
        Log.info("skill", "readreviews_one_miss", { range = range })
        callback({}, status, err)
    end)
end

local function parse_recommend_payload(payload, count)
    local books, seen = {}, {}
    for _, item in ipairs(as_table(payload.books)) do
        add_book(books, seen, item)
    end
    local last_idx = 0
    for _, book in ipairs(books) do
        local idx = tonumber(book.search_idx) or 0
        if idx > last_idx then
            last_idx = idx
        end
    end
    enrich_reader_params(books)
    Log.info("skill", "recommend_ok", { count = #books, max_idx = last_idx })
    return {
        books = books,
        max_idx = last_idx,
        has_more = #books >= count,
        upgrade_info = payload.upgrade_info,
    }
end

function Skill.recommend(opts)
    opts = opts or {}
    local count = math.max(1, tonumber(opts.count) or 12)
    local payload, status, err = Skill.call("/book/recommend", {
        count = count,
        maxIdx = tonumber(opts.max_idx) or 0,
    })
    if not payload then
        return nil, status, err
    end
    return parse_recommend_payload(payload, count), status, err
end

function Skill.recommend_async(opts, callback)
    opts = opts or {}
    callback = type(callback) == "function" and callback or function() end
    local count = math.max(1, tonumber(opts.count) or 12)
    Skill.call_async("/book/recommend", {
        count = count,
        maxIdx = tonumber(opts.max_idx) or 0,
    }, function(payload, status, err)
        if not payload then
            callback(nil, status, err)
            return
        end
        callback(parse_recommend_payload(payload, count), status, err)
    end)
end

local function parse_similar_payload(payload, book_id, count)
    local similar = as_table(payload.booksimilar or payload.bookSimilar)
    local books, seen = {}, {}
    for _, row in ipairs(as_table(similar.books)) do
        row = as_table(row)
        local wrap = as_table(row.book)
        local info = as_table(wrap.bookInfo or wrap.book_info)
        if next(info) then
            add_book(books, seen, {
                bookInfo = info,
                searchIdx = row.idx,
                newRating = info.newRating,
                newRatingCount = info.newRatingCount,
                readingCount = info.readingCount,
                soldout = info.soldout,
            })
        end
    end
    local last_idx = 0
    for _, book in ipairs(books) do
        local idx = tonumber(book.search_idx) or 0
        if idx > last_idx then
            last_idx = idx
        end
    end
    enrich_reader_params(books)
    Log.info("skill", "similar_ok", {
        book_id = book_id,
        count = #books,
        max_idx = last_idx,
        session_id = tostring(similar.sessionId or similar.session_id or ""),
    })
    return {
        book_id = book_id,
        books = books,
        session_id = tostring(similar.sessionId or similar.session_id or ""),
        max_idx = last_idx,
        has_more = #books >= count,
        upgrade_info = payload.upgrade_info,
    }
end

function Skill.similar(book_id, opts)
    opts = opts or {}
    book_id = tostring(book_id or "")
    if book_id == "" then
        return nil, "http_error", "missing bookId"
    end
    local count = math.max(1, tonumber(opts.count) or 12)
    local params = {
        bookId = book_id,
        count = count,
        maxIdx = tonumber(opts.max_idx) or 0,
    }
    local session_id = tostring(opts.session_id or "")
    if session_id ~= "" then
        params.sessionId = session_id
    end
    local payload, status, err = Skill.call("/book/similar", params)
    if not payload then
        return nil, status, err
    end
    return parse_similar_payload(payload, book_id, count), status, err
end

function Skill.similar_async(book_id, opts, callback)
    opts = opts or {}
    callback = type(callback) == "function" and callback or function() end
    book_id = tostring(book_id or "")
    if book_id == "" then
        UIManager:nextTick(function()
            callback(nil, "http_error", "missing bookId")
        end)
        return
    end
    local count = math.max(1, tonumber(opts.count) or 12)
    local params = {
        bookId = book_id,
        count = count,
        maxIdx = tonumber(opts.max_idx) or 0,
    }
    local session_id = tostring(opts.session_id or "")
    if session_id ~= "" then
        params.sessionId = session_id
    end
    Skill.call_async("/book/similar", params, function(payload, status, err)
        if not payload then
            callback(nil, status, err)
            return
        end
        callback(parse_similar_payload(payload, book_id, count), status, err)
    end)
end

function Skill.book_info(book_id)
    book_id = tostring(book_id or "")
    if book_id == "" then
        return nil, "http_error", "missing bookId"
    end
    local payload, status, err = Skill.call("/book/info", {
        bookId = book_id,
    })
    if not payload then
        return nil, status, err
    end
    local book = parse_book_from_payload(payload)
    if not book then
        return nil, status, err or "empty"
    end
    Log.info("skill", "book_info_ok", { book_id = book_id, title = book.title })
    return book, status, err
end

function Skill.book_info_async(book_id, callback)
    book_id = tostring(book_id or "")
    callback = type(callback) == "function" and callback or function() end
    if book_id == "" then
        UIManager:nextTick(function()
            callback(nil, "http_error", "missing bookId")
        end)
        return
    end
    Skill.call_async("/book/info", { bookId = book_id }, function(payload, status, err)
        if not payload then
            callback(nil, status, err)
            return
        end
        local book = parse_book_from_payload(payload)
        if not book then
            callback(nil, status, err or "empty")
            return
        end
        Log.info("skill", "book_info_ok", { book_id = book_id, title = book.title })
        callback(book, status, err)
    end)
end

local function start_of_day(ts)
    ts = tonumber(ts) or 0
    if ts <= 0 then
        return 0
    end
    if ts > 100000000000 then
        ts = math.floor(ts / 1000)
    end
    local t = os.date("*t", ts)
    t.hour, t.min, t.sec = 0, 0, 0
    return os.time(t)
end

local function absorb_day_map(map, data)
    data = as_table(data)
    local function absorb(times)
        if type(times) ~= "table" then
            return
        end
        for key, value in pairs(times) do
            local day = start_of_day(key)
            if day > 0 then
                map[day] = (map[day] or 0) + (tonumber(value) or 0)
            end
        end
    end
    absorb(data.readTimes)
    absorb(data.dailyReadTimes)
end

local function parse_readdata_payload(payload)
    if type(payload.readDetail) == "table" then
        local nested = payload.readDetail
        nested.upgrade_info = nested.upgrade_info or payload.upgrade_info
        return nested
    end
    return payload
end

function Skill.readdata(mode, baseTime)
    mode = tostring(mode or "monthly")
    local params = { mode = mode }
    local ts = tonumber(baseTime)
    if ts and ts > 0 then
        params.baseTime = math.floor(ts)
    end
    local payload, status, err = Skill.call("/readdata/detail", params)
    if not payload then
        return nil, status, err
    end
    return parse_readdata_payload(payload)
end

function Skill.readdata_async(mode, baseTime, callback)
    if type(baseTime) == "function" then
        callback = baseTime
        baseTime = nil
    end
    callback = type(callback) == "function" and callback or function() end
    mode = tostring(mode or "monthly")
    local params = { mode = mode }
    local ts = tonumber(baseTime)
    if ts and ts > 0 then
        params.baseTime = math.floor(ts)
    end
    Skill.call_async("/readdata/detail", params, function(payload, status, err)
        if not payload then
            callback(nil, status, err)
            return
        end
        callback(parse_readdata_payload(payload), status, err)
    end)
end

function Skill.heatmap30(opts)
    opts = opts or {}
    local map = {}
    local now = os.time()
    local today = os.date("*t", now)
    local current = opts.monthly
    if type(current) ~= "table" then
        local status, err
        current, status, err = Skill.readdata("monthly")
        if not current then
            return nil, status, err
        end
    end
    absorb_day_map(map, current)
    local first = start_of_day(now) - 29 * 86400
    local last = start_of_day(now)
    local seen = {
        [string.format("%04d-%02d", today.year, today.month)] = true,
    }
    local ts = first
    while ts <= last do
        local t = os.date("*t", ts)
        local key = string.format("%04d-%02d", t.year, t.month)
        if not seen[key] then
            seen[key] = true
            local extra = Skill.readdata("monthly", os.time({
                year = t.year,
                month = t.month,
                day = 15,
                hour = 12,
                min = 0,
                sec = 0,
            }))
            if extra then
                absorb_day_map(map, extra)
            end
        end
        ts = ts + 86400
    end
    return map
end

function Skill.heatmap30_async(opts, callback)
    opts = opts or {}
    callback = type(callback) == "function" and callback or function() end
    local map = {}
    local now = os.time()
    local today = os.date("*t", now)
    local first = start_of_day(now) - 29 * 86400
    local last = start_of_day(now)
    local months = {}
    local seen = {
        [string.format("%04d-%02d", today.year, today.month)] = true,
    }
    months[#months + 1] = { label = "current", base = nil }
    local ts = first
    while ts <= last do
        local t = os.date("*t", ts)
        local key = string.format("%04d-%02d", t.year, t.month)
        if not seen[key] then
            seen[key] = true
            months[#months + 1] = {
                label = key,
                base = os.time({
                    year = t.year,
                    month = t.month,
                    day = 15,
                    hour = 12,
                    min = 0,
                    sec = 0,
                }),
            }
        end
        ts = ts + 86400
    end

    local index = 1
    local function step(seed)
        if type(seed) == "table" then
            absorb_day_map(map, seed)
        end
        if index > #months then
            callback(map, "ok")
            return
        end
        local item = months[index]
        index = index + 1
        if item.label == "current" and type(opts.monthly) == "table" then
            step(opts.monthly)
            return
        end
        Skill.readdata_async("monthly", item.base, function(data, status, err)
            if not data and item.label == "current" then
                callback(nil, status, err)
                return
            end
            step(data)
        end)
    end
    step(nil)
end

return Skill
