local Nuxt = {}

function Nuxt.unescape(text)
    text = tostring(text or "")
    text = text:gsub("\\u(%x%x%x%x)", function(hex)
        local n = tonumber(hex, 16) or 0
        if n < 128 then
            return string.char(n)
        elseif n < 2048 then
            return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64)
        end
        return string.char(
            0xE0 + math.floor(n / 4096),
            0x80 + math.floor(n / 64) % 64,
            0x80 + n % 64
        )
    end)
    return (text:gsub("\\/", "/"))
end

function Nuxt.parse_args(text)
    local args = {}
    local index, length = 1, #tostring(text or "")
    text = tostring(text or "")
    while index <= length do
        local char = text:sub(index, index)
        if char:match("%s") or char == "," then
            index = index + 1
        elseif char == '"' then
            local chunk, cursor = {}, index + 1
            while cursor <= length do
                local current = text:sub(cursor, cursor)
                if current == "\\" then
                    local next_char = text:sub(cursor + 1, cursor + 1)
                    if next_char == "u" then
                        chunk[#chunk + 1] = Nuxt.unescape("\\u" .. text:sub(cursor + 2, cursor + 5))
                        cursor = cursor + 6
                    else
                        chunk[#chunk + 1] = next_char == "/" and "/" or next_char
                        cursor = cursor + 2
                    end
                elseif current == '"' then
                    break
                else
                    chunk[#chunk + 1] = current
                    cursor = cursor + 1
                end
            end
            args[#args + 1] = table.concat(chunk)
            index = cursor + 1
        elseif text:sub(index, index + 7) == "Array(" then
            local close = text:find("%)", index)
            args[#args + 1] = {}
            index = (close or index) + 1
        elseif char == "{" then
            local _, last = text:find("%b{}", index)
            args[#args + 1] = {}
            index = (last or index) + 1
        elseif text:sub(index, index + 8) == "undefined" then
            args[#args + 1] = ""
            index = index + 9
        elseif text:sub(index, index + 3) == "true" then
            args[#args + 1] = true
            index = index + 4
        elseif text:sub(index, index + 4) == "false" then
            args[#args + 1] = false
            index = index + 5
        elseif text:sub(index, index + 3) == "null" then
            args[#args + 1] = ""
            index = index + 4
        else
            local number = text:match("^%-?%d+", index)
            if number then
                args[#args + 1] = tonumber(number)
                index = index + #number
            else
                index = index + 1
            end
        end
    end
    return args
end

function Nuxt.env(html)
    html = tostring(html or "")
    local params = html:match("window%.__NUXT__=%(function%(([^)]*)%)")
    local args_src = html:match("window%.__NUXT__=%(function%([^)]*%){.*}%((.*)%)%);")
    if not args_src then
        args_src = html:match("window%.__NUXT__=%(function%([^)]*%){return .*%}%}%}%((.*)%)%);")
    end
    if not params or not args_src then
        return {}
    end
    local names, values, env = {}, Nuxt.parse_args(args_src), {}
    for name in params:gmatch("[^,%s]+") do
        names[#names + 1] = name
    end
    for i, name in ipairs(names) do
        env[name] = values[i]
    end
    return env
end

function Nuxt.resolve(token, env)
    if token == nil then
        return nil
    end
    token = tostring(token)
    if token:sub(1, 1) == '"' then
        return Nuxt.unescape(token:sub(2, -2))
    end
    if env and env[token] ~= nil then
        return env[token]
    end
    return token
end

function Nuxt.scalar(token, env)
    local value = Nuxt.resolve(token, env)
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        return value
    end
    return tostring(value or "")
end

local function skip_sep(text, index, length)
    while index <= length do
        local ch = text:sub(index, index)
        if ch:match("%s") or ch == "," then
            index = index + 1
        else
            break
        end
    end
    return index
end

local function parse_quoted(text, index, length)
    local chunk = {}
    local cursor = index + 1
    while cursor <= length do
        local current = text:sub(cursor, cursor)
        if current == "\\" then
            local next_char = text:sub(cursor + 1, cursor + 1)
            if next_char == "u" then
                chunk[#chunk + 1] = Nuxt.unescape("\\u" .. text:sub(cursor + 2, cursor + 5))
                cursor = cursor + 6
            else
                chunk[#chunk + 1] = next_char == "/" and "/" or next_char
                cursor = cursor + 2
            end
        elseif current == '"' then
            return table.concat(chunk), cursor + 1
        else
            chunk[#chunk + 1] = current
            cursor = cursor + 1
        end
    end
    return table.concat(chunk), cursor
end

local parse_value_at
local parse_object_at
local parse_array_at

parse_object_at = function(text, index, env, length)
    local obj = {}
    index = index + 1
    while index <= length do
        index = skip_sep(text, index, length)
        if text:sub(index, index) == "}" then
            return obj, index + 1
        end
        local key
        if text:sub(index, index) == '"' then
            key, index = parse_quoted(text, index, length)
        else
            key = text:match("^[%w_]+", index)
            if key then
                index = index + #key
            else
                index = index + 1
            end
        end
        index = skip_sep(text, index, length)
        if text:sub(index, index) == ":" then
            index = index + 1
        end
        local value
        value, index = parse_value_at(text, index, env, length)
        if key and key ~= "" then
            obj[key] = value
        end
    end
    return obj, index
end

parse_array_at = function(text, index, env, length)
    local arr = {}
    index = index + 1
    while index <= length do
        index = skip_sep(text, index, length)
        if text:sub(index, index) == "]" then
            return arr, index + 1
        end
        local value
        value, index = parse_value_at(text, index, env, length)
        arr[#arr + 1] = value
    end
    return arr, index
end

parse_value_at = function(text, index, env, length)
    index = skip_sep(text, index or 1, length)
    if index > length then
        return nil, index
    end
    local ch = text:sub(index, index)
    if ch == '"' then
        return parse_quoted(text, index, length)
    end
    if ch == "{" then
        return parse_object_at(text, index, env, length)
    end
    if ch == "[" then
        return parse_array_at(text, index, env, length)
    end
    if text:sub(index, index + 8) == "undefined" then
        return nil, index + 9
    end
    if text:sub(index, index + 3) == "true" and not text:sub(index + 4, index + 4):match("[%w_]") then
        return true, index + 4
    end
    if text:sub(index, index + 4) == "false" and not text:sub(index + 5, index + 5):match("[%w_]") then
        return false, index + 5
    end
    if text:sub(index, index + 3) == "null" and not text:sub(index + 4, index + 4):match("[%w_]") then
        return nil, index + 4
    end
    if ch:match("[%d%-]") then
        local number = text:match("^%-?%d+%.?%d*", index)
        if number then
            local after = text:sub(index + #number, index + #number)
            if after == "" or not after:match("[%w_]") then
                return tonumber(number), index + #number
            end
        end
    end
    local token = text:match("^[%w_]+", index)
    if token then
        return Nuxt.resolve(token, env), index + #token
    end
    return nil, index + 1
end

function Nuxt.parse_value(text, index, env)
    text = tostring(text or "")
    return parse_value_at(text, index or 1, env, #text)
end

function Nuxt.parse_object(text, env)
    text = tostring(text or "")
    local start = text:find("{", 1, true)
    if not start then
        return {}
    end
    local obj = parse_object_at(text, start, env, #text)
    return type(obj) == "table" and obj or {}
end

function Nuxt.parse_field(html, key, env)
    html = tostring(html or "")
    key = tostring(key or "")
    if key == "" then
        return nil
    end
    local start = html:find(key .. ":", 1, true)
    if not start then
        return nil
    end
    local value = parse_value_at(html, start + #key + 1, env, #html)
    return value
end

return Nuxt
