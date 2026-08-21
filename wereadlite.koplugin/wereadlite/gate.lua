local UIManager = require("ui/uimanager")
local Log = require("wereadlite.log")
local Net = require("wereadlite.net")
local Session = require("wereadlite.session")

local Gate = {
    widget = nil,
    state = nil,
}

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
    if not Net.is_online() then
        return "wifi"
    end
    if not Session.has_auth() then
        return "login"
    end
    return "app"
end

function Gate.refresh()
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
