local logger = require("logger")
local Config = require("wereadlite.config")

local Log = {}
local TAG = Config.LOG_TAG or "wereadlite"
local BODY_PREVIEW = 512

local SENSITIVE = {
    cookie = true,
    ["set-cookie"] = true,
    authorization = true,
    skey = true,
    wr_skey = true,
    token = true,
    tk = true,
    password = true,
    apikey = true,
    api_key = true,
}

local function now_ms()
    local ok, socket = pcall(require, "socket")
    if ok and socket and type(socket.gettime) == "function" then
        return socket.gettime() * 1000
    end
    return os.time() * 1000
end

function Log.now_ms()
    return now_ms()
end

function Log.is_verbose()
    local info = debug.getinfo(logger.dbg, "u")
    return info and (info.nups or 0) > 0
end

local function fmt_value(key, value)
    if value == nil then
        return "-"
    end
    if type(value) == "boolean" then
        return value and "true" or "false"
    end
    if type(value) == "number" then
        return tostring(value)
    end
    if type(value) == "table" then
        return string.format("{n=%d}", #value)
    end
    local text = tostring(value):gsub("[%c]", " ")
    if SENSITIVE[tostring(key or ""):lower()] then
        return string.format("<redacted len=%d>", #tostring(value))
    end
    if #text > 240 then
        text = text:sub(1, 240) .. "..."
    end
    if text:find("%s") or text:find("=") then
        return '"' .. text:gsub('"', "'") .. '"'
    end
    return text
end

local function format(module, action, fields)
    local parts = { TAG, tostring(module or "-"), tostring(action or "-") }
    if type(fields) == "table" then
        local keys = {}
        for key in pairs(fields) do
            if type(key) == "string" then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            parts[#parts + 1] = key .. "=" .. fmt_value(key, fields[key])
        end
    elseif fields ~= nil then
        parts[#parts + 1] = tostring(fields)
    end
    return table.concat(parts, " ")
end

local function emit(level, module, action, fields)
    local fn = logger[level]
    if type(fn) == "function" then
        fn(format(module, action, fields))
    end
end

function Log.dbg(module, action, fields)
    emit("dbg", module, action, fields)
end

function Log.verbose(module, action, fields)
    if Log.is_verbose() then
        emit("dbg", module, action, fields)
    end
end

function Log.info(module, action, fields)
    emit("info", module, action, fields)
end

function Log.warn(module, action, fields)
    emit("warn", module, action, fields)
end

function Log.err(module, action, fields)
    emit("err", module, action, fields)
end

local function header_name(name)
    return tostring(name or ""):lower()
end

local function cookie_names(value)
    local names = {}
    for name in tostring(value or ""):gmatch("([^;=]+)=") do
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" then
            names[#names + 1] = name
        end
    end
    return names
end

local function redact_header(name, value)
    name = header_name(name)
    value = tostring(value or "")
    if name == "cookie" then
        return string.format("<redacted len=%d names=%s>", #value, table.concat(cookie_names(value), ","))
    end
    if name == "set-cookie" then
        local cookie_name = value:match("^([^;=]+)") or "?"
        return string.format("<redacted name=%s len=%d>", cookie_name, #value)
    end
    if SENSITIVE[name] then
        return string.format("<redacted len=%d>", #value)
    end
    if #value > 300 then
        return value:sub(1, 300) .. "..."
    end
    return value
end

local function dump_headers(kind, headers)
    if type(headers) ~= "table" then
        return
    end
    local names = {}
    for name in pairs(headers) do
        if type(name) == "string" then
            names[#names + 1] = name
        end
    end
    table.sort(names, function(a, b)
        return header_name(a) < header_name(b)
    end)
    for _, name in ipairs(names) do
        Log.verbose("http", kind, {
            header = name,
            value = redact_header(name, headers[name]),
        })
    end
end

local function looks_binary(body, content_type)
    content_type = tostring(content_type or ""):lower()
    if content_type:find("image/", 1, true)
        or content_type:find("octet-stream", 1, true)
        or content_type:find("font/", 1, true)
        or content_type:find("audio/", 1, true)
        or content_type:find("video/", 1, true) then
        return true
    end
    body = tostring(body or "")
    if body == "" then
        return false
    end
    local b1, b2, b3, b4 = body:byte(1, 4)
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then
        return true
    end
    if b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then
        return true
    end
    if body:sub(1, 4) == "RIFF" or body:sub(1, 4) == "wOFF" or body:sub(1, 4) == "OTTO" then
        return true
    end
    local sample = body:sub(1, 64)
    local binary = 0
    for i = 1, #sample do
        local byte = sample:byte(i)
        if byte == 0 or (byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13) then
            binary = binary + 1
        end
    end
    return binary >= 4
end

local function body_preview(body, content_type)
    body = tostring(body or "")
    if body == "" then
        return "", 0
    end
    if looks_binary(body, content_type) then
        return "<binary>", #body
    end
    local text = body:gsub("[%c]", function(ch)
        if ch == "\n" or ch == "\t" or ch == "\r" then
            return " "
        end
        return "?"
    end)
    text = text:gsub("%s+", " ")
    text = text:gsub('"apikey"%s*:%s*"[^"]+"', '"apikey":"<redacted>"')
    text = text:gsub("wrk%-[A-Za-z0-9_%-]+", "wrk-<redacted>")
    if #text > BODY_PREVIEW then
        text = text:sub(1, BODY_PREVIEW) .. "..."
    end
    return text, #body
end

function Log.http_request(method, url, headers, body, extra)
    extra = extra or {}
    Log.verbose("http", "request", {
        method = method,
        url = url,
        timeout = extra.timeout,
        hop = extra.hop,
        body_bytes = body and #body or 0,
    })
    dump_headers("req_header", headers)
    if body and body ~= "" then
        local preview, bytes = body_preview(body, headers and headers["Content-Type"])
        Log.verbose("http", "req_body", {
            bytes = bytes,
            preview = preview,
        })
    end
end

function Log.http_response(method, url, code, status, headers, body, extra)
    extra = extra or {}
    local content_type
    if type(headers) == "table" then
        for name, value in pairs(headers) do
            if type(name) == "string" and name:lower() == "content-type" then
                content_type = value
                break
            end
        end
    end
    local preview, bytes = body_preview(body, content_type)
    Log.verbose("http", "response", {
        method = method,
        url = url,
        code = code,
        status = status,
        result = extra.result,
        bytes = bytes,
        elapsed_ms = extra.elapsed_ms and math.floor(extra.elapsed_ms + 0.5) or nil,
        content_type = content_type,
    })
    dump_headers("res_header", headers)
    if preview ~= "" then
        Log.verbose("http", "res_body", {
            bytes = bytes,
            preview = preview,
        })
    end
end

function Log.http_error(method, url, extra)
    extra = extra or {}
    local preview
    if extra.body and extra.body ~= "" then
        preview = body_preview(extra.body, extra.content_type)
    end
    Log.warn("http", "error", {
        method = method,
        url = url,
        code = extra.code,
        exit = extra.exit,
        status = extra.status,
        writeout = extra.writeout,
        header = extra.status_line,
        err = extra.err and tostring(extra.err):gsub("[%c]", " "):sub(1, 180) or nil,
        bytes = extra.bytes,
        body = (preview and preview ~= "") and preview or nil,
    })
end

return Log
