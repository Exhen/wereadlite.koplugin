--[[--
Blocking HTTP client for wereadlite.

Official KOReader pattern (newsdownloader / assistant / #5002):
  socket.http / ssl.https + socketutil:set_timeout + socket.skip(1, request(...))

On Kobo (no curl), callers run this inside async_http's subprocess
(Trapper-style ffiUtil.runInSubProcess).
]]

local ltn12 = require("ltn12")
local socket = require("socket")
local Config = require("wereadlite.config")
local CookieStore = require("wereadlite.cookie_store")
local Http = require("wereadlite.async_http")
local Log = require("wereadlite.log")

local Client = {}

local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")

local MAX_REDIRECTS = 5

local function headers_from_raw(raw)
    local headers = {}
    for line in tostring(raw or ""):gmatch("[^\r\n]+") do
        local name, value = line:match("^([^:]+):%s*(.+)$")
        if name then
            headers[name] = value
            headers[name:lower()] = value
        end
    end
    return headers
end

local function apply_timeout(seconds)
    seconds = tonumber(seconds) or 15
    local ok_su, socketutil = pcall(require, "socketutil")
    if ok_su and socketutil and type(socketutil.set_timeout) == "function" then
        pcall(socketutil.set_timeout, socketutil, seconds, seconds + 20)
        return function()
            pcall(socketutil.reset_timeout, socketutil)
        end
    end
    local old_http, old_https
    if ok_http and http then
        old_http = http.TIMEOUT
        http.TIMEOUT = seconds
    end
    if ok_https and https then
        old_https = https.TIMEOUT
        https.TIMEOUT = seconds
    end
    return function()
        if old_http ~= nil then
            http.TIMEOUT = old_http
        end
        if old_https ~= nil then
            https.TIMEOUT = old_https
        end
    end
end

local function header_get(headers, name)
    if type(headers) ~= "table" then
        return nil
    end
    local target = name:lower()
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == target then
            return value
        end
    end
end

local function absorb_cookies(headers)
    local set_cookie = header_get(headers, "set-cookie")
    if set_cookie then
        CookieStore.merge_set_cookie(set_cookie, "response")
        Log.dbg("http", "set_cookie", { bytes = #tostring(set_cookie) })
    end
end

local function absolute_url(base, loc)
    loc = tostring(loc or "")
    if loc == "" then
        return base
    end
    if loc:match("^https?://") then
        return loc
    end
    local scheme, host = tostring(base):match("^(https?)://([^/]+)")
    if not scheme then
        return loc
    end
    if loc:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. loc
    end
    local dir = tostring(base):match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return dir .. loc
end

local function classify(code, err)
    code = tonumber(code) or 0
    local lower = tostring(err or ""):lower()
    if code == 401 or code == 403 then
        return "auth_expired"
    end
    if code >= 200 and code < 400 then
        return "ok"
    end
    if code > 0 then
        return "http_error"
    end
    if lower:find("timeout", 1, true)
        or lower:find("closed", 1, true)
        or lower:find("refused", 1, true)
        or lower:find("network is unreachable", 1, true)
        or lower:find("host or service not provided", 1, true)
        or lower:find("name or service not known", 1, true)
        or lower:find("temporary failure in name resolution", 1, true) then
        return "offline"
    end
    return "http_error"
end

local function transport_for(url)
    if tostring(url):match("^https://") then
        return ok_https and https
    end
    return ok_http and http
end

local function table_sink(chunks)
    local ok_su, socketutil = pcall(require, "socketutil")
    if ok_su and socketutil and type(socketutil.table_sink) == "function" then
        return socketutil.table_sink(chunks)
    end
    return ltn12.sink.table(chunks)
end

function Client.request(opts)
    opts = opts or {}
    local url = opts.url
    local method = opts.method or "GET"
    local body = opts.body
    local last_err
    local timeout = math.max(15, tonumber(opts.timeout) or 25)

    Log.dbg("http", "start", {
        method = method,
        url = url,
        timeout = timeout,
        body_bytes = body and #body or 0,
    })

    if Http.has_curl and Http.has_curl() then
        local started = Log.now_ms()
        local res = Http.request_sync({
            url = url,
            method = method,
            body = body,
            timeout = timeout,
            user_agent = opts.user_agent,
            referer = opts.referer or Config.SHELF_URL,
            origin = opts.origin,
            accept = opts.accept,
            send_cookie = opts.send_cookie,
            absorb_cookies = opts.absorb_cookies,
            headers = opts.headers,
        }) or {}
        local text = res.body or ""
        local code = tonumber(res.code) or 0
        local elapsed = Log.now_ms() - started
        local response_headers = headers_from_raw(res.headers)
        if not res.ok then
            local result = res.status or classify(code, res.err)
            Log.warn("http", "failed", {
                method = method,
                url = url,
                err = res.err or result,
                elapsed_ms = math.floor(elapsed + 0.5),
            })
            return nil, result, res.err or text, code, response_headers
        end
        return text, "ok", nil, code, response_headers
    end

    for hop = 0, MAX_REDIRECTS do
        local client = transport_for(url)
        if not client or type(client.request) ~= "function" then
            return nil, "offline", "http client unavailable"
        end
        local headers = {
            ["User-Agent"] = opts.user_agent or Config.KINDLE_UA,
            ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8",
            ["Cache-Control"] = "no-cache",
            Pragma = "no-cache",
            Referer = opts.referer or Config.SHELF_URL,
            Accept = opts.accept or "*/*",
        }
        if opts.send_cookie ~= false then
            headers.Cookie = CookieStore.header()
        end
        if opts.origin then
            headers.Origin = opts.origin
        end
        if type(opts.headers) == "table" then
            for key, value in pairs(opts.headers) do
                if value ~= nil then
                    headers[key] = value
                end
            end
        end
        if body then
            headers["Content-Length"] = tostring(#body)
            headers["Content-Type"] = headers["Content-Type"] or "application/json;charset=UTF-8"
        end

        local chunks = {}
        local started = Log.now_ms()
        local reset = apply_timeout(timeout)
        local request = {
            url = url,
            method = method,
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = table_sink(chunks),
        }

        -- newsdownloader pattern: code, headers, status = socket.skip(1, http.request(...))
        local ok_call, code, response_headers, status = pcall(function()
            return socket.skip(1, client.request(request))
        end)
        reset()
        local text = table.concat(chunks)
        local elapsed = Log.now_ms() - started

        if not ok_call then
            last_err = tostring(code)
            Log.warn("http", "threw", {
                method = method,
                url = url,
                err = last_err,
                elapsed_ms = math.floor(elapsed + 0.5),
            })
            return nil, "offline", last_err
        end

        -- Timeout sentinels from socketutil
        local ok_su, socketutil = pcall(require, "socketutil")
        if ok_su and socketutil then
            if code == socketutil.TIMEOUT_CODE
                or code == socketutil.SSL_HANDSHAKE_CODE
                or code == socketutil.SINK_TIMEOUT_CODE then
                Log.warn("http", "failed", {
                    method = method,
                    url = url,
                    err = tostring(status or code),
                    elapsed_ms = math.floor(elapsed + 0.5),
                })
                return nil, "offline", tostring(status or code)
            end
        end

        if code == nil and response_headers == nil then
            last_err = tostring(status or "network unreachable")
            Log.warn("http", "failed", {
                method = method,
                url = url,
                err = last_err,
                elapsed_ms = math.floor(elapsed + 0.5),
            })
            return nil, classify(0, last_err), last_err
        end

        code = tonumber(code)
        if opts.absorb_cookies ~= false then
            absorb_cookies(response_headers)
        end
        local location = header_get(response_headers, "location")
        local result = classify(code, status)
        Log.dbg("http", "done", {
            method = method,
            url = url,
            code = code,
            result = result,
            bytes = #text,
            elapsed_ms = math.floor(elapsed + 0.5),
        })

        if code and code >= 300 and code < 400 and location and hop < MAX_REDIRECTS then
            url = absolute_url(url, location)
            if code == 303 then
                method, body = "GET", nil
            end
        else
            if result ~= "ok" then
                return nil, result, text, code, response_headers
            end
            return text, result, nil, code, response_headers
        end
    end
    return nil, "http_error", last_err or "too many redirects"
end

return Client
