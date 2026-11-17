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
local Skill = require("wereadlite.skill")

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
    if not Settings.load_review_avatars() then
        show_review_comments(reviews)
        return
    end
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

local function reader_param_from_reader_url(url)
    url = tostring(url or "")
    return url:match("[?&]v=([%w_%-]+)") or url:match("[?&]bc=([^&]+)")
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

-- The chapter a chapter file belongs to ("<uid>_<start>-<end>.html").  Taken
-- from the file rather than Reading.state: while a chapter switch is opening,
-- the state already describes the new chapter but the document on screen is
-- still the old one.
local function uid_from_html_path(path)
    return tostring(path or ""):match("/([^/_]+)_%d+%-%d+%.html$")
end

-- Remember the exact page on screen.  WeRead's own progress only catches up when
-- the reading progress syncs, so a couple of page turns are otherwise lost when
-- the book is closed and reopened.
function Reading.save_reader_position(ui)
    if not ui then
        local ok, ReaderUI = pcall(require, "apps/reader/readerui")
        ui = ok and ReaderUI and ReaderUI.instance
    end
    local document = ui and ui.document
    local file = document and document.file
    local book_id = file and Reading.book_id_from_path(file)
    local uid = uid_from_html_path(file)
    if not book_id or not uid then
        return false
    end
    -- CreDocument:getXPointer() reports the page actually on screen; the rolling
    -- widget's record is the fallback.
    local xpointer
    if type(document.getXPointer) == "function" then
        pcall(function()
            xpointer = document:getXPointer()
        end)
    end
    if (not xpointer or xpointer == "") and ui.rolling
        and type(ui.rolling.getLastProgress) == "function" then
        pcall(function()
            xpointer = ui.rolling:getLastProgress()
        end)
    end
    if not xpointer or xpointer == "" then
        return false
    end
    return Settings.set_reader_position(book_id, uid, xpointer)
end

-- The saved page is only meaningful for the chapter it was taken from.
local function saved_resume(state)
    if not state then
        return nil
    end
    local ok, saved = pcall(Settings.reader_position, state.book_id)
    if not ok or not saved then
        return nil
    end
    local uid = state.cur and tostring(state.cur.uid or "") or ""
    if uid == "" or saved.uid ~= uid then
        return nil
    end
    return { xpointer = saved.xpointer }
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

-- The full table of contents is not needed to show the first page, so it is
-- fetched in the background after the book is open instead of delaying the open.
local function catalog_done(state)
    local total = tonumber(state.chapter_count) or 0
    if total > 0 and #Reading.chapters >= total then
        return true
    end
    return total <= 0 and #(state.chapters or {}) > 0
end

function Reading.cancel_catalog()
    local job = Reading._catalog_job
    Reading._catalog_job = nil
    if job and type(job.cancel) == "function" then
        pcall(job.cancel, job)
    end
end

local function ensure_catalog(state)
    if Reading.catalog_complete or not state or Reading._catalog_job then
        return
    end
    local total = tonumber(state.chapter_count) or 0
    if total > 0 and #Reading.chapters >= total then
        Reading.catalog_complete = true
        return
    end
    local job
    job = Reader.expand_catalog(state, function(chapters)
        if Reading._catalog_job == job then
            Reading._catalog_job = nil
        end
        if type(chapters) == "table" and #chapters > 0 then
            state.chapters = chapters
            merge_chapters(state)
        end
        if catalog_done(state) then
            Reading.catalog_complete = true
        end
        -- Chapters opened since then keep working from the merged list, and a
        -- table of contents already built from the partial list is rebuilt.
        if Reading.state then
            Reading.state.chapters = Reading.chapters
        end
        local ok, ReaderUI = pcall(require, "apps/reader/readerui")
        local ui = ok and ReaderUI and ReaderUI.instance
        if ui and Reading.is_ours(ui.document and ui.document.file) then
            Reading.apply_document_toc(ui)
        end
    end)
    Reading._catalog_job = job
end

function Reading.is_ours(file)
    file = tostring(file or "")
    return file:find("/data/reading/", 1, true) ~= nil
        and (file:find("wereadlite", 1, true) ~= nil
            or file:find("微信读书", 1, true) ~= nil
            or file:find("微信阅读", 1, true) ~= nil)
end

-- Chapters live in <plugin>/data/reading/<book_id>/<chapter>.html, so the
-- directory name is the book the font-size setting belongs to.  Parse it from
-- the path itself: KOReader may hand us the file in a different form (relative,
-- doubled slashes) than the plugin root string, so a prefix match is unreliable.
function Reading.book_id_from_path(file)
    file = tostring(file or "")
    if not Reading.is_ours(file) then
        return nil
    end
    return file:match("/data/reading/([^/]+)/[^/]+$")
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
    local mark
    for _, item in ipairs(Reader.review_marks or {}) do
        if item.id == review_id then
            mark = item
            break
        end
    end
    if not mark then
        Log.warn("reading", "review_link_miss", { id = review_id })
        return false
    end

    local reviews = Reader.review_data and Reader.review_data[review_id]
    if type(reviews) ~= "table" or #reviews == 0 then
        reviews = mark.reviews
    end
    if type(reviews) == "table" and #reviews > 0 then
        Log.info("reading", "review_link_cached", { id = review_id, reviews = #reviews })
        prepare_review_comments(reviews)
        return true
    end

    local state = Reading.state
    local book_id = state and tostring(state.book_id or "")
    local chapter_uid = state and state.cur and tonumber(state.cur.uid)
    local range = tostring(mark.range or "")
    if book_id == "" or not chapter_uid or range == "" then
        Log.warn("reading", "review_link_context", { id = review_id, range = range })
        return false
    end

    local loading = InfoMessage:new{ text = "正在加载评论…" }
    UIManager:show(loading)
    Skill.fetch_range_reviews_async(book_id, chapter_uid, range, function(fetched, status, err)
        UIManager:close(loading)
        if type(fetched) ~= "table" then
            Log.warn("reading", "review_fetch_fail", { id = review_id, range = range, status = status, err = err })
            UIManager:show(InfoMessage:new{ text = "加载评论失败", timeout = 2 })
            return
        end
        if #fetched == 0 then
            Log.info("reading", "review_fetch_empty", { id = review_id, range = range })
            UIManager:show(InfoMessage:new{ text = "暂无评论", timeout = 2 })
            return
        end
        Reader.review_data = Reader.review_data or {}
        Reader.review_data[review_id] = fetched
        mark.reviews = fetched
        Log.info("reading", "review_link", { id = review_id, range = range, reviews = #fetched })
        prepare_review_comments(fetched)
    end)
    return true
end

local RESUME_DELAYS = { 0.35, 0.9, 1.6 }

local function has_resume_target(resume)
    return type(resume) == "table"
        and ((tonumber(resume.percent) or 0) > 0
            or (resume.anchor ~= nil and resume.anchor ~= "")
            or (type(resume.xpointer) == "string" and resume.xpointer ~= ""))
end

-- Fallback when the jump could not be made while the reader was opening.
local function schedule_resume(resume, path, state)
    if not has_resume_target(resume) then
        return
    end
    for attempt, delay in ipairs(RESUME_DELAYS) do
        UIManager:scheduleIn(delay, function()
            Reading.goto_resume(resume, path, state)
            if attempt == 1 then
                Log.dbg("reading", "resume_scheduled", {
                    percent = resume.percent,
                    anchor = resume.anchor,
                })
            end
        end)
    end
end

-- Jump to the saved position before the reader is first painted, so the first
-- page shown is already the right one: one paint instead of a paint at the top
-- followed by one repaint per later retry.  Returns true when the jump was made.
local function resume_before_first_paint(reader, resume, path, state)
    if not reader or not has_resume_target(resume) then
        return false
    end
    -- The jump queues refreshes of its own; the reader's first show() queues the
    -- real one, so anything queued here would only add a flash.
    local refreshes = UIManager._refresh_stack and #UIManager._refresh_stack or 0
    local funcs = UIManager._refresh_func_stack and #UIManager._refresh_func_stack or 0
    local ok, jumped = pcall(Reading.goto_resume, resume, path, state, reader)
    pcall(function()
        for i = #UIManager._refresh_stack, refreshes + 1, -1 do
            UIManager._refresh_stack[i] = nil
        end
        for i = #UIManager._refresh_func_stack, funcs + 1, -1 do
            UIManager._refresh_func_stack[i] = nil
        end
    end)
    if not ok then
        Log.warn("reading", "resume_early", { err = jumped })
        return false
    end
    Log.dbg("reading", "resume_early", { jumped = jumped })
    return jumped
end

-- KOReader fills the CRE options from the sidecar while ReaderUI is built, and
-- on a fresh open the DocSettingsLoad handler runs after the reader already has
-- its document: the chapter was laid out at the global size and then again at
-- the saved one (a re-layout right after opening, which also costs time).
-- Writing the sidecar before the reader exists makes the first layout use the
-- saved size.
function Reading.prime_reader_font_size(path)
    local book_id = Reading.book_id_from_path(path)
    if not book_id then
        return false
    end
    local ok, size = pcall(Settings.reader_font_size, book_id)
    if not ok or not size then
        return false
    end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or type(DocSettings) ~= "table" or type(DocSettings.open) ~= "function" then
        return false
    end
    local opened, doc_settings = pcall(DocSettings.open, DocSettings, path)
    if not opened or not doc_settings then
        return false
    end
    pcall(doc_settings.saveSetting, doc_settings, "copt_font_size", size)
    pcall(doc_settings.flush, doc_settings)
    Log.dbg("reading", "font_size_prime", { book_id = book_id, size = size })
    return true
end

-- hooks.before_show runs while the new reader is being built, before KOReader
-- puts it on screen.
local function open_document(path, resume, state, hooks)
    hooks = hooks or {}
    -- These HTML files are regenerated from the remote chapter. A previous
    -- KOReader sidecar must not override the position selected below.
    Reader.clear_sidecars(path)
    Reading.prime_reader_font_size(path)
    -- switchDocument closes the current doc first; our onClose hook must not
    -- delete the target file when reopening/replacing a WeRead chapter.
    Reading._preserve_html = path
    -- KOReader calls this as reader:after_open_callback(), with the new ReaderUI.
    local function after_open(reader)
        Reading._preserve_html = nil
        if hooks.before_show then
            -- The load box is modal, and KOReader never stacks a normal window
            -- above a modal one: once the reader is shown the box would still be
            -- painted over the book, and closing it then repaints the page.
            -- Dropping it now, before anything is shown, means the first paint
            -- is just the book.  Nothing is drawn in between: this runs inside
            -- the same UI tick that shows the reader.
            local ok_hook, hook_err = pcall(hooks.before_show)
            if not ok_hook then
                Log.warn("reading", "before_show", { err = hook_err })
            end
        end
        Reading.ensure_reader_font_size(reader)
        Reading.snapshot_reader_font_size(reader)
        -- This runs before the new reader is shown. A shelf left underneath
        -- the reader would be repainted as soon as the next chapter switch
        -- closes the current document, so drop it now.
        local ok_gate, gate_err = pcall(function()
            require("wereadlite.gate").close()
        end)
        if not ok_gate then
            Log.warn("reading", "close_shelf", { err = gate_err })
        end
        Reading.remove_from_history(path)
        Reader.cleanup_reading(path)
        if not resume_before_first_paint(reader, resume, path, state) then
            schedule_resume(resume, path, state)
        end
    end
    local ReaderUI = require("apps/reader/readerui")
    -- seamless=true hides KOReader's "Opening file ..." infomessage (same as legado.koplugin).
    local ok_switch, switch_err = true, nil
    if ReaderUI.instance and ReaderUI.instance.switchDocument then
        ok_switch, switch_err = pcall(function()
            ReaderUI.instance:switchDocument(path, true, after_open)
        end)
    else
        ok_switch, switch_err = pcall(function()
            ReaderUI:showReader(path, nil, true, nil, after_open)
        end)
    end
    if not ok_switch then
        Reading._preserve_html = nil
        error(switch_err)
    end
end

function Reading.goto_resume(resume, expected_path, expected_state, ui_override)
    resume = resume or {}
    local ui = ui_override
    if not ui then
        local ok, ReaderUI = pcall(require, "apps/reader/readerui")
        ui = ok and ReaderUI and ReaderUI.instance
    end
    if not ui then
        return false
    end
    local current_path = ui.document and ui.document.file
    if expected_state and Reading.state ~= expected_state then
        Log.dbg("reading", "resume_stale", { reason = "state" })
        return false
    end
    if expected_path and tostring(current_path or "") ~= tostring(expected_path) then
        Log.dbg("reading", "resume_stale", {
            reason = "document",
            expected = expected_path,
            current = current_path,
        })
        return false
    end
    local xpointer = type(resume.xpointer) == "string" and resume.xpointer or ""
    if xpointer ~= "" and ui.document then
        local valid = false
        if type(ui.document.isXPointerInDocument) == "function" then
            pcall(function()
                valid = ui.document:isXPointerInDocument(xpointer)
            end)
        end
        if valid then
            -- Our books are reflowable, so the rolling widget owns pagination in
            -- both modes and is the one that knows how to land on an xpointer.
            local jumped = false
            if ui.rolling and type(ui.rolling.onGotoXPointer) == "function" then
                jumped = pcall(function()
                    ui.rolling:onGotoXPointer(xpointer)
                end)
            else
                local Event = require("ui/event")
                jumped = pcall(function()
                    ui:handleEvent(Event:new("GotoXPointer", xpointer))
                end)
            end
            if jumped then
                Log.dbg("reading", "resume_xpointer")
                return true
            end
        else
            -- The chapter markup changed (another plugin version, a different
            -- section window): fall back to the percentages below.
            Log.info("reading", "resume_xpointer_stale")
        end
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
                local jumped = pcall(function()
                    ui.rolling:onGotoXPointer(xp, xp)
                end)
                return jumped
            end
        end
    end
    if percent > 0 and percent <= 100 then
        Log.dbg("reading", "resume_percent", { percent = percent })
        local Event = require("ui/event")
        local jumped = pcall(function()
            ui:handleEvent(Event:new("GotoPercent", percent))
        end)
        return jumped
    end
    return false
end

local function chapter_file_ok(path)
    local file = path and io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

-- Put the load box on screen now.  UIManager:show() only queues a refresh, so
-- anything slow that runs before the next paint tick (chapter teardown, decode
-- tables, the first request) would delay the box by that much; painting it here
-- keeps the tap responsive.
function Reading.show_load_bar(stage)
    local ok, widget = pcall(LoadProgress.open, {
        stage = stage,
        on_cancel = function()
            Reading.cancel_load()
        end,
    })
    if not ok then
        Log.warn("reading", "progress_ui", { err = widget })
        return nil
    end
    Reading._load_bar = widget
    pcall(UIManager.forceRePaint, UIManager)
    return widget
end

function Reading.open_url(url, book, opts)
    opts = opts or {}
    url = tostring(url or "")
    Reading.cancel_load(opts.bar)
    if opts.continue_sections then
        Reading._continuing_sections = true
    end
    Reading.cancel_prefetch_schedule()
    Reading._load_generation = Reading._load_generation + 1
    local my_generation = Reading._load_generation
    Log.dbg("reading", "open_url", { url = url, book_id = book and book.bookId })
    local bar
    if opts.bar then
        if Reading._load_bar ~= opts.bar then
            -- Its cancel button was tapped while the open was being set up.
            Log.info("reading", "open_cancelled_before_load")
            return nil, "cancelled", "cancelled"
        end
        bar = opts.bar
    elseif opts.resume == true then
        -- Opening a whole book always takes a while (the reader still has to
        -- load and lay out the text), so there is nothing to spare by waiting.
        bar = Reading.show_load_bar("open")
    end
    -- Shown only when a network load is actually needed (not on a prefetch
    -- hit), so the user can still force-cancel large chapters.
    local function show_bar(stage)
        if bar then
            return
        end
        bar = Reading.show_load_bar(stage)
    end
    -- Any load that gets this far still has to parse and lay the chapter out,
    -- which takes seconds, and the fetching/parsing itself keeps the UI loop busy
    -- long enough that a delayed box would only appear after the wait.  Cached
    -- chapters never reach this point: they are served before the box is asked
    -- for, so there is nothing to flash.
    local function report(stage, done, total)
        if bar and Settings.show_chapter_load_progress() then
            pcall(bar.update, bar, stage, done, total)
        elseif bar and not Settings.show_chapter_load_progress() then
            -- Minimal mode: keep a static "正在加载" title with cancel only.
            if not bar._minimal_set then
                bar._minimal_set = true
                pcall(function()
                    bar.title_widget:setText("正在加载…")
                    bar.subtitle_widget:setText(" ")
                    bar:paint()
                end)
            end
        end
    end
    -- Safety net: if the reader never comes up, do not leave the box on screen.
    local OPEN_TIMEOUT = 30
    local bar_watchdog
    local function close_bar(quiet)
        if bar_watchdog then
            UIManager:unschedule(bar_watchdog)
            bar_watchdog = nil
        end
        if Reading._load_bar == bar then
            Reading._load_bar = nil
        end
        if bar then
            pcall(bar.close, bar, quiet)
            bar = nil
        end
    end
    -- Downloading is finished but the reader still has to load and lay out the
    -- text, which is the slow part of opening a book.  Keep the box up for it
    -- (showing it now when the download was too quick to have needed one) so the
    -- screen never sits idle between the box and the book.
    local function show_opening()
        if not bar and opts.resume ~= true then
            return
        end
        if bar then
            if Settings.show_chapter_load_progress() then
                pcall(bar.update, bar, "open", 1, 1)
            end
        else
            show_bar("open")
        end
        if not bar then
            return
        end
        bar_watchdog = function()
            bar_watchdog = nil
            close_bar()
        end
        UIManager:scheduleIn(OPEN_TIMEOUT, bar_watchdog)
    end

    local function complete(state, status, err)
        Reading._continuing_sections = false
        if my_generation ~= Reading._load_generation then
            if state and state.html_path then
                Reader.remove_chapter(state.html_path)
            end
            close_bar()
            return
        end
        Reading._load_task = nil
        if not state then
            close_bar()
            -- User cancelled: do not toast a failure.
            if status == "cancelled" or tostring(err or ""):find("cancel", 1, true) then
                Log.info("reading", "open_cancelled")
                return
            end
            Log.warn("reading", "open_async", { status = status, err = err })
            show_error(status == "offline" and "网络不可用" or "打开章节失败")
            return
        end
        if book then
            Reading.book = book
        end
        merge_chapters(state)
        Reading.state = state
        -- A background prefetch runs the same pipeline as an open, so review
        -- metadata must be activated only when its chapter is actually shown.
        Reader.review_data = state.review_data or {}
        Reader.review_marks = state.review_marks or {}
        if not chapter_file_ok(state.html_path) then
            -- A chapter that was prefetched earlier can be deleted by a later
            -- open (only the chapter on screen is kept).  Fetch it again rather
            -- than handing KOReader a missing path, which aborts the open and
            -- tears the UI down.
            Log.warn("reading", "open_chapter_missing", { html = state.html_path })
            close_bar()
            if not opts.retried then
                Reading.open_url(url, book, {
                    resume = opts.resume,
                    retried = true,
                    chapter_uid = opts.chapter_uid,
                })
            else
                show_error("打开章节失败")
            end
            return
        end
        local resume
        if opts.resume == true then
            resume = saved_resume(state)
                or { percent = state.resume_percent, anchor = state.resume_anchor }
        elseif opts.at_end then
            -- Turning back into the previous chapter shows its last page.
            resume = { percent = 100 }
        end
        -- Keep this chapter (html + sidecar) so coming back to it needs no
        -- fetch, parse or image rewriting; cleanup_reading() preserves it.
        Reader.remember_chapter(url, state, true)
        show_opening()
        local opened, open_err = pcall(open_document, state.html_path, resume, state, {
            before_show = function()
                close_bar(true)
            end,
        })
        if not opened then
            close_bar()
            Reader.remove_chapter(state.html_path)
            show_error("打开章节失败")
            Log.warn("reading", "open_document", { err = open_err })
            return
        end
        -- Not needed to show the page; load it once the reader is up.
        UIManager:scheduleIn(0.5, function()
            if Reading.state == state then
                ensure_catalog(state)
            end
        end)
        pcall(BookDb.save_last_read, Reading.book, {
            book_info = state.book_info,
            chapter_title = state.chapter_title or (state.cur and state.cur.title),
            state = state,
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
    if not prefetched and opts.chapter_uid then
        -- The same chapter can be requested under the book entry URL and under
        -- its own chapter URL; the second index catches that spelling.
        local cache_book = book or Reading.book or {}
        local cache_book_id = cache_book.bookId
            or (Reading.state and Reading.state.book_id)
            or ""
        prefetched = Reader.take_cached_chapter(cache_book_id, opts.chapter_uid)
    end
    if prefetched then
        complete(prefetched)
        return true, "prefetched"
    end

    -- Same chapter already loading in background: adopt that job (no second fetch).
    if Reader.is_prefetching(url) then
        show_bar()
        local adopted, job = Reader.adopt_prefetch(url, report, complete)
        if adopted then
            Reading._load_task = job
            Log.info("reading", "open_adopt_prefetch", { url = url })
            return true, "adopted"
        end
        -- Race: finished into cache between checks.
        prefetched = Reader.take_prefetched(url)
        if prefetched then
            complete(prefetched)
            return true, "prefetched"
        end
    else
        -- Opening a different chapter (or no prefetch): stop the background job
        -- so it cannot write the same html_path as the new load.
        Reading.cancel_prefetch()
    end

    show_bar()
    local called, state, status, err = pcall(Reader.load, url, book or Reading.book, report, complete, opts)
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

-- keep_bar: the box is handed over to the load that is starting, so it stays up.
function Reading.cancel_load(keep_bar)
    Reading._load_generation = (Reading._load_generation or 0) + 1
    Reading._continuing_sections = false
    local task = Reading._load_task
    Reading._load_task = nil
    if task and type(task.cancel) == "function" then
        pcall(task.cancel, task)
    end
    local bar = Reading._load_bar
    if bar and bar ~= keep_bar then
        Reading._load_bar = nil
        pcall(bar.close, bar)
    end
    Log.info("reading", "load_cancelled")
end

function Reading.open_book(book)
    local BookDetail = require("wereadlite.book_detail")
    book = type(book) == "table" and book or {}
    if tostring(book.bookId or "") ~= "" and (not book.reader_param or book.reader_param == "") then
        local cached = BookDb.get(book.bookId)
        if type(cached) == "table" then
            for _, key in ipairs({ "title", "author", "cover", "intro", "category", "reader_url" }) do
                local value = cached[key]
                if value ~= nil and value ~= "" and (book[key] == nil or book[key] == "") then
                    book[key] = value
                end
            end
        end
    end
    book = BookDetail.enrich_reader_param(BookDetail.resolve_owned(book))
    local entry_param = reader_param_from_reader_url(book.reader_url) or book.reader_param
    local url
    if entry_param and entry_param ~= "" then
        url = Reader.url_for(entry_param)
    elseif book.reader_url and book.reader_url ~= "" then
        url = book.reader_url
    else
        show_error("缺少阅读参数")
        return
    end
    Reading.cancel_load()
    Reading.cancel_catalog()
    Reading.book = book
    Reading.chapters = {}
    Reading.state = nil
    Reading.catalog_complete = false
    Heartbeat.stop(false)
    -- Show the box on the tap: the prefetch teardown, the chapter cleanup and
    -- the first request all keep the UI thread busy, so a box scheduled for
    -- later would only appear seconds after the tap.
    local bar = Reading.show_load_bar("open")
    Reader.cancel_prefetch()
    Reader.clear_prefetched()
    Reader.cleanup_reading()
    UIManager:nextTick(function()
        local ok, status, err = Reading.open_url(url, book, { resume = true, bar = bar })
        if ok then
            UIManager:nextTick(Reader.warm_up)
            return
        end
        if status == "cancelled" then
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
        Log.warn("reading", "next_missing", {
            book_id = Reading.state and Reading.state.book_id,
            uid = current_uid(),
            chapters = #(Reading.chapters or {}),
        })
        show_error("无法打开下一章")
        return false
    end
    local from_state = Reading.state
    UIManager:nextTick(function()
        -- A repeated page-turn at the chapter end must not skip a chapter.
        if Reading.state ~= from_state then
            return
        end
        local ok, status, err = Reading.open_url(url, Reading.book, {
            resume = false,
            chapter_uid = from_state and from_state.next_param and from_state.next_param.uid,
        })
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

-- Turning past the last page (or back from the first one) makes KOReader re-draw
-- the very same page (page-update footer/view refresh).  We are about to replace
-- the document, so drop that queued repaint instead of letting the old page flash
-- once before the new chapter shows.
local function discard_pending_paint()
    pcall(function()
        UIManager._refresh_stack = {}
        UIManager._refresh_func_stack = {}
        local ok, ReaderUI = pcall(require, "apps/reader/readerui")
        local ui = ok and ReaderUI and ReaderUI.instance
        if ui and UIManager._dirty then
            UIManager._dirty[ui.dialog or ui] = nil
        end
    end)
end

-- Turning back from the first page of a chapter.  A long chapter is loaded as a
-- window of sections; inside a later window the previous data is simply not on
-- disk, so stay put instead of jumping over a whole chapter.
function Reading.open_prev()
    local state = Reading.state
    if state and (tonumber(state.section_start) or 0) > 0 then
        Log.info("reading", "prev_section_window", {
            section_start = state.section_start,
            uid = current_uid(),
        })
        return false
    end
    local url = Reader.prev_url(state)
    if not url then
        Log.info("reading", "prev_missing", {
            book_id = state and state.book_id,
            uid = current_uid(),
            chapters = #(Reading.chapters or {}),
        })
        show_error("已经是第一章")
        return false
    end
    discard_pending_paint()
    local from_state = state
    UIManager:nextTick(function()
        -- A repeated page-turn at the chapter start must not skip a chapter.
        if Reading.state ~= from_state then
            return
        end
        -- Land on the last page: the reader is moving backwards into this chapter.
        local ok, status, err = Reading.open_url(url, Reading.book, {
            resume = false,
            at_end = true,
            chapter_uid = from_state and from_state.prev_param and from_state.prev_param.uid,
        })
        if ok then
            return
        end
        Log.warn("reading", "prev_chapter", { status = status, err = err })
        if status == "auth_expired" then
            show_error("登录已过期，请重新登录")
        elseif status == "need_pay" then
            show_error("上一章需要购买")
        elseif status == "offline" then
            show_error("网络不可用")
        else
            show_error("打开上一章失败")
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
    Reading.cancel_catalog()
    Heartbeat.stop(false)
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

function Reading.show_toc()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok and ReaderUI and ReaderUI.instance
    if not ui then
        show_error("目录不可用")
        return false
    end
    local Event = require("ui/event")
    local handled = false
    pcall(function()
        handled = ui:handleEvent(Event:new("ShowToc"))
    end)
    if not handled and ui.toc and type(ui.toc.onShowToc) == "function" then
        pcall(function()
            ui.toc:onShowToc()
        end)
    end
    return true
end

-- Load the next segment window of the current (oversized) chapter.
function Reading.continue_sections()
    local state = Reading.state
    local url, segment_start = Reader.continue_sections_request(state)
    if not url then
        return false
    end
    if Reading._continuing_sections or Reading._load_task then
        return true
    end
    Reading._continuing_sections = true
    local count = tonumber(state.section_count) or 0
    local end_sect = tonumber(state.section_end) or 0
    local max_n = Settings.max_segments_per_load()
    UIManager:show(InfoMessage:new{
        text = string.format(
            "正在加载后续内容（%d–%d / %d）…",
            end_sect + 2,
            math.min(count, end_sect + 1 + max_n),
            count
        ),
        timeout = 2,
    })
    Log.info("reading", "continue_sections", {
        url = url,
        segment_start = segment_start,
        section_end = end_sect,
        section_count = count,
    })
    UIManager:nextTick(function()
        local ok, status, err = Reading.open_url(url, Reading.book, {
            resume = false,
            segment_start = segment_start,
            continue_sections = true,
        })
        if not ok then
            Reading._continuing_sections = false
            Log.warn("reading", "continue_sections_fail", { status = status, err = err })
            if status == "auth_expired" then
                show_error("登录已过期，请重新登录")
            elseif status == "offline" then
                show_error("网络不可用")
            else
                show_error("加载后续内容失败")
            end
        end
        -- Flag cleared in open_url complete/cancel when load finishes.
    end)
    return true
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

    -- Oversized chapter: HTML end is only the current segment window.
    if Reader.has_more_sections(Reading.state) then
        Log.info("reading", "end_of_window", {
            section_end = Reading.state and Reading.state.section_end,
            section_count = Reading.state and Reading.state.section_count,
        })
        Reading.continue_sections()
        return true
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
                        text = "打开目录",
                        callback = function()
                            UIManager:close(dialog)
                            Reading.show_toc()
                        end,
                    },
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
    -- Chapter end: go straight to the next chapter without asking.
    discard_pending_paint()
    if Reading._load_task then
        return true
    end
    Reading.open_next()
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
        local ok, status, err = Reading.open_url(url, Reading.book, {
            resume = false,
            chapter_uid = uid ~= "" and uid or nil,
        })
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
    Heartbeat.stop(false)
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

function Reading.save_reader_font_size(ui)
    local document = ui and ui.document
    local book_id = document and Reading.book_id_from_path(document.file)
    local configurable = document and document.configurable
    local size = configurable and tonumber(configurable.font_size)
    if not book_id or not size then
        Log.dbg("reading", "font_size_save_skip", {
            file = document and document.file,
            book_id = book_id,
            size = size,
        })
        return
    end
    local ok, err = pcall(Settings.set_reader_font_size, book_id, size)
    if not ok then
        Log.warn("reading", "save_font_size", { book_id = book_id, err = err })
    end
end

-- Called by KOReader's DocSettingsLoad event, after plugins are loaded and
-- before ReaderConfig/ReaderFont read the document settings, so the chapter is
-- laid out at the saved size from the start.  ReaderConfig reads CRE options
-- from the document settings with the "copt_" prefix (CreOptions.prefix).
function Reading.inject_reader_font_size(doc_settings, file)
    local book_id = Reading.book_id_from_path(file)
    if not book_id or not doc_settings then
        return false
    end
    local ok, size = pcall(Settings.reader_font_size, book_id)
    if not ok or not size then
        return false
    end
    doc_settings:saveSetting("copt_font_size", size)
    Log.dbg("reading", "font_size_inject", { book_id = book_id, size = size })
    return true
end

-- crengine can scale each fallback font so its x-height matches the main font
-- (KOReader: "Adjust fallback font sizes"): it re-sizes the fallback font by
-- main x-height / fallback x-height, so a font with a smaller x-height is drawn
-- bigger.  Han characters have no x-height, yet a rare character the main font
-- lacks comes from a fallback font, so it ends up drawn at a size unrelated to
-- the rest of the line.  WeRead draws those characters at the normal size, so
-- turn the adjustment off for its chapters.
--
-- The flag lives on crengine's font manager, not on the document, but KOReader
-- re-applies the user's own setting in setupDefaultView() before DocSettingsLoad
-- on every open, so a normal book opened afterwards gets their preference back.
-- The saved setting is never modified.
function Reading.disable_fallback_size_adjustment(document)
    if not document or not Reading.is_ours(document.file) then
        return false
    end
    if type(document.setAdjustedFallbackFontSizes) ~= "function" then
        -- Older KOReader without the property; the glyph images cap still applies.
        Log.warn("reading", "fallback_size_unavailable")
        return false
    end
    local ok, err = pcall(document.setAdjustedFallbackFontSizes, document, false)
    if not ok then
        Log.warn("reading", "fallback_size_adjust", { err = err })
        return false
    end
    Log.info("reading", "fallback_size_off")
    return true
end

-- Safety net run once the new chapter is open: if the saved size did not make
-- it into the layout for any reason, apply it directly.
function Reading.ensure_reader_font_size(ui)
    local document = ui and ui.document
    local book_id = document and Reading.book_id_from_path(document.file)
    local configurable = document and document.configurable
    if not book_id or not configurable then
        return
    end
    local ok, size = pcall(Settings.reader_font_size, book_id)
    if not ok or not size or tonumber(configurable.font_size) == size then
        return
    end
    Log.warn("reading", "font_size_fallback", {
        book_id = book_id,
        have = configurable.font_size,
        want = size,
    })
    local applied, err = pcall(function()
        local Screen = Device.screen
        configurable.font_size = size
        document:setFontSize(Screen:scaleBySize(size))
        ui:handleEvent(require("ui/event"):new("UpdatePos"))
    end)
    if not applied then
        Log.warn("reading", "font_size_fallback_fail", { err = err })
    end
end

-- Take the size the chapter opened with, so the close-time fallback can tell
-- whether the user actually changed it and avoid pinning the default onto
-- books that were only ever read as-is.
function Reading.snapshot_reader_font_size(ui)
    local configurable = ui and ui.document and ui.document.configurable
    if configurable then
        ui._wereadlite_font_size_opened = tonumber(configurable.font_size)
    end
end

function Reading.save_reader_font_size_if_changed(ui)
    local configurable = ui and ui.document and ui.document.configurable
    local current = configurable and tonumber(configurable.font_size)
    local opened = ui and tonumber(ui._wereadlite_font_size_opened)
    if current and opened and current ~= opened then
        Reading.save_reader_font_size(ui)
    end
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

-- KOReader reports "reached the end of the document" (EndOfBook) but has no
-- counterpart for the first page, so catch the backward turn here.
local function install_page_back_hook()
    local ok, ReaderPaging = pcall(require, "apps/reader/modules/readerpaging")
    if not ok or not ReaderPaging or ReaderPaging._wereadlite_back_hooked then
        return
    end
    ReaderPaging._wereadlite_back_hooked = true
    local original = ReaderPaging.onGotoPageRel
    function ReaderPaging:onGotoPageRel(diff, no_page_turn)
        if not no_page_turn and diff < 0
            and Reading.is_ours(self.document and self.document.file)
        then
            if self.current_page == 1 then
                Log.info("reading", "back_at_start", {
                    mode = "paging",
                    page = self.current_page,
                    zoom = tostring(self.zoom_mode),
                    scroll = self.view and self.view.page_scroll and true or false,
                })
                if self.zoom_mode ~= "free" and not Reading._load_task and Reading.open_prev() then
                    return true
                end
            end
        end
        if original then
            return original(self, diff, no_page_turn)
        end
    end
    Log.info("reading", "hook", { name = "page_back" })
end

-- Scroll mode (and paged mode inside ReaderRolling) keeps its own position, so
-- the first-page check above never sees it; hook the same turn there.
local function install_rolling_back_hook()
    local ok, ReaderRolling = pcall(require, "apps/reader/modules/readerrolling")
    if not ok or not ReaderRolling or ReaderRolling._wereadlite_back_hooked then
        return
    end
    ReaderRolling._wereadlite_back_hooked = true
    local original = ReaderRolling.onGotoViewRel
    function ReaderRolling:onGotoViewRel(diff)
        if type(diff) == "number" and diff < 0
            and Reading.is_ours(self.ui and self.ui.document and self.ui.document.file)
        then
            local scrolling = self.view and self.view.view_mode == "scroll"
            local at_start
            if scrolling then
                at_start = (tonumber(self.current_pos) or 0) <= 0
            else
                at_start = self.current_page == 1
            end
            if at_start then
                Log.info("reading", "back_at_start", {
                    mode = scrolling and "scroll" or "rolling_page",
                    pos = self.current_pos,
                    page = self.current_page,
                })
                if not Reading._load_task and Reading.open_prev() then
                    return true
                end
            end
        end
        if original then
            return original(self, diff)
        end
    end
    Log.info("reading", "hook", { name = "rolling_back" })
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
            Reading.save_reader_position(self)
            Reading.save_reader_font_size_if_changed(self)
            Heartbeat.stop(false)
        end
        local result
        if original then
            result = original(self, full_refresh)
        end
        if ours then
            Reading.remove_from_history(file)
            local preserve = tostring(Reading._preserve_html or "")
            if preserve ~= "" and tostring(file or "") == preserve then
                Log.dbg("reading", "close_preserve_html", { file = file })
            else
                -- A chapter switch closes the old document too: forget_chapter()
                -- keeps the file when the chapter cache still points at it, so
                -- turning back into it does not rebuild the whole chapter.
                Reader.forget_chapter(file)
            end
        end
        return result
    end
    -- Suspend and explicit "save settings" flushes go through this, and the
    -- document is still alive: keep the page for a resume after a power-off.
    local original_flush = ReaderUI.onFlushSettings
    function ReaderUI:onFlushSettings(show_notification)
        if self.document and Reading.is_ours(self.document.file) then
            Reading.save_reader_position(self)
        end
        if original_flush then
            return original_flush(self, show_notification)
        end
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
            and type(Reader.review_marks) == "table"
            and #Reader.review_marks > 0
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

local function install_font_size_hook()
    -- Remember every font size the user picks in the reading menu for the book
    -- being read, so its next chapter (and the next session) opens with it.
    local ok_font, ReaderFont = pcall(require, "apps/reader/modules/readerfont")
    if ok_font and ReaderFont and not ReaderFont._wereadlite_font_hooked then
        ReaderFont._wereadlite_font_hooked = true
        local original_set = ReaderFont.onSetFontSize
        if type(original_set) == "function" then
            function ReaderFont:onSetFontSize(size)
                local result = original_set(self, size)
                local file = self.ui and self.ui.document and self.ui.document.file
                if Reading.is_ours(file) then
                    Reading.save_reader_font_size(self.ui)
                end
                return result
            end
        end
    end

    Log.dbg("reading", "hook", { name = "reader_font_size" })
end

function Reading.install_hook()
    install_history_filter()
    install_end_of_book_hook()
    install_page_back_hook()
    install_rolling_back_hook()
    install_close_hook()
    install_exit_hook()
    install_toc_hook()
    install_review_link_hook()
    install_highlight_hook()
    install_font_size_hook()
end

return Reading
