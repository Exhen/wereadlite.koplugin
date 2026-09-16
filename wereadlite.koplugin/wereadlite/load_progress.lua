local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

-- Ordered stages with non-overlapping ranges so the bar only moves forward.
local STAGES = {
    info = { order = 1, from = 0, to = 0.12, text = "获取书籍信息" },
    segments = { order = 2, from = 0.12, to = 0.55, text = "下载分段" },
    images = { order = 3, from = 0.55, to = 0.82, text = "加载图片" },
    reviews = { order = 4, from = 0.82, to = 1, text = "获取划线内容" },
}

local LoadProgress = InputContainer:extend{
    modal = true,
    on_cancel = nil,
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

-- Unknown total stays at the stage start (never jumps to stage end).
local function fraction(done, total)
    done = tonumber(done) or 0
    total = tonumber(total) or 0
    if total <= 0 then
        return 0
    end
    return clamp(done / total)
end

function LoadProgress:init()
    self.dimen = Screen:getSize()
    self._percent = 0
    self._stage_order = 0
    local width = Screen:getWidth() - Screen:scaleBySize(80)
    self.title_widget = TextWidget:new{
        text = STAGES.info.text,
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
    self.cancel_button = Button:new{
        text = "取消加载",
        width = math.min(width, Screen:scaleBySize(160)),
        bordersize = Size.border.button,
        radius = Size.radius.button,
        show_parent = self,
        callback = function()
            self:request_cancel()
        end,
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
                VerticalSpan:new{ width = Size.padding.large },
                self.cancel_button,
            },
        },
    }
    if Device:hasKeys() then
        self.key_events = {
            Cancel = { { Device.input.group.Back }, doc = "cancel load" },
        }
    end
end

function LoadProgress:request_cancel()
    if self._cancelled then
        return true
    end
    self._cancelled = true
    self.title_widget:setText("正在取消…")
    self.subtitle_widget:setText(" ")
    self:paint()
    if type(self.on_cancel) == "function" then
        pcall(self.on_cancel)
    end
    return true
end

function LoadProgress:onCancel()
    return self:request_cancel()
end

function LoadProgress:paint()
    UIManager:setDirty(self, function()
        return "fast", self.dimen
    end)
    UIManager:forceRePaint()
end

function LoadProgress:update(stage, done, total)
    if self._cancelled then
        return
    end
    local spec = STAGES[stage] or STAGES.info
    local order = tonumber(spec.order) or 0
    -- Ignore stale callbacks from an earlier pipeline stage.
    if order < (self._stage_order or 0) then
        return
    end
    self._stage_order = order

    total = tonumber(total) or 0
    done = tonumber(done) or 0
    local percent = spec.from + (spec.to - spec.from) * fraction(done, total)
    -- Never roll the bar backwards (e.g. entering a stage at 0 after a prior peak).
    if percent < (self._percent or 0) then
        percent = self._percent
    end
    self._percent = percent

    local subtitle = " "
    if total > 0 then
        subtitle = string.format("%d/%d", math.min(done, total), total)
    end
    self.title_widget:setText(spec.text)
    self.subtitle_widget:setText(subtitle)
    self.bar:setPercentage(percent)
    self:paint()
end

function LoadProgress.open(opts)
    opts = opts or {}
    local widget = LoadProgress:new{
        on_cancel = opts.on_cancel,
    }
    UIManager:show(widget, "ui")
    widget:update("info", 0, 0)
    return widget
end

function LoadProgress:close()
    UIManager:close(self, "ui")
    UIManager:forceRePaint()
end

return LoadProgress
