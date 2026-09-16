local Config = require("wereadlite.config")
local Net = require("wereadlite.net")
local Panel = require("wereadlite.panel")

local WifiView = {}

function WifiView.new(opts)
    opts = opts or {}
    return Panel:new{
        title = Config.NAME,
        body = "未连接到网络。\n请先打开 Wi-Fi 并连接，成功后会自动继续。\n若仍失败，请先退出到系统（Nickel）连一次 Wi-Fi。",
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
