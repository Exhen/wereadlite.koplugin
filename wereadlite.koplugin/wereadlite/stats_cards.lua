local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Screen = Device.screen

local ok_geom, Geom = pcall(require, "ui/geometry")
if not ok_geom then
    Geom = require("ui/geom")
end

local StatsCards = {
    TEXT_TABS = 4,
    CHART_TABS = 3,
    MODES = {
        { id = "overall", label = "总计" },
        { id = "annually", label = "年" },
        { id = "monthly", label = "月" },
        { id = "weekly", label = "周" },
    },
}

local WEEKDAYS = { "一", "二", "三", "四", "五", "六", "日" }

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

local function as_table(value)
    return type(value) == "table" and value or {}
end

local function as_list(value)
    if type(value) ~= "table" then
        return {}
    end
    if value[1] ~= nil then
        return value
    end
    local list = {}
    for _, item in pairs(value) do
        list[#list + 1] = item
    end
    return list
end

local function fmt_seconds(sec)
    sec = math.floor(tonumber(sec) or 0)
    if sec < 0 then
        sec = 0
    end
    local hours = math.floor(sec / 3600)
    local minutes = math.floor((sec % 3600) / 60)
    if hours > 0 and minutes > 0 then
        return string.format("%d小时%d分钟", hours, minutes)
    end
    if hours > 0 then
        return string.format("%d小时", hours)
    end
    if minutes > 0 then
        return string.format("%d分钟", minutes)
    end
    if sec > 0 then
        return string.format("%d秒", sec)
    end
    return "0分钟"
end

local function parse_duration(text)
    if type(text) == "number" then
        return math.max(0, text)
    end
    text = tostring(text or "")
    local hours = tonumber(text:match("(%d+)%s*小时")) or 0
    local minutes = tonumber(text:match("(%d+)%s*分钟")) or 0
    local seconds = tonumber(text:match("(%d+)%s*秒")) or 0
    return hours * 3600 + minutes * 60 + seconds
end

local function start_of_day(ts)
    ts = tonumber(ts) or 0
    if ts <= 0 then
        return 0
    end
    if ts > 100000000000 then
        ts = math.floor(ts / 1000)
    end
    local t = os.date("*t", ts)
    t.hour, t.min, t.sec = 0, 0, 0
    return os.time(t)
end

local function monday0(ts)
    return (tonumber(os.date("%w", ts)) + 6) % 7
end

local function utf8_cut(text, max_chars)
    text = tostring(text or "")
    max_chars = max_chars or 8
    local index, seen = 1, 0
    while index <= #text and seen < max_chars do
        local byte = text:byte(index)
        if byte < 128 then
            index = index + 1
        elseif byte < 224 then
            index = index + 2
        elseif byte < 240 then
            index = index + 3
        else
            index = index + 4
        end
        seen = seen + 1
    end
    if index <= #text then
        return text:sub(1, index - 1) .. "…"
    end
    return text
end

function StatsCards.top_books(data, n)
    n = n or 3
    local out = {}
    for _, item in ipairs(as_list(as_table(data).readLongest)) do
        if #out >= n then
            break
        end
        item = as_table(item)
        local book = as_table(item.book)
        local album = as_table(item.albumInfo)
        out[#out + 1] = {
            label = tostring(book.title or album.title or album.name or "未命名"),
            value = tonumber(item.readTime) or 0,
        }
    end
    return out
end

function StatsCards.top_authors(data, n)
    n = n or 3
    data = as_table(data)
    local scores = {}
    local function add(name, sec)
        name = tostring(name or ""):match("^%s*(.-)%s*$") or ""
        if name == "" then
            return
        end
        sec = tonumber(sec) or 0
        scores[name] = math.max(scores[name] or 0, sec)
    end
    for _, item in ipairs(as_list(data.readLongest)) do
        item = as_table(item)
        add(as_table(item.book).author, item.readTime)
    end
    for _, item in ipairs(as_list(data.preferAuthor)) do
        item = as_table(item)
        add(item.name, parse_duration(item.readTime))
    end
    local out = {}
    for name, value in pairs(scores) do
        out[#out + 1] = { label = name, value = value }
    end
    table.sort(out, function(a, b)
        if a.value == b.value then
            return a.label < b.label
        end
        return a.value > b.value
    end)
    while #out > n do
        out[#out] = nil
    end
    return out
end

local function add_row(rows, label, value)
    label = tostring(label or "")
    value = tostring(value or "")
    if label == "" then
        return
    end
    if value == "" then
        value = "—"
    end
    rows[#rows + 1] = { label = label, value = value }
end

local function overview_rows(data)
    data = as_table(data)
    local rows = {}
    add_row(rows, "总时长", fmt_seconds(data.totalReadTime))
    add_row(rows, "阅读天数", tostring(data.readDays or 0) .. " 天")
    add_row(rows, "日均时长", fmt_seconds(data.dayAverageReadTime))
    local compare = tonumber(data.compare)
    if compare then
        local pct = math.floor(compare * 100 + (compare >= 0 and 0.5 or -0.5))
        if pct > 0 then
            add_row(rows, "较上期", "日均 +" .. pct .. "%")
        elseif pct < 0 then
            add_row(rows, "较上期", "日均 -" .. math.abs(pct) .. "%")
        else
            add_row(rows, "较上期", "持平")
        end
    end
    if data.preferTimeWord and data.preferTimeWord ~= "" then
        add_row(rows, "偏好时段", data.preferTimeWord)
    end
    local prefer = tostring(data.preferCategoryWord or "")
    if prefer ~= "" then
        local value = prefer:gsub("^偏好阅读%s*", "")
        add_row(rows, "阅读偏好", value ~= "" and value or prefer)
    else
        local first = as_table(as_list(data.preferCategory)[1])
        local name = first.categoryTitle or first.parentCategoryTitle
        add_row(rows, "阅读偏好", (name and name ~= "") and name or "暂无")
    end
    return rows
end

local function stat_rows(data)
    local rows = {}
    for _, item in ipairs(as_list(as_table(data).readStat)) do
        item = as_table(item)
        add_row(rows, item.stat, item.counts)
    end
    return rows
end

local function rank_rows(items, compact)
    local rows = {}
    for i, item in ipairs(items or {}) do
        local title = utf8_cut(item.label, compact and 8 or 12)
        local time = fmt_seconds(item.value)
        if compact then
            add_row(rows, "第" .. i .. "名", title .. "  " .. time)
        else
            add_row(rows, "第" .. i .. "名", title)
            add_row(rows, "时长", time)
        end
    end
    return rows
end

local function text_rows(tab, data, compact)
    if tab == 1 then
        return overview_rows(data), "暂无阅读统计"
    end
    if tab == 2 then
        return stat_rows(data), "暂无阅读统计"
    end
    if tab == 3 then
        return rank_rows(StatsCards.top_books(data, 3), compact), "暂无时长排行"
    end
    return rank_rows(StatsCards.top_authors(data, 3), compact), "暂无作者排行"
end

local HeatCalendar = WidgetContainer:extend{
    width = 1,
    height = 1,
    days = {},
}

function HeatCalendar:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function HeatCalendar:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local width = math.max(1, self.width)
    local height = math.max(1, self.height)
    local face = Font:getFace("xx_smallinfofont")
    local label_h = 0
    local cell_gap = math.max(1, Screen:scaleBySize(2))
    local show_label = height >= Screen:scaleBySize(70)
    if show_label then
        local sample = TextWidget:new{ text = "一", face = face }
        label_h = (sample:getSize().h or 0) + cell_gap
    end
    local weeks = math.max(1, math.ceil(#self.days / 7))
    local cell_w = math.max(4, math.floor((width - cell_gap * 6) / 7))
    local cell_h = math.max(4, math.floor((height - label_h - cell_gap * math.max(0, weeks - 1)) / weeks))
    local date_size = math.max(8, math.min(12, math.floor(math.min(cell_w, cell_h) * 0.55)))
    local date_face = Font:getFace("cfont", date_size)
    if show_label then
        for col = 0, 6 do
            local label = TextWidget:new{
                text = WEEKDAYS[col + 1],
                face = face,
                max_width = cell_w,
            }
            local size = label:getSize()
            local lx = x + col * (cell_w + cell_gap) + math.floor((cell_w - (size.w or 0)) / 2)
            label:paintTo(bb, lx, y)
        end
    end
    local max_sec = 1
    for _, day in ipairs(self.days) do
        if day.in_range then
            max_sec = math.max(max_sec, day.sec or 0)
        end
    end
    for i, day in ipairs(self.days) do
        local col = (i - 1) % 7
        local row = math.floor((i - 1) / 7)
        local cx = x + col * (cell_w + cell_gap)
        local cy = y + label_h + row * (cell_h + cell_gap)
        local color = Blitbuffer.COLOR_WHITE
        if day.in_range then
            local sec = day.sec or 0
            if sec <= 0 then
                color = Blitbuffer.COLOR_LIGHT_GRAY
            else
                local ratio = sec / max_sec
                if ratio > 0.75 then
                    color = Blitbuffer.COLOR_BLACK
                elseif ratio > 0.4 then
                    color = Blitbuffer.COLOR_DARK_GRAY
                elseif ratio > 0.15 then
                    color = Blitbuffer.COLOR_GRAY
                else
                    color = Blitbuffer.COLOR_LIGHT_GRAY
                end
            end
        end
        local gray = (color and color.a) or 0xFF
        local dark = day.in_range and gray <= 0x99
        if dark then
            bb:paintRect(cx, cy, cell_w, cell_h, color:invert())
        else
            bb:paintRect(cx, cy, cell_w, cell_h, color)
        end
        local date_text = os.date("%d", day.ts or 0)
        if date_text and cell_w >= 8 and cell_h >= 8 then
            local fg = Blitbuffer.COLOR_BLACK
            if not day.in_range then
                fg = Blitbuffer.COLOR_GRAY
            end
            local date = TextWidget:new{
                text = date_text,
                face = date_face,
                fgcolor = fg,
                padding = 0,
                max_width = math.max(1, cell_w - 2),
            }
            local size = date:getSize()
            local dx = cx + math.max(0, math.floor((cell_w - (size.w or 0)) / 2))
            local dy = cy + math.max(0, math.floor((cell_h - (size.h or 0)) / 2))
            date:paintTo(bb, dx, dy)
        end
        if dark then
            bb:invertRect(cx, cy, cell_w, cell_h)
        end
        if day.in_range then
            local border = Blitbuffer.COLOR_GRAY
            bb:paintRect(cx, cy, cell_w, 1, border)
            bb:paintRect(cx, cy + cell_h - 1, cell_w, 1, border)
            bb:paintRect(cx, cy, 1, cell_h, border)
            bb:paintRect(cx + cell_w - 1, cy, 1, cell_h, border)
        end
    end
end

local BarList = WidgetContainer:extend{
    width = 1,
    height = 1,
    items = {},
}

function BarList:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function BarList:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local items = self.items or {}
    if #items == 0 then
        local empty = TextWidget:new{
            text = "暂无排行",
            face = Font:getFace("xx_smallinfofont"),
            max_width = self.width,
        }
        empty:paintTo(bb, x, y)
        return
    end
    local rows = math.max(1, #items)
    local row_h = math.max(1, math.floor(self.height / rows))
    local max_v = 1
    for _, item in ipairs(items) do
        max_v = math.max(max_v, item.value or 0)
    end
    local face = Font:getFace("xx_smallinfofont")
    local pad = math.max(1, Screen:scaleBySize(2))
    local bar_h = math.max(4, math.min(Screen:scaleBySize(10), math.floor(row_h / 3)))
    for i, item in ipairs(items) do
        local ry = y + (i - 1) * row_h
        local label = TextWidget:new{
            text = utf8_cut(item.label, 12),
            face = face,
            bold = true,
            max_width = self.width,
        }
        label:paintTo(bb, x, ry)
        local lh = label:getSize().h or 0
        local value = TextWidget:new{
            text = fmt_seconds(item.value),
            face = face,
            max_width = self.width,
        }
        local vw = value:getSize().w or 0
        local bar_y = ry + lh + pad
        local bar_max = math.max(8, self.width - vw - pad)
        local bw = math.max(2, math.floor(bar_max * (item.value or 0) / max_v))
        bb:paintRect(x, bar_y, bw, bar_h, Blitbuffer.COLOR_BLACK)
        value:paintTo(bb, x + bar_max + pad, bar_y + math.floor((bar_h - (value:getSize().h or 0)) / 2))
    end
end

local FormList = WidgetContainer:extend{
    width = 1,
    height = 1,
    rows = {},
    empty = "暂无数据",
}

function FormList:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

local function paint_dashed_hline(bb, x, y, w, color)
    local dash = math.max(3, Screen:scaleBySize(4))
    local gap = math.max(2, Screen:scaleBySize(3))
    local thick = math.max(1, Screen:scaleBySize(1))
    local cx = x
    local end_x = x + w
    while cx < end_x do
        local dw = math.min(dash, end_x - cx)
        if dw > 0 then
            bb:paintRect(cx, y, dw, thick, color)
        end
        cx = cx + dash + gap
    end
end

function FormList:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local rows = self.rows or {}
    local face = Font:getFace("xx_smallinfofont")
    if #rows == 0 then
        local empty = TextWidget:new{
            text = self.empty or "暂无数据",
            face = face,
            fgcolor = Blitbuffer.COLOR_GRAY,
            padding = 0,
            max_width = self.width,
        }
        local size = empty:getSize()
        local ey = y + math.max(0, math.floor((self.height - (size.h or 0)) / 2))
        local ex = x + math.max(0, math.floor((self.width - (size.w or 0)) / 2))
        empty:paintTo(bb, ex, ey)
        return
    end
    local col_gap = math.max(6, Screen:scaleBySize(8))
    local row_pad = math.max(4, Screen:scaleBySize(5))
    local sep_h = math.max(1, Screen:scaleBySize(1))
    local label_w = 0
    for _, row in ipairs(rows) do
        local probe = TextWidget:new{
            text = tostring(row.label or ""),
            face = face,
            padding = 0,
        }
        label_w = math.max(label_w, probe:getSize().w or 0)
    end
    local cap = math.max(1, math.floor(self.width * 0.46))
    if label_w > cap then
        label_w = cap
    end
    local value_w = math.max(1, self.width - label_w - col_gap)
    local sample = TextWidget:new{ text = "字", face = face, padding = 0, bold = true }
    local text_h = sample:getSize().h or 16
    local row_h = text_h + row_pad * 2
    local unit = row_h + sep_h
    local max_rows = math.max(1, math.floor((self.height + sep_h) / unit))
    local shown = math.min(#rows, max_rows)
    local content_h = shown * row_h + math.max(0, shown - 1) * sep_h
    local oy = y + math.max(0, math.floor((self.height - content_h) / 2))
    for i = 1, shown do
        local row = rows[i]
        local ry = oy + (i - 1) * unit
        local label = TextWidget:new{
            text = tostring(row.label or ""),
            face = face,
            fgcolor = Blitbuffer.COLOR_GRAY,
            padding = 0,
            max_width = math.max(1, label_w),
        }
        local value = TextWidget:new{
            text = tostring(row.value or ""),
            face = face,
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            padding = 0,
            max_width = value_w,
        }
        local lh = label:getSize().h or 0
        local vh = value:getSize().h or 0
        local lw = label:getSize().w or 0
        local text_y = ry + math.floor((row_h - math.max(lh, vh)) / 2)
        label:paintTo(bb, x + math.max(0, label_w - lw), text_y + math.floor((math.max(lh, vh) - lh) / 2))
        value:paintTo(bb, x + label_w + col_gap, text_y + math.floor((math.max(lh, vh) - vh) / 2))
        if i < shown then
            paint_dashed_hline(bb, x, ry + row_h, self.width, Blitbuffer.COLOR_GRAY)
        end
    end
end

local function heatmap_days(day_map)
    day_map = as_table(day_map)
    local today = start_of_day(os.time())
    local first = today - 29 * 86400
    local grid_start = first - monday0(first) * 86400
    local last_week = today - monday0(today) * 86400
    local weeks = math.max(1, math.floor((last_week - grid_start) / (7 * 86400)) + 1)
    local days = {}
    for i = 0, weeks * 7 - 1 do
        local ts = grid_start + i * 86400
        days[#days + 1] = {
            ts = ts,
            sec = tonumber(day_map[ts]) or 0,
            in_range = ts >= first and ts <= today,
        }
    end
    return days
end

local function arrow_widget(icon, size)
    local widget
    local ok = pcall(function()
        widget = IconWidget:new{
            icon = icon,
            width = size,
            height = size,
        }
    end)
    if ok and widget then
        return widget
    end
    return TextWidget:new{
        text = icon:find("left", 1, true) and "‹" or "›",
        face = Font:getFace("cfont", 16),
    }
end

local ConnectedTabs = WidgetContainer:extend{
    width = 1,
    height = 1,
    items = {},
    current = nil,
}

function ConnectedTabs:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function ConnectedTabs:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local items = self.items or {}
    local n = #items
    if n <= 0 then
        return
    end
    local sep = math.max(1, Size.border.default)
    local face = Font:getFace("xx_smallinfofont")
    local x_off = 0
    for i, item in ipairs(items) do
        local w
        if i == n then
            w = math.max(1, self.width - x_off)
        else
            w = math.max(1, math.floor((self.width - x_off) / (n - i + 1)))
        end
        local active = item.id == self.current
        local bg = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_LIGHT_GRAY
        bb:paintRect(x + x_off, y, w, self.height, bg)
        -- Inactive chips keep a bottom edge; active opens into content (通底).
        if not active then
            bb:paintRect(x + x_off, y + self.height - sep, w, sep, Blitbuffer.COLOR_GRAY)
        end
        if i < n then
            bb:paintRect(x + x_off + w - sep, y, sep, self.height, Blitbuffer.COLOR_GRAY)
        end
        local label = TextWidget:new{
            text = item.label,
            face = face,
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            padding = 0,
            max_width = math.max(1, w - 4),
        }
        local size = label:getSize()
        local lx = x + x_off + math.max(0, math.floor((w - (size.w or 0)) / 2))
        local ly = y + math.max(0, math.floor((self.height - (size.h or 0)) / 2))
        label:paintTo(bb, lx, ly)
        x_off = x_off + w
    end
end

local function append_mode_tabs(root, hits, items, current, width, height, hit_kind)
    root[#root + 1] = ConnectedTabs:new{
        width = width,
        height = height,
        items = items,
        current = current,
    }
    local x_off = 0
    local n = #items
    for i, item in ipairs(items) do
        local w
        if i == n then
            w = math.max(1, width - x_off)
        else
            w = math.max(1, math.floor((width - x_off) / (n - i + 1)))
        end
        hits[#hits + 1] = {
            kind = hit_kind,
            mode = item.id,
            x = x_off,
            y = 0,
            w = w,
            h = height,
        }
        x_off = x_off + w
    end
end

function StatsCards.rank_limit(height)
    local min_row = math.max(Screen:scaleBySize(36), 32)
    local n = math.floor(math.max(1, tonumber(height) or 1) / min_row)
    if n < 3 then
        return 3
    end
    if n > 5 then
        return 5
    end
    return n
end

function StatsCards.tab_height()
    return math.max(Screen:scaleBySize(28), 24)
end

function StatsCards.build(opts)
    opts = opts or {}
    local width = math.max(1, tonumber(opts.width) or 1)
    local height = math.max(1, tonumber(opts.height) or 1)
    local kind = opts.kind == "chart" and "chart" or "text"
    local tab = math.max(1, tonumber(opts.tab) or 1)
    local mode = opts.mode or "monthly"
    -- Heatmap ignores period; ranks / text cards share 总计/年/月/周 tabs.
    local show_mode = not (kind == "chart" and tab == 1)
    local content_pad = math.max(10, Screen:scaleBySize(10))
    local tab_h = show_mode and StatsCards.tab_height() or 0
    local arrow_w = math.max(Screen:scaleBySize(18), 16)
    local hits = {}
    local root = VerticalGroup:new{ align = "left" }
    local header_h = 0

    if show_mode then
        append_mode_tabs(
            root,
            hits,
            StatsCards.MODES,
            mode,
            width,
            tab_h,
            kind == "chart" and "chart_mode" or "text_mode"
        )
        header_h = tab_h
    end

    local body_h = math.max(1, height - header_h)
    local top_pad = show_mode and 0 or content_pad
    local inner_h = math.max(1, body_h - top_pad - content_pad)
    local content_w = math.max(1, width - content_pad * 2 - arrow_w * 2)
    local rank_n = StatsCards.rank_limit(inner_h)

    local inner
    if opts.loading then
        inner = TextWidget:new{
            text = "加载中",
            face = Font:getFace("xx_smallinfofont"),
            max_width = content_w,
        }
    elseif opts.error then
        inner = TextBoxWidget:new{
            text = "加载失败\n点按重试",
            face = Font:getFace("xx_smallinfofont"),
            width = content_w,
            height = inner_h,
            alignment = "center",
            height_overflow_show_ellipsis = true,
        }
    elseif kind == "chart" and tab == 1 then
        inner = HeatCalendar:new{
            width = content_w,
            height = inner_h,
            days = heatmap_days(opts.heatmap),
        }
    elseif kind == "chart" and tab == 2 then
        inner = BarList:new{
            width = content_w,
            height = inner_h,
            items = StatsCards.top_books(opts.data, rank_n),
        }
    elseif kind == "chart" then
        inner = BarList:new{
            width = content_w,
            height = inner_h,
            items = StatsCards.top_authors(opts.data, rank_n),
        }
    else
        local compact = inner_h < Screen:scaleBySize(18) * 6
        local rows, empty = text_rows(tab, opts.data, compact)
        inner = FormList:new{
            width = content_w,
            height = inner_h,
            rows = rows,
            empty = empty,
        }
    end

    local body = HorizontalGroup:new{
        align = "center",
        FixedBox:new{
            width = arrow_w,
            height = inner_h,
            align = "center",
            arrow_widget("chevron.left", arrow_w),
        },
        FixedBox:new{
            width = content_w,
            height = inner_h,
            align = kind == "text" and "left_center" or "left",
            inner,
        },
        FixedBox:new{
            width = arrow_w,
            height = inner_h,
            align = "center",
            arrow_widget("chevron.right", arrow_w),
        },
    }

    local body_stack = VerticalGroup:new{ align = "left" }
    if top_pad > 0 then
        body_stack[#body_stack + 1] = VerticalSpan:new{ width = top_pad }
    end
    body_stack[#body_stack + 1] = FixedBox:new{
        width = width,
        height = inner_h,
        align = "center",
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = content_pad },
            body,
            HorizontalSpan:new{ width = content_pad },
        },
    }
    body_stack[#body_stack + 1] = VerticalSpan:new{ width = content_pad }
    root[#root + 1] = FixedBox:new{
        width = width,
        height = body_h,
        align = "top",
        body_stack,
    }

    local content_y = header_h + top_pad
    hits[#hits + 1] = {
        kind = kind == "chart" and "chart_prev" or "text_prev",
        x = content_pad,
        y = content_y,
        w = arrow_w,
        h = inner_h,
    }
    hits[#hits + 1] = {
        kind = kind == "chart" and "chart_next" or "text_next",
        x = width - content_pad - arrow_w,
        y = content_y,
        w = arrow_w,
        h = inner_h,
    }

    return FixedBox:new{
        width = width,
        height = height,
        align = "left",
        root,
    }, hits
end

return StatsCards
