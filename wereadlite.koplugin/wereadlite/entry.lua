local lfs = require("libs/libkoreader-lfs")
local Config = require("wereadlite.config")
local Log = require("wereadlite.log")

local SOURCE = debug.getinfo(1, "S").source:gsub("^@", "")
local Entry = {}

local function filemanagerutil()
    local ok, util = pcall(require, "apps/filemanager/filemanagerutil")
    if ok then
        return util
    end
end

local function ffiutil()
    local ok, util = pcall(require, "ffi/util")
    if ok then
        return util
    end
end

local function realpath(path)
    if not path or path == "" then
        return nil
    end
    local util = ffiutil()
    if util and type(util.realpath) == "function" then
        return util.realpath(path) or path
    end
    return path
end

local function trim_slash(path)
    return tostring(path or ""):gsub("/+$", "")
end

local function plugin_root()
    local root = SOURCE:match("(.+)/wereadlite/entry%.lua$")
    if root and root ~= "" then
        return root
    end
    return SOURCE:match("(.+)/[^/]+$")
end

function Entry.cover_source()
    return plugin_root() .. "/" .. (Config.ENTRY_COVER or "resources/front.png")
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read("*a")
    file:close()
    return data
end

local function drop_bookinfo(path)
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if ok and BookInfoManager and type(BookInfoManager.deleteBookInfo) == "function" then
        pcall(function()
            BookInfoManager:deleteBookInfo(path)
        end)
        Log.dbg("entry", "bookinfo_cleared", { path = path })
    end
end

local function remove_path(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "file" then
        os.remove(path)
        return
    end
    if mode ~= "directory" then
        return
    end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            remove_path(path .. "/" .. name)
        end
    end
    lfs.rmdir(path)
end

local function remove_legacy_entry(parent)
    local old_files = {
        "微信阅读.wereadlite",
        "微信读书.wereadlite",
        "微信阅读.html",
        "微信读书.html",
    }
    for _, name in ipairs(old_files) do
        local old_file = parent .. "/" .. name
        if name ~= Config.ENTRY_FILENAME and lfs.attributes(old_file) then
            drop_bookinfo(old_file)
            os.remove(old_file)
            Log.dbg("entry", "legacy_removed", { path = old_file })
        end
    end
    local old_sdrs = { parent .. "/微信阅读.sdr", parent .. "/微信读书.sdr" }
    for _, old_sdr in ipairs(old_sdrs) do
        if lfs.attributes(old_sdr) then
            remove_path(old_sdr)
        end
    end
end

local function epub_up_to_date(path, src)
    local dest_attr = lfs.attributes(path)
    local src_attr = lfs.attributes(src)
    return dest_attr and dest_attr.mode == "file"
        and src_attr
        and dest_attr.size > 1024
        and dest_attr.modification >= src_attr.modification
end

local function add_epub_file(epub, name, content, mtime)
    if not epub:addFileFromMemory(name, content, mtime) then
        return false, epub.err or name
    end
    return true
end

local function build_cover_epub(dest, png_bytes)
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not ok or not Archiver or not Archiver.Writer then
        return nil, "archiver missing"
    end
    local title = Config.NAME
    local mtime = os.time()
    local tmp = dest .. ".tmp"
    os.remove(tmp)
    local epub = Archiver.Writer:new{}
    if not epub:open(tmp, "epub") then
        return nil, epub.err or "open failed"
    end
    local function fail(err)
        pcall(function() epub:close() end)
        os.remove(tmp)
        return nil, err
    end
    if not epub:setZipCompression("store") then
        return fail(epub.err or "store")
    end
    local added, err = add_epub_file(epub, "mimetype", "application/epub+zip", mtime)
    if not added then
        return fail(err)
    end
    if not epub:setZipCompression("deflate") then
        return fail(epub.err or "deflate")
    end
    local files = {
        ["META-INF/container.xml"] = [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
]],
        ["OEBPS/content.opf"] = table.concat({
            "<?xml version='1.0' encoding='utf-8'?>\n",
            '<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" unique-identifier="bookid" version="2.0">\n',
            "  <metadata>\n",
            "    <dc:title>", title, "</dc:title>\n",
            '    <dc:identifier id="bookid">wereadlite-entry</dc:identifier>\n',
            '    <meta name="cover" content="cover-image"/>\n',
            "  </metadata>\n",
            "  <manifest>\n",
            '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n',
            '    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>\n',
            '    <item id="cover-image" href="images/cover.png" media-type="image/png"/>\n',
            "  </manifest>\n",
            '  <spine toc="ncx">\n',
            '    <itemref idref="cover"/>\n',
            "  </spine>\n",
            "  <guide>\n",
            '    <reference href="cover.xhtml" type="cover" title="Cover"/>\n',
            "  </guide>\n",
            "</package>\n",
        }),
        ["OEBPS/toc.ncx"] = table.concat({
            "<?xml version='1.0' encoding='utf-8'?>\n",
            '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n',
            "  <head>\n",
            '    <meta name="dtb:uid" content="wereadlite-entry"/>\n',
            '    <meta name="dtb:depth" content="1"/>\n',
            "  </head>\n",
            "  <docTitle><text>", title, "</text></docTitle>\n",
            "  <navMap>\n",
            '    <navPoint id="navpoint-1" playOrder="1">\n',
            "      <navLabel><text>", title, "</text></navLabel>\n",
            '      <content src="cover.xhtml"/>\n',
            "    </navPoint>\n",
            "  </navMap>\n",
            "</ncx>\n",
        }),
        ["OEBPS/cover.xhtml"] = table.concat({
            "<?xml version='1.0' encoding='utf-8'?>\n",
            '<html xmlns="http://www.w3.org/1999/xhtml">\n',
            "<head><title>", title, "</title></head>\n",
            '<body><div><img src="images/cover.png" alt="', title, '"/></div></body>\n',
            "</html>\n",
        }),
        ["OEBPS/images/cover.png"] = png_bytes,
    }
    local order = {
        "META-INF/container.xml",
        "OEBPS/content.opf",
        "OEBPS/toc.ncx",
        "OEBPS/cover.xhtml",
        "OEBPS/images/cover.png",
    }
    for _, name in ipairs(order) do
        added, err = add_epub_file(epub, name, files[name], mtime)
        if not added then
            return fail(err)
        end
    end
    epub:close()
    os.remove(dest)
    local renamed, rename_err = os.rename(tmp, dest)
    if not renamed then
        os.remove(tmp)
        return nil, rename_err or "rename failed"
    end
    return true
end

function Entry.home_dir()
    local util = filemanagerutil()
    if util and type(util.getHomeFolder) == "function" then
        return util.getHomeFolder()
    end
    local Device = require("device")
    return G_reader_settings:readSetting("home_dir") or Device.home_dir or "."
end

function Entry.sentinel_path()
    return trim_slash(Entry.home_dir()) .. "/" .. Config.ENTRY_FILENAME
end

function Entry.suffix(path)
    return (tostring(path or ""):match("%.([^./]+)$") or ""):lower()
end

function Entry.is_entry_file(path)
    if not path or path == "" then
        return false
    end
    local a = realpath(path)
    local b = realpath(Entry.sentinel_path())
    if a ~= nil and b ~= nil and a == b then
        return true
    end
    local name = tostring(path):match("([^/]+)$")
    return name == Config.ENTRY_FILENAME
end

function Entry.is_entry_item(item)
    return type(item) == "table" and (item.wereadlite_entry == true or Entry.is_entry_file(item.path))
end

function Entry.ensure_sentinel()
    local path = Entry.sentinel_path()
    local parent = trim_slash(Entry.home_dir())
    if lfs.attributes(parent, "mode") ~= "directory" then
        Log.warn("entry", "home_missing", { path = parent })
        return path
    end
    remove_legacy_entry(parent)
    local src = Entry.cover_source()
    if lfs.attributes(src, "mode") ~= "file" then
        Log.warn("entry", "cover_missing", { path = src })
        return path
    end
    if epub_up_to_date(path, src) then
        return path
    end
    local png = read_file(src)
    if not png or png == "" then
        Log.warn("entry", "cover_read", { path = src })
        return path
    end
    local ok, err = build_cover_epub(path, png)
    if not ok then
        Log.warn("entry", "epub_fail", { path = path, err = err })
        return path
    end
    drop_bookinfo(path)
    Log.info("entry", "sentinel_epub", { path = path, bytes = #png })
    return path
end

function Entry.bind_provider()
    -- A real EPUB so CoverBrowser extracts the cover through CreDocument + cr3cache.
    return Entry.ensure_sentinel()
end

local function insert_index(items)
    local index = 1
    for i, item in ipairs(items or {}) do
        if item.is_go_up or (item.path and tostring(item.path):match("/%.+$")) then
            index = i + 1
        else
            break
        end
    end
    return index
end

local function remove_existing(items, path)
    local sentinel = realpath(path)
    for i = #items, 1, -1 do
        local item = items[i]
        if item and (item.wereadlite_entry or Entry.is_entry_file(item.path)
            or (sentinel and realpath(item.path) == sentinel)) then
            table.remove(items, i)
        end
    end
end

function Entry.pin_item_table(items, path)
    if type(items) ~= "table" then
        return items
    end
    path = path or Entry.sentinel_path()
    remove_existing(items, path)
    table.insert(items, insert_index(items), {
        text = Config.NAME,
        path = path,
        is_file = true,
        bold = true,
        mandatory = "入口",
        wereadlite_entry = true,
    })
    return items
end

function Entry.should_pin(chooser, path)
    if not chooser or chooser.name ~= "filemanager" then
        return false
    end
    return trim_slash(realpath(path) or path) == trim_slash(realpath(Entry.home_dir()) or Entry.home_dir())
end

function Entry.install_filechooser_hook()
    local FileChooser = require("ui/widget/filechooser")
    if FileChooser._wereadlite_patched then
        return
    end
    FileChooser._wereadlite_patched = true
    local original = FileChooser.genItemTableFromPath
    function FileChooser:genItemTableFromPath(path)
        local items = original(self, path)
        if Entry.should_pin(self, path) then
            Entry.ensure_sentinel()
            Entry.pin_item_table(items, Entry.sentinel_path())
        end
        return items
    end
end

function Entry.install_open_hook(open_app)
    local ok, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
    if ok and filemanagerutil and not filemanagerutil._wereadlite_patched then
        filemanagerutil._wereadlite_patched = true
        local original = filemanagerutil.openFile
        function filemanagerutil.openFile(ui, file, ...)
            if Entry.is_entry_file(file) then
                Log.info("entry", "openFile")
                open_app()
                return
            end
            return original(ui, file, ...)
        end
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and not FileManager._wereadlite_open_patched then
        FileManager._wereadlite_open_patched = true
        local original_open = FileManager.openFile
        function FileManager:openFile(file, ...)
            if Entry.is_entry_file(file) then
                Log.info("entry", "FileManager.openFile")
                open_app()
                return
            end
            return original_open(self, file, ...)
        end
    end
    local ok_ui, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_ui and ReaderUI and not ReaderUI._wereadlite_show_patched then
        ReaderUI._wereadlite_show_patched = true
        local original_show = ReaderUI.showReader
        function ReaderUI:showReader(file, ...)
            if Entry.is_entry_file(file) then
                open_app()
                return
            end
            return original_show(self, file, ...)
        end
        local original_switch = ReaderUI.switchDocument
        if type(original_switch) == "function" then
            function ReaderUI:switchDocument(file, ...)
                if Entry.is_entry_file(file) then
                    open_app()
                    return
                end
                return original_switch(self, file, ...)
            end
        end
    end
end

function Entry.hook_file_chooser_hold(ui, open_app)
    local chooser = ui and ui.file_chooser
    if not chooser then
        return
    end
    if not chooser._wereadlite_select_hooked then
        chooser._wereadlite_select_hooked = true
        local original_select = chooser.onFileSelect
        function chooser:onFileSelect(item)
            if Entry.is_entry_item(item) then
                Log.info("entry", "select")
                open_app()
                return true
            end
            return original_select(self, item)
        end
    end
    if chooser._wereadlite_hold_hooked then
        return
    end
    chooser._wereadlite_hold_hooked = true
    local original = chooser.onFileHold
    function chooser:onFileHold(item)
        if Entry.is_entry_item(item) then
            open_app()
            return true
        end
        return original(self, item)
    end
end

return Entry
