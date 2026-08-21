local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")

local ok_geom, Geom = pcall(require, "ui/geometry")
if not ok_geom then
    Geom = require("ui/geom")
end

local Panel = InputContainer:extend{
    title = "",
    body = "",
    buttons = nil,
    on_close = nil,
}

function Panel:init()
    self.covers_fullscreen = true
    self.fullscreen = true
    local width = Screen:getWidth()
    local height = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = width, h = height }

    local title_bar = TitleBar:new{
        width = width,
        fullscreen = true,
        title = self.title,
        with_bottom_line = true,
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }

    local body_width = width - 2 * Size.padding.large
    local inner = VerticalGroup:new{ align = "center" }
    table.insert(inner, TextBoxWidget:new{
        text = self.body or "",
        face = Font:getFace("infofont"),
        width = body_width,
        alignment = "center",
    })
    for _, spec in ipairs(self.buttons or {}) do
        table.insert(inner, VerticalSpan:new{ width = Size.padding.large })
        table.insert(inner, Button:new{
            text = spec.text,
            width = math.floor(body_width * 0.8),
            callback = spec.callback,
            show_parent = self,
        })
    end

    local title_h = title_bar:getHeight()
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        width = width,
        height = height,
        VerticalGroup:new{
            align = "left",
            title_bar,
            CenterContainer:new{
                dimen = Geom:new{ w = width, h = math.max(0, height - title_h) },
                inner,
            },
        },
    }

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back }, doc = "close" },
        }
    end
end

function Panel:onClose()
    UIManager:close(self)
    if self.on_close then
        self.on_close()
    end
    return true
end

return Panel
