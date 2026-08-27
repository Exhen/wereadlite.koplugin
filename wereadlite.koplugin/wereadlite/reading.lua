local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local LoadProgress = require("wereadlite.load_progress")
local Log = require("wereadlite.log")
local Reader = require("wereadlite.kindle.reader")
local BookDb = require("wereadlite.book_db")
local Heartbeat = require("wereadlite.kindle.heartbeat")
local Bookmark = require("wereadlite.kindle.bookmark")
local Covers = require("wereadlite.covers")
local ReviewDialog = require("wereadlite.review_dialog")
local Settings = require("wereadlite.settings")

local Reading = {
    book = nil,
    state = nil,
    chapters = {},
    catalog_complete = false,
    _load_generation = 0,
    _load_task = nil,
    _load_bar = nil,
    _prefetch_task = nil,
}

local function show_review_comments(reviews)
    local dialog = ReviewDialog:new{ reviews = reviews }
    UIManager:show(dialog)
    -- The dialog is built from asynchronous avatar callbacks.  Schedule the
    -- refresh after it has entered the UI tree so e-ink devices repaint the
    -- newly created widgets without re-entering the callback stack.
    UIManager:nextTick(function()
        UIManager:setDirty(dialog, "full")
        if type(UIManager.forceRePaint) == "function" then
            UIManager:forceRePaint()
        end
    end)
end

local function prepare_review_comments(reviews)
    local loading = InfoMessage:new{ text = "正在加载评论…" }
    UIManager:show(loading)
    local jobs = {}
    local by_url = {}
    for _, review in ipairs(reviews or {}) do
        if type(review) == "table" and review.avatar and review.avatar ~= "" then
            local url = tostring(review.avatar)
            local job = by_url[url]
            if not job then
                job = { url = url, reviews = {} }
                by_url[url] = job
                jobs[#jobs + 1] = job
            end
            job.reviews[#job.reviews + 1] = review
        end
    end

    local next_job, active, completed = 1, 0, 0
    local total = #jobs
    local finished = false
    local function finish()
        if finished then return end
        finished = true
        UIManager:close(loading)
        show_review_comments(reviews)
    end

    local launch_more
    launch_more = function()
        while active < 2 and next_job <= total do
            local job = jobs[next_job]
            next_job = next_job + 1
            active = active + 1
            local first = job.reviews[1]
            local stem = Covers.dir() .. "/review_avatar_" .. tostring(first.id or next_job):gsub("[^%w%-_]", "_")
            Log.dbg("reading", "review_avatar_start", {
                active = active,
                total = total,
            })
            Covers.download_async(job.url, stem, nil, function(path, err)
                active = math.max(0, active - 1)
                completed = completed + 1
                for _, review in ipairs(job.reviews) do
                    review.avatar_path = path
                end
                if path then
                    Log.dbg("reading", "review_avatar_done", { completed = completed, total = total })
                else
                    Log.dbg("reading", "review_avatar_fail", {
                        completed = completed,
                        total = total,
                        err = err,
                    })
                end
                if completed >= total then
                    finish()
                else
                    launch_more()
                end
            end, 1)
        end
    end
    if total == 0 then
        finish()
    else
        launch_more()
    end
end

local function show_error(text)
    UIManager:show(InfoMessage:new{
        text = tostring(text or "打开失败"),
        timeout = 2,
    })
end

local function merge_chapters(state)
    if not state then
        return
    end
    local by_uid = {}
    for _, chapter in ipairs(Reading.chapters) do
        local uid = chapter.uid and tostring(chapter.uid) or ""
        if uid ~= "" then
            chapter.uid = uid
            by_uid[uid] = chapter
        end
    end
    for _, chapter in ipairs(state.chapters or {}) do
        local uid = chapter.uid and tostring(chapter.uid) or ""
        if uid ~= "" then
            local prev = by_uid[uid]
            if not prev then
                by_uid[uid] = chapter
            else
                if chapter.param and chapter.param ~= "" then
                    prev.param = chapter.param
                    prev.url = chapter.url or prev.url
                end
                if chapter.title and chapter.title ~= "" then
                    prev.title = chapter.title
                end
                if chapter.idx and chapter.idx ~= 0 then
                    prev.idx = chapter.idx
                end
                if chapter.level and chapter.level ~= 0 then
                    prev.level = chapter.level
                end
            end
        end
    end
    local list = {}
    for _, chapter in pairs(by_uid) do
        list[#list + 1] = chapter
    end
    table.sort(list, function(a, b)
        return (a.idx or 0) < (b.idx or 0)
    end)
    Reading.chapters = list
    state.chapters = list
end

local function current_uid()
    local state = Reading.state
    if not state then
        return ""
    end
    if state.cur and state.cur.uid then
        return tostring(state.cur.uid)
    end
    if state.cur_param and state.cur_param.uid then
        return tostring(state.cur_param.uid)
    end
    return ""
end

function Reading.toc_items()
    local toc = {}
    for i, chapter in ipairs(Reading.chapters or {}) do
        local idx = tonumber(chapter.idx) or i
        local depth = tonumber(chapter.level) or 1
        if depth < 1 then
            depth = 1
        end
        local title = tostring(chapter.title or "")
        if title == "" then
            title = "第" .. tostring(idx) .. "章"
        end
        toc[#toc + 1] = {
            title = title,
            page = math.max(1, idx),
            depth = depth,
            wereadlite_uid = tostring(chapter.uid or ""),
            wereadlite_url = chapter.url,
        }
    end
    return toc
end

function Reading.apply_document_toc(ui)
    local doc = ui and ui.document
    if not doc or not Reading.is_ours(doc.file) then
        return
    end
    doc.getToc = function()
        return Reading.toc_items()
    end
    if ui.toc and ui.toc.resetToc then
        ui.toc:resetToc()
    end
end

local function ensure_catalog(state)
    if Reading.catalog_complete or not state then
        return
    end
    local total = tonumber(state.chapter_count) or 0
    if total > 0 and #Reading.chapters >= total then
        Reading.catalog_complete = true
        return
    end
    local ok, chapters = pcall(Reader.expand_catalog, state)
    if ok and type(chapters) == "table" and #chapters > 0 then
        state.chapters = chapters
        merge_chapters(state)
    elseif not ok then
        Log.warn("reading", "catalog", { err = chapters })
    end
    if total > 0 and #Reading.chapters >= total then
        Reading.catalog_complete = true
    elseif total <= 0 and #(state.chapters or {}) > 0 then
        Reading.catalog_complete = true
    end
end

function Reading.is_ours(file)
    file = tostring(file or "")
    return file:find("/data/reading/", 1, true) ~= nil
        and (file:find("wereadlite", 1, true) ~= nil
            or file:find("微信读书", 1, true) ~= nil
            or file:find("微信阅读", 1, true) ~= nil)
end

local function history_item_path(item)
    if type(item) == "table" then
        return item.file or item.path or item.filename
    end
    return item
end

function Reading.remove_from_history(path)
    path = tostring(path or "")
    if path == "" then
        return false
    end
    local ok, history = pcall(require, "readhistory")
    if not ok or not history or type(history.removeItemByPath) ~= "function" then
        return false
    end
    local removed, err = pcall(history.removeItemByPath, history, path)
    if not removed then
        Log.warn("reading", "history_remove", { file = path, err = err })
        return false
    end
    return true
end

function Reading.purge_history()
    local ok, history = pcall(require, "readhistory")
    if not ok or not history then
        return 0
    end
    local paths, seen = {}, {}
    local rows = history.hist or history.history or history.items
    if type(rows) == "table" then
        for _, item in pairs(rows) do
            local path = tostring(history_item_path(item) or "")
            if path ~= "" and Reading.is_ours(path) and not seen[path] then
                seen[path] = true
                paths[#paths + 1] = path
            end
        end
    end
    if type(history.removeItemByPath) == "function" then
        for _, path in ipairs(paths) do
            pcall(history.removeItemByPath, history, path)
        end
    end
    if #paths > 0 then
        Log.info("reading", "history_purge", { count = #paths })
    end
    return #paths
end


local function install_history_filter()
    local ok, history = pcall(require, "readhistory")
    if not ok or not history or history._wereadlite_filtered then
        return
    end
    history._wereadlite_filtered = true
    local function filter_method(name)
        local original = history[name]
        if type(original) ~= "function" then
            return
        end
        history[name] = function(...)
            for i = 1, select("#", ...) do
                local path = history_item_path(select(i, ...))
                if Reading.is_ours(path) then
                    Log.dbg("reading", "history_block", { file = path, method = name })
                    return
                end
            end
            return original(...)
        end
    end
    filter_method("addItem")
    filter_method("updateItem")
    Reading.purge_history()
end

function Reading.is_last()
    return Reader.is_last(Reading.state)
end

function Reading.cancel_prefetch_schedule()
    if Reading._prefetch_task then
        UIManager:unschedule(Reading._prefetch_task)
        Reading._prefetch_task = nil
    end
end

function Reading.cancel_prefetch()
    Reading.cancel_prefetch_schedule()
    if Reader and type(Reader.cancel_prefetch) == "function" then
        pcall(Reader.cancel_prefetch)
    end
end

local function review_id_from_href(href)
    href = tostring(href or "")
    local id = href:match("^wereadlite://review/(wereadlite_review_%d+)$")
    if id then
        return id
    end
    local num = href:match("^wereadlite://review/(%d+)$")
    if num then
        return "wereadlite_review_" .. num
    end
end

local function review_id_from_link(link)
    if type(link) ~= "table" then
        return nil
    end
    local href = link.xpointer
        or link.uri
        or (type(link.link) == "table" and (link.link.uri or link.link.url))
        or ""
    return review_id_from_href(href)
end

local function open_review_by_id(review_id)
    review_id = tostring(review_id or "")
    if review_id == "" or not Reading.is_active() then
        return false
    end
    local reviews = Reader.review_data and Reader.review_data[review_id]
    if type(reviews) ~= "table" or #reviews == 0 then
        for _, mark in ipairs(Reader.review_marks or {}) do
            if mark.id == review_id then
                reviews = mark.reviews
                break
            end
        end
    end
    if type(reviews) ~= "table" or #reviews == 0 then
        Log.warn("reading", "review_link_miss", { id = review_id })
        return false
    end
    Log.info("reading", "review_link", { id = review_id, reviews = #reviews })
    prepare_review_comments(reviews)
    return true
end

local function open_document(path, resume, state)
    -- These HTML files are regenerated from the remote chapter. A previous
    -- KOReader sidecar must not override the position selected below.
    Reader.clear_sidecars(path)
    local function after_open()
        Reading.remove_from_history(path)
        Reader.cleanup_reading(path)
        if type(resume) == "table" then
            UIManager:scheduleIn(0.35, function()
                Reading.goto_resume(resume, path, state)
            end)
        end
    end
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance and ReaderUI.instance.switchDocument then
        ReaderUI.instance:switchDocument(path, nil, after_open)
    else
        ReaderUI:showReader(path, nil, nil, nil, after_open)
    end
end

function Reading.goto_resume(resume, expected_path, expected_state)
    resume = resume or {}
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok and ReaderUI and ReaderUI.instance
    if not ui then
        return
    end
    local current_path = ui.document and ui.document.file
    if expected_state and Reading.state ~= expected_state then
        Log.dbg("reading", "resume_stale", { reason = "state" })
        return
    end
    if expected_path and tostring(current_path or "") ~= tostring(expected_path) then
        Log.dbg("reading", "resume_stale", {
            reason = "document",
            expected = expected_path,
            current = current_path,
        })
        return
    end
    local percent = tonumber(resume.percent) or 0
    local anchor = resume.anchor
    -- Use the CRE section anchor only when no precise offset was available.
    if anchor and ui.document and ui.document.isXPointerInDocument then
        local candidates = {
            "#" .. anchor,
            "#_doc_fragment_0_" .. anchor,
        }
        for _, xp in ipairs(candidates) do
            local valid = false
            pcall(function()
                valid = ui.document:isXPointerInDocument(xp)
            end)
            if valid and ui.rolling then
                Log.dbg("reading", "resume_anchor", { xp = xp })
                pcall(function()
                    ui.rolling:onGotoXPointer(xp, xp)
                end)
                return
            end
        end
    end
    if percent > 0 and percent < 100 then
        Log.dbg("reading", "resume_percent", { percent = percent })
        local Event = require("ui/event")
        pcall(function()
            ui:handleEvent(Event:new("GotoPercent", percent))
        end)
    end
end

function Reading.open_url(url, book, opts)
    opts = opts or {}
    Reading.cancel_load()
    -- Do not cancel a running next-chapter request here: if it is nearly
    -- complete, the reader can still consume its ready result. Only the
    -- delayed trigger for the previous chapter must be removed.
    Reading.cancel_prefetch_schedule()
    Reading._load_generation = Reading._load_generation + 1
    local my_generation = Reading._load_generation
    Log.dbg("reading", "open_url", { url = url, book_id = book and book.bookId })
    local ok_bar, bar = pcall(LoadProgress.open)
    if not ok_bar then
        Log.warn("reading", "progress_ui", { err = bar })
        bar = nil
    end
    Reading._load_bar = bar
    local function report(stage, done, total)
        if bar then
            pcall(bar.update, bar, stage, done, total)
        end
    end
    local function close_bar()
        if Reading._load_bar == bar then
            Reading._load_bar = nil
        end
        if bar then
            pcall(bar.close, bar)
            bar = nil
        end
    end

    local function complete(state, status, err)
        if my_generation ~= Reading._load_generation then
            if state and state.html_path then
                Reader.remove_chapter(state.html_path)
            end
            return
        end
        Reading._load_task = nil
        close_bar()
        if not state then
            Log.warn("reading", "open_async", { status = status, err = err })
            show_error(status == "offline" and "网络不可用" or "打开章节失败")
            return
        end
        if book then
            Reading.book = book
        end
        merge_chapters(state)
        ensure_catalog(state)
        Reading.state = state
        -- A background prefetch runs the same pipeline as an open, so review
        -- metadata must be activated only when its chapter is actually shown.
        Reader.review_data = state.review_data or {}
        Reader.review_marks = state.review_marks or {}
        local resume
        if opts.resume == true then
            resume = { percent = state.resume_percent, anchor = state.resume_anchor }
        end
        local opened, open_err = pcall(open_document, state.html_path, resume, state)
        if not opened then
            Reader.remove_chapter(state.html_path)
            show_error("打开章节失败")
            Log.warn("reading", "open_document", { err = open_err })
            return
        end
        pcall(BookDb.save_last_read, Reading.book, {
            book_info = state.book_info,
            chapter_title = state.chapter_title or (state.cur and state.cur.title),
        })
        Heartbeat.start(state)
        -- Delay the expensive full next-chapter pipeline until the reader has
        -- been active for five seconds.  The state/document checks prevent a
        -- stale callback from running after a chapter switch or shelf return.
        local prefetch_task
        prefetch_task = function()
            if Reading._prefetch_task == prefetch_task then
                Reading._prefetch_task = nil
            end
            if Reading.state ~= state or not Reading.is_active() then
                Log.dbg("reading", "prefetch_skip", { reason = "stale_after_delay" })
                return
            end
            if not Settings.prefetch_next_chapter() then
                Log.dbg("reading", "prefetch_skip", { reason = "disabled" })
                return
            end
            Log.dbg("reading", "prefetch_delay_done", { seconds = 5 })
            Reader.prefetch_next(state, Reading.book)
        end
        Reading._prefetch_task = prefetch_task
        UIManager:scheduleIn(5, prefetch_task)
        Log.dbg("reading", "open_ok", {
            book_id = state.book_id,
            uid = state.cur and state.cur.uid,
            html = state.html_path,
            resume_percent = state.resume_percent,
            resume_anchor = state.resume_anchor,
        })
    end

    local prefetched = Reader.take_prefetched(url)
    if prefetched then
        complete(prefetched)
        return true, "prefetched"
    end
    local called, state, status, err = pcall(Reader.load, url, book or Reading.book, report, complete)
    if not called then
        close_bar()
        return nil, "http_error", state
    end
    if status == "pending" then
        Reading._load_task = err
        return true, "pending"
    end
    close_bar()
    if not state then
        return nil, status, err
    end
    complete(state)
    return state
end

function Reading.cancel_load()
    Reading._load_generation = (Reading._load_generation or 0) + 1
    local task = Reading._load_task
    Reading._load_task = nil
    if task and type(task.cancel) == "function" then
        pcall(task.cancel, task)
    end
    local bar = Reading._load_bar
    Reading._load_bar = nil
    if bar then
        pcall(bar.close, bar)
    end
end

function Reading.open_book(book)
    if type(book) ~= "table" or not book.reader_param or book.reader_param == "" then
        show_error("缺少阅读参数")
        return
    end
    Reading.cancel_load()
    Reading.book = book
    Reading.chapters = {}
    Reading.state = nil
    Reading.catalog_complete = false
    Heartbeat.stop(true)
    Reader.cleanup_reading()
    UIManager:nextTick(function()
        local ok, status, err = Reading.open_url(Reader.url_for(book.reader_param), book, { resume = true })
        if ok then
            return
        end
        if status == "auth_expired" then
            show_error("登录已过期，请重新登录")
        elseif status == "need_pay" then
            show_error("本章需要购买")
        elseif status == "offline" then
            show_error("网络不可用")
        else
            show_error("打开失败")
            Log.warn("reading", "open_book", { status = status, err = err })
        end
    end)
end

function Reading.open_next()
    local url = Reader.next_url(Reading.state)
    if not url then
        return false
    end
    UIManager:nextTick(function()
        local ok, status, err = Reading.open_url(url, Reading.book, { resume = false })
        if ok then
            return
        end
        Log.warn("reading", "next_chapter", { status = status, err = err })
        if status == "auth_expired" then
            show_error("登录已过期，请重新登录")
        elseif status == "need_pay" then
            show_error("下一章需要购买")
        else
            show_error("打开下一章失败")
        end
    end)
    return true
end

function Reading.show_wechat_shelf()
    if Reading._returning then
        return
    end
    Reading._returning = true
    Reading.cancel_load()
    Heartbeat.stop(true)
    Reader.cleanup_reading()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager then
        local filemanagerutil = require("apps/filemanager/filemanagerutil")
        local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
            or filemanagerutil.getDefaultDir()
        if FileManager.instance then
            if home and FileManager.instance.file_chooser then
                pcall(function()
                    FileManager.instance.file_chooser:changeToPath(home)
                end)
            end
        else
            pcall(function()
                FileManager:showFiles(home)
            end)
        end
    end
    local Gate = require("wereadlite.gate")
    Gate.close()
    Gate.open()
    Reading._returning = false
end

function Reading.return_to_shelf()
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    UIManager:nextTick(function()
        if reader and reader.document then
            pcall(function()
                reader:onClose()
            end)
        end
        Reading.show_wechat_shelf()
    end)
end

function Reading.handle_end_of_book(status_widget)
    local file = status_widget and status_widget.ui and status_widget.ui.document and status_widget.ui.document.file
    if not Reading.is_ours(file) then
        return false
    end
    local dialog
    if Reading.is_last() then
        dialog = ButtonDialog:new{
            name = "wereadlite_end_of_book",
            title = "全书已读完",
            title_align = "center",
            buttons = {
                {
                    {
                        text = "返回书架",
                        callback = function()
                            UIManager:close(dialog)
                            Reading.return_to_shelf()
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        return true
    end
    dialog = ButtonDialog:new{
        name = "wereadlite_next_chapter",
        title = "本章已读完",
        title_align = "center",
        buttons = {
            {
                {
                    text = "下一章",
                    callback = function()
                        UIManager:close(dialog)
                        Reading.open_next()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return true
end

function Reading.open_toc_item(item)
    if type(item) ~= "table" then
        return
    end
    local uid = tostring(item.wereadlite_uid or "")
    if uid ~= "" and uid == current_uid() then
        return
    end
    local url = item.wereadlite_url
    if (not url or url == "") and uid ~= "" then
        for _, chapter in ipairs(Reading.chapters or {}) do
            if tostring(chapter.uid) == uid and chapter.url then
                url = chapter.url
                break
            end
        end
    end
    if not url or url == "" then
        show_error("无法打开该章节")
        return
    end
    UIManager:nextTick(function()
        local ok, status, err = Reading.open_url(url, Reading.book, { resume = false })
        if ok then
            return
        end
        Log.warn("reading", "toc_chapter", { status = status, err = err })
        if status == "auth_expired" then
            show_error("登录已过期，请重新登录")
        elseif status == "need_pay" then
            show_error("本章需要购买")
        elseif status == "offline" then
            show_error("网络不可用")
        else
            show_error("打开章节失败")
        end
    end)
end

function Reading.cleanup_temp()
    Reading.cancel_load()
    Heartbeat.stop(true)
    Reader.cleanup_reading()
end

function Reading.is_active()
    if not Reading.state then
        return false
    end
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok and ReaderUI and ReaderUI.instance
    local file = ui and ui.document and ui.document.file
    return Reading.is_ours(file)
end

local function ours_from_toc(toc)
    local file = toc and toc.ui and toc.ui.document and toc.ui.document.file
    return Reading.is_ours(file)
end

local function install_end_of_book_hook()
    local ok, ReaderStatus = pcall(require, "apps/reader/modules/readerstatus")
    if not ok or not ReaderStatus or ReaderStatus._wereadlite_end_hooked then
        return
    end
    ReaderStatus._wereadlite_end_hooked = true
    local original = ReaderStatus.onEndOfBook
    function ReaderStatus:onEndOfBook()
        local handled = Reading.handle_end_of_book(self)
        if handled then
            return true
        end
        if original then
            return original(self)
        end
    end
    Log.dbg("reading", "hook", { name = "end_of_book" })
end

local function install_close_hook()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI or ReaderUI._wereadlite_close_hooked then
        return
    end
    ReaderUI._wereadlite_close_hooked = true
    local original = ReaderUI.onClose
    function ReaderUI:onClose(full_refresh)
        local file = self.document and self.document.file
        local ours = Reading.is_ours(file)
        if ours then
            Heartbeat.stop(true)
        end
        local result
        if original then
            result = original(self, full_refresh)
        end
        if ours then
            Reading.remove_from_history(file)
            Reader.remove_chapter(file)
        end
        return result
    end
    Log.dbg("reading", "hook", { name = "reader_close" })
end

local function patch_exit_menu(menu)
    if not menu or not menu.menu_items or not menu.menu_items.filemanager then
        return
    end
    local item = menu.menu_items.filemanager
    if item._wereadlite_exit_patched then
        return
    end
    item._wereadlite_exit_patched = true
    local original_cb = item.callback
    item.callback = function()
        local file = menu.ui and menu.ui.document and menu.ui.document.file
        if Reading.is_ours(file) then
            if menu.onTapCloseMenu then
                menu:onTapCloseMenu()
            end
            Reading.return_to_shelf()
            return
        end
        if original_cb then
            return original_cb()
        end
    end
end

local function install_exit_hook()
    local ok_menu, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
    if ok_menu and ReaderMenu and not ReaderMenu._wereadlite_exit_hooked then
        ReaderMenu._wereadlite_exit_hooked = true
        local original_init = ReaderMenu.init
        function ReaderMenu:init()
            local result = original_init(self)
            patch_exit_menu(self)
            return result
        end
    end
    local ok_ui, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_ui or not ReaderUI or ReaderUI._wereadlite_exit_hooked then
        return
    end
    ReaderUI._wereadlite_exit_hooked = true
    local original_show = ReaderUI.showFileManager
    function ReaderUI:showFileManager(file, selected_files)
        if Reading.is_ours(file) then
            Reading.show_wechat_shelf()
            return
        end
        if original_show then
            return original_show(self, file, selected_files)
        end
    end
    local original_home = ReaderUI.onHome
    function ReaderUI:onHome()
        local file = self.document and self.document.file
        if Reading.is_ours(file) then
            Reading.return_to_shelf()
            return true
        end
        if original_home then
            return original_home(self)
        end
    end
    if ReaderUI.instance and ReaderUI.instance.menu then
        patch_exit_menu(ReaderUI.instance.menu)
    end
    Log.dbg("reading", "hook", { name = "exit_to_shelf" })
end

function Reading.patch_reader_ui(ui)
    if ui and ui.menu then
        patch_exit_menu(ui.menu)
    end
end

local function install_toc_hook()
    local ok, ReaderToc = pcall(require, "apps/reader/modules/readertoc")
    if not ok or not ReaderToc or ReaderToc._wereadlite_toc_hooked then
        return
    end
    ReaderToc._wereadlite_toc_hooked = true
    local BD = require("ui/bidi")
    local original_fill = ReaderToc.fillToc
    function ReaderToc:fillToc()
        if ours_from_toc(self) then
            if self.toc then
                return
            end
            self.toc = Reading.toc_items()
            if self.validateAndFixToc then
                self:validateAndFixToc()
            end
            return
        end
        return original_fill(self)
    end
    local original_index = ReaderToc.getTocIndexByPage
    function ReaderToc:getTocIndexByPage(pn_or_xp, skip_ignored_ticks)
        if ours_from_toc(self) then
            self:fillToc()
            local uid = current_uid()
            for i, item in ipairs(self.toc or {}) do
                if tostring(item.wereadlite_uid or "") == uid then
                    return i
                end
            end
            return nil
        end
        return original_index(self, pn_or_xp, skip_ignored_ticks)
    end
    local original_title = ReaderToc.getTocTitleByPage
    function ReaderToc:getTocTitleByPage(pn_or_xp)
        if ours_from_toc(self) then
            local title = Reading.state and Reading.state.chapter_title
            if title and title ~= "" then
                return title
            end
            local uid = current_uid()
            for _, chapter in ipairs(Reading.chapters or {}) do
                if tostring(chapter.uid) == uid then
                    return chapter.title or ""
                end
            end
            return title or ""
        end
        return original_title(self, pn_or_xp)
    end
    local original_ticks = ReaderToc.getTocTicksFlattened
    function ReaderToc:getTocTicksFlattened(for_chapter_navigation)
        if ours_from_toc(self) then
            return { 1 }
        end
        return original_ticks(self, for_chapter_navigation)
    end
    local original_current = ReaderToc.updateCurrentNode
    function ReaderToc:updateCurrentNode()
        if ours_from_toc(self) then
            local uid = current_uid()
            if self.search_string ~= nil and self.search_string ~= "*" then
                return
            end
            if #self.collapsed_toc > 0 then
                for i, item in ipairs(self.collapsed_toc) do
                    if tostring(item.wereadlite_uid or "") == uid then
                        self.collapsed_toc.current = i
                        return
                    end
                end
            end
        end
        if original_current then
            return original_current(self)
        end
    end
    local original_show = ReaderToc.onShowToc
    function ReaderToc:onShowToc()
        local result = original_show(self)
        if not ours_from_toc(self) then
            return result
        end
        local toc_menu = self.toc_menu
        if not toc_menu then
            return result
        end
        function toc_menu:onMenuSelect(item, pos)
            local do_toggle_state = false
            if item.state and pos and pos.x then
                if BD.mirroredUILayout() then
                    do_toggle_state = pos.x > 0.7
                else
                    do_toggle_state = pos.x < 0.3
                end
            end
            if do_toggle_state then
                item.state.callback(item.index)
                return
            end
            toc_menu:close_callback()
            Reading.open_toc_item(item)
        end
        return result
    end
    Log.dbg("reading", "hook", { name = "toc" })
end


local function install_review_link_hook()
    local ok, ReaderLink = pcall(require, "apps/reader/modules/readerlink")
    if not ok or not ReaderLink or ReaderLink._wereadlite_review_hooked then
        return
    end
    ReaderLink._wereadlite_review_hooked = true

    local original_tap = ReaderLink.onTap
    function ReaderLink:onTap(_, ges)
        -- Prefer native link hit-testing. Empty page areas return nil and
        -- fall through to KOReader page-turn zones without a plugin overlay.
        local has_reviews = Reading.is_active()
            and type(Reader.review_data) == "table"
            and next(Reader.review_data) ~= nil
        if has_reviews and ges and type(self.getLinkFromGes) == "function" then
            local link
            local ok_link, result = pcall(self.getLinkFromGes, self, ges)
            if ok_link then
                link = result
            end
            local review_id = review_id_from_link(link)
            if review_id and open_review_by_id(review_id) then
                return true
            end
        end
        if original_tap then
            return original_tap(self, _, ges)
        end
    end

    local original_goto = ReaderLink.onGotoLink
    function ReaderLink:onGotoLink(link, neglect_current_location, allow_footnote_popup)
        if Reading.is_active() then
            local review_id = review_id_from_link(link)
            if review_id and open_review_by_id(review_id) then
                return true
            end
        end
        if original_goto then
            return original_goto(self, link, neglect_current_location, allow_footnote_popup)
        end
    end

    local original_init = ReaderLink.init
    if type(original_init) == "function" then
        function ReaderLink:init()
            local result = original_init(self)
            if type(self.registerScheme) == "function" then
                pcall(self.registerScheme, self, "wereadlite")
            end
            return result
        end
    end
    Log.dbg("reading", "hook", { name = "review_link" })
end

local function install_highlight_hook()
    local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if not ok or not ReaderHighlight or ReaderHighlight._wereadlite_hl_hooked then
        return
    end
    ReaderHighlight._wereadlite_hl_hooked = true
    local original_save = ReaderHighlight.saveHighlight
    function ReaderHighlight:saveHighlight(extend_to_sentence)
        local index = original_save(self, extend_to_sentence)
        local file = self.ui and self.ui.document and self.ui.document.file
        if not Reading.is_ours(file) or not index then
            return index
        end
        local item
        pcall(function()
            item = self.ui.annotation.annotations[index]
        end)
        if type(item) ~= "table" or not item.text or item.text == "" then
            return index
        end
        local state = Reading.state
        UIManager:nextTick(function()
            if Reading.state ~= state then
                return
            end
            Bookmark.sync_highlight(item, state)
        end)
        return index
    end
    local original_delete = ReaderHighlight.deleteHighlight
    function ReaderHighlight:deleteHighlight(index)
        local file = self.ui and self.ui.document and self.ui.document.file
        local item
        if Reading.is_ours(file) then
            pcall(function()
                item = self.ui.annotation.annotations[index]
            end)
            if type(item) == "table" then
                -- Snapshot fields before local removal.
                item = {
                    text = item.text,
                    wereadlite_bookmark_id = item.wereadlite_bookmark_id,
                    wereadlite_range = item.wereadlite_range,
                    wereadlite_chapter_uid = item.wereadlite_chapter_uid,
                }
            else
                item = nil
            end
        end
        local result = original_delete(self, index)
        if item then
            local state = Reading.state
            UIManager:nextTick(function()
                if Reading.state ~= state then
                    return
                end
                Bookmark.sync_delete(item, state)
            end)
        end
        return result
    end
    Log.dbg("reading", "hook", { name = "highlight" })
end

function Reading.install_hook()
    install_history_filter()
    install_end_of_book_hook()
    install_close_hook()
    install_exit_hook()
    install_toc_hook()
    install_review_link_hook()
    install_highlight_hook()
end

return Reading
