local Log = require("wereadlite.log")
local Paths = require("wereadlite.paths")

local CookieStore = {}

local jar
local AUTH_KEYS = { "wr_vid", "wr_skey" }
local RESERVED = {
    path = true,
    domain = true,
    expires = true,
    ["max-age"] = true,
    samesite = true,
    secure = true,
    httponly = true,
}

local function data_dir()
    return Paths.data_dir()
end

local function cookies_path()
    return data_dir() .. "/cookies.lua"
end

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function quote(value)
    return string.format("%q", tostring(value))
end

local function empty_jar(source)
    return {
        version = 1,
        updated_at = os.time(),
        source = source or "empty",
        order = {},
        cookies = {},
    }
end

local function add_cookie(target, name, value, extra)
    if not name or name == "" or RESERVED[name:lower()] then
        return
    end
    extra = extra or {}
    if not target.cookies[name] then
        target.order[#target.order + 1] = name
    end
    local row = target.cookies[name] or { name = name }
    row.name = name
    row.value = value or ""
    if extra.domain then row.domain = extra.domain end
    if extra.path then row.path = extra.path end
    if extra.expires then row.expires = extra.expires end
    target.cookies[name] = row
end

function CookieStore.parse_header(text)
    local parsed = empty_jar("import")
    for part in tostring(text or ""):gmatch("[^;]+") do
        local pair = trim(part)
        local name, value = pair:match("^([^=]+)=(.*)$")
        if name then
            add_cookie(parsed, trim(name), trim(value))
        end
    end
    return parsed
end

local function split_set_cookie_lines(raw)
    if type(raw) == "table" then
        local out = {}
        for _, value in pairs(raw) do
            local rows = split_set_cookie_lines(value)
            for i = 1, #rows do
                out[#out + 1] = rows[i]
            end
        end
        return out
    end
    local text = tostring(raw or "")
    if text:find("\r", 1, true) or text:find("\n", 1, true) then
        local out = {}
        for line in text:gmatch("[^\r\n]+") do
            local rows = split_set_cookie_lines(line)
            for i = 1, #rows do
                out[#out + 1] = rows[i]
            end
        end
        return out
    end
    -- LuaSocket joins multiple Set-Cookie with ", ". Expires values also contain commas.
    local out, start, in_expires = {}, 1, false
    local lower = text:lower()
    for i = 1, #text do
        if lower:sub(i, i + 7) == "expires=" then
            in_expires = true
        end
        local ch = text:sub(i, i)
        if in_expires and ch == ";" then
            in_expires = false
        end
        if ch == "," and not in_expires then
            local next_name = text:sub(i + 1):match("^%s*([^=;,]+)=")
            if next_name and not RESERVED[trim(next_name):lower()] then
                out[#out + 1] = trim(text:sub(start, i - 1))
                start = i + 1
            end
        end
    end
    if start <= #text then
        out[#out + 1] = trim(text:sub(start))
    end
    return out
end

local function parse_one_set_cookie(text)
    text = trim(text)
    if text == "" then
        return nil
    end
    local first = true
    local current
    for part in text:gmatch("[^;]+") do
        local piece = trim(part)
        local name, value = piece:match("^([^=]+)=(.*)$")
        if first then
            if name then
                current = {
                    name = trim(name),
                    value = trim(value),
                }
            end
            first = false
        elseif current and name then
            local key = trim(name):lower()
            if key == "domain" or key == "path" or key == "expires" or key == "max-age" then
                current[key == "max-age" and "max_age" or key] = trim(value)
            end
        end
    end
    return current
end

function CookieStore.parse_set_cookie(raw)
    local parsed = {}
    for _, line in ipairs(split_set_cookie_lines(raw)) do
        local row = parse_one_set_cookie(line)
        if row and row.name then
            parsed[#parsed + 1] = row
        end
    end
    return parsed
end

local function serialize(target)
    local lines = {
        "-- MiuRead Lite cookie jar. Do not commit this file.",
        "return {",
        "    version = " .. tostring(target.version or 1) .. ",",
        "    updated_at = " .. tostring(target.updated_at or os.time()) .. ",",
        "    source = " .. quote(target.source or "unknown") .. ",",
        "    order = {",
    }
    for _, name in ipairs(target.order or {}) do
        lines[#lines + 1] = "        " .. quote(name) .. ","
    end
    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "    cookies = {"
    for _, name in ipairs(target.order or {}) do
        local row = target.cookies[name]
        if row then
            lines[#lines + 1] = "        [" .. quote(name) .. "] = {"
            lines[#lines + 1] = "            name = " .. quote(row.name or name) .. ","
            lines[#lines + 1] = "            value = " .. quote(row.value or "") .. ","
            if row.domain then
                lines[#lines + 1] = "            domain = " .. quote(row.domain) .. ","
            end
            if row.path then
                lines[#lines + 1] = "            path = " .. quote(row.path) .. ","
            end
            if row.expires then
                lines[#lines + 1] = "            expires = " .. quote(row.expires) .. ","
            end
            lines[#lines + 1] = "        },"
        end
    end
    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

function CookieStore.path()
    return cookies_path()
end

function CookieStore.data_dir()
    return data_dir()
end

function CookieStore.exists()
    local file = io.open(cookies_path(), "r")
    if not file then
        return false
    end
    file:close()
    return true
end

function CookieStore.load(force)
    if jar and not force then
        return jar
    end
    if CookieStore.exists() then
        local loader, err = loadfile(cookies_path())
        if loader then
            local ok, data = pcall(loader)
            if ok and type(data) == "table" and type(data.cookies) == "table" then
                jar = data
                jar.order = jar.order or {}
                jar.cookies = jar.cookies or {}
                Log.dbg("cookies", "load", { count = #(jar.order or {}), empty = false })
                return jar
            end
            Log.warn("cookies", "invalid_jar", { err = err or data })
        end
    end
    jar = empty_jar("empty")
    Log.dbg("cookies", "load", { empty = true })
    return jar
end

function CookieStore.save()
    local target = CookieStore.load()
    target.updated_at = os.time()
    Paths.ensure(data_dir())
    local file, err = io.open(cookies_path(), "w")
    if not file then
        Log.warn("cookies", "write_fail", { err = err })
        return false, err
    end
    file:write(serialize(target))
    file:close()
    return true
end

function CookieStore.replace_header(text, source)
    jar = CookieStore.parse_header(text)
    jar.source = source or "import"
    return CookieStore.save()
end

function CookieStore.merge_set_cookie(raw, source)
    local target = CookieStore.load()
    local rows = CookieStore.parse_set_cookie(raw)
    for _, row in ipairs(rows) do
        add_cookie(target, row.name, row.value, row)
    end
    if source then
        target.source = source
    end
    jar = target
    return CookieStore.save()
end

function CookieStore.set(name, value, source)
    local target = CookieStore.load()
    add_cookie(target, name, value)
    if source then
        target.source = source
    end
    jar = target
    return CookieStore.save()
end

function CookieStore.get(name)
    local target = CookieStore.load()
    local row = target.cookies[name]
    if row then
        return row.value
    end
end

function CookieStore.header()
    local target = CookieStore.load()
    local parts = {}
    for _, name in ipairs(target.order or {}) do
        local row = target.cookies[name]
        if row then
            parts[#parts + 1] = name .. "=" .. tostring(row.value or "")
        end
    end
    return table.concat(parts, "; ")
end

function CookieStore.has_auth()
    CookieStore.load()
    for _, name in ipairs(AUTH_KEYS) do
        local value = CookieStore.get(name)
        if not value or value == "" then
            return false
        end
    end
    return true
end

function CookieStore.unescape(value)
    value = tostring(value or ""):gsub("+", " ")
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

function CookieStore.display_name()
    local name = CookieStore.get("wr_name")
    if name and name ~= "" then
        return CookieStore.unescape(name)
    end
    return CookieStore.get("wr_vid")
end

function CookieStore.clear()
    jar = empty_jar("cleared")
    return CookieStore.save()
end

CookieStore.AUTH_KEYS = AUTH_KEYS

return CookieStore
