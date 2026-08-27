local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local STAGES = {
    download = { from = 0, to = 0.30, text = "下载章节" },
    load = { from = 0.30, to = 0.60, text = "加载章节" },
    images = { from = 0.60, to = 0.85, text = "下载书内图片" },
    reviews = { from = 0.85, to = 1, text = "加载划线" },
}

local LoadProgress = InputContainer:extend{
    modal = true,
}

local function clamp(value)
    if value < 0 then
        return 0
    end
    if value > 1 then
        return 1
    end
    return value
end

local function fraction(done, total)
    done = tonumber(done) or 0
    total = tonumber(total) or 0
    if total <= 0 then
        return 1
    end
    return clamp(done / total)
end

function LoadProgress:init()
    self.dimen = Screen:getSize()
    local width = Screen:getWidth() - Screen:scaleBySize(80)
    self.title_widget = TextWidget:new{
        text = STAGES.download.text,
        face = Font:getFace("ffont"),
        bold = true,
        max_width = width,
    }
    self.subtitle_widget = TextWidget:new{
        text = " ",
        face = Font:getFace("smallffont"),
        max_width = width,
    }
    self.bar = ProgressWidget:new{
        fillcolor = Blitbuffer.COLOR_BLACK,
        width = width,
        height = Screen:scaleBySize(18),
        padding = Size.padding.large,
        margin = Size.margin.tiny,
        percentage = 0,
    }
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        FrameContainer:new{
            radius = Size.radius.window,
            bordersize = Size.border.window,
            padding = Size.padding.large,
            background = Blitbuffer.COLOR_WHITE,
            VerticalGroup:new{
                align = "center",
                self.title_widget,
                VerticalSpan:new{ width = Size.padding.small },
                self.subtitle_widget,
                VerticalSpan:new{ width = Size.padding.small },
                self.bar,
            },
        },
    }
end

function LoadProgress:paint()
    UIManager:setDirty(self, function()
        return "fast", self.dimen
    end)
    UIManager:forceRePaint()
end

function LoadProgress:update(stage, done, total)
    local spec = STAGES[stage] or STAGES.download
    local percent = spec.from + (spec.to - spec.from) * fraction(done, total)
    local subtitle = " "
    total = tonumber(total) or 0
    done = tonumber(done) or 0
    if total > 0 then
        subtitle = string.format("%d/%d", math.min(done, total), total)
    end
    self.title_widget:setText(spec.text)
    self.subtitle_widget:setText(subtitle)
    self.bar:setPercentage(percent)
    self:paint()
end

function LoadProgress.open()
    local widget = LoadProgress:new{}
    UIManager:show(widget, "ui")
    widget:update("download", 0, 1)
    return widget
end

function LoadProgress:close()
    UIManager:close(self, "ui")
    UIManager:forceRePaint()
end

return LoadProgress
