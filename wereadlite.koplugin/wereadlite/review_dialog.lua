local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen
local Paths = require("wereadlite.paths")

local PAD = Screen:scaleBySize(16)
local GAP = Screen:scaleBySize(10)
local AVATAR = Screen:scaleBySize(52)
local BORDER = Size.border.default
local TEXT_COLOR = Blitbuffer.COLOR_BLACK
local BORDER_COLOR = Blitbuffer.COLOR_GRAY_3
local FOLD_LINES = 5
local BODY_SIZE = 18
local NAME_SIZE = 19

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
    self[1]:paintTo(bb, px, py)
end

local ReviewDialog = InputContainer:extend{ reviews = nil }

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

local function show_full_review(review)
    review = type(review) == "table" and review or {}
    UIManager:show(TextViewer:new{
        title = tostring(review.username or "微信读书用户"),
        text = tostring(review.content or ""),
        fgcolor = TEXT_COLOR,
        alignment = "left",
        justified = false,
        auto_para_direction = false,
    })
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

function ReviewDialog:init()
    self.fullscreen, self.covers_fullscreen = true, true
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.reviews = self.reviews or {}
    self.page = tonumber(self.initial_page) or 1
    self._per_page = self:_calc_per_page()
    self:_rebuild()
    self.key_events = { Close = {{ Device.input.group.Back }, doc = "close" } }
end

function ReviewDialog:_calc_per_page()
    local title_h = Screen:scaleBySize(48)
    local list_height = math.max(1, self.height - title_h - Screen:scaleBySize(92))
    local card_h = Screen:scaleBySize(150)
    return math.max(1, math.floor(list_height / card_h))
end

function ReviewDialog:_page_count()
    local total = #(self.reviews or {})
    if total == 0 then
        return 1
    end
    return math.ceil(total / self._per_page)
end

function ReviewDialog:_page_slice(page)
    page = math.max(1, tonumber(page) or 1)
    local per = self._per_page
    local total = #(self.reviews or {})
    local start = (page - 1) * per + 1
    if start > total then
        return {}
    end
    local slice = {}
    for i = start, math.min(page * per, total) do
        slice[#slice + 1] = self.reviews[i]
    end
    return slice
end

function ReviewDialog:_free_root()
    free_widget(self[1])
    self[1] = nil
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

function ReviewDialog:onClose()
    UIManager:close(self)
    return true
end

function ReviewDialog:onCloseWidget()
    self:_free_root()
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
    body[#body + 1] = VerticalSpan:new{ width = Screen:scaleBySize(6) }
    body[#body + 1] = content_widget(content, text_w, folded, line_h)
    if folded then
        body[#body + 1] = VerticalSpan:new{ width = Screen:scaleBySize(6) }
        body[#body + 1] = Button:new{
            text = "查看全文",
            width = math.min(text_w, Screen:scaleBySize(120)),
            bordersize = BORDER,
            radius = Screen:scaleBySize(6),
            callback = function()
                show_full_review(review)
            end,
        }
    end

    local row = HorizontalGroup:new{ align = "top" }
    row[#row + 1] = avatar(review.avatar_path)
    row[#row + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(20) }
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
    local title_h = Screen:scaleBySize(48)
    local max_w = self.width - Screen:scaleBySize(56)
    local text_w = max_w - PAD * 2 - AVATAR - GAP
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
                list[#list + 1] = VerticalSpan:new{ height = Screen:scaleBySize(10) }
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
            callback = function()
                self:_goto_page(self.page - 1)
            end,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(18) },
        Button:new{
            text = string.format("第 %d / %d 页", self.page, pages),
            enabled = false,
            width = Screen:scaleBySize(130),
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(18) },
        Button:new{
            text = "下一页",
            enabled = self.page < pages,
            width = Screen:scaleBySize(100),
            bordersize = BORDER,
            callback = function()
                self:_goto_page(self.page + 1)
            end,
        },
    }

    local total = #(self.reviews or {})
    local title = total > 0 and string.format("划线评论（%d）", total) or "划线评论"
    local list_height = self.height - title_h - Screen:scaleBySize(92)
    local list_frame = FixedBox:new{ width = self.width, height = list_height, align = "top", list }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        width = self.width,
        height = self.height,
        VerticalGroup:new{
            align = "center",
            TitleBar:new{
                width = self.width,
                fullscreen = true,
                title = title,
                with_bottom_line = true,
                close_callback = function()
                    self:onClose()
                end,
            },
            LineWidget:new{
                dimen = Geom:new{ w = self.width, h = Size.border.thin },
                background = BORDER_COLOR,
            },
            list_frame,
            VerticalSpan:new{ height = Screen:scaleBySize(8) },
            nav,
            VerticalSpan:new{ height = Screen:scaleBySize(12) },
        },
    }
end

return ReviewDialog
