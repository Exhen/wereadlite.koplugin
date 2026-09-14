local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Config = require("wereadlite.config")
local Log = require("wereadlite.log")
local Session = require("wereadlite.session")

local Screen = Device.screen

local ok_geom, Geom = pcall(require, "ui/geometry")
if not ok_geom then
    Geom = require("ui/geom")
end

local DimBox = WidgetContainer:extend{
    faded = false,
}

function DimBox:getSize()
    if self[1] then
        return self[1]:getSize()
    end
    return Geom:new{ w = 1, h = 1 }
end

function DimBox:paintTo(bb, x, y)
    if self[1] then
        self[1]:paintTo(bb, x, y)
    end
    if not self.faded then
        return
    end
    local size = self:getSize()
    local width = size.w or 1
    local height = size.h or 1
    if type(bb.lightenRect) == "function" then
        for _ = 1, 8 do
            bb:lightenRect(x, y, width, height)
        end
    end
end

local LoginView = InputContainer:extend{
    on_close = nil,
    on_logged_in = nil,
}

local function login_api()
    return require("wereadlite.kindle.login")
end

function LoginView:init()
    self.covers_fullscreen = true
    self.fullscreen = true
    self._closed = false
    self._gen = 0
    self._phase = "idle"
    self._status = "请使用微信扫描二维码登录"
    self._qr_path = nil
    self._expired = false
    self.dimen = Screen:getSize()
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back }, doc = "close" },
        }
    end
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    self:_paint()
end

function LoginView:_qr_size()
    local side = math.min(Screen:getWidth(), Screen:getHeight())
    return math.max(120, math.min(Screen:scaleBySize(220), math.floor(side * 0.52)))
end

function LoginView:_free_root()
    if self[1] and type(self[1].free) == "function" then
        pcall(self[1].free, self[1])
    end
    self[1] = nil
end

function LoginView:_paint()
    -- Replacing the QR ImageWidget without free() leaks its BlitBuffer.
    self:_free_root()
    local width = Screen:getWidth()
    local height = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = width, h = height }
    local title_bar = TitleBar:new{
        width = width,
        fullscreen = true,
        title = Config.NAME,
        with_bottom_line = true,
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }
    local inner = VerticalGroup:new{ align = "center" }
    local body_width = width - 2 * Size.padding.large
    local phase = self._phase or "idle"
    if phase == "idle" then
        inner[#inner + 1] = TextBoxWidget:new{
            text = "请登录微信读书账号。\n点击登录后将显示二维码，使用微信扫一扫即可。",
            face = Font:getFace("infofont"),
            width = body_width,
            alignment = "center",
        }
        inner[#inner + 1] = VerticalSpan:new{ width = Size.padding.large }
        inner[#inner + 1] = Button:new{
            text = "登录",
            width = math.floor(body_width * 0.6),
            callback = function()
                self:_start()
            end,
            show_parent = self,
        }
    else
        local qr_size = self:_qr_size()
        local qr
        if self._qr_path then
            local ok, image = pcall(function()
                local widget = ImageWidget:new{
                    file = self._qr_path,
                    width = qr_size,
                    height = qr_size,
                    scale_factor = 0,
                    file_do_cache = false,
                }
                widget:getSize()
                return widget
            end)
            if ok and image then
                qr = DimBox:new{
                    faded = self._expired,
                    image,
                }
            end
        end
        if not qr then
            qr = FrameContainer:new{
                width = qr_size,
                height = qr_size,
                bordersize = Size.border.thin,
                padding = 0,
                background = Blitbuffer.COLOR_WHITE,
                CenterContainer:new{
                    dimen = Geom:new{ w = qr_size, h = qr_size },
                    TextWidget:new{
                        text = self._expired and "已过期" or "…",
                        face = Font:getFace("infofont"),
                    },
                },
            }
        end
        inner[#inner + 1] = qr
        inner[#inner + 1] = VerticalSpan:new{ width = Size.padding.large }
        inner[#inner + 1] = TextWidget:new{
            text = self._status or "",
            face = Font:getFace("infofont"),
        }
        if phase == "expired" or phase == "error" then
            inner[#inner + 1] = VerticalSpan:new{ width = Size.padding.large }
            inner[#inner + 1] = Button:new{
                text = "重新加载",
                width = math.floor(width * 0.45),
                callback = function()
                    self:_start()
                end,
                show_parent = self,
            }
        end
    end
    local title_h = title_bar:getHeight()
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        width = width,
        height = height,
        VerticalGroup:new{
            align = "left",
            title_bar,
            CenterContainer:new{
                dimen = Geom:new{ w = width, h = math.max(0, height - title_h) },
                inner,
            },
        },
    }
    UIManager:setDirty(self, "ui")
end

function LoginView:_fail(gen, message)
    if self._closed or gen ~= self._gen then
        return
    end
    self._phase = "error"
    self._expired = true
    self._status = message or "二维码加载失败"
    self:_paint()
end

function LoginView:_expire(gen, reason)
    if self._closed or gen ~= self._gen then
        return
    end
    Log.info("login", "expired", { err = reason or "timeout" })
    self._phase = "expired"
    self._expired = true
    self._status = "二维码已过期"
    self:_paint()
end

function LoginView:_start()
    local Login = login_api()
    self._gen = (self._gen or 0) + 1
    local gen = self._gen
    self._qr_path = nil
    self._uid = nil
    self._cgi_key = nil
    self._wait_started = false
    self._expired = false
    self._phase = "loading"
    self._status = "二维码加载中"
    self:_paint()
    Login.fetch_qr(function(err, payload)
        if self._closed or gen ~= self._gen then
            return
        end
        if err or not payload then
            Log.warn("login", "qr_fail", { err = err })
            pcall(function()
                Login.cancel()
            end)
            self:_fail(gen, "二维码加载失败")
            return
        end
        self._qr_path = payload.qr_path
        self._uid = payload.uid
        self._cgi_key = payload.cgi_key
        self._phase = "qr"
        self._expired = false
        self._status = "请使用微信扫描二维码登录"
        self:_paint()
        if not self._wait_started then
            self._wait_started = true
            self:_begin_wait(gen)
        end
    end)
end

function LoginView:_begin_wait(gen)
    local Login = login_api()
    Login.wait_scan(self._uid, self._cgi_key, function(err, info)
        if self._closed or gen ~= self._gen then
            return
        end
        if err then
            self:_expire(gen, err)
            return
        end
        self:_login(gen, info)
    end)
end

function LoginView:_login(gen, info)
    local Login = login_api()
    self._phase = "qr"
    self._expired = false
    self._status = "正在登录…"
    self:_paint()
    Login.weblogin(info, self._cgi_key, function(err, data)
        if self._closed or gen ~= self._gen then
            return
        end
        if err or not data or not Session.has_auth() then
            Log.warn("login", "weblogin_fail", { err = err })
            self:_fail(gen, "登录失败")
            return
        end
        self._status = "登录成功，正在进入书架"
        self:_paint()
        UIManager:scheduleIn(0.4, function()
            if self._closed or gen ~= self._gen then
                return
            end
            if self.on_logged_in then
                self.on_logged_in()
            end
        end)
    end)
end

function LoginView:onClose()
    self._closed = true
    self._gen = (self._gen or 0) + 1
    pcall(function()
        login_api().cancel()
    end)
    UIManager:close(self)
    if self.on_close then
        self.on_close()
    end
    return true
end

function LoginView:onCloseWidget()
    self._closed = true
    self._gen = (self._gen or 0) + 1
    pcall(function()
        login_api().cancel()
    end)
    self:_free_root()
end

return LoginView
