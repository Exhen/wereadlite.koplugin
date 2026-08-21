local Config = require("wereadlite.config")
local Panel = require("wereadlite.panel")
local Session = require("wereadlite.session")

local AppView = {}

function AppView.new(opts)
    opts = opts or {}
    local name = Session.display_name()
    local who = name and ("当前账号：" .. name) or "已登录。"
    return Panel:new{
        title = Config.NAME,
        body = who .. "\n书架与阅读将在 Kindle 接口接入后实现。",
        buttons = {},
        on_close = opts.on_close,
    }
end

return AppView
