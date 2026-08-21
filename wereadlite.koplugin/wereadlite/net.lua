local Log = require("wereadlite.log")

local Net = {}

local function manager()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok then
        return NetworkMgr
    end
end

local function call(nm, name, ...)
    if not nm or type(nm[name]) ~= "function" then
        return false
    end
    local ok, result = pcall(nm[name], nm, ...)
    if not ok then
        Log.warn("net", name, { err = result })
        return false
    end
    return true, result
end

-- Never call NetworkMgr:isOnline(): it does a blocking DNS lookup.
function Net.is_online()
    local Device = require("device")
    if type(Device.hasWifiToggle) ~= "function" or not Device:hasWifiToggle() then
        return true
    end
    return Net.is_wifi_on()
end

function Net.is_wifi_on()
    local nm = manager()
    if not nm then
        return true
    end
    local ok, value = call(nm, "isWifiOn")
    if not ok then
        return true
    end
    if value == nil then
        return true
    end
    return value == true
end

function Net.open_wifi_menu(done)
    local nm = manager()
    if not nm then
        if done then done() end
        return false
    end
    if type(nm.reconnectOrShowNetworkMenu) == "function" then
        return call(nm, "reconnectOrShowNetworkMenu", done, true)
    end
    if type(nm.toggleWifiOn) == "function" then
        return call(nm, "toggleWifiOn", done, true, true)
    end
    if type(nm.turnOnWifi) == "function" then
        return call(nm, "turnOnWifi", done, true)
    end
    if done then done() end
    return false
end

return Net
