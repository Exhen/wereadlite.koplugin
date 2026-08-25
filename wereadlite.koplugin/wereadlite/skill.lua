local Config = require("wereadlite.config")
local Client = require("wereadlite.kindle.client")
local Json = require("wereadlite.json")
local Log = require("wereadlite.log")
local Settings = require("wereadlite.settings")

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
        search_idx = tonumber(item.searchIdx or item.search_idx),
        group = item._group,
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

function Skill.chapter_highlights(book_id, chapter_uid)
    book_id = tostring(book_id or "")
    chapter_uid = tonumber(chapter_uid) or 0
    if book_id == "" then
        return {}
    end
    Log.info("skill", "chapter_highlights_start", { book_id = book_id, chapter_uid = chapter_uid })
    local best = Skill.call("/book/bestbookmarks", {
        bookId = book_id,
        chapterUid = chapter_uid,
        synckey = 0,
    })
    if type(best) ~= "table" or type(best.items) ~= "table" then
        Log.warn("skill", "bestbookmarks_empty", { book_id = book_id, chapter_uid = chapter_uid, type = type(best) })
        return {}
    end
    Log.info("skill", "bestbookmarks_ok", { book_id = book_id, chapter_uid = chapter_uid, items = #best.items })
    local requests = {}
    for _, item in ipairs(best.items) do
        local range = tostring(item.range or "")
        if range ~= "" then
            requests[#requests + 1] = { range = range, maxIdx = 0, count = 20, synckey = 0 }
        end
    end
    if #requests == 0 then
        Log.info("skill", "readreviews_skip", { reason = "no_ranges" })
        return {}
    end
    Log.info("skill", "readreviews_start", { book_id = book_id, chapter_uid = chapter_uid, ranges = #requests })
    local reviews = Skill.call("/book/readreviews", {
        bookId = book_id,
        chapterUid = chapter_uid,
        reviews = requests,
    })
    local by_range = {}
    if type(reviews) == "table" and type(reviews.reviews) == "table" then
        Log.info("skill", "readreviews_ok", { groups = #reviews.reviews })
        for _, group in ipairs(reviews.reviews) do
            local range = tostring(group.range or "")
            local list = {}
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
            if range ~= "" and #list > 0 then
                by_range[range] = list
            end
        end
    end
    if type(reviews) ~= "table" or type(reviews.reviews) ~= "table" then
        Log.warn("skill", "readreviews_empty", { type = type(reviews) })
    end
    local out = {}
    for _, item in ipairs(best.items) do
        local range = tostring(item.range or "")
        if range ~= "" and by_range[range] then
            out[#out + 1] = {
                range = range,
                text = tostring(item.markText or ""),
                reviews = by_range[range],
                total = tonumber(item.totalCount) or 0,
            }
        end
    end
    Log.info("skill", "chapter_highlights_done", { matched = #out, ranges = #requests })
    return out
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
    if type(payload.readDetail) == "table" then
        local nested = payload.readDetail
        nested.upgrade_info = nested.upgrade_info or payload.upgrade_info
        return nested
    end
    return payload
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

return Skill
