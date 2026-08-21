local DocumentRegistry = require("document/documentregistry")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Config = require("wereadlite.config")
local CookieStore = require("wereadlite.cookie_store")
local Entry = require("wereadlite.entry")
local Gate = require("wereadlite.gate")
local Log = require("wereadlite.log")
local Paths = require("wereadlite.paths")
local Reading = require("wereadlite.reading")
local Settings = require("wereadlite.settings")

local Plugin = WidgetContainer:extend{
    name = "wereadlite",
    is_doc_only = false,
    version = Config.VERSION,
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

function Plugin:onNetworkConnected()
    Gate.on_network_changed()
end

function Plugin:onNetworkDisconnected()
    Gate.on_network_changed()
end

return Plugin
