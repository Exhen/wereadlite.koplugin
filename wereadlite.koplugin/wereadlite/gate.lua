local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Log = require("wereadlite.log")
local Net = require("wereadlite.net")
local Session = require("wereadlite.session")

local Gate = {
    widget = nil,
    state = nil,
}

local UNSUPPORTED_MSG = table.concat({
    "本插件仅支持 Kindle 等电纸书设备。",
    "安卓版 KOReader 暂不支持，请使用官方微信读书 App。",
}, "\n")

local function is_android()
    return type(Device.isAndroid) == "function" and Device:isAndroid()
end

function Gate.is_supported()
    return not is_android()
end

function Gate.show_unsupported()
    UIManager:show(InfoMessage:new{
        text = UNSUPPORTED_MSG,
        timeout = 4,
    })
    Log.warn("gate", "unsupported_platform", { android = true })
end

function Gate.block_if_unsupported()
    if Gate.is_supported() then
        return false
    end
    Gate.show_unsupported()
    return true
end

local function close_widget()
    if not Gate.widget then
        return
    end
    UIManager:close(Gate.widget)
    Gate.widget = nil
end

local function after_paint(fn)
    local tick = UIManager.tickAfterNext or UIManager.nextTick
    tick(UIManager, fn)
end

function Gate.is_open()
    return Gate.widget ~= nil
end

function Gate.close()
    close_widget()
    Gate.state = nil
end

function Gate.current_state()
    -- UI gate: Wi‑Fi/link only. DNS readiness is handled at Http.request time
    -- (res_init + NetworkMgr:isOnline), so we do not bounce to wifi_view on
    -- transient resolver stalls after USBMS/resume.
    if not Net.is_connected() and not Net.is_wifi_on() then
        return "wifi"
    end
    if not Session.has_auth() then
        return "login"
    end
    return "app"
end

function Gate.refresh()
    if not Gate.is_supported() then
        close_widget()
        Gate.state = nil
        return
    end
    local state = Gate.current_state()
    if Gate.widget and Gate.state == state then
        return
    end
    Log.info("gate", "refresh", { state = state })
    close_widget()
    Gate.state = state

    local opts = {
        on_close = function()
            Gate.widget = nil
            Gate.state = nil
        end,
        on_connected = function()
            Gate.refresh()
        end,
    }

    if state == "wifi" then
        local WifiView = require("wereadlite.wifi_view")
        Gate.widget = WifiView.new(opts)
    elseif state == "login" then
        local LoginView = require("wereadlite.login_view")
        Gate.widget = LoginView:new{
            on_close = opts.on_close,
            on_logged_in = opts.on_connected,
        }
    else
        local Shelf = require("wereadlite.kindle.shelf")
        local ShelfView = require("wereadlite.shelf_view")
        Shelf.reset()
        Gate.widget = ShelfView:new{
            on_close = opts.on_close,
            on_auth_expired = function()
                Session.clear_auth()
                Gate.state = nil
                Gate.refresh()
            end,
        }
    end
    UIManager:show(Gate.widget)
    UIManager:setDirty("all", "ui")
    if Gate.widget and type(Gate.widget.start_load) == "function" then
        after_paint(function()
            if Gate.widget and type(Gate.widget.start_load) == "function" then
                Gate.widget:start_load()
            end
        end)
    end
end

function Gate.open()
    if Gate.block_if_unsupported() then
        return
    end
    Log.info("gate", "open")
    Gate.state = nil
    Gate.refresh()
end

function Gate.on_network_changed()
    if Gate.is_open() then
        Gate.refresh()
    end
end

return Gate
