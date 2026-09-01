local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local BD = require("ui/bidi")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Config = require("wereadlite.config")
local Covers = require("wereadlite.covers")
local BookDb = require("wereadlite.book_db")
local Log = require("wereadlite.log")
local Reading = require("wereadlite.reading")
local Session = require("wereadlite.session")
local Settings = require("wereadlite.settings")
local Shelf = require("wereadlite.kindle.shelf")
local ClockCard = require("wereadlite.clock_card")
local StatsCards = require("wereadlite.stats_cards")
local RecommendCard = require("wereadlite.recommend_card")

local Screen = Device.screen

local ok_geom, Geom = pcall(require, "ui/geometry")
if not ok_geom then
    Geom = require("ui/geom")
end

-- Fixed-size box. HorizontalGroup/VerticalGroup must not see child overflow.
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
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    if not self[1] then
        return
    end
    local size = self[1]:getSize() or {}
    local child_w = math.min(size.w or self.width, self.width)
    local child_h = math.min(size.h or self.height, self.height)
    local px = x
    local py = y
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

local OffsetBox = WidgetContainer:extend{
    x_off = 0,
    y_off = 0,
}
function OffsetBox:getSize()
    if self[1] then
        return self[1]:getSize()
    end
    return Geom:new{ w = 0, h = 0 }
end
function OffsetBox:paintTo(bb, x, y)
    if self[1] then
        self[1]:paintTo(bb, x + (self.x_off or 0), y + (self.y_off or 0))
    end
end

local ShelfView = InputContainer:extend{
    page = 1,
    on_close = nil,
    on_auth_expired = nil,
}

-- Persists across Gate.close/open; avoids refetching stats/recommend on each home visit.
local TILE_CACHE = {
    stats = {},
    recommend = nil,
    stats_ui = {
        text_tab = 1,
        text_mode = "monthly",
        chart_tab = 1,
        chart_mode = "monthly",
    },
    recommend_ui = { page = 1 },
}

local function geom()
    return Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
end

local function grid_gap()
    return Screen:scaleBySize(8)
end

local function utf8_prefix(text, count)
    text = tostring(text or "")
    count = count or 1
    local index, seen = 1, 0
    while index <= #text and seen < count do
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
    return text:sub(1, index - 1)
end

local function placeholder(width, height, text)
    return FixedBox:new{
        width = math.max(1, width),
        height = math.max(1, height),
        align = "center",
        TextWidget:new{
            text = text or "书",
            face = Font:getFace("cfont", 16),
        },
    }
end

local function safe_image(path, width, height, fill)
    path = tostring(path or "")
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    if path == "" then
        return nil
    end
    local ext = path:lower():match("%.([%w]+)$")
    if ext ~= "png" and ext ~= "jpg" and ext ~= "jpeg" and ext ~= "gif"
        and ext ~= "webp" and ext ~= "svg" then
        return nil
    end
    local image
    local ok = pcall(function()
        local scale = 0
        if fill then
            local probe = ImageWidget:new{
                file = path,
                scale_factor = 1,
                file_do_cache = false,
            }
            local native = probe:getSize()
            local nw = math.max(1, tonumber(native and native.w) or 1)
            local nh = math.max(1, tonumber(native and native.h) or 1)
            scale = math.max(width / nw, height / nh)
            if math.floor(nw * scale + 1e-6) < width or math.floor(nh * scale + 1e-6) < height then
                scale = scale * 1.002
            end
            if probe and type(probe.free) == "function" then
                pcall(probe.free, probe)
            end
        end
        image = ImageWidget:new{
            file = path,
            width = width,
            height = height,
            scale_factor = scale,
            file_do_cache = false,
        }
        -- _render() runs here, not in :new(); must stay inside pcall.
        image:getSize()
    end)
    if ok and image then
        return image
    end
    if image and type(image.free) == "function" then
        pcall(image.free, image)
    end
end

function ShelfView:init()
    self.covers_fullscreen = true
    self.fullscreen = true
    self.page = 1
    self._closed = false
    self._cells = {}
    self._cover_gen = 0
    self._preload_gen = 0
    self._preload_busy = false
    self._stats_busy = false
    self._stats_cache = TILE_CACHE.stats
    self._stats_ui = TILE_CACHE.stats_ui
    self._recommend_ui = TILE_CACHE.recommend_ui
    self._recommend_cache = TILE_CACHE.recommend
    self._recommend_busy = false
    self._search = nil
    self._shelf_page = nil
    self._clock_gen = 0
    self._clock_stamp = nil
    self.dimen = geom()
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back }, doc = "close" },
            NextPage = { { "RPgFwd", "LPgFwd", "Right" }, doc = "next" },
            PrevPage = { { "RPgBack", "LPgBack", "Left" }, doc = "prev" },
        }
    end
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:_set_body(self:_status_widget("正在加载书架…"))
end

function ShelfView:start_load()
    if self._closed or self._started then
        return
    end
    self._started = true
    Log.info("shelf", "start_load")
    self:_load_first()
end

function ShelfView:_pager_line_height()
    return Size.line.medium
end

function ShelfView:_pager_height()
    return self:_pager_line_height() + Screen:scaleBySize(40)
end

function ShelfView:_bar_height()
    if self._bar_h then
        return self._bar_h
    end
    local ok, height = pcall(function()
        local title_bar = TitleBar:new{
            width = Screen:getWidth(),
            fullscreen = true,
            title = "微信读书",
            with_bottom_line = true,
            close_callback = function() end,
            show_parent = self,
        }
        local value = title_bar:getHeight() or title_bar:getSize().h
        if title_bar.free then
            pcall(title_bar.free, title_bar)
        end
        return value
    end)
    self._bar_h = (ok and height and height > 0) and height or Screen:scaleBySize(40)
    return self._bar_h
end

function ShelfView:_chrome_top()
    return grid_gap() + self:_bar_height()
end

local function card_pad()
    return math.max(10, Screen:scaleBySize(10))
end

local function card_inset()
    return Size.border.default + card_pad()
end

local function card_radius()
    return Screen:scaleBySize(Settings.card_radius())
end

local function clip_round_corners(bb, x, y, w, h, r, color)
    r = math.floor(tonumber(r) or 0)
    w = math.floor(tonumber(w) or 0)
    h = math.floor(tonumber(h) or 0)
    if r <= 0 or w <= 0 or h <= 0 then
        return
    end
    r = math.min(r, math.floor(w / 2), math.floor(h / 2))
    local r2 = r * r
    for i = 0, r - 1 do
        local oy = r - i
        local n = 0
        for j = 0, r - 1 do
            local ox = r - j
            if ox * ox + oy * oy > r2 then
                n = n + 1
            else
                break
            end
        end
        if n > 0 then
            bb:paintRect(x, y + i, n, 1, color)
            bb:paintRect(x + w - n, y + i, n, 1, color)
            bb:paintRect(x, y + h - 1 - i, n, 1, color)
            bb:paintRect(x + w - n, y + h - 1 - i, n, 1, color)
        end
    end
end

local RoundClipFrame = FrameContainer:extend{}

function RoundClipFrame:paintTo(bb, x, y)
    FrameContainer.paintTo(self, bb, x, y)
    local radius = tonumber(self.radius) or 0
    if radius <= 0 then
        return
    end
    local width = self.width or (self.dimen and self.dimen.w) or 0
    local height = self.height or (self.dimen and self.dimen.h) or 0
    clip_round_corners(bb, x, y, width, height, radius, self.background or Blitbuffer.COLOR_WHITE)
    if (self.bordersize or 0) > 0 then
        local anti_alias = true
        if G_reader_settings then
            anti_alias = G_reader_settings:nilOrTrue("anti_alias_ui")
        end
        local margin = self.margin or 0
        bb:paintBorder(
            x + margin,
            y + margin,
            width - margin * 2,
            height - margin * 2,
            self.bordersize,
            self.color or Blitbuffer.COLOR_BLACK,
            radius,
            anti_alias
        )
    end
end

function ShelfView:_make_toolbar()
    local gap = grid_gap()
    local width = Screen:getWidth()
    local bar_h = self:_bar_height()
    local inner_w = math.max(1, width - gap * 2)
    local outer_inset = Size.border.default + Size.padding.small
    local content_w = math.max(1, inner_w - outer_inset * 2)
    local content_h = math.max(1, bar_h - outer_inset * 2)
    local item_gap = Size.padding.small
    local icon_size = math.max(1, math.min(content_h, Screen:scaleBySize(32)))
    local search_w = math.max(1, content_w - icon_size * 2 - item_gap * 2)
    local search_pad = Size.padding.small
    local search_border = Size.border.default
    local hint_icon = math.max(1, math.floor(icon_size * 0.62))
    local search_inner_w = math.max(1, search_w - search_pad * 2 - search_border * 2)
    local search_inner_h = math.max(1, content_h - search_pad * 2 - search_border * 2)
    local searching = self:_is_search()
    local clear_size = searching and hint_icon or 0
    local text_max = math.max(1, search_inner_w - hint_icon - Size.padding.small
        - (searching and (Size.padding.small + clear_size) or 0))
    local origin_x = gap + outer_inset
    self._toolbar_hit = {
        y1 = gap,
        y2 = gap + bar_h,
        search_x1 = origin_x,
        search_x2 = origin_x + search_w,
        search_clear_x1 = searching and (origin_x + search_w - search_pad - clear_size - Size.padding.small) or nil,
        search_clear_x2 = searching and (origin_x + search_w) or nil,
        settings_x1 = origin_x + search_w + item_gap,
        settings_x2 = origin_x + search_w + item_gap + icon_size,
        close_x1 = origin_x + search_w + item_gap * 2 + icon_size,
        close_x2 = origin_x + content_w,
    }
    local search_row = HorizontalGroup:new{ align = "center" }
    search_row[#search_row + 1] = IconWidget:new{
        icon = "appbar.search",
        width = hint_icon,
        height = hint_icon,
    }
    search_row[#search_row + 1] = HorizontalSpan:new{ width = Size.padding.small }
    search_row[#search_row + 1] = TextWidget:new{
        text = searching and self:_browse_title() or "搜索书籍",
        face = Font:getFace("x_smallinfofont"),
        fgcolor = searching and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_5,
        max_width = text_max,
    }
    if searching then
        search_row[#search_row + 1] = HorizontalSpan:new{ width = Size.padding.small }
        search_row[#search_row + 1] = IconWidget:new{
            icon = "close",
            width = clear_size,
            height = clear_size,
        }
    end
    return OffsetBox:new{
        x_off = gap,
        y_off = gap,
        RoundClipFrame:new{
            width = inner_w,
            height = bar_h,
            bordersize = Size.border.default,
            padding = Size.padding.small,
            margin = 0,
            radius = card_radius(),
            background = Blitbuffer.COLOR_WHITE,
            allow_mirroring = false,
            FixedBox:new{
                width = content_w,
                height = content_h,
                align = "center",
                HorizontalGroup:new{
                    align = "center",
                    FixedBox:new{
                        width = search_w,
                        height = content_h,
                        align = "center",
                        RoundClipFrame:new{
                            width = search_w,
                            height = content_h,
                            bordersize = search_border,
                            padding = search_pad,
                            margin = 0,
                            radius = math.min(card_radius(), math.floor(content_h / 2)),
                            color = Blitbuffer.COLOR_GRAY,
                            background = Blitbuffer.COLOR_GRAY_E,
                            allow_mirroring = false,
                            FixedBox:new{
                                width = search_inner_w,
                                height = search_inner_h,
                                align = "left_center",
                                search_row,
                            },
                        },
                    },
                    HorizontalSpan:new{ width = item_gap },
                    FixedBox:new{
                        width = icon_size,
                        height = content_h,
                        align = "center",
                        IconWidget:new{
                            icon = "appbar.settings",
                            width = icon_size,
                            height = icon_size,
                        },
                    },
                    HorizontalSpan:new{ width = item_gap },
                    FixedBox:new{
                        width = icon_size,
                        height = content_h,
                        align = "center",
                        IconWidget:new{
                            icon = "exit",
                            width = icon_size,
                            height = icon_size,
                        },
                    },
                },
            },
        },
    }
end

function ShelfView:_pager_arrow(icon, width, enabled, callback)
    return Button:new{
        icon = icon,
        width = width,
        enabled = enabled,
        bordersize = 0,
        radius = 0,
        margin = 0,
        padding = 0,
        show_parent = self,
        callback = callback,
    }
end

function ShelfView:_pager_bar(width, height)
    width = width or Screen:getWidth()
    height = height or self:_pager_height()
    local line_h = self:_pager_line_height()
    local bar_h = math.max(1, height - line_h)
    local pages, page, can_prev, can_next
    if self:_is_search() then
        pages = math.max(1, self:_search_page_count())
        page = math.max(1, math.min(self.page or 1, pages))
        can_prev = page > 1
        can_next = page < pages or (self._search.has_more and true or false)
    else
        pages = math.max(1, Shelf.ui_page_count())
        page = math.max(1, math.min(self.page or 1, pages))
        can_prev = page > 1
        if (tonumber(Shelf.total) or 0) > 0 then
            can_next = page < pages
        else
            can_next = page < pages or not Shelf.eof
        end
    end
    local arrow_w = math.max(Screen:scaleBySize(40), math.floor(width * 0.12))
    local label_w = math.max(1, width - arrow_w * 4)
    local chevron_left = "chevron.left"
    local chevron_right = "chevron.right"
    local chevron_first = "chevron.first"
    local chevron_last = "chevron.last"
    if BD.mirroredUILayout() then
        chevron_left, chevron_right = chevron_right, chevron_left
        chevron_first, chevron_last = chevron_last, chevron_first
    end
    self._pager_h = height
    self._pager_hit = {
        y = Screen:getHeight() - height,
        h = height,
        first_x2 = arrow_w,
        prev_x1 = arrow_w,
        prev_x2 = arrow_w * 2,
        next_x1 = width - arrow_w * 2,
        next_x2 = width - arrow_w,
        last_x1 = width - arrow_w,
        can_prev = can_prev,
        can_next = can_next,
    }
    return VerticalGroup:new{
        align = "center",
        LineWidget:new{
            dimen = Geom:new{ w = width, h = line_h },
            background = Blitbuffer.COLOR_BLACK,
        },
        FixedBox:new{
            width = width,
            height = bar_h,
            align = "center",
            HorizontalGroup:new{
                align = "center",
                self:_pager_arrow(chevron_first, arrow_w, can_prev, function()
                    self:onFirstPage()
                end),
                self:_pager_arrow(chevron_left, arrow_w, can_prev, function()
                    self:onPrevPage()
                end),
                FixedBox:new{
                    width = label_w,
                    height = bar_h,
                    align = "center",
                    TextWidget:new{
                        text = string.format("%d / %d", page, pages),
                        face = Font:getFace("infofont", 16),
                    },
                },
                self:_pager_arrow(chevron_right, arrow_w, can_next, function()
                    self:onNextPage()
                end),
                self:_pager_arrow(chevron_last, arrow_w, can_next, function()
                    self:onLastPage()
                end),
            },
        },
    }
end

function ShelfView:_set_body(body)
    local width = Screen:getWidth()
    local height = Screen:getHeight()
    self._title_h = self:_chrome_top()
    local pager_h = self:_pager_height()
    local content_h = math.max(1, height - self._title_h - pager_h)
    if self[1] and self[1].free then
        pcall(self[1].free, self[1])
    end
    self.dimen = geom()
    -- OverlapGroup has no background. Without an opaque fill, FileManager /
    -- the previous reader frame show through and look like stacked layers.
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        width = width,
        height = height,
        OverlapGroup:new{
            dimen = Geom:new{ x = 0, y = 0, w = width, h = height },
            allow_mirroring = false,
            self:_make_toolbar(),
            OffsetBox:new{
                x_off = 0,
                y_off = self._title_h,
                FixedBox:new{
                    width = width,
                    height = content_h,
                    align = "top",
                    body,
                },
            },
            OffsetBox:new{
                x_off = 0,
                y_off = height - pager_h,
                self:_pager_bar(width, pager_h),
            },
        },
    }
    UIManager:setDirty(self, "ui")
end

function ShelfView:_status_widget(text)
    local width = Screen:getWidth()
    local title_h = self._title_h or self:_chrome_top()
    local height = math.max(1, Screen:getHeight() - title_h - self:_pager_height())
    return FixedBox:new{
        width = width,
        height = height,
        align = "center",
        TextWidget:new{
            text = text,
            face = Font:getFace("infofont"),
        },
    }
end

function ShelfView:_fail(status, err)
    Log.warn("shelf", "load", { status = status, err = err })
    if status == "auth_expired" or tostring(err or ""):find("userInfo missing", 1, true) then
        self:_expire()
        return
    end
    local message = "书架加载失败"
    if status == "offline" then
        message = "网络不可用"
    end
    self:_set_body(self:_status_widget(message))
end

function ShelfView:_expire()
    if self.on_auth_expired then
        self.on_auth_expired()
    else
        Session.clear_auth()
        self:onClose()
    end
end

function ShelfView:_load_first()
    Shelf.ensure_user(function(user, status, err)
        if self._closed then
            return
        end
        if not user then
            self:_fail(status, err)
            return
        end
        Shelf.ensure_books(Shelf.books_needed(1), function(_, book_status, book_err)
            if self._closed then
                return
            end
            if book_status and book_status ~= "ok" and not Shelf.has_books() then
                self:_fail(book_status, book_err)
                return
            end
            self:_paint()
            if type(UIManager.forceRePaint) == "function" then
                UIManager:forceRePaint()
            end
            self:_prefetch_covers()
            self:_start_clock()
        end)
    end)
end

function ShelfView:_start_clock()
    self._clock_gen = (self._clock_gen or 0) + 1
    local gen = self._clock_gen
    self._clock_stamp = os.date("%H%M")
    local function tick()
        if self._closed or gen ~= self._clock_gen then
            return
        end
        local stamp = os.date("%H%M")
        if stamp ~= self._clock_stamp then
            self._clock_stamp = stamp
            if self.page == 1 and not self:_is_search() then
                self:_paint()
            end
        end
        UIManager:scheduleIn(1, tick)
    end
    UIManager:scheduleIn(1, tick)
end

function ShelfView:_card(width, height, inner, align)
    local pad = card_pad()
    local inset = card_inset()
    return RoundClipFrame:new{
        width = width,
        height = height,
        bordersize = Size.border.default,
        padding = pad,
        margin = 0,
        radius = card_radius(),
        background = Blitbuffer.COLOR_WHITE,
        allow_mirroring = false,
        FixedBox:new{
            width = math.max(1, width - inset * 2),
            height = math.max(1, height - inset * 2),
            align = align or "center",
            inner,
        },
    }
end

-- Stats tabs sit flush against the card frame (no top/side padding).
function ShelfView:_stats_frame(width, height, inner)
    local border = Size.border.default
    return RoundClipFrame:new{
        width = width,
        height = height,
        bordersize = border,
        padding = 0,
        margin = 0,
        radius = card_radius(),
        background = Blitbuffer.COLOR_WHITE,
        allow_mirroring = false,
        FixedBox:new{
            width = math.max(1, width - border * 2),
            height = math.max(1, height - border * 2),
            align = "left",
            inner,
        },
    }
end

function ShelfView:_recommend_frame(width, height, inner)
    local pad = card_pad()
    local inset = card_inset()
    return RoundClipFrame:new{
        width = width,
        height = height,
        bordersize = Size.border.default,
        padding = pad,
        margin = 0,
        radius = card_radius(),
        background = Blitbuffer.COLOR_WHITE,
        allow_mirroring = false,
        FixedBox:new{
            width = math.max(1, width - inset * 2),
            height = math.max(1, height - inset * 2),
            align = "left",
            inner,
        },
    }
end

function ShelfView:_cell_size()
    local width = Screen:getWidth()
    local title_h = self._title_h or self:_chrome_top()
    local height = math.max(1, Screen:getHeight() - title_h - self:_pager_height())
    local cols = Settings.grid_cols()
    local rows = Settings.grid_rows()
    local gap = grid_gap()
    local cell_w = math.max(1, math.floor((width - gap * (cols + 1)) / cols))
    local cell_h = math.max(1, math.floor((height - gap * (rows + 1)) / rows))
    return cell_w, cell_h, width, height, gap
end

function ShelfView:_col_rect(col, span, cell_w, gap, width, cols)
    col = tonumber(col) or 0
    span = math.max(1, tonumber(span) or 1)
    local x = gap + col * (cell_w + gap)
    local last_col = col + span - 1
    local w
    if last_col >= cols - 1 then
        w = math.max(1, width - x - gap)
    else
        w = span * cell_w + (span - 1) * gap
    end
    return x, w
end

function ShelfView:_last_book()
    local BookDetail = require("wereadlite.book_detail")
    local last = BookDb.get_last_read()
    if type(last) ~= "table" or tostring(last.bookId or "") == "" then
        return nil
    end
    for _, book in ipairs(Shelf.books or {}) do
        if tostring(book.bookId or "") == tostring(last.bookId) then
            if not last.reader_param or last.reader_param == "" then
                last.reader_param = book.reader_param
            end
            if not last.reader_url or last.reader_url == "" then
                last.reader_url = book.reader_url
            end
            if not last.cover or last.cover == "" then
                last.cover = book.cover
            end
            if not last.title or last.title == "" then
                last.title = book.title
            end
            break
        end
    end
    if (not last.reader_param or last.reader_param == "") or (not last.reader_url or last.reader_url == "") then
        local cached = BookDb.get(last.bookId)
        if type(cached) == "table" then
            if not last.reader_param or last.reader_param == "" then
                last.reader_param = cached.reader_param
            end
            if not last.reader_url or last.reader_url == "" then
                last.reader_url = cached.reader_url
            end
            if not last.cover or last.cover == "" then
                last.cover = cached.cover
            end
            if not last.title or last.title == "" then
                last.title = cached.title
            end
            if not last.author or last.author == "" then
                last.author = cached.author
            end
        end
    end
    return BookDetail.enrich_reader_param(last)
end

function ShelfView:_user_row(width, height)
    local user = Shelf.user or {}
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    local text_w = width
    local name = tostring(user.name or Config.NAME)
    local vip = (user.deep_v_title and user.deep_v_title ~= "") and tostring(user.deep_v_title) or nil
    local books = tostring(Shelf.total or Shelf.loaded_count()) .. " 本书"
    local stats = "阅读统计 ›"

    -- Prefer fitting inside the card: margins first, then distribute leftover.
    local min_gap = 1
    local max_gap = math.max(min_gap, Screen:scaleBySize(6))
    local name_face = Settings.grid_face("body")
    local meta_face = Settings.grid_face("meta")
    if height >= Screen:scaleBySize(120) then
        name_face = Settings.grid_face("title")
        meta_face = Settings.grid_face("body")
    end

    local function make_text(text, face, bold)
        return TextWidget:new{
            text = text,
            face = face,
            bold = bold,
            max_width = text_w,
            padding = 0,
        }
    end

    local texts = {
        make_text(name, name_face, true),
    }
    if vip then
        texts[#texts + 1] = make_text(vip, meta_face, false)
    end
    texts[#texts + 1] = make_text(books, meta_face, false)
    texts[#texts + 1] = make_text(stats, meta_face, false)

    local text_h = 0
    for _, widget in ipairs(texts) do
        text_h = text_h + (widget:getSize().h or 0)
    end
    -- avatar + N text lines => N gaps between them
    local gap_count = #texts
    local room_for_avatar = height - text_h - gap_count * min_gap
    local avatar_cap = math.min(width, Screen:scaleBySize(64), math.floor(height * 0.36))
    local avatar_size = math.max(1, math.min(avatar_cap, math.max(Screen:scaleBySize(24), room_for_avatar)))
    if avatar_size + text_h + gap_count * min_gap > height then
        avatar_size = math.max(1, height - text_h - gap_count * min_gap)
    end

    local used_min = avatar_size + text_h + gap_count * min_gap
    local leftover = math.max(0, height - used_min)
    local gap = min_gap
    if gap_count > 0 then
        gap = math.min(max_gap, min_gap + math.floor(leftover / gap_count))
    end

    local avatar = safe_image(Covers.cached_avatar(), avatar_size, avatar_size)
        or placeholder(avatar_size, avatar_size, utf8_prefix(name, 1))

    local group = VerticalGroup:new{ align = "center" }
    group[#group + 1] = avatar
    for _, widget in ipairs(texts) do
        group[#group + 1] = VerticalSpan:new{ width = gap }
        group[#group + 1] = widget
    end

    return FixedBox:new{
        width = width,
        height = height,
        align = "center",
        group,
    }
end

function ShelfView:_recent_row(width, height, book)
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    local gap = math.max(8, Screen:scaleBySize(8))
    local min_text = Screen:scaleBySize(96)
    local min_cover = Screen:scaleBySize(52)
    local stacked = width < (min_cover + gap + min_text)
    local wide = (not stacked) and width >= Screen:scaleBySize(320)

    local title = "暂无阅读记录"
    local author = ""
    local chapter = ""
    local caption = "上次阅读"
    local mark = "读"
    if book then
        title = tostring(book.title or "未命名")
        author = tostring(book.author or "")
        chapter = tostring(book.chapter_title or "")
        if chapter ~= "" then
            chapter = "章节位置：" .. chapter
        end
        mark = utf8_prefix(title, 1)
    else
        author = "打开一本书后，会显示在这里"
        caption = ""
    end

    local title_face = (stacked or not wide) and Settings.grid_face("body")
        or Settings.grid_face("title")
    local meta_face = Settings.grid_face("meta")
    local line_gap = math.max(2, Screen:scaleBySize(wide and 4 or 3))

    local cover_w, cover_h
    if stacked then
        local sample = TextWidget:new{
            text = "字",
            face = title_face,
            padding = 0,
        }
        local title_h = sample:getSize().h or 16
        local meta_h = TextWidget:new{
            text = "字",
            face = meta_face,
            padding = 0,
        }:getSize().h or 14
        local text_reserve = title_h + gap
        if author ~= "" then
            text_reserve = text_reserve + line_gap + meta_h
        end
        cover_h = math.max(min_cover, height - text_reserve)
        cover_w = math.min(width, math.max(1, math.floor(cover_h * 0.70)))
        if cover_w < width then
            cover_h = math.min(cover_h, math.max(1, math.floor(cover_w / 0.70)))
        end
    else
        cover_h = height
        cover_w = math.max(1, math.floor(cover_h * 0.70))
        local max_cover = math.max(min_cover, width - gap - min_text)
        if wide then
            max_cover = math.min(max_cover, math.floor(width * 0.32))
        else
            max_cover = math.min(max_cover, math.floor(width * 0.40))
        end
        if cover_w > max_cover then
            cover_w = max_cover
            cover_h = math.min(height, math.max(1, math.floor(cover_w / 0.70)))
        end
    end

    local border = Size.border.default
    local img_w = math.max(1, cover_w - border * 2)
    local img_h = math.max(1, cover_h - border * 2)
    local image = (book and safe_image(Covers.cached(book.bookId), img_w, img_h, true))
        or placeholder(img_w, img_h, mark)
    local cover = FrameContainer:new{
        bordersize = border,
        padding = 0,
        margin = 0,
        radius = 0,
        color = Blitbuffer.COLOR_GRAY,
        background = Blitbuffer.COLOR_WHITE,
        allow_mirroring = false,
        FixedBox:new{
            width = img_w,
            height = img_h,
            align = "center",
            image,
        },
    }

    local text_w = stacked and width or math.max(1, width - cover_w - gap)
    local text_h = stacked and math.max(1, height - cover_h - gap) or height
    local col = VerticalGroup:new{ align = stacked and "center" or "left" }
    local used = 0
    local function add_line(text, face, bold, color)
        text = tostring(text or "")
        if text == "" then
            return
        end
        local widget = TextWidget:new{
            text = text,
            face = face,
            bold = bold,
            fgcolor = color or Blitbuffer.COLOR_BLACK,
            max_width = text_w,
            padding = 0,
        }
        local h = widget:getSize().h or 0
        local extra = (#col > 0) and line_gap or 0
        if used + extra + h > text_h and used > 0 then
            return
        end
        if extra > 0 then
            col[#col + 1] = VerticalSpan:new{ width = extra }
            used = used + extra
        end
        col[#col + 1] = widget
        used = used + h
    end
    if not stacked then
        add_line(caption, meta_face, false, Blitbuffer.COLOR_GRAY)
    end
    add_line(title, title_face, true, Blitbuffer.COLOR_BLACK)
    add_line(author, meta_face, false, Blitbuffer.COLOR_DARK_GRAY)
    if not stacked then
        add_line(chapter, meta_face, false, Blitbuffer.COLOR_GRAY)
    end

    if stacked then
        return FixedBox:new{
            width = width,
            height = height,
            align = "center",
            VerticalGroup:new{
                align = "center",
                cover,
                VerticalSpan:new{ width = gap },
                col,
            },
        }
    end
    return FixedBox:new{
        width = width,
        height = height,
        align = "left_center",
        HorizontalGroup:new{
            align = "center",
            cover,
            HorizontalSpan:new{ width = gap },
            FixedBox:new{
                width = text_w,
                height = height,
                align = "left_center",
                col,
            },
        },
    }
end

function ShelfView:_book_cell(book, cell_w, cell_h)
    local border = Size.border.default
    local show_title = Settings.show_book_title()
    local title_gap = 0
    local title_h = 0
    local title
    if show_title then
        title_gap = math.max(1, Screen:scaleBySize(2))
        title = TextWidget:new{
            text = tostring(book.title or ""),
            face = Settings.grid_face("body"),
            max_width = math.max(1, cell_w),
        }
        title_h = title:getSize().h or 0
    end
    local frame_h = math.max(1, cell_h - title_h - title_gap)
    local cover_w = math.max(1, cell_w - border * 2)
    local cover_h = math.max(1, frame_h - border * 2)
    local mark = utf8_prefix(book.title or "书", 1)
    local cover = safe_image(Covers.cached(book.bookId), cover_w, cover_h, true)
        or placeholder(cover_w, cover_h, mark)
    local frame = RoundClipFrame:new{
        width = cell_w,
        height = frame_h,
        bordersize = border,
        padding = 0,
        margin = 0,
        radius = card_radius(),
        background = Blitbuffer.COLOR_WHITE,
        allow_mirroring = false,
        FixedBox:new{
            width = cover_w,
            height = cover_h,
            align = "center",
            cover,
        },
    }
    if not show_title then
        return frame
    end
    return FixedBox:new{
        width = cell_w,
        height = cell_h,
        align = "top",
        VerticalGroup:new{
            align = "center",
            frame,
            VerticalSpan:new{ width = title_gap },
            title,
        },
    }
end

function ShelfView:_paint()
    local ok, err = pcall(function()
        local cell_w, cell_h, width, height, gap = self:_cell_size()
        local rows = Settings.grid_rows()
        local cols = Settings.grid_cols()
        local searching = self:_is_search()
        local books = searching and self:_search_books_for_page(self.page) or Shelf.books_for_page(self.page)
        local layers = OverlapGroup:new{
            dimen = Geom:new{ x = 0, y = 0, w = width, h = height },
            allow_mirroring = false,
        }
        self._cells = {}
        local origin_y = self._title_h or self:_chrome_top()
        local inset = card_inset()
        local book_index = 1
        local tiles_by_row = {}
        local books_by_row = {}
        if not searching and self.page == 1 then
            local placed, book_slots = Settings.pack_tiles()
            for _, tile in ipairs(placed) do
                local list = tiles_by_row[tile.row]
                if not list then
                    list = {}
                    tiles_by_row[tile.row] = list
                end
                list[#list + 1] = tile
            end
            for _, slot in ipairs(book_slots) do
                local list = books_by_row[slot.row]
                if not list then
                    list = {}
                    books_by_row[slot.row] = list
                end
                list[#list + 1] = slot.col
            end
        end
        for row = 0, rows - 1 do
            local y = gap + row * (cell_h + gap)
            local row_h = (row == rows - 1) and math.max(1, height - y - gap) or cell_h
            local inner_h = math.max(1, row_h - inset * 2)
            local function add_book_cell(col)
                local x, col_w = self:_col_rect(col, 1, cell_w, gap, width, cols)
                local book = books[book_index]
                book_index = book_index + 1
                local cell
                if book then
                    cell = self:_book_cell(book, col_w, row_h)
                    self._cells[#self._cells + 1] = {
                        x = x,
                        y = origin_y + y,
                        w = col_w,
                        h = row_h,
                        kind = "book",
                        book = book,
                    }
                else
                    cell = FixedBox:new{ width = col_w, height = row_h }
                end
                layers[#layers + 1] = OffsetBox:new{
                    x_off = x,
                    y_off = y,
                    cell,
                }
            end
            if searching or self.page ~= 1 then
                for col = 0, cols - 1 do
                    add_book_cell(col)
                end
            else
                local ctx = {
                    y = y,
                    origin_y = origin_y,
                    row_h = row_h,
                    inner_h = inner_h,
                    inset = inset,
                    cell_w = cell_w,
                    gap = gap,
                    width = width,
                    cols = cols,
                }
                for _, tile in ipairs(tiles_by_row[row] or {}) do
                    self:_add_func_tile(layers, tile, ctx)
                end
                for _, col in ipairs(books_by_row[row] or {}) do
                    add_book_cell(col)
                end
            end
        end
        self:_set_body(layers)
    end)
    if not ok then
        Log.warn("shelf", "paint", { err = err, trace = debug.traceback(tostring(err), 2) })
        self:_set_body(self:_status_widget("书架排版失败"))
        return
    end
    if self.page == 1 then
        self:_ensure_stats()
        self:_ensure_recommend()
    end
end

function ShelfView:_recommend_book_slots(span)
    span = math.max(1, tonumber(span) or 1)
    return math.max(0, span - 1)
end

function ShelfView:_recommend_books()
    local cache = self._recommend_cache
    if type(cache) == "table" and type(cache.books) == "table" then
        return cache.books
    end
    return {}
end

function ShelfView:_recommend_page_count(span)
    span = math.max(2, tonumber(span) or 2)
    local book_slots = self:_recommend_book_slots(span)
    if book_slots <= 0 then
        return 1
    end
    local books = self:_recommend_books()
    local pages = math.max(1, math.ceil(#books / book_slots))
    local cache = self._recommend_cache
    if type(cache) == "table" and cache.has_more and #books > 0 and (#books % book_slots) == 0 then
        pages = pages + 1
    end
    return pages
end

function ShelfView:_recommend_arrow_widget(icon, size)
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
        face = Settings.grid_face("body"),
        bold = true,
    }
end

function ShelfView:_recommend_nav_button(icon, width, height, enabled)
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    local border = Size.border.default
    local inner_w = math.max(1, width - border * 2)
    local inner_h = math.max(1, height - border * 2)
    local icon_size = math.min(
        inner_w - Screen:scaleBySize(4),
        inner_h - Screen:scaleBySize(4),
        Screen:scaleBySize(22)
    )
    icon_size = math.max(Screen:scaleBySize(14), icon_size)
    return RoundClipFrame:new{
        width = width,
        height = height,
        bordersize = border,
        padding = 0,
        margin = 0,
        radius = math.min(card_radius(), math.floor(height / 2)),
        color = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        background = enabled and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_GRAY_E,
        allow_mirroring = false,
        FixedBox:new{
            width = inner_w,
            height = inner_h,
            align = "center",
            self:_recommend_arrow_widget(icon, icon_size),
        },
    }
end

function ShelfView:_recommend_pager(width, height, page, pages, mid_gap)
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    page = math.max(1, tonumber(page) or 1)
    pages = math.max(1, tonumber(pages) or 1)
    -- Horizontal gap between buttons matches vertical gap under the title badge.
    local mid = math.max(1, tonumber(mid_gap) or Screen:scaleBySize(6))
    mid = math.min(mid, math.max(1, width - 2))
    local can_prev = page > 1
    local can_next = page < pages
    -- Flush to badge left/right; remaining width is split into two wider buttons.
    local btn_w = math.max(1, math.floor((width - mid) / 2))
    local right_w = math.max(1, width - mid - btn_w)
    local chevron_left = "chevron.left"
    local chevron_right = "chevron.right"
    if BD.mirroredUILayout() then
        chevron_left, chevron_right = chevron_right, chevron_left
    end
    local hits = {}
    if can_prev then
        hits[#hits + 1] = {
            kind = "recommend_prev",
            x = 0,
            y = 0,
            w = btn_w,
            h = height,
        }
    end
    if can_next then
        hits[#hits + 1] = {
            kind = "recommend_next",
            x = btn_w + mid,
            y = 0,
            w = right_w,
            h = height,
        }
    end
    local row = HorizontalGroup:new{
        align = "center",
        self:_recommend_nav_button(chevron_left, btn_w, height, can_prev),
        HorizontalSpan:new{ width = mid },
        self:_recommend_nav_button(chevron_right, right_w, height, can_next),
    }
    return FixedBox:new{
        width = width,
        height = height,
        align = "left",
        row,
    }, hits
end

function ShelfView:_recommend_title_icon(size)
    size = math.max(1, tonumber(size) or 1)
    local Paths = require("wereadlite.paths")
    local path = Paths.root() .. "/resources/thumb.up.svg"
    local widget
    local ok = pcall(function()
        -- IconWidget with `file` skips name lookup and acts as ImageWidget.
        widget = IconWidget:new{
            file = path,
            width = size,
            height = size,
            scale_factor = 0,
            alpha = true,
        }
        widget:getSize()
    end)
    if ok and widget then
        return widget
    end
    if widget and type(widget.free) == "function" then
        pcall(widget.free, widget)
    end
    return TextWidget:new{
        text = "赞",
        face = Font:getFace("cfont", math.max(14, math.floor(size * 0.7))),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end

function ShelfView:_recommend_title_slot(cell_w, cell_h, page, pages)
    cell_w = math.max(1, tonumber(cell_w) or 1)
    cell_h = math.max(1, tonumber(cell_h) or 1)
    local border = Size.border.default
    local pager_gap = math.max(6, Screen:scaleBySize(6))
    local pager_h = math.max(Screen:scaleBySize(30), 26)
    local title_h = math.max(1, cell_h - pager_h - pager_gap)
    local pager, pager_hits = self:_recommend_pager(cell_w, pager_h, page, pages, pager_gap)
    local pager_y = title_h + pager_gap
    local hits = {}
    for _, hit in ipairs(pager_hits) do
        hits[#hits + 1] = {
            kind = hit.kind,
            x = hit.x or 0,
            y = pager_y + (hit.y or 0),
            w = hit.w,
            h = hit.h,
        }
    end

    local pad = math.max(4, Screen:scaleBySize(4))
    local inner_w = math.max(1, cell_w - border * 2)
    local inner_h = math.max(1, title_h - border * 2)
    local face = Settings.grid_face("body")
    if title_h >= Screen:scaleBySize(110) then
        face = Settings.grid_face("title")
    end
    local sample = TextWidget:new{
        text = "推",
        face = face,
        bold = true,
        padding = 0,
    }
    local line_h = sample:getSize().h or Screen:scaleBySize(18)
    if type(sample.free) == "function" then
        pcall(sample.free, sample)
    end
    local text_block = line_h * 2 + math.max(2, Screen:scaleBySize(2))
    local icon_room = math.max(0, inner_h - text_block - pad * 3)
    local icon_size = math.min(
        Screen:scaleBySize(32),
        math.floor(inner_w * 0.42),
        icon_room > 0 and icon_room or Screen:scaleBySize(18)
    )
    icon_size = math.max(Screen:scaleBySize(16), icon_size)
    local icon_gap = math.max(3, Screen:scaleBySize(3))

    local badge_inner = VerticalGroup:new{
        align = "center",
        self:_recommend_title_icon(icon_size),
        VerticalSpan:new{ width = icon_gap },
        TextWidget:new{
            text = "为你",
            face = face,
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = math.max(1, inner_w - pad * 2),
            padding = 0,
        },
        TextWidget:new{
            text = "推荐",
            face = face,
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = math.max(1, inner_w - pad * 2),
            padding = 0,
        },
    }
    local badge = RoundClipFrame:new{
        width = cell_w,
        height = title_h,
        bordersize = border,
        padding = 0,
        margin = 0,
        radius = card_radius(),
        color = Blitbuffer.COLOR_GRAY_B,
        background = Blitbuffer.COLOR_GRAY_E,
        allow_mirroring = false,
        FixedBox:new{
            width = inner_w,
            height = inner_h,
            align = "center",
            badge_inner,
        },
    }

    local widget = FixedBox:new{
        width = cell_w,
        height = cell_h,
        align = "top",
        VerticalGroup:new{
            align = "center",
            badge,
            VerticalSpan:new{ width = pager_gap },
            pager,
        },
    }
    return widget, hits
end

function ShelfView:_recommend_empty_cell(cell_w, cell_h)
    return FixedBox:new{
        width = cell_w,
        height = cell_h,
    }
end

function ShelfView:_recommend_message_cell(text, cell_w, cell_h)
    local border = Size.border.default
    local inner_w = math.max(1, cell_w - border * 2)
    local inner_h = math.max(1, cell_h - border * 2)
    return RoundClipFrame:new{
        width = cell_w,
        height = cell_h,
        bordersize = border,
        padding = 0,
        margin = 0,
        radius = card_radius(),
        background = Blitbuffer.COLOR_WHITE,
        allow_mirroring = false,
        FixedBox:new{
            width = inner_w,
            height = inner_h,
            align = "center",
            TextBoxWidget:new{
                text = tostring(text or ""),
                face = Settings.grid_face("meta"),
                width = inner_w,
                height = inner_h,
                alignment = "center",
                height_overflow_show_ellipsis = true,
            },
        },
    }
end

function ShelfView:_recommend_cover_widget(book, cover_w, cover_h)
    book = type(book) == "table" and book or {}
    local border = Size.border.default
    local mark = utf8_prefix(book.title or "书", 1)
    local inner_w = math.max(1, cover_w - border * 2)
    local inner_h = math.max(1, cover_h - border * 2)
    local cover = placeholder(inner_w, inner_h, mark)
    local path = Covers.cached(book.bookId)
    if path and path ~= "" then
        local ok, image = pcall(function()
            return safe_image(path, inner_w, inner_h, true)
        end)
        if ok and image then
            cover = image
        end
    end
    local ok_frame, frame = pcall(function()
        return RoundClipFrame:new{
            width = cover_w,
            height = cover_h,
            bordersize = border,
            padding = 0,
            margin = 0,
            radius = card_radius(),
            background = Blitbuffer.COLOR_WHITE,
            allow_mirroring = false,
            FixedBox:new{
                width = inner_w,
                height = inner_h,
                align = "center",
                cover,
            },
        }
    end)
    if ok_frame and frame then
        return frame
    end
    Log.warn("shelf", "recommend_cover", { err = tostring(frame) })
    return self:_recommend_empty_cell(cover_w, cover_h)
end

function ShelfView:_recommend_card(span, ctx)
    span = math.max(2, tonumber(span) or 2)
    ctx = type(ctx) == "table" and ctx or {}
    local ui = self._recommend_ui or { page = 1 }
    local page = math.max(1, tonumber(ui.page) or 1)
    local cache = self._recommend_cache
    local books = self:_recommend_books()
    local loading = cache == nil
    local err = cache == false
    local cell_w = math.max(1, tonumber(ctx.cell_w) or 1)
    local gap = math.max(0, tonumber(ctx.gap) or 0)
    local cell_h = math.max(1, tonumber(ctx.row_h) or 1)
    local book_slots = self:_recommend_book_slots(span)
    local start = book_slots > 0 and ((page - 1) * book_slots + 1) or 1
    local pages = self:_recommend_page_count(span)
    local slots = {}
    local title_widget, title_hits = self:_recommend_title_slot(cell_w, cell_h, page, pages)
    slots[1] = { widget = title_widget }

    for i = 1, book_slots do
        local slot_idx = 1 + i
        local book = books[start + i - 1]
        if loading then
            slots[slot_idx] = {
                widget = i == 1
                    and self:_recommend_message_cell("加载中", cell_w, cell_h)
                    or self:_recommend_empty_cell(cell_w, cell_h),
            }
        elseif err then
            slots[slot_idx] = {
                widget = i == 1
                    and self:_recommend_message_cell("加载失败\n点按重试", cell_w, cell_h)
                    or self:_recommend_empty_cell(cell_w, cell_h),
            }
        elseif type(book) == "table" then
            slots[slot_idx] = {
                widget = self:_recommend_cover_widget(book, cell_w, cell_h),
                hit_kind = "recommend_book",
                book = book,
            }
        else
            slots[slot_idx] = {
                widget = self:_recommend_empty_cell(cell_w, cell_h),
            }
        end
    end

    local grid, hits = RecommendCard.build({
        span = span,
        cell_w = cell_w,
        gap = gap,
        height = cell_h,
        slots = slots,
    })
    for _, hit in ipairs(title_hits) do
        hits[#hits + 1] = hit
    end

    return grid, hits
end

function ShelfView:_ensure_recommend()
    if self._closed or self.page ~= 1 or self._recommend_busy or self:_is_search() then
        return
    end
    if not Settings.tile_enabled("recommend") then
        return
    end
    local span = Settings.recommend_span()
    local ui = self._recommend_ui or { page = 1 }
    local page = math.max(1, tonumber(ui.page) or 1)
    local cache = self._recommend_cache
    if cache == false then
        return
    end
    local book_slots = self:_recommend_book_slots(span)
    local books = type(cache) == "table" and cache.books or {}
    local need = book_slots > 0 and (page * book_slots) or 0
    if need <= 0 then
        return
    end
    if type(cache) == "table" and not cache.has_more and #books >= need then
        return
    end
    if type(cache) == "table" and #books >= need then
        return
    end
    self._recommend_busy = true
    local later = UIManager.tickAfterNext or UIManager.nextTick
    later(UIManager, function()
        if self._closed then
            self._recommend_busy = false
            return
        end
        local Skill = require("wereadlite.skill")
        local max_idx = 0
        local has_more = true
        if type(self._recommend_cache) == "table" then
            max_idx = tonumber(self._recommend_cache.max_idx) or 0
            has_more = self._recommend_cache.has_more ~= false
            books = self._recommend_cache.books or {}
        else
            books = {}
        end
        if not has_more then
            self._recommend_busy = false
            return
        end
        local fetch_count = math.max(span * 2, 12)
        Skill.recommend_async({
            count = fetch_count,
            max_idx = max_idx,
        }, function(data, status, err)
            if self._closed then
                self._recommend_busy = false
                return
            end
            if type(data) ~= "table" or type(data.books) ~= "table" then
                if type(self._recommend_cache) ~= "table" then
                    self._recommend_cache = false
                    TILE_CACHE.recommend = false
                end
                if status then
                    Log.warn("shelf", "recommend", { status = status, err = err })
                end
            else
                local seen = {}
                for _, book in ipairs(books) do
                    if type(book) == "table" then
                        local id = tostring(book.bookId or book.title or "")
                        if id ~= "" then
                            seen[id] = true
                        end
                    end
                end
                for _, book in ipairs(data.books) do
                    if type(book) == "table" then
                        local id = tostring(book.bookId or book.title or "")
                        if id ~= "" and not seen[id] then
                            books[#books + 1] = book
                            seen[id] = true
                        end
                    end
                end
                self._recommend_cache = {
                    books = books,
                    max_idx = tonumber(data.max_idx) or max_idx,
                    has_more = data.has_more ~= false and #data.books > 0,
                }
                TILE_CACHE.recommend = self._recommend_cache
            end
            if type(self._recommend_cache) ~= "table" then
                self._recommend_cache = { books = books, max_idx = 0, has_more = false }
                TILE_CACHE.recommend = self._recommend_cache
            end
            self._recommend_busy = false
            if not self._closed then
                self:_paint()
                local later2 = UIManager.tickAfterNext or UIManager.nextTick
                later2(UIManager, function()
                    if not self._closed and self.page == 1 then
                        self:_prefetch_covers()
                    end
                end)
            end
        end)
    end)
end

function ShelfView:_add_func_tile(layers, tile, ctx)
    local x, w = self:_col_rect(tile.col, tile.span, ctx.cell_w, ctx.gap, ctx.width, ctx.cols)
    local is_stats = tile.id == "text_stats" or tile.id == "chart_stats"
    local is_recommend = tile.id == "recommend"
    local border = Size.border.default
    local content_inset = is_recommend and card_inset() or nil
    local inset = (is_stats or is_recommend) and border or ctx.inset
    local inner_w = math.max(1, w - (content_inset or inset) * 2)
    local inner_h = math.max(1, ctx.row_h - (content_inset or inset) * 2)
    local inner
    local align = "center"
    local extra = { kind = tile.id }
    if tile.id == "recent" then
        extra.book = self:_last_book()
        inner = self:_recent_row(inner_w, ctx.inner_h, extra.book)
        align = "left_center"
    elseif tile.id == "user" then
        inner = self:_user_row(inner_w, ctx.inner_h)
    elseif tile.id == "clock" then
        inner = ClockCard.build(inner_w, ctx.inner_h)
    elseif is_stats then
        inner, extra.hits = self:_stats_card(tile.id == "chart_stats" and "chart" or "text", inner_w, inner_h)
        align = "left"
    elseif is_recommend then
        local rec_ctx = {
            cell_w = math.max(1, math.floor((inner_w - (tile.span - 1) * ctx.gap) / tile.span)),
            gap = ctx.gap,
            row_h = inner_h,
        }
        local ok_card, inner_or_err, hits = pcall(function()
            return self:_recommend_card(tile.span, rec_ctx)
        end)
        if ok_card then
            inner, extra.hits = inner_or_err, hits
        else
            Log.warn("shelf", "recommend_card", { err = tostring(inner_or_err) })
            inner = TextWidget:new{
                text = "推荐卡片加载失败",
                face = Settings.grid_face("meta"),
                max_width = inner_w,
            }
        end
        align = "left"
    else
        inner = FixedBox:new{ width = inner_w, height = ctx.inner_h }
    end
    local wrapped
    if is_recommend then
        wrapped = self:_recommend_frame(w, ctx.row_h, inner)
    elseif is_stats then
        wrapped = self:_stats_frame(w, ctx.row_h, inner)
    else
        wrapped = self:_card(w, ctx.row_h, inner, align)
    end
    layers[#layers + 1] = OffsetBox:new{
        x_off = x,
        y_off = ctx.y,
        wrapped,
    }
    self._cells[#self._cells + 1] = {
        x = x,
        y = ctx.origin_y + ctx.y,
        w = w,
        h = ctx.row_h,
        kind = extra.kind,
        book = extra.book,
    }
    local hit_inset = content_inset or inset
    for _, hit in ipairs(extra.hits or {}) do
        self._cells[#self._cells + 1] = {
            x = x + hit_inset + (hit.x or 0),
            y = ctx.origin_y + ctx.y + hit_inset + (hit.y or 0),
            w = hit.w,
            h = hit.h,
            kind = hit.kind,
            book = hit.book,
            mode = hit.mode,
            tab = hit.tab,
        }
    end
end

function ShelfView:_stats_card(kind, width, height)
    local ui = self._stats_ui or {}
    local cache = self._stats_cache or {}
    local mode = kind == "chart" and (ui.chart_mode or "monthly") or (ui.text_mode or "monthly")
    local tab = kind == "chart" and (ui.chart_tab or 1) or (ui.text_tab or 1)
    local data = cache[mode]
    local heatmap = cache.heatmap
    local loading, err
    if kind == "chart" and tab == 1 then
        loading = heatmap == nil
        err = heatmap == false
    else
        loading = data == nil
        err = data == false
    end
    return StatsCards.build({
        kind = kind,
        width = width,
        height = height,
        tab = tab,
        mode = mode,
        data = type(data) == "table" and data or nil,
        heatmap = type(heatmap) == "table" and heatmap or nil,
        loading = loading,
        error = err,
    })
end

function ShelfView:_ensure_stats()
    if self._closed or self.page ~= 1 or self._stats_busy or self:_is_search() then
        return
    end
    local ui = self._stats_ui or {}
    local cache = self._stats_cache or {}
    local need_modes = {}
    local function want_mode(mode)
        mode = mode or "monthly"
        if cache[mode] == nil then
            need_modes[mode] = true
        end
    end
    want_mode(ui.text_mode)
    if (ui.chart_tab or 1) ~= 1 then
        want_mode(ui.chart_mode)
    end
    local need_heat = cache.heatmap == nil
    if not next(need_modes) and not need_heat then
        return
    end
    self._stats_busy = true
    local later = UIManager.tickAfterNext or UIManager.nextTick
    later(UIManager, function()
        if self._closed then
            self._stats_busy = false
            return
        end
        local Skill = require("wereadlite.skill")
        local modes = {}
        for mode in pairs(need_modes) do
            modes[#modes + 1] = mode
        end
        local index = 1
        local monthly

        local function finish_stats()
            self._stats_busy = false
            if not self._closed and self.page == 1 then
                self:_paint()
            end
        end

        local function fetch_heatmap()
            if not need_heat then
                finish_stats()
                return
            end
            if type(cache.monthly) == "table" then
                monthly = cache.monthly
            end
            Skill.heatmap30_async({ monthly = monthly }, function(map, status, err)
                if self._closed then
                    self._stats_busy = false
                    return
                end
                cache.heatmap = type(map) == "table" and map or false
                if status and status ~= "ok" then
                    Log.warn("shelf", "heatmap", { status = status, err = err })
                end
                finish_stats()
            end)
        end

        local function fetch_next_mode()
            if self._closed then
                self._stats_busy = false
                return
            end
            if index > #modes then
                fetch_heatmap()
                return
            end
            local mode = modes[index]
            index = index + 1
            Skill.readdata_async(mode, function(data, status, err)
                if self._closed then
                    self._stats_busy = false
                    return
                end
                cache[mode] = type(data) == "table" and data or false
                if mode == "monthly" then
                    monthly = data
                end
                if status and not data then
                    Log.warn("shelf", "stats", { mode = mode, status = status, err = err })
                end
                fetch_next_mode()
            end)
        end

        if #modes == 0 then
            fetch_heatmap()
        else
            fetch_next_mode()
        end
    end)
end

local function cycle_tab(value, delta, maxn)
    value = (tonumber(value) or 1) + delta
    if value < 1 then
        return maxn
    end
    if value > maxn then
        return 1
    end
    return value
end

function ShelfView:_schedule_cover_refresh(gen)
    if self._closed or gen ~= self._cover_gen then
        return
    end
    if self._cover_refresh_scheduled then
        self._cover_refresh_dirty = true
        return
    end
    self._cover_refresh_scheduled = true
    self._cover_refresh_dirty = false
    UIManager:scheduleIn(0.15, function()
        self._cover_refresh_scheduled = false
        if self._closed or gen ~= self._cover_gen then
            return
        end
        local again = self._cover_refresh_dirty
        self._cover_refresh_dirty = false
        self:_paint()
        if again then
            self:_schedule_cover_refresh(gen)
        end
    end)
end

function ShelfView:_prefetch_covers()
    self._cover_gen = (self._cover_gen or 0) + 1
    local gen = self._cover_gen
    self._cover_refresh_scheduled = false
    self._cover_refresh_dirty = false
    local searching = self:_is_search()
    local books = searching and self:_search_books_for_page(self.page) or Shelf.books_for_page(self.page)
    local user = (not searching) and Shelf.user or nil
    local queue = {}
    if user and not Covers.cached_avatar() and user.avatar and user.avatar ~= "" then
        queue[#queue + 1] = { kind = "avatar", user = user }
    end
    local seen = {}
    if not searching and self.page == 1 then
        local last = self:_last_book()
        if last and last.bookId and not Covers.cached(last.bookId) then
            queue[#queue + 1] = { kind = "book", book = last }
        end
        if Settings.tile_enabled("recommend") then
            local span = math.max(2, Settings.recommend_span())
            local ui = self._recommend_ui or { page = 1 }
            local page = math.max(1, tonumber(ui.page) or 1)
            local book_slots = self:_recommend_book_slots(span)
            if book_slots > 0 then
                local start = (page - 1) * book_slots + 1
                for i = start, start + book_slots - 1 do
                    local book = self:_recommend_books()[i]
                    if type(book) == "table" then
                        local id = tostring(book.bookId or "")
                        if id ~= "" and not seen[id] and not Covers.cached(id) then
                            seen[id] = true
                            queue[#queue + 1] = { kind = "book", book = book }
                        end
                    end
                end
            end
        end
    end
    for _, book in ipairs(books or {}) do
        local id = tostring(book.bookId or "")
        if id ~= "" and not seen[id] and not Covers.cached(id) then
            seen[id] = true
            queue[#queue + 1] = { kind = "book", book = book }
        end
    end
    if #queue == 0 then
        UIManager:nextTick(function()
            if not self._closed and gen == self._cover_gen and not searching then
                self:_preload_next_api()
            end
        end)
        return
    end
    local concurrency = math.max(1, tonumber(Settings.image_concurrency()) or 4)
    local pending = 0
    local index = 1
    local finished = 0
    local total = #queue
    local pump
    local function done_one(path, err, cached)
        finished = finished + 1
        pending = math.max(0, pending - 1)
        if self._closed or gen ~= self._cover_gen then
            return
        end
        if path and not cached then
            self:_schedule_cover_refresh(gen)
        end
        if finished >= total then
            if not searching then
                self:_preload_next_api()
            end
            return
        end
        pump()
    end
    local function start(job)
        pending = pending + 1
        if job.kind == "avatar" then
            Covers.ensure_avatar_async(job.user, done_one)
        else
            Covers.ensure_async(job.book, done_one)
        end
    end
    pump = function()
        if self._closed or gen ~= self._cover_gen then
            return
        end
        while pending < concurrency and index <= total do
            local job = queue[index]
            index = index + 1
            start(job)
        end
    end
    Log.dbg("shelf", "covers_async", { jobs = total, concurrency = concurrency, page = self.page })
    UIManager:nextTick(function()
        if self._closed or gen ~= self._cover_gen then
            return
        end
        pump()
    end)
end

function ShelfView:_preload_next_api()
    if self._closed or self._preload_busy or self:_is_search() then
        return
    end
    local next_page = (self.page or 1) + 1
    local max_page = math.max(1, Shelf.ui_page_count())
    if next_page > max_page or not Shelf.needs_api_for_page(next_page) then
        return
    end
    local first, last = Shelf.page_slice(next_page)
    local gen = (self._preload_gen or 0) + 1
    self._preload_gen = gen
    self._preload_busy = true
    Log.dbg("shelf", "preload", {
        from_page = self.page,
        next_page = next_page,
        first = first,
        last = last,
        loaded = Shelf.loaded_count(),
        total = Shelf.total,
    })
    UIManager:scheduleIn(0.05, function()
        if self._closed or gen ~= self._preload_gen then
            self._preload_busy = false
            return
        end
        Shelf.ensure_page(next_page, function(_, status)
            if self._closed or gen ~= self._preload_gen then
                self._preload_busy = false
                return
            end
            self._preload_busy = false
            if status == "auth_expired" then
                self:_expire()
                return
            end
            if status and status ~= "ok" then
                Log.warn("shelf", "preload", { status = status, next_page = next_page })
            end
        end)
    end)
end

function ShelfView:_goto(page)
    if self:_is_search() then
        self:_goto_search(page)
        return
    end
    self._preload_gen = (self._preload_gen or 0) + 1
    self._preload_busy = false
    local max_page = math.max(1, Shelf.ui_page_count())
    page = math.max(1, math.min(tonumber(page) or 1, max_page))

    local function finish()
        if self._closed then
            return
        end
        local last = math.max(1, Shelf.ui_page_count())
        local target = math.max(1, math.min(page, last))
        while target > 1 and #Shelf.books_for_page(target) == 0 do
            target = target - 1
        end
        self.page = target
        self:_paint()
        self:_prefetch_covers()
    end

    if not Shelf.needs_api_for_page(page) then
        finish()
        return
    end

    local first, last = Shelf.page_slice(page)
    self.page = page
    self:_set_body(self:_status_widget(string.format(
        "正在加载第 %d 页…",
        page
    )))
    Log.dbg("shelf", "goto_page", {
        page = page,
        first = first,
        last = last,
        total = Shelf.total,
        pages = max_page,
    })
    Shelf.ensure_page(page, function(_, status, err)
        if self._closed then
            return
        end
        if status == "auth_expired" then
            self:_expire()
            return
        end
        if not Shelf.has_books() then
            self:_fail(status, err)
            return
        end
        if status and status ~= "ok" then
            UIManager:show(InfoMessage:new{
                text = "无法加载更多书籍",
                timeout = 1.5,
            })
        end
        finish()
    end)
end

function ShelfView:_open_settings()
    Settings.show_menu(function()
        if self._closed then
            return
        end
        self:_apply_layout()
    end, function()
        if not self._closed then
            self:_open_search()
        end
    end, function()
        if self._closed then
            return
        end
        if self.on_auth_expired then
            self.on_auth_expired()
        else
            self:onClose()
        end
    end)
end

function ShelfView:_open_stats()
    local SkillView = require("wereadlite.skill_view")
    SkillView.show_stats()
end

function ShelfView:_open_search()
    local SkillView = require("wereadlite.skill_view")
    SkillView.show_search(function(keyword)
        if not self._closed then
            self:_start_search(keyword)
        end
    end)
end

function ShelfView:_browse_title()
    local s = self._search
    if not s then
        return "搜索书籍"
    end
    if s.mode == "similar" then
        return "相似推荐：" .. tostring(s.source_title or "图书")
    end
    return s.keyword or "搜索书籍"
end

function ShelfView:_is_search()
    return type(self._search) == "table"
end

function ShelfView:_search_per()
    return math.max(1, Settings.page_books())
end

function ShelfView:_search_page_count()
    local s = self._search
    if not s then
        return 1
    end
    local n = #(s.books or {})
    local per = self:_search_per()
    if n <= 0 then
        return 1
    end
    local pages = math.ceil(n / per)
    if s.has_more then
        pages = math.max(pages, self.page or 1)
    end
    return math.max(1, pages)
end

function ShelfView:_search_books_for_page(page)
    local s = self._search
    if not s then
        return {}
    end
    local per = self:_search_per()
    page = math.max(1, tonumber(page) or 1)
    local first = (page - 1) * per + 1
    local last = page * per
    local out = {}
    for i = first, math.min(last, #(s.books or {})) do
        out[#out + 1] = s.books[i]
    end
    return out
end

function ShelfView:_merge_search_books(books)
    local s = self._search
    if not s then
        return
    end
    s.seen = s.seen or {}
    for _, book in ipairs(books or {}) do
        if type(book) == "table" then
            local key = tostring(book.bookId or "")
            if key == "" then
                key = tostring(book.title or "")
            end
            if key ~= "" and not s.seen[key] then
                s.seen[key] = true
                s.books[#s.books + 1] = book
            end
        end
    end
end

function ShelfView:_start_search(keyword)
    keyword = tostring(keyword or ""):match("^%s*(.-)%s*$") or ""
    if keyword == "" then
        UIManager:show(InfoMessage:new{
            text = "请输入关键词",
            timeout = 1.5,
        })
        return
    end
    if not self:_is_search() then
        self._shelf_page = self.page or 1
    end
    self._search = {
        mode = "search",
        keyword = keyword,
        books = {},
        seen = {},
        has_more = true,
        max_idx = 0,
    }
    self.page = 1
    self:_set_body(self:_status_widget("正在搜索…"))
    UIManager:scheduleIn(0.05, function()
        if self._closed or not self:_is_search() or self._search.keyword ~= keyword then
            return
        end
        local Skill = require("wereadlite.skill")
        Skill.search_async(keyword, {
            scope = 10,
            count = math.max(10, self:_search_per()),
            max_idx = 0,
        }, function(result, status)
            if self._closed or not self:_is_search() or self._search.keyword ~= keyword then
                return
            end
            if not result then
                self._search.has_more = false
                Log.warn("shelf", "search", { status = status })
                UIManager:show(InfoMessage:new{
                    text = status == "auth_expired" and "登录已过期，请重新扫码"
                        or status == "offline" and "网络不可用"
                        or "搜索失败",
                    timeout = 2,
                })
                self:_paint()
                return
            end
            self:_merge_search_books(result.books)
            self._search.has_more = result.has_more and true or false
            self._search.max_idx = result.max_idx or 0
            if result.upgrade_info then
                UIManager:show(InfoMessage:new{
                    text = "Skill 接口有更新，部分功能可能异常",
                    timeout = 2,
                })
            end
            if #self._search.books == 0 then
                UIManager:show(InfoMessage:new{
                    text = string.format("没有找到与“%s”相关的结果", keyword),
                    timeout = 2,
                })
            end
            self:_paint()
            self:_prefetch_covers()
        end)
    end)
end

function ShelfView:_start_similar(book)
    book = type(book) == "table" and book or {}
    local book_id = tostring(book.bookId or book.book_id or "")
    if book_id == "" then
        UIManager:show(InfoMessage:new{
            text = "无法识别图书",
            timeout = 2,
        })
        return
    end
    if not self:_is_search() then
        self._shelf_page = self.page or 1
    end
    local source_title = tostring(book.title or "图书")
    self._search = {
        mode = "similar",
        book_id = book_id,
        source_title = source_title,
        books = {},
        seen = {},
        has_more = true,
        max_idx = 0,
        session_id = "",
    }
    self.page = 1
    self:_set_body(self:_status_widget("正在加载相似推荐…"))
    UIManager:scheduleIn(0.05, function()
        if self._closed or not self:_is_search() or self._search.mode ~= "similar"
            or self._search.book_id ~= book_id then
            return
        end
        local Skill = require("wereadlite.skill")
        Skill.similar_async(book_id, {
            count = math.max(12, self:_search_per()),
            max_idx = 0,
        }, function(result, status)
            if self._closed or not self:_is_search() or self._search.mode ~= "similar"
                or self._search.book_id ~= book_id then
                return
            end
            if not result then
                self._search.has_more = false
                Log.warn("shelf", "similar", { status = status, book_id = book_id })
                UIManager:show(InfoMessage:new{
                    text = status == "auth_expired" and "登录已过期，请重新扫码"
                        or status == "offline" and "网络不可用"
                        or "加载失败",
                    timeout = 2,
                })
                self:_paint()
                return
            end
            self:_merge_search_books(result.books)
            self._search.has_more = result.has_more and true or false
            self._search.max_idx = result.max_idx or 0
            self._search.session_id = tostring(result.session_id or "")
            if result.upgrade_info then
                UIManager:show(InfoMessage:new{
                    text = "Skill 接口有更新，部分功能可能异常",
                    timeout = 2,
                })
            end
            if #self._search.books == 0 then
                UIManager:show(InfoMessage:new{
                    text = "暂无相似推荐",
                    timeout = 2,
                })
            end
            self:_paint()
            self:_prefetch_covers()
        end)
    end)
end

function ShelfView:_close_search()
    if not self:_is_search() then
        return true
    end
    local page = self._shelf_page or 1
    self._search = nil
    self._shelf_page = nil
    self:_goto(page)
    return true
end

function ShelfView:_open_search_book(book)
    if type(book) ~= "table" then
        return
    end
    local BookDetail = require("wereadlite.book_detail")
    BookDetail.show(book)
end

function ShelfView:_show_book_hold_menu(book)
    if type(book) ~= "table" then
        return
    end
    local BookDetail = require("wereadlite.book_detail")
    local dialog
    dialog = ButtonDialog:new{
        title = tostring(book.title or "图书"),
        title_align = "center",
        buttons = {
            {
                {
                    text = "查看详情",
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            BookDetail.show(book)
                        end)
                    end,
                },
                {
                    text = "相似推荐",
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:_start_similar(book)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function ShelfView:_goto_search(page)
    local s = self._search
    if not s then
        return
    end
    self._preload_gen = (self._preload_gen or 0) + 1
    local per = self:_search_per()
    local load_all = page == math.huge
    page = load_all and math.max(1, math.ceil(math.max(#s.books, 1) / per)) or math.max(1, tonumber(page) or 1)

    local function finish()
        if self._closed or not self:_is_search() then
            return
        end
        local last = math.max(1, math.ceil(math.max(#s.books, 1) / per))
        if #s.books == 0 then
            last = 1
        end
        if load_all or not s.has_more then
            self.page = math.min(page, last)
        else
            self.page = math.max(1, math.min(page, math.max(last, page)))
        end
        self:_paint()
        self:_prefetch_covers()
    end

    local function fetch_until()
        if self._closed or not self:_is_search() then
            return
        end
        local enough = (not load_all) and #s.books >= page * per
        if enough or not s.has_more then
            if load_all then
                page = math.max(1, math.ceil(math.max(#s.books, 1) / per))
                if #s.books == 0 then
                    page = 1
                end
            end
            finish()
            return
        end
        local Skill = require("wereadlite.skill")
        local function on_page(result, status)
            if self._closed or not self:_is_search() then
                return
            end
            if not result then
                s.has_more = false
                Log.warn("shelf", s.mode == "similar" and "similar_more" or "search_more", { status = status })
                finish()
                return
            end
            local before = #s.books
            self:_merge_search_books(result.books)
            s.has_more = result.has_more and true or false
            s.max_idx = math.max(s.max_idx or 0, result.max_idx or 0)
            if s.mode == "similar" then
                s.session_id = tostring(result.session_id or s.session_id or "")
            end
            if #s.books == before then
                s.has_more = false
            end
            local loading_text = s.mode == "similar" and "正在加载相似推荐… %d" or "正在加载搜索结果… %d"
            self:_set_body(self:_status_widget(string.format(
                loading_text,
                #s.books
            )))
            UIManager:scheduleIn(0.05, fetch_until)
        end
        if s.mode == "similar" then
            Skill.similar_async(s.book_id, {
                count = math.max(12, per),
                max_idx = s.max_idx or 0,
                session_id = s.session_id,
            }, on_page)
        else
            Skill.search_async(s.keyword, {
                scope = 10,
                count = per,
                max_idx = s.max_idx or 0,
            }, on_page)
        end
    end

    if ((not load_all) and #s.books >= page * per) or not s.has_more then
        finish()
        return
    end
    self.page = page
    local start_text = s.mode == "similar" and "正在加载相似推荐…" or "正在加载搜索结果…"
    self:_set_body(self:_status_widget(start_text))
    UIManager:scheduleIn(0.05, fetch_until)
end

function ShelfView:_open_tile_menu(id)
    Settings.show_tile_menu(id, function()
        if self._closed then
            return
        end
        self:_apply_layout()
    end)
end

local TILE_FROM_KIND = {
    recent = "recent",
    user = "user",
    clock = "clock",
    text_stats = "text_stats",
    text_mode = "text_stats",
    text_prev = "text_stats",
    text_next = "text_stats",
    chart_stats = "chart_stats",
    chart_mode = "chart_stats",
    chart_prev = "chart_stats",
    chart_next = "chart_stats",
    recommend = "recommend",
    recommend_prev = "recommend",
    recommend_next = "recommend",
    recommend_book = "recommend",
}

local HIT_PRIORITY = {
    text_mode = 4,
    chart_mode = 4,
    text_prev = 4,
    text_next = 4,
    chart_prev = 4,
    chart_next = 4,
    recommend_prev = 4,
    recommend_next = 4,
    recommend_book = 4,
    user = 3,
    clock = 2,
    recent = 2,
    book = 2,
    text_stats = 1,
    chart_stats = 1,
    recommend = 1,
}

function ShelfView:_hit_cell(x, y)
    local found
    local found_pri = -1
    for _, cell in ipairs(self._cells) do
        if x >= cell.x and x < cell.x + cell.w and y >= cell.y and y < cell.y + cell.h then
            local pri = HIT_PRIORITY[cell.kind] or 1
            if pri >= found_pri then
                found = cell
                found_pri = pri
            end
        end
    end
    return found
end

function ShelfView:_apply_layout()
    if self:_is_search() then
        self.page = math.max(1, math.min(self.page or 1, self:_search_page_count()))
        self:_goto(self.page)
        return
    end
    local max_page = math.max(1, Shelf.ui_page_count())
    self.page = math.max(1, math.min(self.page, max_page))
    self:_goto(self.page)
end

function ShelfView:onNextPage()
    self:_goto(self.page + 1)
    return true
end

function ShelfView:onPrevPage()
    self:_goto(self.page - 1)
    return true
end

function ShelfView:onFirstPage()
    self:_goto(1)
    return true
end

function ShelfView:onLastPage()
    if self:_is_search() then
        self:_goto(math.huge)
        return true
    end
    -- Jump by local total/page math; Shelf.ensure_page fetches only that slice.
    local last = math.max(1, Shelf.ui_page_count())
    Log.dbg("shelf", "last_page", {
        page = last,
        total = Shelf.total,
        first_last = { Shelf.page_slice(last) },
    })
    self:_goto(last)
    return true
end

function ShelfView:onSwipe(_, ges)
    local start_pos = ges and (ges.start_pos or ges.pos)
    local bar = self._toolbar_hit
    if bar and start_pos and start_pos.y >= bar.y1 and start_pos.y < bar.y2 then
        return true
    end
    local direction = ges and ges.direction
    if direction == "west" then
        return self:onNextPage()
    end
    if direction == "east" then
        return self:onPrevPage()
    end
    return true
end

function ShelfView:onTap(_, ges)
    local pos = ges and ges.pos
    if not pos then
        return true
    end
    local x, y = pos.x, pos.y
    local bar = self._toolbar_hit
    if bar and y >= bar.y1 and y < bar.y2 then
        if bar.search_clear_x1 and x >= bar.search_clear_x1 and x < (bar.search_clear_x2 or bar.search_x2) then
            return self:_close_search()
        end
        if x >= bar.search_x1 and x < bar.search_x2 then
            self:_open_search()
            return true
        end
        if x >= bar.settings_x1 and x < bar.settings_x2 then
            self:_open_settings()
            return true
        end
        if x >= bar.close_x1 and x < bar.close_x2 then
            if self:_is_search() then
                return self:_close_search()
            end
            return self:onClose()
        end
        return true
    end
    local pager = self._pager_hit
    if pager and y >= pager.y then
        if x < pager.first_x2 then
            if pager.can_prev then
                return self:onFirstPage()
            end
            return true
        end
        if x >= pager.prev_x1 and x < pager.prev_x2 then
            if pager.can_prev then
                return self:onPrevPage()
            end
            return true
        end
        if x >= pager.next_x1 and x < pager.next_x2 then
            if pager.can_next then
                return self:onNextPage()
            end
            return true
        end
        if x >= pager.last_x1 then
            if pager.can_next then
                return self:onLastPage()
            end
            return true
        end
        return true
    end
    local cell = self:_hit_cell(x, y)
    if cell then
        if cell.kind == "text_mode" then
            self._stats_ui.text_mode = cell.mode
            self:_paint()
            return true
        end
        if cell.kind == "chart_mode" then
            self._stats_ui.chart_mode = cell.mode
            self:_paint()
            return true
        end
        if cell.kind == "text_prev" then
            self._stats_ui.text_tab = cycle_tab(self._stats_ui.text_tab, -1, StatsCards.TEXT_TABS)
            self:_paint()
            return true
        end
        if cell.kind == "text_next" then
            self._stats_ui.text_tab = cycle_tab(self._stats_ui.text_tab, 1, StatsCards.TEXT_TABS)
            self:_paint()
            return true
        end
        if cell.kind == "chart_prev" then
            self._stats_ui.chart_tab = cycle_tab(self._stats_ui.chart_tab, -1, StatsCards.CHART_TABS)
            self:_paint()
            return true
        end
        if cell.kind == "chart_next" then
            self._stats_ui.chart_tab = cycle_tab(self._stats_ui.chart_tab, 1, StatsCards.CHART_TABS)
            self:_paint()
            return true
        end
        if cell.kind == "recommend_prev" then
            local span = Settings.recommend_span()
            local pages = self:_recommend_page_count(span)
            local page = math.max(1, tonumber(self._recommend_ui.page) or 1)
            if page > 1 then
                self._recommend_ui.page = page - 1
                self:_paint()
                self:_ensure_recommend()
                self:_prefetch_covers()
            end
            return true
        end
        if cell.kind == "recommend_next" then
            local span = Settings.recommend_span()
            local pages = self:_recommend_page_count(span)
            local page = math.max(1, tonumber(self._recommend_ui.page) or 1)
            if page < pages then
                self._recommend_ui.page = page + 1
                self:_paint()
                self:_ensure_recommend()
                self:_prefetch_covers()
            end
            return true
        end
        if cell.kind == "recommend_book" and cell.book then
            self:_open_search_book(cell.book)
            return true
        end
        if cell.kind == "text_stats" then
            local mode = self._stats_ui.text_mode or "monthly"
            if self._stats_cache[mode] == false then
                self._stats_cache[mode] = nil
                self:_paint()
            end
            return true
        end
        if cell.kind == "recommend" then
            if self._recommend_cache == false then
                self._recommend_cache = nil
                TILE_CACHE.recommend = nil
                self:_paint()
                self:_ensure_recommend()
            end
            return true
        end
        if cell.kind == "chart_stats" then
            local ui = self._stats_ui
            if (ui.chart_tab or 1) == 1 then
                if self._stats_cache.heatmap == false then
                    self._stats_cache.heatmap = nil
                    self:_paint()
                end
            elseif self._stats_cache[ui.chart_mode or "monthly"] == false then
                self._stats_cache[ui.chart_mode or "monthly"] = nil
                self:_paint()
            end
            return true
        end
        if (cell.kind == "book" or cell.kind == "recent") and cell.book then
            if self:_is_search() then
                self:_open_search_book(cell.book)
            else
                Reading.open_book(cell.book)
            end
        elseif cell.kind == "user" then
            self:_open_stats()
        end
        return true
    end
    local width = Screen:getWidth()
    if x < width * 0.12 then
        return self:onPrevPage()
    end
    if x > width * 0.88 then
        return self:onNextPage()
    end
    return true
end

function ShelfView:onHold(_, ges)
    local pos = ges and ges.pos
    if not pos then
        return true
    end
    local bar = self._toolbar_hit
    if bar and pos.y >= bar.y1 and pos.y < bar.y2 then
        return true
    end
    local cell = self:_hit_cell(pos.x, pos.y)
    if cell and (cell.kind == "book" or cell.kind == "recent") and cell.book then
        self:_show_book_hold_menu(cell.book)
        return true
    end
    if self:_is_search() then
        return true
    end
    local tile_id = cell and TILE_FROM_KIND[cell.kind]
    if tile_id then
        self:_open_tile_menu(tile_id)
    end
    return true
end

function ShelfView:_mark_closed()
    if self._closed then
        return false
    end
    self._closed = true
    self._clock_gen = (self._clock_gen or 0) + 1
    self._cover_gen = (self._cover_gen or 0) + 1
    self._preload_gen = (self._preload_gen or 0) + 1
    self._recommend_busy = false
    self._stats_busy = false
    return true
end

function ShelfView:onClose()
    if self:_is_search() then
        return self:_close_search()
    end
    self:_mark_closed()
    UIManager:close(self)
    if self.on_close then
        self.on_close()
    end
    return true
end

function ShelfView:onCloseWidget()
    self:_mark_closed()
    if self[1] and self[1].free then
        pcall(self[1].free, self[1])
    end
    self[1] = nil
end

return ShelfView
