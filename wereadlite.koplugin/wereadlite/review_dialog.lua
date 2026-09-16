local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen
local Paths = require("wereadlite.paths")

local PAD = Screen:scaleBySize(10)
local AVATAR_TEXT_GAP = Screen:scaleBySize(20)
local AVATAR = Screen:scaleBySize(52)
local BORDER = Size.border.default
-- Dialog chrome: thicker outer frame than card/button borders.
local OUTER_BORDER = math.max(Size.border.window or BORDER * 2, Screen:scaleBySize(3))
local TEXT_COLOR = Blitbuffer.COLOR_BLACK
local BORDER_COLOR = Blitbuffer.COLOR_GRAY_3
local FOLD_LINES = 5
local BODY_SIZE = 18
local NAME_SIZE = 19
local TITLE_H = Screen:scaleBySize(48)
local NAV_BTN_H = Screen:scaleBySize(36)
local NAV_TOP_GAP = Screen:scaleBySize(8)
local NAV_BOTTOM_GAP = Screen:scaleBySize(12)
local CARD_GAP = Screen:scaleBySize(10)
local NAME_BODY_GAP = Screen:scaleBySize(6)
local BODY_BTN_GAP = Screen:scaleBySize(6)
local VIEW_FULL_BTN_W = Screen:scaleBySize(120)
-- Left/right inset of the comment list inside the dialog.
local LIST_SIDE_INSET = Screen:scaleBySize(16)
-- Outer margin so the reading page remains visible; tap there to dismiss.
local OUTER_MARGIN = math.max(Screen:scaleBySize(36), math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.1))

-- Content size inside FrameContainer after OUTER_BORDER on each side.
local function inner_size(outer_w, outer_h)
    local w = math.max(1, (tonumber(outer_w) or 1) - OUTER_BORDER * 2)
    local h = math.max(1, (tonumber(outer_h) or 1) - OUTER_BORDER * 2)
    return w, h
end

-- Clips children so list content cannot paint into the reserved pager strip.
local FixedBox = WidgetContainer:extend{ width = 1, height = 1 }
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
    local child_w = math.min(tonumber(size.w) or self.width, self.width)
    local child_h = math.min(tonumber(size.h) or self.height, self.height)
    local px, py = x, y
    if self.align ~= "left" and self.align ~= "left_center" then
        px = x + math.floor((self.width - child_w) / 2)
    end
    if self.align == "center" or self.align == "left_center" then
        py = y + math.floor((self.height - child_h) / 2)
    elseif self.align == "bottom" then
        py = y + (self.height - child_h)
    end
    -- BlitBuffer is FFI cdata: probing missing members like getClipRect throws.
    -- Pagination keeps content within height; erase any residual overflow below.
    self[1]:paintTo(bb, px, py)
    local child_full_h = tonumber(size.h) or 0
    if child_full_h > self.height then
        bb:paintRect(
            x,
            y + self.height,
            self.width,
            child_full_h - self.height,
            self.background or Blitbuffer.COLOR_WHITE
        )
    end
end

local ReviewDialog = InputContainer:extend{ reviews = nil }

-- Same outer margin / size as ReviewDialog; shown above it with covers_fullscreen
-- so Button flash_ui cannot paint the parent over an official TextViewer.
local FullReviewDialog = InputContainer:extend{}

local function free_widget(w)
    if w and type(w.free) == "function" then
        pcall(w.free, w)
    end
end

local function body_face()
    return Font:getFace("cfont", BODY_SIZE)
end

local function name_face()
    return Font:getFace("cfont", NAME_SIZE)
end

local function register_margin_close(widget)
    if not Device:isTouchDevice() then
        return
    end
    local mx = OUTER_MARGIN / widget.screen_w
    local my = OUTER_MARGIN / widget.screen_h
    local function close_handler()
        widget:onClose()
        return true
    end
    widget:registerTouchZones({
        {
            id = "wereadlite_full_review_close_top",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = my },
            handler = close_handler,
        },
        {
            id = "wereadlite_full_review_close_bottom",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 1 - my, ratio_w = 1, ratio_h = my },
            handler = close_handler,
        },
        {
            id = "wereadlite_full_review_close_left",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = my, ratio_w = mx, ratio_h = 1 - 2 * my },
            handler = close_handler,
        },
        {
            id = "wereadlite_full_review_close_right",
            ges = "tap",
            screen_zone = { ratio_x = 1 - mx, ratio_y = my, ratio_w = mx, ratio_h = 1 - 2 * my },
            handler = close_handler,
        },
    })
end

function FullReviewDialog:init()
    self.modal = true
    self.covers_fullscreen = true
    self.stop_events_propagation = true
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.width = math.max(1, self.screen_w - OUTER_MARGIN * 2)
    self.height = math.max(1, self.screen_h - OUTER_MARGIN * 2)
    self.inner_w, self.inner_h = inner_size(self.width, self.height)
    self.title = tostring(self.title or "微信读书用户")
    self.text = tostring(self.text or "")

    local title_bar = TitleBar:new{
        width = self.inner_w,
        fullscreen = false,
        title = self.title,
        with_bottom_line = true,
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }
    local title_h = math.max(TITLE_H, tonumber((title_bar:getSize() or {}).h) or TITLE_H)
    local body_h = math.max(1, self.inner_h - title_h - PAD * 2)
    local body_w = math.max(1, self.inner_w - PAD * 2)

    local scroll = ScrollTextWidget:new{
        text = self.text,
        face = body_face(),
        fgcolor = TEXT_COLOR,
        width = body_w,
        height = body_h,
        dialog = self,
        alignment = "left",
        justified = false,
        auto_para_direction = false,
    }

    self.dialog_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = OUTER_BORDER,
        padding = 0,
        margin = 0,
        radius = Screen:scaleBySize(8),
        color = BORDER_COLOR,
        width = self.width,
        height = self.height,
        VerticalGroup:new{
            align = "center",
            title_bar,
            VerticalSpan:new{ width = PAD },
            HorizontalGroup:new{
                align = "top",
                HorizontalSpan:new{ width = PAD },
                scroll,
                HorizontalSpan:new{ width = PAD },
            },
            VerticalSpan:new{ width = PAD },
        },
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = self.screen_h },
        self.dialog_frame,
    }
    register_margin_close(self)
    if Device:hasKeys() then
        self.key_events = { Close = {{ Device.input.group.Back }, doc = "close" } }
    end
end

function FullReviewDialog:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.dialog_frame and self.dialog_frame.dimen or self.dimen
    end)
    return true
end

function FullReviewDialog:onClose()
    UIManager:close(self)
    return true
end

function FullReviewDialog:onCloseWidget()
    local region = self.dialog_frame and self.dialog_frame.dimen or self.dimen
    free_widget(self[1])
    self[1] = nil
    self.dialog_frame = nil
    local parent = self.parent_dialog
    if parent and parent._full_dialog == self then
        parent._full_dialog = nil
    end
    -- Repaint the review list underneath so closing full text does not leave ghosts.
    if parent then
        UIManager:setDirty(parent, "ui")
    end
    UIManager:setDirty(nil, function()
        return "ui", region
    end)
end

local function avatar_icon()
    local icon_size = Screen:scaleBySize(30)
    local widget
    local ok = pcall(function()
        widget = IconWidget:new{
            file = Paths.root() .. "/resources/person.svg",
            width = icon_size,
            height = icon_size,
            scale_factor = 0,
            alpha = true,
        }
        local size = widget:getSize()
        if not size or not size.w or not size.h or size.w < 1 or size.h < 1 then
            error("invalid avatar icon size")
        end
    end)
    if ok and widget then
        return widget
    end
    free_widget(widget)
    return TextWidget:new{
        text = "人",
        face = Font:getFace("cfont", 22),
        bold = true,
        fgcolor = TEXT_COLOR,
    }
end

local function avatar(path)
    if path and path ~= "" then
        local w
        local ok = pcall(function()
            w = ImageWidget:new{
                file = path,
                width = Screen:scaleBySize(48),
                height = Screen:scaleBySize(48),
                file_do_cache = false,
            }
            local size = w:getSize()
            if not size or not size.w or not size.h or size.w < 1 or size.h < 1 then
                error("invalid avatar size")
            end
        end)
        if ok and w then
            return w
        end
        free_widget(w)
    end
    return FrameContainer:new{
        width = AVATAR,
        height = AVATAR,
        bordersize = BORDER,
        padding = 0,
        margin = 0,
        radius = Screen:scaleBySize(6),
        color = BORDER_COLOR,
        background = Blitbuffer.COLOR_WHITE,
        FixedBox:new{
            width = AVATAR - BORDER * 2,
            height = AVATAR - BORDER * 2,
            align = "center",
            avatar_icon(),
        },
    }
end

local function measure_lines(text, width)
    local box = TextBoxWidget:new{
        text = tostring(text or ""),
        width = width,
        face = body_face(),
        fgcolor = TEXT_COLOR,
        alignment = "left",
    }
    local lines = box:getAllLineCount()
    local line_h = box:getLineHeight()
    free_widget(box)
    return lines, line_h
end

local function content_widget(text, width, folded, line_h)
    text = tostring(text or "")
    if folded then
        return TextBoxWidget:new{
            text = text,
            width = width,
            face = body_face(),
            fgcolor = TEXT_COLOR,
            alignment = "left",
            height = math.max(line_h or 1, 1) * FOLD_LINES,
            height_overflow_show_ellipsis = true,
        }
    end
    return TextBoxWidget:new{
        text = text,
        width = width,
        face = body_face(),
        fgcolor = TEXT_COLOR,
        alignment = "left",
    }
end

local function nav_reserved_height()
    return NAV_TOP_GAP + NAV_BTN_H + NAV_BOTTOM_GAP
end

local function list_area_height(total_h, chrome_top, chrome_bottom)
    chrome_top = math.max(0, tonumber(chrome_top) or TITLE_H)
    chrome_bottom = math.max(0, tonumber(chrome_bottom) or nav_reserved_height())
    return math.max(1, total_h - chrome_top - chrome_bottom)
end

function ReviewDialog:init()
    self.modal = true
    self.covers_fullscreen = true
    self.stop_events_propagation = true
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.width = math.max(1, self.screen_w - OUTER_MARGIN * 2)
    self.height = math.max(1, self.screen_h - OUTER_MARGIN * 2)
    self.inner_w, self.inner_h = inner_size(self.width, self.height)
    self.reviews = self.reviews or {}
    self.page = tonumber(self.initial_page) or 1
    self:_rebuild()
    -- Only the outer margin closes the dialog. A fullscreen TapClose ges_event
    -- would run after children and swallow taps when a nested Button dimen
    -- missed the hit-test — breaking 「查看全文」.
    if Device:isTouchDevice() then
        local mx = OUTER_MARGIN / self.screen_w
        local my = OUTER_MARGIN / self.screen_h
        local function close_handler()
            self:onClose()
            return true
        end
        self:registerTouchZones({
            {
                id = "wereadlite_review_close_top",
                ges = "tap",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = my },
                handler = close_handler,
            },
            {
                id = "wereadlite_review_close_bottom",
                ges = "tap",
                screen_zone = { ratio_x = 0, ratio_y = 1 - my, ratio_w = 1, ratio_h = my },
                handler = close_handler,
            },
            {
                id = "wereadlite_review_close_left",
                ges = "tap",
                screen_zone = { ratio_x = 0, ratio_y = my, ratio_w = mx, ratio_h = 1 - 2 * my },
                handler = close_handler,
            },
            {
                id = "wereadlite_review_close_right",
                ges = "tap",
                screen_zone = { ratio_x = 1 - mx, ratio_y = my, ratio_w = mx, ratio_h = 1 - 2 * my },
                handler = close_handler,
            },
        })
    end
    if Device:hasKeys() then
        self.key_events = { Close = {{ Device.input.group.Back }, doc = "close" } }
    end
end

function ReviewDialog:_close_full_dialog()
    local dlg = self._full_dialog
    if not dlg then
        return
    end
    self._full_dialog = nil
    dlg.parent_dialog = nil
    UIManager:close(dlg)
end

function ReviewDialog:show_full_review(review)
    review = type(review) == "table" and review or {}
    self:_close_full_dialog()
    local dlg = FullReviewDialog:new{
        title = tostring(review.username or "微信读书用户"),
        text = tostring(review.content or ""),
        parent_dialog = self,
    }
    self._full_dialog = dlg
    -- Defer past Button flash_ui / forceRePaint so the parent cannot paint over us.
    UIManager:nextTick(function()
        if self._full_dialog ~= dlg then
            return
        end
        UIManager:show(dlg)
    end)
end

function ReviewDialog:_text_width()
    local inner_w = self.inner_w or select(1, inner_size(self.width, self.height))
    local max_w = inner_w - LIST_SIDE_INSET * 2
    -- Must match _build_review_card: PAD*2 + AVATAR + AVATAR_TEXT_GAP (+ borders stay outside text).
    return max_w, max_w - PAD * 2 - AVATAR - AVATAR_TEXT_GAP
end

-- Measure a folded card, then free it. Used only for pagination packing.
function ReviewDialog:_measure_card_height(review, max_w, text_w)
    local card = self:_build_review_card(review, max_w, text_w)
    local size = card:getSize() or {}
    local h = math.max(1, tonumber(size.h) or 1)
    free_widget(card)
    return h
end

-- Pack reviews by measured (folded) height so none enter the pager strip.
function ReviewDialog:_pack_pages(avail)
    local reviews = self.reviews or {}
    local pages = {}
    if #reviews == 0 then
        return { {} }
    end
    local max_w, text_w = self:_text_width()
    avail = math.max(1, tonumber(avail) or list_area_height(self.height))
    local page = {}
    local used = 0
    for _, review in ipairs(reviews) do
        local h = self:_measure_card_height(review, max_w, text_w)
        -- Single oversized card still gets its own page; FixedBox clips paint.
        if h > avail then
            h = avail
        end
        local need = h + (#page > 0 and CARD_GAP or 0)
        if #page > 0 and used + need > avail then
            pages[#pages + 1] = page
            page = { review }
            used = h
        else
            page[#page + 1] = review
            used = used + need
        end
    end
    if #page > 0 then
        pages[#pages + 1] = page
    end
    if #pages == 0 then
        pages[1] = {}
    end
    return pages
end

function ReviewDialog:_page_count()
    return math.max(1, #(self._pages or {}))
end

function ReviewDialog:_page_slice(page)
    page = math.max(1, tonumber(page) or 1)
    local pages = self._pages or {}
    return pages[page] or {}
end

function ReviewDialog:_free_root()
    free_widget(self[1])
    self[1] = nil
    self.dialog_frame = nil
end

function ReviewDialog:_goto_page(page)
    page = math.max(1, tonumber(page) or 1)
    local last = self:_page_count()
    if page > last then
        page = last
    end
    if page == self.page and self[1] then
        return
    end
    self.page = page
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

function ReviewDialog:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.dialog_frame and self.dialog_frame.dimen or self.dimen
    end)
end

function ReviewDialog:onClose()
    self:_close_full_dialog()
    UIManager:close(self)
    return true
end

function ReviewDialog:onCloseWidget()
    self:_close_full_dialog()
    -- Full-screen dirty: margin leftovers from FullReviewDialog / TextViewer ghosts.
    local region = self.dimen
    self:_free_root()
    UIManager:setDirty(nil, function()
        return "ui", region
    end)
end

function ReviewDialog:_build_review_card(review, max_w, text_w)
    review = type(review) == "table" and review or {}
    local username = tostring(review.username or "微信读书用户")
    local content = tostring(review.content or "")
    local lines, line_h = measure_lines(content, text_w)
    local folded = lines > FOLD_LINES

    local body = VerticalGroup:new{ align = "left" }
    body[#body + 1] = TextBoxWidget:new{
        text = username,
        width = text_w,
        face = name_face(),
        fgcolor = TEXT_COLOR,
        bold = true,
        alignment = "left",
    }
    body[#body + 1] = VerticalSpan:new{ width = NAME_BODY_GAP }
    body[#body + 1] = content_widget(content, text_w, folded, line_h)
    if folded then
        body[#body + 1] = VerticalSpan:new{ width = BODY_BTN_GAP }
        body[#body + 1] = Button:new{
            text = "查看全文",
            width = math.min(text_w, VIEW_FULL_BTN_W),
            bordersize = BORDER,
            radius = Screen:scaleBySize(6),
            show_parent = self,
            callback = function()
                self:show_full_review(review)
            end,
        }
    end

    local row = HorizontalGroup:new{ align = "top" }
    row[#row + 1] = avatar(review.avatar_path)
    row[#row + 1] = HorizontalSpan:new{ width = AVATAR_TEXT_GAP }
    row[#row + 1] = body

    return FrameContainer:new{
        padding = PAD,
        width = max_w,
        bordersize = BORDER,
        radius = Screen:scaleBySize(10),
        color = BORDER_COLOR,
        background = Blitbuffer.COLOR_WHITE,
        row,
    }
end

function ReviewDialog:_rebuild()
    self:_free_root()
    local max_w, text_w = self:_text_width()
    local total = #(self.reviews or {})
    local title_text = total > 0 and string.format("划线评论（%d）", total) or "划线评论"

    local title_bar = TitleBar:new{
        width = self.inner_w,
        fullscreen = false,
        title = title_text,
        with_bottom_line = true,
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }
    local title_h = math.max(TITLE_H, tonumber((title_bar:getSize() or {}).h) or TITLE_H)

    -- Build a probe nav to reserve its real height for the pager strip.
    local probe_nav = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = "上一页",
            enabled = false,
            width = Screen:scaleBySize(100),
            bordersize = BORDER,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(18) },
        Button:new{
            text = "第 1 / 1 页",
            enabled = false,
            width = Screen:scaleBySize(130),
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(18) },
        Button:new{
            text = "下一页",
            enabled = false,
            width = Screen:scaleBySize(100),
            bordersize = BORDER,
        },
    }
    local nav_h = math.max(NAV_BTN_H, tonumber((probe_nav:getSize() or {}).h) or NAV_BTN_H)
    free_widget(probe_nav)
    local chrome_bottom = NAV_TOP_GAP + nav_h + NAV_BOTTOM_GAP
    -- TitleBar already draws its bottom line; size against the inner frame area.
    local list_height = list_area_height(self.inner_h, title_h, chrome_bottom)

    self._pages = self:_pack_pages(list_height)
    local pages = self:_page_count()
    if self.page < 1 then
        self.page = 1
    elseif self.page > pages then
        self.page = pages
    end

    local list = VerticalGroup:new{ align = "center" }
    local slice = self:_page_slice(self.page)
    if #slice == 0 then
        list[#list + 1] = TextWidget:new{
            text = "暂无评论",
            face = body_face(),
            fgcolor = TEXT_COLOR,
        }
    else
        for i, review in ipairs(slice) do
            list[#list + 1] = self:_build_review_card(review, max_w, text_w)
            if i < #slice then
                list[#list + 1] = VerticalSpan:new{ width = CARD_GAP }
            end
        end
    end

    local nav = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = "上一页",
            enabled = self.page > 1,
            width = Screen:scaleBySize(100),
            bordersize = BORDER,
            show_parent = self,
            callback = function()
                self:_goto_page(self.page - 1)
            end,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(18) },
        Button:new{
            text = string.format("第 %d / %d 页", self.page, pages),
            enabled = false,
            width = Screen:scaleBySize(130),
            show_parent = self,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(18) },
        Button:new{
            text = "下一页",
            enabled = self.page < pages,
            width = Screen:scaleBySize(100),
            bordersize = BORDER,
            show_parent = self,
            callback = function()
                self:_goto_page(self.page + 1)
            end,
        },
    }

    local list_frame = FixedBox:new{
        width = self.inner_w,
        height = list_height,
        align = "top",
        background = Blitbuffer.COLOR_WHITE,
        list,
    }
    self.dialog_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = OUTER_BORDER,
        padding = 0,
        margin = 0,
        radius = Screen:scaleBySize(8),
        color = BORDER_COLOR,
        width = self.width,
        height = self.height,
        VerticalGroup:new{
            align = "center",
            title_bar,
            list_frame,
            VerticalSpan:new{ width = NAV_TOP_GAP },
            nav,
            VerticalSpan:new{ width = NAV_BOTTOM_GAP },
        },
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = self.screen_h },
        self.dialog_frame,
    }
end

return ReviewDialog
