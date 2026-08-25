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

return Covers
