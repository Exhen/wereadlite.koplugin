local Config = require("wereadlite.config")
local Http = require("wereadlite.async_http")
local Log = require("wereadlite.log")
local Client = require("wereadlite.kindle.client")
local UIManager = require("ui/uimanager")

local Covers = {}

local IMAGE_EXTS = { "jpg", "jpeg", "png", "webp", "gif" }
local inflight = {}

local function valid_file(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    local size = file:seek("end")
    file:close()
    return size and size >= 32
end

local function sniff_ext(body)
    if type(body) ~= "string" or #body < 12 then
        return nil
    end
    local b1, b2, b3, b4 = body:byte(1, 4)
    if b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then
        return "jpg"
    end
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then
        return "png"
    end
    if body:sub(1, 6) == "GIF87a" or body:sub(1, 6) == "GIF89a" then
        return "gif"
    end
    if body:sub(1, 4) == "RIFF" and body:sub(9, 12) == "WEBP" then
        return "webp"
    end
end

local function safe_id(book_id)
    return tostring(book_id or "unknown"):gsub("[^%w%-_]", "_")
end

local function find_cached(stem)
    for _, ext in ipairs(IMAGE_EXTS) do
        local path = stem .. "." .. ext
        if valid_file(path) then
            return path
        end
    end
    local legacy = stem .. ".img"
    if valid_file(legacy) then
        local dest = stem .. ".jpg"
        os.remove(dest)
        os.rename(legacy, dest)
        if valid_file(dest) then
            return dest
        end
    end
end

local function write_body(dest_stem, body)
    local ext = sniff_ext(body)
    if not ext then
        return nil, "not an image"
    end
    local dest = dest_stem .. "." .. ext
    local tmp = dest .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then
        return nil, "write failed"
    end
    file:write(body)
    file:close()
    os.remove(dest)
    os.rename(tmp, dest)
    return dest
end

local function notify_waiters(key, path, err, cached)
    local waiters = inflight[key]
    inflight[key] = nil
    for _, cb in ipairs(waiters or {}) do
        pcall(cb, path, err, cached)
    end
end

function Covers.dir()
    return require("wereadlite.paths").covers_dir()
end

function Covers.path_for(book_id)
    return Covers.dir() .. "/" .. safe_id(book_id)
end

function Covers.cached(book_id)
    return find_cached(Covers.path_for(book_id))
end

function Covers.download(url, dest_stem, referer, timeout)
    url = tostring(url or "")
    if url == "" then
        return nil, "empty url"
    end
    local ok, body, status, err = pcall(Client.request, {
        url = url,
        accept = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        referer = referer or Config.SHELF_URL,
        timeout = tonumber(timeout) or 30,
        absorb_cookies = false,
    })
    if not ok then
        Log.warn("covers", "download_throw", { url = url, err = body })
        return nil, body
    end
    if not body or status ~= "ok" then
        return nil, status or err
    end
    local dest, write_err = write_body(dest_stem, body)
    if not dest then
        return nil, write_err
    end
    Log.dbg("covers", "download", { url = url, dest = dest, bytes = #body })
    return dest
end

function Covers.download_async(url, dest_stem, referer, callback, timeout)
    callback = callback or function() end
    url = tostring(url or "")
    if url == "" then
        UIManager:nextTick(function()
            callback(nil, "empty url")
        end)
        return
    end
    if not Http.available() then
        UIManager:nextTick(function()
            local path, err = Covers.download(url, dest_stem, referer, timeout)
            callback(path, err)
        end)
        return
    end
    Http.request({
        url = url,
        accept = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        referer = referer or Config.SHELF_URL,
        user_agent = Config.KINDLE_UA,
        timeout = tonumber(timeout) or 30,
        absorb_cookies = false,
    }, function(res)
        if not res or not res.ok or not res.body then
            callback(nil, (res and res.status) or (res and res.err) or "http_error")
            return
        end
        local dest, write_err = write_body(dest_stem, res.body)
        if not dest then
            callback(nil, write_err)
            return
        end
        Log.dbg("covers", "download_async", { url = url, dest = dest, bytes = #res.body })
        callback(dest)
    end)
end

function Covers.ensure(book)
    if type(book) ~= "table" then
        return nil
    end
    local cached = Covers.cached(book.bookId)
    if cached then
        return cached
    end
    local path, err = Covers.download(book.cover, Covers.path_for(book.bookId))
    if not path then
        Log.dbg("covers", "skip", { book_id = book.bookId, err = err })
    end
    return path
end

-- callback(path, err, cached)
-- cached=true means file was already on disk; no UI refresh needed.
function Covers.ensure_async(book, callback)
    callback = callback or function() end
    if type(book) ~= "table" then
        UIManager:nextTick(function()
            callback(nil, "bad book", false)
        end)
        return
    end
    local book_id = tostring(book.bookId or "")
    local cached = Covers.cached(book_id)
    if cached then
        UIManager:nextTick(function()
            callback(cached, nil, true)
        end)
        return
    end
    local key = "book:" .. book_id
    if inflight[key] then
        inflight[key][#inflight[key] + 1] = callback
        return
    end
    inflight[key] = { callback }
    Covers.download_async(book.cover, Covers.path_for(book_id), nil, function(path, err)
        if not path then
            Log.dbg("covers", "skip_async", { book_id = book_id, err = err })
        end
        notify_waiters(key, path, err, false)
    end)
end

function Covers.cached_avatar()
    return find_cached(Covers.dir() .. "/avatar")
end

function Covers.ensure_avatar(user)
    local cached = Covers.cached_avatar()
    if cached then
        return cached
    end
    if type(user) ~= "table" or not user.avatar or user.avatar == "" then
        return nil
    end
    local url = user.avatar:gsub("/0$", "/132")
    return Covers.download(url, Covers.dir() .. "/avatar")
end

function Covers.ensure_avatar_async(user, callback)
    callback = callback or function() end
    local cached = Covers.cached_avatar()
    if cached then
        UIManager:nextTick(function()
            callback(cached, nil, true)
        end)
        return
    end
    if type(user) ~= "table" or not user.avatar or user.avatar == "" then
        UIManager:nextTick(function()
            callback(nil, "no avatar", false)
        end)
        return
    end
    local key = "avatar"
    if inflight[key] then
        inflight[key][#inflight[key] + 1] = callback
        return
    end
    inflight[key] = { callback }
    local url = user.avatar:gsub("/0$", "/132")
    Covers.download_async(url, Covers.dir() .. "/avatar", nil, function(path, err)
        notify_waiters(key, path, err, false)
    end)
end

--- Batch-download covers via Http.request (curl or Trapper-style subprocess).
-- jobs: { { kind="book", book=table } | { kind="avatar", user=table } , ... }
-- on_item(path, err, cached, job) for each; on_done() when the batch finishes.
function Covers.prefetch_many_async(jobs, opts)
    opts = opts or {}
    local on_item = type(opts.on_item) == "function" and opts.on_item or function() end
    local on_done = type(opts.on_done) == "function" and opts.on_done or function() end
    jobs = type(jobs) == "table" and jobs or {}

    local tasks = {}
    local cached_hits = 0
    for _, job in ipairs(jobs) do
        if type(job) == "table" then
            if job.kind == "avatar" then
                local cached = Covers.cached_avatar()
                if cached then
                    cached_hits = cached_hits + 1
                    on_item(cached, nil, true, job)
                elseif type(job.user) == "table" and job.user.avatar and job.user.avatar ~= "" then
                    tasks[#tasks + 1] = {
                        kind = "avatar",
                        url = tostring(job.user.avatar):gsub("/0$", "/132"),
                        stem = Covers.dir() .. "/avatar",
                        job = job,
                    }
                else
                    on_item(nil, "no avatar", false, job)
                end
            else
                local book = job.book or job
                local book_id = tostring(book.bookId or "")
                local cached = book_id ~= "" and Covers.cached(book_id) or nil
                if cached then
                    cached_hits = cached_hits + 1
                    on_item(cached, nil, true, job)
                elseif book.cover and tostring(book.cover) ~= "" and book_id ~= "" then
                    tasks[#tasks + 1] = {
                        kind = "book",
                        book_id = book_id,
                        url = tostring(book.cover),
                        stem = Covers.path_for(book_id),
                        job = job,
                    }
                else
                    on_item(nil, "no cover", false, job)
                end
            end
        end
    end

    if #tasks == 0 then
        UIManager:nextTick(on_done)
        return
    end

    -- Always use Http.request: curl on Kindle/desktop, subprocess+ssl.https on Kobo
    -- (official #5002 / Trapper pattern). Do not use custom DNS or IP dial.
    local concurrency = math.max(1, tonumber(opts.concurrency) or 4)
    -- On Kobo, async_http is serial (MAX_WORKERS=1); keep pump concurrency low.
    if not (Http.has_curl and Http.has_curl()) then
        concurrency = 1
    end
    local referer = opts.referer or Config.SHELF_URL
    local via = (Http.has_curl and Http.has_curl()) and "curl" or "subprocess"
    Log.info("covers", "prefetch_many", {
        tasks = #tasks,
        cached = cached_hits,
        concurrency = concurrency,
        via = via,
    })
    local pending = 0
    local index = 1
    local finished = 0
    local ok_count = 0
    local total = #tasks
    local pump
    local function done_one(task, path, err)
        finished = finished + 1
        pending = math.max(0, pending - 1)
        if path then
            ok_count = ok_count + 1
            on_item(path, nil, false, task.job)
        else
            on_item(nil, err or "http_error", false, task.job)
        end
        if finished >= total then
            Log.info("covers", "prefetch_many_done", {
                via = via,
                ok = ok_count,
                fail = total - ok_count,
                total = total,
            })
            on_done()
            return
        end
        pump()
    end
    pump = function()
        while pending < concurrency and index <= total do
            local task = tasks[index]
            index = index + 1
            pending = pending + 1
            Covers.download_async(task.url, task.stem, referer, function(path, err)
                done_one(task, path, err)
            end)
        end
    end
    UIManager:nextTick(pump)
end

return Covers
