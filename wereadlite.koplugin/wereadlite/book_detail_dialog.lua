local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Screen = Device.screen
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local BookDetail = require("wereadlite.book_detail")
local Covers = require("wereadlite.covers")
local Settings = require("wereadlite.settings")

local PAD = Screen:scaleBySize(14)
local GAP = Screen:scaleBySize(10)
local FOOTER_H = Screen:scaleBySize(52)

local FixedBox = WidgetContainer:extend{ width = 1, height = 1, align = "left" }
function FixedBox:getSize()
    return Geom:new{ w = self.width, h = self.height }
end
function FixedBox:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    if self.background then
        bb:paintRect(x, y, self.width, self.height, self.background)
    end
    if not self[1] then
        return
    end
    local size = self[1]:getSize() or {}
    local child_w = math.min(size.w or self.width, self.width)
    local child_h = math.min(size.h or self.height, self.height)
    local px, py = x, y
    if self.align == "center" then
        px = x + math.floor((self.width - child_w) / 2)
        py = y + math.floor((self.height - child_h) / 2)
    end
    self[1]:paintTo(bb, px, py)
end

local function fmt_rating(value)
    value = tonumber(value) or 0
    if value <= 0 then
        return ""
    end
    if value > 10 then
        return string.format("%.1f 分", value / 10)
    end
    return string.format("%.1f 分", value)
end

local function fmt_words(count)
    count = tonumber(count) or 0
    if count <= 0 then
        return ""
    end
    if count >= 10000 then
        return string.format("%.1f 万字", count / 10000)
    end
    return tostring(count) .. " 字"
end

local function meta_line(label, value)
    value = tostring(value or "")
    if value == "" then
        return nil
    end
    return TextWidget:new{
        text = label .. value,
        face = Settings.grid_face("meta"),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = 100000,
    }
end

local function cover_widget(book, width, height)
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    local mark = (tostring(book.title or "书"):gsub("^%s+", ""):sub(1, 3))
    local placeholder = TextWidget:new{
        text = mark,
        face = Font:getFace("cfont", 28),
        fgcolor = Blitbuffer.COLOR_GRAY,
    }
    local path = Covers.cached(book.bookId)
    if path and path ~= "" then
        local image
        local ok = pcall(function()
            image = ImageWidget:new{
                file = path,
                width = width,
                height = height,
                scale_factor = 0,
                file_do_cache = false,
            }
            image:getSize()
        end)
        if ok and image then
            return FrameContainer:new{
                width = width,
                height = height,
                bordersize = Screen:scaleBySize(1),
                padding = 0,
                margin = 0,
                radius = Screen:scaleBySize(6),
                background = Blitbuffer.COLOR_WHITE,
                color = Blitbuffer.COLOR_GRAY,
                image,
            }
        end
        if image and type(image.free) == "function" then
            pcall(image.free, image)
        end
    end
    return FrameContainer:new{
        width = width,
        height = height,
        bordersize = Screen:scaleBySize(1),
        padding = 0,
        margin = 0,
        radius = Screen:scaleBySize(6),
        background = Blitbuffer.COLOR_GRAY_3,
        color = Blitbuffer.COLOR_GRAY,
        FixedBox:new{
            width = width,
            height = height,
            align = "center",
            placeholder,
        },
    }
end

local BookDetailDialog = InputContainer:extend{
    book = nil,
}

function BookDetailDialog:init()
    self.fullscreen = true
    self.covers_fullscreen = true
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self._closed = false
    self._close_gen = 0
    self:_rebuild()
    self.key_events = {
        Close = { { Device.input.group.Back }, doc = "close" },
    }
end

function BookDetailDialog:_cancel_pending()
    if self._closed then
        return false
    end
    self._closed = true
    self._close_gen = (self._close_gen or 0) + 1
    self._cover_fetching = false
    return true
end

function BookDetailDialog:_schedule_close(after_close)
    UIManager:nextTick(function()
        if after_close then
            pcall(after_close)
        end
        UIManager:close(self)
    end)
end

function BookDetailDialog:onClose()
    if not self:_cancel_pending() then
        return true
    end
    if self.on_close_callback then
        pcall(self.on_close_callback)
    end
    self:_schedule_close()
    return true
end

function BookDetailDialog:onCloseWidget()
    self._closed = true
    self._close_gen = (self._close_gen or 0) + 1
    self._cover_fetching = false
    if self[1] and self[1].free then
        pcall(self[1].free, self[1])
    end
    self[1] = nil
end

function BookDetailDialog:update_book(book)
    if self._closed then
        return
    end
    self.book = type(book) == "table" and book or self.book
    self:_rebuild()
    if not self._closed then
        UIManager:setDirty(self, "ui")
    end
end

function BookDetailDialog:_rebuild()
    if self._closed then
        return
    end
    if self[1] and self[1].free then
        pcall(self[1].free, self[1])
    end
    self._cover_fetching = false
    local book = type(self.book) == "table" and self.book or {}
    local title_h = Screen:scaleBySize(48)
    local content_h = math.max(1, self.height - title_h - FOOTER_H - Screen:scaleBySize(8))
    local inner_w = self.width - PAD * 2
    local cover_w = math.min(math.floor(inner_w * 0.32), Screen:scaleBySize(120))
    local cover_h = math.floor(cover_w * 1.45)
    local meta_w = math.max(1, inner_w - cover_w - GAP)

    local meta = VerticalGroup:new{ align = "left" }
    meta[#meta + 1] = TextBoxWidget:new{
        text = tostring(book.title or "未知书名"),
        face = Settings.grid_face("title"),
        width = meta_w,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        alignment = "left",
    }
    meta[#meta + 1] = VerticalSpan:new{ width = GAP }
    if book.author and book.author ~= "" then
        meta[#meta + 1] = TextWidget:new{
            text = book.author,
            face = Settings.grid_face("body"),
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = meta_w,
        }
        meta[#meta + 1] = VerticalSpan:new{ width = math.max(4, GAP - 2) }
    end

    local function add_meta(label, value)
        local line = meta_line(label, value)
        if line then
            meta[#meta + 1] = line
            meta[#meta + 1] = VerticalSpan:new{ width = math.max(3, GAP - 4) }
        end
    end

    add_meta("分类  ", book.category)
    add_meta("出版社  ", book.publisher)
    local rating = fmt_rating(book.rating)
    if rating ~= "" then
        local extra = ""
        if (book.rating_count or 0) > 0 then
            extra = string.format("（%d 人评）", book.rating_count)
        end
        add_meta("评分  ", rating .. extra)
    end
    if (book.reading_count or 0) > 0 then
        add_meta("在读  ", tostring(book.reading_count) .. " 人")
    end
    local words = fmt_words(book.total_words)
    if words ~= "" then
        add_meta("字数  ", words)
    end
    if book.isbn and book.isbn ~= "" then
        add_meta("ISBN  ", book.isbn)
    end
    if (book.soldout or 0) == 1 then
        add_meta("状态  ", "已下架")
    end

    local header = HorizontalGroup:new{ align = "top" }
    header[#header + 1] = cover_widget(book, cover_w, cover_h)
    header[#header + 1] = HorizontalSpan:new{ width = GAP }
    header[#header + 1] = FixedBox:new{
        width = meta_w,
        height = cover_h,
        align = "left",
        meta,
    }

    local intro = tostring(book.intro or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local header_block_h = cover_h + GAP
    local intro_h = math.max(Screen:scaleBySize(80), content_h - header_block_h - GAP)
    local body = VerticalGroup:new{ align = "left" }
    body[#body + 1] = header
    body[#body + 1] = VerticalSpan:new{ width = GAP }
    body[#body + 1] = LineWidget:new{
        dimen = Geom:new{ w = inner_w, h = Screen:scaleBySize(1) },
        background = Blitbuffer.COLOR_GRAY_3,
    }
    body[#body + 1] = VerticalSpan:new{ width = GAP }
    if intro ~= "" then
        body[#body + 1] = TextBoxWidget:new{
            text = intro,
            face = Settings.grid_face("body"),
            width = inner_w,
            height = intro_h,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            alignment = "left",
            height_overflow_show_ellipsis = true,
        }
    else
        body[#body + 1] = TextWidget:new{
            text = "暂无简介",
            face = Settings.grid_face("meta"),
            fgcolor = Blitbuffer.COLOR_GRAY,
        }
    end

    local can_read = BookDetail.can_read(book)
    local btn_w = math.floor((inner_w - GAP) / 2)
    local footer = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = "关闭",
            width = btn_w,
            callback = function()
                self:onClose()
            end,
        },
        HorizontalSpan:new{ width = GAP },
        Button:new{
            text = "开始阅读",
            width = btn_w,
            enabled = can_read,
            callback = function()
                if not self:_cancel_pending() then
                    return
                end
                if self.on_close_callback then
                    pcall(self.on_close_callback)
                end
                self:_schedule_close(function()
                    BookDetail.start_reading(book)
                end)
            end,
        },
    }

    if book.bookId and book.cover and book.cover ~= "" and not Covers.cached(book.bookId) and not self._cover_fetching then
        self._cover_fetching = true
        local close_gen = self._close_gen
        local book_id = tostring(book.bookId or "")
        Covers.ensure_async(book, function()
            if self._closed or self._close_gen ~= close_gen then
                return
            end
            self._cover_fetching = false
            if self.book and tostring(self.book.bookId or "") == book_id then
                self:_rebuild()
                if not self._closed then
                    UIManager:setDirty(self, "ui")
                end
            end
        end)
    end

    if self._closed then
        return
    end

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        width = self.width,
        height = self.height,
        VerticalGroup:new{
            align = "center",
            TitleBar:new{
                width = self.width,
                fullscreen = true,
                title = "图书详情",
                with_bottom_line = true,
                close_callback = function()
                    self:onClose()
                end,
            },
            FixedBox:new{
                width = self.width,
                height = content_h,
                align = "top",
                FrameContainer:new{
                    width = inner_w + PAD * 2,
                    padding = PAD,
                    bordersize = 0,
                    margin = 0,
                    background = Blitbuffer.COLOR_WHITE,
                    body,
                },
            },
            VerticalSpan:new{ width = Screen:scaleBySize(4) },
            footer,
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
        },
    }
end

return BookDetailDialog
