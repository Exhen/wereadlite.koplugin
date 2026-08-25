local DocumentRegistry = require("document/documentregistry")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Config = require("wereadlite.config")
local Http = require("wereadlite.async_http")
local CookieStore = require("wereadlite.cookie_store")
local Entry = require("wereadlite.entry")
local Gate = require("wereadlite.gate")
local Log = require("wereadlite.log")
local Net = require("wereadlite.net")
local Paths = require("wereadlite.paths")
local Reading = require("wereadlite.reading")
local Heartbeat = require("wereadlite.kindle.heartbeat")
local Settings = require("wereadlite.settings")

local Plugin = WidgetContainer:extend{
    name = "wereadlite",
    is_doc_only = false,
    version = Config.VERSION,
}

local RESUME_DELAY = 3

function Plugin:init()
    if not (self.ui and self.ui.document) then
        Paths.purge_cache()
        Reading.cleanup_temp()
    end
    CookieStore.load()
    Settings.load()
    Reading.install_hook()
    self:_register_aux_provider()
    Entry.bind_provider()
    Entry.install_filechooser_hook()
    Entry.install_open_hook(function()
        self:openApp()
    end)
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
    UIManager:nextTick(function()
        if self.ui then
            Entry.hook_file_chooser_hold(self.ui, function()
                self:openApp()
            end)
        end
    end)
    Log.info("plugin", "ready", { version = Config.VERSION })
end

function Plugin:_register_aux_provider()
    DocumentRegistry:addAuxProvider({
        provider_name = Config.NAME,
        provider = self.name,
        order = 20,
        disable_file = true,
        disable_type = false,
    })
end

function Plugin:isFileTypeSupported(file)
    return Entry.is_entry_file(file)
end

function Plugin:openFile(file)
    if Entry.is_entry_file(file) then
        self:openApp()
    end
end

function Plugin:openApp()
    Log.info("plugin", "openApp")
    Gate.open()
end

function Plugin:addToMainMenu(menu_items)
    menu_items.wereadlite = {
        text = Config.NAME,
        sorting_hint = "tools",
        callback = function()
            self:openApp()
        end,
    }
end

function Plugin:onReaderReady()
    Reading.apply_document_toc(self.ui)
    Reading.patch_reader_ui(self.ui)
end

function Plugin:onPageUpdate()
    Reading.refresh_review_hit_regions(self.ui)
end

function Plugin:onPosUpdate()
    Reading.refresh_review_hit_regions(self.ui)
end

function Plugin:onNetworkConnected()
    Gate.on_network_changed()
    self:_scheduleHeartbeatResume("network_connected")
end

function Plugin:onNetworkDisconnected()
    self:_cancelHeartbeatResume()
    Reading.cancel_load()
    Heartbeat.pause("network_disconnected")
    Gate.on_network_changed()
end

function Plugin:_cancelHeartbeatResume()
    if self._heartbeat_resume_task then
        UIManager:unschedule(self._heartbeat_resume_task)
        self._heartbeat_resume_task = nil
    end
end

function Plugin:_scheduleHeartbeatResume(reason)
    self:_cancelHeartbeatResume()
    local function resume_task()
        self._heartbeat_resume_task = nil
        if Reading.is_active() and Net.is_online() then
            Heartbeat.resume()
        else
            Log.info("plugin", "heartbeat_resume_skip", {
                reason = reason,
                reading = Reading.is_active(),
                online = Net.is_online(),
            })
        end
    end
    self._heartbeat_resume_task = resume_task
    UIManager:scheduleIn(RESUME_DELAY, resume_task)
end

function Plugin:onSuspend()
    self:_cancelHeartbeatResume()
    Reading.cancel_load()
    Heartbeat.pause("suspend")
    local cancelled = Http.cancel_all()
    Log.info("plugin", "suspend", { cancelled_http = cancelled })
end

function Plugin:onResume()
    Log.info("plugin", "resume")
    self:_scheduleHeartbeatResume("resume")
end

return Plugin
