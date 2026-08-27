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
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local PAD = Screen:scaleBySize(16)
local GAP = Screen:scaleBySize(10)
local AVATAR = Screen:scaleBySize(52)

local FixedBox = WidgetContainer:extend{ width = 1, height = 1 }
function FixedBox:getSize()
    return Geom:new{ w = self.width, h = self.height }
end
function FixedBox:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    -- FixedBox is also used as the avatar fallback.  It is deliberately a
    -- leaf widget, unlike FrameContainer, so it must not be asked to paint a
    -- missing child (FrameContainer:getSize() assumes one exists).
    if self.background then
        bb:paintRect(x, y, self.width, self.height, self.background)
    end
    if not self[1] then return end
    local size = self[1]:getSize() or {}
    local w = math.min(tonumber(size.w) or self.width, self.width)
    local h = math.min(tonumber(size.h) or self.height, self.height)
    self[1]:paintTo(bb, x + math.floor((self.width - w) / 2), y)
end

local ReviewDialog = InputContainer:extend{ reviews = nil }

local function free_widget(w)
    if w and type(w.free) == "function" then
        pcall(w.free, w)
    end
end

local function avatar(path)
    if not path or path == "" then return end
    local w
    local ok = pcall(function()
        w = ImageWidget:new{
            file = path,
            width = Screen:scaleBySize(48),
            height = Screen:scaleBySize(48),
            file_do_cache = false,
        }
        -- ImageWidget decodes lazily. Force decoding here while protected so
        -- one malformed avatar cannot crash the whole review dialog.
        local size = w:getSize()
        if not size or not size.w or not size.h or size.w < 1 or size.h < 1 then
            error("invalid avatar size")
        end
    end)
    if ok then return w end
    free_widget(w)
end

local function content_height(text, width)
    local box = TextBoxWidget:new{
        text = tostring(text or ""),
        width = width,
        face = Font:getFace("cfont", 18),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        alignment = "left",
    }
    local size = type(box.getSize) == "function" and box:getSize() or nil
    local text_h = size and tonumber(size.h) or Screen:scaleBySize(48)
    free_widget(box)
    return math.max(Screen:scaleBySize(108), text_h + PAD * 2 + Screen:scaleBySize(28))
end

function ReviewDialog:init()
    self.fullscreen, self.covers_fullscreen = true, true
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.page = tonumber(self.initial_page) or 1
    self.reviews = self.reviews or {}
    self:_rebuild()
    self.key_events = { Close = {{ Device.input.group.Back }, doc = "close" } }
end

function ReviewDialog:_free_root()
    free_widget(self[1])
    self[1] = nil
end

function ReviewDialog:_goto_page(page)
    page = math.max(1, tonumber(page) or 1)
    local last = self.pages and #self.pages or 1
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

function ReviewDialog:_rebuild()
    self:_free_root()
    local title_h = Screen:scaleBySize(48)
    local max_w = self.width - Screen:scaleBySize(56)
    local text_w = max_w - PAD * 2 - AVATAR - GAP
    local limit = self.height - title_h - Screen:scaleBySize(92)
    local pages, page, used = {}, {}, 0
    for _, r in ipairs(self.reviews) do
        -- Measure with a throwaway TextBox, then free it so off-page boxes
        -- are never left outside the widget tree.
        local h = content_height(r.content, text_w)
        if #page > 0 and used + h > limit then
            pages[#pages + 1] = page
            page, used = {}, 0
        end
        page[#page + 1] = { r = r, h = h }
        used = used + h
    end
    if #page > 0 or #pages == 0 then
        pages[#pages + 1] = page
    end
    self.pages = pages
    if self.page < 1 then
        self.page = 1
    elseif self.page > #pages then
        self.page = #pages
    end

    local list = VerticalGroup:new{ align = "center" }
    for _, item in ipairs(pages[self.page]) do
        local r = item.r
        local name = TextBoxWidget:new{
            text = tostring(r.username or "微信读书用户"),
            width = text_w,
            face = Font:getFace("cfont", 19),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            bold = true,
            alignment = "left",
        }
        local box = TextBoxWidget:new{
            text = tostring(r.content or ""),
            width = text_w,
            face = Font:getFace("cfont", 18),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            alignment = "left",
        }
        -- Never use an empty FrameContainer here: its getSize() dereferences
        -- a nil child during the next e-ink repaint when an avatar request
        -- timed out or returned an invalid image.
        local photo = avatar(r.avatar_path) or FixedBox:new{
            width = AVATAR,
            height = AVATAR,
            background = Blitbuffer.COLOR_GRAY_4,
        }
        local row = HorizontalGroup:new{ align = "top" }
        row[#row + 1] = photo
        row[#row + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(20) }
        row[#row + 1] = VerticalGroup:new{
            align = "left",
            name,
            VerticalSpan:new{ height = Screen:scaleBySize(6) },
            box,
        }
        list[#list + 1] = FrameContainer:new{
            padding = PAD,
            width = max_w,
            bordersize = Screen:scaleBySize(1),
            radius = Screen:scaleBySize(10),
            background = Blitbuffer.COLOR_WHITE,
            row,
        }
        list[#list + 1] = VerticalSpan:new{ height = Screen:scaleBySize(10) }
    end

    local nav = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = "上一页",
            enabled = self.page > 1,
            width = Screen:scaleBySize(100),
            callback = function()
                self:_goto_page(self.page - 1)
            end,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(18) },
        Button:new{
            text = string.format("第 %d / %d 页", self.page, #pages),
            enabled = false,
            width = Screen:scaleBySize(130),
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(18) },
        Button:new{
            text = "下一页",
            enabled = self.page < #pages,
            width = Screen:scaleBySize(100),
            callback = function()
                self:_goto_page(self.page + 1)
            end,
        },
    }
    local list_height = self.height - title_h - Screen:scaleBySize(92)
    local list_frame = FixedBox:new{ width = self.width, height = list_height, list }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        width = self.width,
        height = self.height,
        VerticalGroup:new{
            align = "center",
            TitleBar:new{
                width = self.width,
                fullscreen = true,
                title = "划线评论",
                with_bottom_line = true,
                close_callback = function()
                    self:onClose()
                end,
            },
            list_frame,
            VerticalSpan:new{ height = Screen:scaleBySize(8) },
            nav,
            VerticalSpan:new{ height = Screen:scaleBySize(12) },
        },
    }
end

return ReviewDialog
