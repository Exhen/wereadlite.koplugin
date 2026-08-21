local Config = require("wereadlite.config")
local Net = require("wereadlite.net")
local Panel = require("wereadlite.panel")

local WifiView = {}

function WifiView.new(opts)
    opts = opts or {}
    return Panel:new{
        title = Config.NAME,
        body = "未连接到网络。\n请先设置 Wi-Fi，连接成功后会自动继续。",
        buttons = {
            {
                text = "Wi-Fi 设置",
                callback = function()
                    Net.open_wifi_menu(opts.on_connected)
                end,
            },
        },
        on_close = opts.on_close,
    }
end

return WifiView
