local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Screen = Device.screen

local ok_geom, Geom = pcall(require, "ui/geometry")
if not ok_geom then
    Geom = require("ui/geom")
end

local WEEKDAYS = { "日", "一", "二", "三", "四", "五", "六" }

-- A B C D E F G
local DIGITS = {
    [0] = { 1, 1, 1, 1, 1, 1, 0 },
    [1] = { 0, 1, 1, 0, 0, 0, 0 },
    [2] = { 1, 1, 0, 1, 1, 0, 1 },
    [3] = { 1, 1, 1, 1, 0, 0, 1 },
    [4] = { 0, 1, 1, 0, 0, 1, 1 },
    [5] = { 1, 0, 1, 1, 0, 1, 1 },
    [6] = { 1, 0, 1, 1, 1, 1, 1 },
    [7] = { 1, 1, 1, 0, 0, 0, 0 },
    [8] = { 1, 1, 1, 1, 1, 1, 1 },
    [9] = { 1, 1, 1, 1, 0, 1, 1 },
}

local ClockCard = {}

local SevenClock = WidgetContainer:extend{
    width = 1,
    height = 1,
}

function SevenClock:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

local function chamfer_for(t, span)
    local tip = math.max(1, math.floor(t * 0.30))
    local limit = math.max(1, math.floor((span - 2) / 2))
    local half = math.max(1, math.floor(t / 2))
    if tip > limit then
        tip = limit
    end
    if tip > half then
        tip = half
    end
    return tip
end

local function paint_h(bb, x, y, w, t, color)
    if w < 3 or t < 1 then
        return
    end
    local chamfer = chamfer_for(t, w)
    for i = 0, t - 1 do
        local from_edge = math.min(i, t - 1 - i)
        local inset = chamfer - from_edge
        if inset < 0 then
            inset = 0
        end
        local sw = w - inset * 2
        if sw > 0 then
            bb:paintRect(x + inset, y + i, sw, 1, color)
        end
    end
end

local function paint_v(bb, x, y, t, h, color)
    if h < 3 or t < 1 then
        return
    end
    local chamfer = chamfer_for(t, h)
    for i = 0, t - 1 do
        local from_edge = math.min(i, t - 1 - i)
        local inset = chamfer - from_edge
        if inset < 0 then
            inset = 0
        end
        local sh = h - inset * 2
        if sh > 0 then
            bb:paintRect(x + i, y + inset, 1, sh, color)
        end
    end
end

local function paint_segments(bb, x, y, w, h, segs, color)
    local t = math.max(2, math.floor(math.min(w, h) * 0.18))
    local gap = math.max(1, math.floor(t * 0.22))
    local inner = math.max(3, w - t)
    local half = math.floor((h - t) / 2)
    local upper = math.max(3, half - t - gap * 2)
    local lower = math.max(3, h - half - t * 2 - gap * 2)
    local bar_w = math.max(1, inner - t - gap * 2)
    if segs[1] == 1 then
        paint_h(bb, x + t + gap, y, bar_w, t, color)
    end
    if segs[2] == 1 then
        paint_v(bb, x + w - t, y + t + gap, t, upper, color)
    end
    if segs[3] == 1 then
        paint_v(bb, x + w - t, y + half + t + gap, t, lower, color)
    end
    if segs[4] == 1 then
        paint_h(bb, x + t + gap, y + h - t, bar_w, t, color)
    end
    if segs[5] == 1 then
        paint_v(bb, x, y + half + t + gap, t, lower, color)
    end
    if segs[6] == 1 then
        paint_v(bb, x, y + t + gap, t, upper, color)
    end
    if segs[7] == 1 then
        paint_h(bb, x + t + gap, y + half, bar_w, t, color)
    end
end

local ALL_ON = { 1, 1, 1, 1, 1, 1, 1 }

local function paint_digit(bb, x, y, w, h, value)
    paint_segments(bb, x, y, w, h, ALL_ON, Blitbuffer.COLOR_LIGHT_GRAY)
    local segs = DIGITS[tonumber(value) or 0] or DIGITS[0]
    paint_segments(bb, x, y, w, h, segs, Blitbuffer.COLOR_BLACK)
end

local function layout_digits(width, area_h)
    local ratio = 0.56
    local digit_h = math.max(10, area_h)
    local digit_w = math.max(6, math.floor(digit_h * ratio))
    local function metrics(dw)
        local gap = math.max(3, math.floor(dw * 0.22))
        local colon_w = math.max(4, math.floor(dw * 0.38))
        return gap, colon_w, dw * 4 + colon_w + gap * 4
    end
    local gap, colon_w, total = metrics(digit_w)
    if total > width then
        local scale = width / total
        digit_w = math.max(6, math.floor(digit_w * scale))
        gap, colon_w, total = metrics(digit_w)
        while total > width and digit_w > 6 do
            digit_w = digit_w - 1
            gap, colon_w, total = metrics(digit_w)
        end
        digit_h = math.max(10, math.min(area_h, math.floor(digit_w / ratio)))
    else
        local extra = width - total
        local max_gap = math.max(gap, math.floor(digit_w * 0.55))
        local add = math.min(max_gap - gap, math.floor(extra / 4))
        if add > 0 then
            gap = gap + add
            total = digit_w * 4 + colon_w + gap * 4
        end
    end
    return digit_w, digit_h, gap, colon_w, total
end

function SevenClock:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local width = math.max(1, self.width)
    local height = math.max(1, self.height)
    local now = os.date("*t")
    local date_line = string.format("%d月%d日", now.month, now.day)
    local week_line = string.format("周%s", WEEKDAYS[now.wday] or "")
    local date_gap = 0
    local date_h = 0
    local date_widgets = {}
    if height >= Screen:scaleBySize(56) then
        local face = Font:getFace("xx_smallinfofont")
        local line_gap = math.max(1, Screen:scaleBySize(2))
        local single = TextWidget:new{
            text = date_line .. " " .. week_line,
            face = face,
            padding = 0,
            truncate_with_ellipsis = false,
        }
        local single_w = single:getSize().w or 0
        if single_w <= width then
            date_widgets[1] = single
            date_h = single:getSize().h or 0
        else
            -- Only wrap between date and weekday: 上一行日期，下一行周几.
            date_widgets[1] = TextWidget:new{
                text = date_line,
                face = face,
                padding = 0,
                truncate_with_ellipsis = false,
            }
            date_widgets[2] = TextWidget:new{
                text = week_line,
                face = face,
                padding = 0,
                truncate_with_ellipsis = false,
            }
            date_h = (date_widgets[1]:getSize().h or 0)
                + line_gap
                + (date_widgets[2]:getSize().h or 0)
            date_widgets._line_gap = line_gap
        end
        date_gap = Screen:scaleBySize(8)
    end
    local area_h = math.max(8, height - date_h - date_gap)
    local digit_w, digit_h, gap, colon_w, total_w = layout_digits(width, area_h)
    local block_h = digit_h + date_gap + date_h
    local ox = x + math.max(0, math.floor((width - total_w) / 2))
    local oy = y + math.max(0, math.floor((height - block_h) / 2))
    local xs = {
        ox,
        ox + digit_w + gap,
        ox + digit_w * 2 + gap * 2 + colon_w + gap,
        ox + digit_w * 3 + gap * 3 + colon_w + gap,
    }
    paint_digit(bb, xs[1], oy, digit_w, digit_h, math.floor(now.hour / 10))
    paint_digit(bb, xs[2], oy, digit_w, digit_h, now.hour % 10)
    local colon_x = ox + digit_w * 2 + gap * 2
    local dot = math.max(2, math.floor(digit_h * 0.13))
    local cx = colon_x + math.floor((colon_w - dot) / 2)
    bb:paintRect(cx, oy + math.floor(digit_h * 0.28), dot, dot, Blitbuffer.COLOR_BLACK)
    bb:paintRect(cx, oy + math.floor(digit_h * 0.62), dot, dot, Blitbuffer.COLOR_BLACK)
    paint_digit(bb, xs[3], oy, digit_w, digit_h, math.floor(now.min / 10))
    paint_digit(bb, xs[4], oy, digit_w, digit_h, now.min % 10)
    if #date_widgets > 0 then
        local dy = oy + digit_h + date_gap
        local line_gap = date_widgets._line_gap or 0
        for i, widget in ipairs(date_widgets) do
            local size = widget:getSize()
            local dx = x + math.max(0, math.floor((width - (size.w or 0)) / 2))
            widget:paintTo(bb, dx, dy)
            dy = dy + (size.h or 0) + (i < #date_widgets and line_gap or 0)
        end
    end
end

function ClockCard.build(width, height)
    return SevenClock:new{
        width = math.max(1, tonumber(width) or 1),
        height = math.max(1, tonumber(height) or 1),
    }
end

return ClockCard
