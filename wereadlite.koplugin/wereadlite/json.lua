local ok, engine = pcall(require, "json")
if not ok then
    ok, engine = pcall(require, "rapidjson")
end
if not ok then
    ok, engine = pcall(require, "dkjson")
end

local Json = {}

local function callable(value)
    if type(value) == "function" then
        return value
    end
    if type(value) == "table" then
        local mt = getmetatable(value)
        if mt and type(mt.__call) == "function" then
            return function(...)
                return value(...)
            end
        end
    end
end

function Json.encode(value)
    local encoder = engine and callable(engine.encode or engine.stringify)
    if not encoder then
        return nil, "json encoder unavailable"
    end
    local encoded_ok, encoded = pcall(encoder, value)
    if not encoded_ok then
        return nil, encoded
    end
    return encoded
end

function Json.decode(text)
    local decoder = engine and callable(engine.decode or engine.parse)
    if not decoder then
        return nil, "json decoder unavailable"
    end
    local decoded_ok, data = pcall(decoder, text)
    if not decoded_ok then
        return nil, data
    end
    return data
end

return Json
