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
local Session = require("wereadlite.session")
local Heartbeat = require("wereadlite.kindle.heartbeat")
local Settings = require("wereadlite.settings")

local Plugin = WidgetContainer:extend{
    name = "wereadlite",
    is_doc_only = false,
    version = Config.VERSION,
}

local RESUME_DELAY = 3
local RESUME_RETRY_DELAY = 3
local RESUME_RETRY_LIMIT = 3

-- Plugin lifecycle is process-wide.  KOReader may deliver suspend/resume and
-- network events more than once while the UI is being rebuilt; keeping the
-- state outside a Plugin object makes those callbacks single-instance and
-- lets generation checks invalidate work scheduled by an older lifecycle.
local lifecycle = {
    state = "active", -- active / suspended / resuming
    generation = 0,
    resume_task = nil,
    resume_attempt = 0,
    resume_pending = false,
}

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
    Log.info("plugin", "ready", {
        version = Config.VERSION,
        supported = Gate.is_supported(),
    })
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
    Log.info("plugin", "openApp", { supported = Gate.is_supported() })
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

function Plugin:onNetworkConnected()
    Net.invalidate()
    Net.ensure_dns({ fallback = true, probe = false })
    if lifecycle.state == "suspended" then
        Log.dbg("plugin", "network_connected_while_suspended", { resume_pending = true })
        lifecycle.resume_pending = true
        return
    end
    -- A resume refresh owns the single lifecycle task until it completes.
    -- Network events commonly arrive during the three-second wake delay and
    -- must not replace that task with a heartbeat-only callback.
    if lifecycle.state == "resuming" then
        Log.dbg("plugin", "network_connected_during_resume")
        return
    end
    Gate.on_network_changed()
    if lifecycle.resume_pending then
        lifecycle.resume_pending = false
        self:_begin_resume("network_connected")
    else
        self:_scheduleHeartbeatResume("network_connected")
    end
end

function Plugin:onNetworkDisconnected()
    Net.invalidate()
    self:_cancelHeartbeatResume()
    Reading.cancel_load()
    Reading.cancel_prefetch()
    Session.cancel_refresh()
    Heartbeat.pause("network_disconnected")
    if lifecycle.state == "suspended" then
        Log.dbg("plugin", "network_disconnected_ignored", { state = lifecycle.state })
        return
    end
    if lifecycle.state == "resuming" then
        lifecycle.generation = lifecycle.generation + 1
        lifecycle.state = "active"
        lifecycle.resume_pending = true
    end
    Gate.on_network_changed()
end

function Plugin:_cancelHeartbeatResume()
    if lifecycle.resume_task then
        UIManager:unschedule(lifecycle.resume_task)
        lifecycle.resume_task = nil
    end
end

function Plugin:_scheduleHeartbeatResume(reason, delay)
    self:_cancelHeartbeatResume()
    local my_gen = lifecycle.generation
    local function resume_task()
        lifecycle.resume_task = nil
        if my_gen ~= lifecycle.generation or lifecycle.state == "suspended" then
            return
        end
        if Reading.is_active() and Net.is_online() and Session.has_auth() then
            Heartbeat.resume()
        else
            Log.info("plugin", "heartbeat_resume_skip", {
                reason = reason,
                reading = Reading.is_active(),
                online = Net.is_online(),
                authenticated = Session.has_auth(),
            })
        end
    end
    lifecycle.resume_task = resume_task
    UIManager:scheduleIn(delay or RESUME_DELAY, resume_task)
end

function Plugin:_scheduleResumeAttempt(reason, my_gen, delay)
    self:_cancelHeartbeatResume()
    local function resume_task()
        lifecycle.resume_task = nil
        if my_gen ~= lifecycle.generation or lifecycle.state ~= "resuming" then
            return
        end
        if not Net.is_online() then
            lifecycle.resume_attempt = lifecycle.resume_attempt + 1
            Log.info("plugin", "session_refresh_wait_network", {
                reason = reason,
                attempt = lifecycle.resume_attempt,
            })
            if lifecycle.resume_attempt <= RESUME_RETRY_LIMIT then
                self:_scheduleResumeAttempt(reason, my_gen, RESUME_RETRY_DELAY)
            else
                lifecycle.state = "active"
                lifecycle.resume_pending = true
                Log.warn("plugin", "session_refresh_deferred", { reason = reason })
            end
            return
        end

        if not (Reading.is_active() or Gate.is_open()) then
            lifecycle.state = "active"
            Log.dbg("plugin", "session_refresh_skip", { reason = "context_closed" })
            return
        end
        if not Session.has_auth() then
            lifecycle.state = "active"
            Log.dbg("plugin", "session_refresh_skip", { reason = "no_auth" })
            return
        end

        Log.info("plugin", "session_refresh_request", {
            reason = reason,
            attempt = lifecycle.resume_attempt,
        })
        Session.refresh_async(function(user, status, err)
            if my_gen ~= lifecycle.generation or lifecycle.state ~= "resuming" then
                Log.dbg("plugin", "session_refresh_stale", { reason = reason })
                return
            end
            if user then
                lifecycle.state = "active"
                lifecycle.resume_pending = false
                Log.info("plugin", "session_refresh_ok", {
                    reason = reason,
                    user_vid = user.user_vid,
                })
                if Gate.is_open() then
                    Gate.on_network_changed()
                end
                if Reading.is_active() and Net.is_online() then
                    Heartbeat.resume()
                end
                return
            end

            Log.warn("plugin", "session_refresh_failed", {
                reason = reason,
                status = status,
                err = err,
                attempt = lifecycle.resume_attempt,
            })
            if status == "offline" or status == "http_error" then
                lifecycle.resume_attempt = lifecycle.resume_attempt + 1
                if lifecycle.resume_attempt <= RESUME_RETRY_LIMIT then
                    self:_scheduleResumeAttempt(reason, my_gen, RESUME_RETRY_DELAY)
                    return
                end
                lifecycle.resume_pending = true
            elseif status == "auth_expired" then
                lifecycle.resume_pending = true
            end
            -- Keep the saved Cookie and Skill API key intact.  An auth
            -- response is handled on the next explicit user operation/login;
            -- it must not be turned into a destructive logout here.
            lifecycle.state = "active"
        end)
    end
    lifecycle.resume_task = resume_task
    UIManager:scheduleIn(delay or RESUME_DELAY, resume_task)
end

function Plugin:_begin_resume(reason)
    if lifecycle.state == "resuming" then
        Log.dbg("plugin", "resume_ignored", { reason = "already_resuming" })
        return
    end
    lifecycle.state = "resuming"
    lifecycle.generation = lifecycle.generation + 1
    lifecycle.resume_attempt = 0
    lifecycle.resume_pending = false
    local my_gen = lifecycle.generation
    Log.info("plugin", "resume_start", { reason = reason, generation = my_gen })
    self:_scheduleResumeAttempt(reason, my_gen, RESUME_DELAY)
end

function Plugin:onSuspend()
    if lifecycle.state == "suspended" then
        Log.dbg("plugin", "suspend_ignored", { reason = "already_suspended" })
        return
    end
    lifecycle.state = "suspended"
    lifecycle.generation = lifecycle.generation + 1
    lifecycle.resume_pending = false
    self:_cancelHeartbeatResume()
    Reading.cancel_load()
    Reading.cancel_prefetch()
    Session.cancel_refresh()
    -- Keep heartbeat state so resume can continue; only cancel in-flight work.
    Heartbeat.pause("suspend")
    local cancelled = Http.cancel_all()
    local orphans = 0
    if type(Http.kill_orphans) == "function" then
        orphans = Http.kill_orphans() or 0
    end
    Log.info("plugin", "suspend", {
        cancelled_http = cancelled,
        orphan_http = orphans,
        generation = lifecycle.generation,
    })
end

function Plugin:onResume()
    if lifecycle.state == "resuming" then
        return
    end
    if lifecycle.state == "suspended" or lifecycle.resume_pending then
        self:_begin_resume("resume")
        return
    end
    Log.dbg("plugin", "resume_ignored", { state = lifecycle.state })
end

return Plugin
