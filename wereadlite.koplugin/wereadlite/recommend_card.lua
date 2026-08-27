local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local ok_geom, Geom = pcall(require, "ui/geometry")
if not ok_geom then
    Geom = require("ui/geom")
end

local RecommendCard = {}

local FixedBox = WidgetContainer:extend{
    width = 1,
    height = 1,
    align = "center",
}
function FixedBox:getSize()
    return Geom:new{ w = self.width, h = self.height }
end
function FixedBox:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    if not self[1] then
        return
    end
    local size = self[1]:getSize() or {}
    local child_w = math.min(size.w or self.width, self.width)
    local child_h = math.min(size.h or self.height, self.height)
    local px, py = x, y
    if self.align ~= "left" and self.align ~= "left_center" then
        px = x + math.floor((self.width - child_w) / 2)
    end
    if self.align == "center" or self.align == "left_center" then
        py = y + math.floor((self.height - child_h) / 2)
    elseif self.align == "bottom" then
        py = y + (self.height - child_h)
    end
    self[1]:paintTo(bb, px, py)
end

-- Lay out `span` grid-aligned slots: each slot_w wide, gap between, total matches shelf grid.
function RecommendCard.build(opts)
    opts = opts or {}
    local span = math.max(1, tonumber(opts.span) or 1)
    local cell_w = math.max(1, tonumber(opts.cell_w) or 1)
    local gap = math.max(0, tonumber(opts.gap) or 0)
    local height = math.max(1, tonumber(opts.height) or 1)
    local slots = opts.slots or {}
    local total_w = span * cell_w + math.max(0, span - 1) * gap
    local row = HorizontalGroup:new{ align = "center" }
    local hits = {}
    local x = 0
    for i = 1, span do
        if i > 1 then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
            x = x + gap
        end
        local slot = slots[i] or {}
        local widget = slot.widget
        if not widget then
            widget = FixedBox:new{
                width = cell_w,
                height = height,
            }
        end
        row[#row + 1] = FixedBox:new{
            width = cell_w,
            height = height,
            align = "center",
            widget,
        }
        if slot.hit_kind then
            hits[#hits + 1] = {
                kind = slot.hit_kind,
                book = slot.book,
                x = x,
                y = 0,
                w = cell_w,
                h = height,
            }
        end
        x = x + cell_w
    end
    return FixedBox:new{
        width = total_w,
        height = height,
        align = "left",
        row,
    }, hits
end

return RecommendCard
