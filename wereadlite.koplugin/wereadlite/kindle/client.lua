local ltn12 = require("ltn12")
local Config = require("wereadlite.config")
local CookieStore = require("wereadlite.cookie_store")
local Http = require("wereadlite.async_http")
local Log = require("wereadlite.log")

local Client = {}

local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")

local MAX_REDIRECTS = 5

local function tcp_create(seconds)
    local ok, socket = pcall(require, "socket")
    if not ok or not socket or type(socket.tcp) ~= "function" then
        return nil
    end
    return function()
        local sock = socket.tcp()
        if sock and sock.settimeout then
            sock:settimeout(seconds)
        end
        return sock
    end
end

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
    local old = {}
    if ok_http and http then
        old.http = http.TIMEOUT
        old.http_set = true
        http.TIMEOUT = seconds
    end
    if ok_https and https then
        old.https = https.TIMEOUT
        old.https_set = true
        https.TIMEOUT = seconds
    end
    local ok_sock, socket = pcall(require, "socket")
    if ok_sock and socket then
        old.socket = socket.TIMEOUT
        old.socket_set = true
        socket.TIMEOUT = seconds
    end
    local ok_su, socketutil = pcall(require, "socketutil")
    if ok_su and socketutil and type(socketutil.set_timeout) == "function" then
        pcall(socketutil.set_timeout, socketutil, seconds, seconds + 20)
        old.socketutil = socketutil
    end
    return function()
        if old.http_set then
            http.TIMEOUT = old.http
        end
        if old.https_set then
            https.TIMEOUT = old.https
        end
        if old.socket_set then
            socket.TIMEOUT = old.socket
        end
        if old.socketutil then
            pcall(old.socketutil.reset_timeout, old.socketutil)
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
    local text = tostring(err or "")
    if code == 401 or code == 403 then
        return "auth_expired"
    end
    if code >= 200 and code < 400 then
        return "ok"
    end
    if code > 0 then
        return "http_error"
    end
    if text:find("timeout", 1, true)
        or text:find("closed", 1, true)
        or text:find("refused", 1, true)
        or text:find("Network is unreachable", 1, true) then
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

function Client.request(opts)
    opts = opts or {}
    local url = opts.url
    local method = opts.method or "GET"
    local body = opts.body
    local last_err
    local timeout = opts.timeout or 20

    Log.dbg("http", "start", {
        method = method,
        url = url,
        timeout = timeout,
        body_bytes = body and #body or 0,
    })

    if Http.available() then
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
        Log.dbg("http", "done", {
            method = method,
            url = url,
            code = code,
            result = "ok",
            bytes = #text,
            elapsed_ms = math.floor(elapsed + 0.5),
        })
        return text, "ok", nil, code, response_headers
    end

    for hop = 0, MAX_REDIRECTS do
        local client = transport_for(url)
        if not client or type(client.request) ~= "function" then
            Log.warn("http", "no_client", { url = url })
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
        if Log.is_verbose() then
            Log.http_request(method, url, headers, body, { timeout = timeout, hop = hop })
        end
        local reset = apply_timeout(timeout)
        local req = {
            url = url,
            method = method,
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = ltn12.sink.table(chunks),
            timeout = timeout,
        }
        -- LuaSec HTTPS forbids a custom create callback.
        if not tostring(url):match("^https://") then
            local create = tcp_create(timeout)
            if create then
                req.create = create
            end
        end
        local called, res, code, response_headers, status = pcall(client.request, req)
        reset()
        local text = table.concat(chunks)
        local elapsed = Log.now_ms() - started
        if not called then
            last_err = tostring(res)
            Log.warn("http", "threw", {
                method = method,
                url = url,
                err = last_err,
                elapsed_ms = math.floor(elapsed + 0.5),
            })
            return nil, "offline", last_err
        end
        if not res then
            last_err = tostring(code or status or "request failed")
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
        if Log.is_verbose() then
            Log.http_response(method, url, code, status, response_headers, text, {
                result = result,
                elapsed_ms = elapsed,
            })
        else
            Log.dbg("http", "done", {
                method = method,
                url = url,
                code = code,
                result = result,
                bytes = #text,
                elapsed_ms = math.floor(elapsed + 0.5),
            })
        end
        if code and code >= 300 and code < 400 and location and hop < MAX_REDIRECTS then
            local next_url = absolute_url(url, location)
            Log.info("http", "redirect", {
                code = code,
                from = url,
                to = next_url,
                hop = hop + 1,
            })
            url = next_url
            if code == 303 then
                method, body = "GET", nil
            end
        else
            if result ~= "ok" then
                Log.warn("http", "status", {
                    result = result,
                    code = code,
                    url = url,
                    status = status,
                    bytes = #text,
                })
                return nil, result, text, code, response_headers
            end
            return text, result, nil, code, response_headers
        end
    end
    Log.warn("http", "redirect_limit", { url = url, err = last_err })
    return nil, "http_error", last_err or "too many redirects"
end

return Client
