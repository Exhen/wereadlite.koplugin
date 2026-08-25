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
    if not self[1] then return end
    local size = self[1]:getSize() or {}
    local w = math.min(tonumber(size.w) or self.width, self.width)
    local h = math.min(tonumber(size.h) or self.height, self.height)
    self[1]:paintTo(bb, x + math.floor((self.width - w) / 2), y)
end

local ReviewDialog = InputContainer:extend{ reviews = nil }
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
    if w and type(w.free) == "function" then pcall(w.free, w) end
end
function ReviewDialog:init()
    self.fullscreen, self.covers_fullscreen = true, true
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.page, self.reviews = tonumber(self.initial_page) or 1, self.reviews or {}
    self:_rebuild()
    self.key_events = { Close = {{ Device.input.group.Back }, doc = "close" } }
end
function ReviewDialog:_rebuild()
    local title_h, max_w = Screen:scaleBySize(48), self.width - Screen:scaleBySize(56)
    local limit, pages, page, used = self.height - title_h - Screen:scaleBySize(92), {}, {}, 0
    for _, r in ipairs(self.reviews) do
        local box = TextBoxWidget:new{ text = tostring(r.content or ""), width = max_w - PAD * 2 - AVATAR - GAP, face = Font:getFace("cfont", 18), fgcolor = Blitbuffer.COLOR_DARK_GRAY, alignment = "left" }
        local size = type(box.getSize) == "function" and box:getSize() or nil
        local text_h = size and tonumber(size.h) or Screen:scaleBySize(48)
        local h = math.max(Screen:scaleBySize(108), text_h + PAD * 2 + Screen:scaleBySize(28))
        if #page > 0 and used + h > limit then pages[#pages + 1], page, used = page, {}, 0 end
        page[#page + 1], used = { r = r, box = box }, used + h
    end
    if #page > 0 or #pages == 0 then pages[#pages + 1] = page end
    self.pages = pages
    local list = VerticalGroup:new{ align = "center" }
    for _, item in ipairs(pages[self.page]) do
        local r = item.r
        local name = TextBoxWidget:new{ text = tostring(r.username or "微信读书用户"), width = max_w - PAD * 2 - AVATAR - GAP, face = Font:getFace("cfont", 19), fgcolor = Blitbuffer.COLOR_DARK_GRAY, bold = true, alignment = "left" }
        local photo = avatar(r.avatar_path) or FrameContainer:new{ width = AVATAR, height = AVATAR, background = Blitbuffer.COLOR_GRAY_4 }
        local row = HorizontalGroup:new{ align = "top" }
        row[#row + 1] = photo
        row[#row + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(20) }
        row[#row + 1] = VerticalGroup:new{ align = "left", name, VerticalSpan:new{ height = Screen:scaleBySize(6) }, item.box }
        list[#list + 1] = FrameContainer:new{ padding = PAD, width = max_w, bordersize = Screen:scaleBySize(1), radius = Screen:scaleBySize(10), background = Blitbuffer.COLOR_WHITE, row }
        list[#list + 1] = VerticalSpan:new{ height = Screen:scaleBySize(10) }
    end
    local function turn(page)
        UIManager:close(self)
        UIManager:nextTick(function()
            UIManager:show(ReviewDialog:new{ reviews = self.reviews, initial_page = page })
        end)
    end
    local nav = HorizontalGroup:new{ align = "center", Button:new{ text = "上一页", enabled = self.page > 1, width = Screen:scaleBySize(100), callback = function() turn(self.page - 1) end }, HorizontalSpan:new{ width = Screen:scaleBySize(18) }, Button:new{ text = string.format("第 %d / %d 页", self.page, #pages), enabled = false, width = Screen:scaleBySize(130) }, HorizontalSpan:new{ width = Screen:scaleBySize(18) }, Button:new{ text = "下一页", enabled = self.page < #pages, width = Screen:scaleBySize(100), callback = function() turn(self.page + 1) end } }
    local list_height = self.height - title_h - Screen:scaleBySize(92)
    local list_frame = FixedBox:new{ width = self.width, height = list_height, FrameContainer:new{ width = self.width, height = list_height, padding = 0, background = Blitbuffer.COLOR_WHITE, list } }
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, width = self.width, height = self.height, VerticalGroup:new{ align = "center", TitleBar:new{ width = self.width, fullscreen = true, title = "划线评论", with_bottom_line = true, close_callback = function() UIManager:close(self) end }, list_frame, VerticalSpan:new{ height = Screen:scaleBySize(8) }, nav, VerticalSpan:new{ height = Screen:scaleBySize(12) } } }
end
return ReviewDialog
