local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local LoadProgress = require("wereadlite.load_progress")
local Log = require("wereadlite.log")
local Reader = require("wereadlite.kindle.reader")
local BookDb = require("wereadlite.book_db")
local Heartbeat = require("wereadlite.kindle.heartbeat")
local Bookmark = require("wereadlite.kindle.bookmark")
local TextViewer = require("ui/widget/textviewer")
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

local REVIEW_TOUCH_ZONE_ID = "wereadlite_review_tap"
local REVIEW_TOUCH_OVERRIDES = {
    -- Keep links and KOReader's native highlight handling above this zone,
    -- but let review taps win over menus, footer controls and page turns.
    "tap_top_left_corner",
    "tap_top_right_corner",
    "tap_left_bottom_corner",
    "tap_right_bottom_corner",
    "readerfooter_tap",
    "readerconfigmenu_ext_tap",
    "readerconfigmenu_tap",
    "readermenu_ext_tap",
    "readermenu_tap",
    "tap_forward",
    "tap_backward",
}
local REVIEW_TOUCH_UNREGISTER_OVERRIDES = {
    -- Include the old native-highlight dependency so hot reloading removes
    -- it if the zone was installed by a previous plugin version.
    "readerhighlight_tap",
    table.unpack(REVIEW_TOUCH_OVERRIDES),
}

local MAX_VISIBLE_REVIEW_CHARS = 10000

local function utf8_from_codepoint(cp)
    cp = tonumber(cp)
    if not cp or cp < 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
        return ""
    elseif cp <= 0x7F then
        return string.char(cp)
    elseif cp <= 0x7FF then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp <= 0xFFFF then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40)
    end
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40,
        0x80 + cp % 0x40)
end

local function decode_review_entities(text)
    return tostring(text or "")
        :gsub("&#x([%da-fA-F]+);", function(value)
            return utf8_from_codepoint(tonumber(value, 16))
        end)
        :gsub("&#(%d+);", function(value)
            return utf8_from_codepoint(tonumber(value, 10))
        end)
        :gsub("&nbsp;", "\194\160")
        :gsub("&quot;", '"')
        :gsub("&apos;", "'")
        :gsub("&#39;", "'")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&amp;", "&")
end

local REVIEW_UNICODE_WHITESPACE = {
    ["\194\160"] = true, -- no-break space
    ["\225\154\128"] = true,
    ["\226\128\128"] = true,
    ["\226\128\129"] = true,
    ["\226\128\130"] = true,
    ["\226\128\131"] = true,
    ["\226\128\132"] = true,
    ["\226\128\133"] = true,
    ["\226\128\134"] = true,
    ["\226\128\135"] = true,
    ["\226\128\136"] = true,
    ["\226\128\137"] = true,
    ["\226\128\138"] = true,
    ["\226\128\168"] = true,
    ["\226\128\169"] = true,
    ["\226\128\175"] = true,
    ["\226\129\159"] = true,
    ["\227\128\128"] = true,
}

local function normalized_review_chars(text)
    text = decode_review_entities(text)
    local chars = {}
    local i = 1
    while i <= #text do
        local first = text:byte(i)
        local width = 1
        if first and first >= 0xF0 and first <= 0xF7 then
            width = 4
        elseif first and first >= 0xE0 and first <= 0xEF then
            width = 3
        elseif first and first >= 0xC2 and first <= 0xDF then
            width = 2
        end
        if i + width - 1 > #text then
            width = 1
        end
        local char = text:sub(i, i + width - 1)
        if not char:match("^%s$") and not REVIEW_UNICODE_WHITESPACE[char] then
            chars[#chars + 1] = char
        end
        i = i + width
    end
    return chars
end

local function normalized_review_text(text)
    return table.concat(normalized_review_chars(text))
end

local function active_reader_ui()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then
        return nil
    end
    return ReaderUI.instance
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

local function clear_legacy_review_overlay(ui)
    if not ui then return end
    -- Remove state left by an older plugin version.  The current
    -- implementation does not create or paint a review overlay.
    if ui._wereadlite_review_hit_overlay then
        pcall(UIManager.close, UIManager, ui._wereadlite_review_hit_overlay)
        ui._wereadlite_review_hit_overlay = nil
    end
    if ui.view then
        ui.view._wereadlite_review_hit_boxes = nil
    end
end

local function unregister_review_touch_zone(ui, reason)
    if not ui then
        return false
    end
    ui._wereadlite_review_hit_regions = nil
    ui._wereadlite_review_hit_regions_state = nil
    ui._wereadlite_review_hit_regions_viewport = nil
    if ui._wereadlite_review_refresh_task then
        UIManager:unschedule(ui._wereadlite_review_refresh_task)
        ui._wereadlite_review_refresh_task = nil
    end
    clear_legacy_review_overlay(ui)
    if type(ui.unRegisterTouchZones) ~= "function" then
        return false
    end
    local registered = ui._wereadlite_review_touch_registered
    if not registered and type(ui.checkRegisterTouchZone) == "function" then
        local ok, result = pcall(ui.checkRegisterTouchZone, ui, REVIEW_TOUCH_ZONE_ID)
        registered = ok and result
    end
    if not registered then
        return false
    end
    local ok, err = pcall(ui.unRegisterTouchZones, ui, {{
        id = REVIEW_TOUCH_ZONE_ID,
        overrides = REVIEW_TOUCH_UNREGISTER_OVERRIDES,
    }})
    if not ok then
        Log.warn("reading", "review_touch_unregister_fail", { reason = reason, err = err })
        return false
    end
    ui._wereadlite_review_touch_registered = nil
    Log.dbg("reading", "review_touch_unregistered", { reason = reason })
    return true
end

local function ensure_review_touch_priority(ui)
    if not ui or type(ui.touch_zone_dg) ~= "table"
            or type(ui.touch_zone_dg.addNodeDep) ~= "function"
            or type(ui.touch_zone_dg.serialize) ~= "function"
            or type(ui._zones) ~= "table" then
        return false
    end

    -- registerTouchZones normally creates these dependencies. Re-apply them
    -- explicitly because KOReader can re-register menu/footer zones after a
    -- document switch, and an already-existing review zone otherwise keeps an
    -- old ordering graph.
    for _, overridden_id in ipairs(REVIEW_TOUCH_OVERRIDES) do
        pcall(ui.touch_zone_dg.addNodeDep, ui.touch_zone_dg,
            overridden_id, REVIEW_TOUCH_ZONE_ID)
    end

    local ordered = {}
    for _, zone_id in ipairs(ui.touch_zone_dg:serialize()) do
        local zone = ui._zones[zone_id]
        if zone then
            ordered[#ordered + 1] = zone
        end
    end
    local review_zone
    local filtered = {}
    for _, zone in ipairs(ordered) do
        local id = zone.def and zone.def.id
        if id == REVIEW_TOUCH_ZONE_ID then
            review_zone = zone
        else
            filtered[#filtered + 1] = zone
        end
    end

    -- Make the intended order explicit in addition to the dependency graph.
    -- This protects against a native module rebuilding its ordered list while
    -- the plugin zone is already present.
    local insert_at = 1
    for index, zone in ipairs(filtered) do
        local id = zone.def and zone.def.id
        local is_overridden = false
        for _, overridden_id in ipairs(REVIEW_TOUCH_OVERRIDES) do
            if id == overridden_id then
                is_overridden = true
                break
            end
        end
        if is_overridden then
            insert_at = index
            break
        end
    end
    if review_zone then
        table.insert(filtered, insert_at, review_zone)
    end
    ui._ordered_touch_zones = filtered

    local review_index
    local first_overridden_index
    for index, zone in ipairs(filtered) do
        local id = zone.def and zone.def.id
        if id == REVIEW_TOUCH_ZONE_ID then
            review_index = index
        elseif not first_overridden_index then
            for _, overridden_id in ipairs(REVIEW_TOUCH_OVERRIDES) do
                if id == overridden_id then
                    first_overridden_index = index
                    break
                end
            end
        end
    end
    Log.dbg("reading", "review_touch_priority", {
        review_index = review_index,
        first_overridden_index = first_overridden_index,
        zones = #ordered,
    })
    return review_index ~= nil
end

local function inside_screen_box(pos, box, padding)
    if type(pos) ~= "table" or type(box) ~= "table" then
        return false
    end
    local x, y = tonumber(pos.x), tonumber(pos.y)
    local bx, by = tonumber(box.x), tonumber(box.y)
    local bw, bh = tonumber(box.w), tonumber(box.h)
    if not x or not y or not bx or not by or not bw or not bh then
        return false
    end
    padding = tonumber(padding) or 0
    return x >= bx - padding and x <= bx + bw + padding
        and y >= by - padding and y <= by + bh + padding
end

local function review_viewport_key(ui)
    local document = ui and ui.document
    local page, top, width, height = "", "", "", ""
    if document and type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then page = value end
    end
    if document and type(document.getCurrentPos) == "function" then
        local ok, value = pcall(document.getCurrentPos, document)
        if ok then top = value end
    end
    if ui and ui.dimen then
        width, height = ui.dimen.w or "", ui.dimen.h or ""
    end
    return table.concat({ tostring(page), tostring(top), tostring(width), tostring(height) }, ":")
end

local function append_normalized_tokens(tokens, text, fields)
    for _, char in ipairs(normalized_review_chars(text)) do
        local token = { char = char }
        for key, value in pairs(fields or {}) do
            token[key] = value
        end
        tokens[#tokens + 1] = token
    end
end

local function collect_paging_review_tokens(ui)
    local document, view = ui.document, ui.view
    if not document or not view or type(document.getTextBoxes) ~= "function"
            or type(view.pageToScreenTransform) ~= "function" then
        return nil
    end
    local pages = {}
    if type(view.getCurrentPageList) == "function" then
        local ok, current = pcall(view.getCurrentPageList, view)
        if ok and type(current) == "table" then
            pages = current
        end
    end
    if #pages == 0 then
        local page
        if type(ui.getCurrentPage) == "function" then
            local ok, current = pcall(ui.getCurrentPage, ui)
            if ok then page = current end
        end
        if page then pages[1] = page end
    end

    local tokens = {}
    for _, page in ipairs(pages) do
        local ok, lines = pcall(document.getTextBoxes, document, page)
        if ok and type(lines) == "table" then
            for line_index, line in ipairs(lines) do
                for _, box in ipairs(line or {}) do
                    if type(box) == "table" and type(box.word) == "string"
                            and box.x0 and box.y0 and box.x1 and box.y1 then
                        append_normalized_tokens(tokens, box.word, {
                            mode = "paging",
                            page = page,
                            line = line_index,
                            box = box,
                        })
                    end
                end
            end
        end
    end
    return #tokens > 0 and tokens or nil
end

local function compare_xp(document, first, second)
    local ok, result = pcall(document.compareXPointers, document, first, second)
    return ok and result or nil
end

local function collect_rolling_review_tokens(ui)
    local document = ui.document
    if not document or type(document.getTextFromPositions) ~= "function"
            or type(document.getTextFromXPointers) ~= "function"
            or type(document.getNextVisibleChar) ~= "function"
            or type(document.compareXPointers) ~= "function" then
        return nil
    end
    local width = ui.dimen and tonumber(ui.dimen.w) or Device.screen:getWidth()
    local height = ui.dimen and tonumber(ui.dimen.h) or Device.screen:getHeight()
    local ok, visible = pcall(document.getTextFromPositions, document,
        { x = 0, y = 0 }, { x = width - 1, y = height - 1 }, true)
    if not ok or type(visible) ~= "table" or not visible.pos0 or not visible.pos1 then
        return nil
    end

    local tokens = {}
    local cursor = visible.pos0
    local truncated = false
    for _ = 1, MAX_VISIBLE_REVIEW_CHARS do
        if compare_xp(document, cursor, visible.pos1) ~= 1 then
            break
        end
        local next_ok, next_pos = pcall(document.getNextVisibleChar, document, cursor)
        if not next_ok or not next_pos or next_pos == cursor then
            break
        end
        if compare_xp(document, next_pos, visible.pos1) == -1 then
            next_pos = visible.pos1
        end
        local text_ok, chunk = pcall(document.getTextFromXPointers,
            document, cursor, next_pos, false)
        if text_ok and type(chunk) == "string" then
            append_normalized_tokens(tokens, chunk, {
                mode = "rolling",
                pos0 = cursor,
                pos1 = next_pos,
            })
        end
        cursor = next_pos
        if cursor == visible.pos1 then
            break
        end
        if #tokens >= MAX_VISIBLE_REVIEW_CHARS then
            truncated = true
            break
        end
    end
    if truncated then
        Log.warn("reading", "review_visible_text_truncated", { chars = #tokens })
    end
    return #tokens > 0 and tokens or nil
end

local function visible_review_tokens(ui)
    if ui.paging then
        local tokens = collect_paging_review_tokens(ui)
        if tokens then return tokens, "paging" end
    end
    local tokens = collect_rolling_review_tokens(ui)
    if tokens then return tokens, "rolling" end
    return nil
end

local function clip_screen_box(ui, box)
    if type(box) ~= "table" then return nil end
    local x, y = tonumber(box.x), tonumber(box.y)
    local w, h = tonumber(box.w), tonumber(box.h)
    if not x or not y or not w or not h or w <= 0 or h <= 0 then return nil end
    local screen_w = ui.dimen and tonumber(ui.dimen.w) or Device.screen:getWidth()
    local screen_h = ui.dimen and tonumber(ui.dimen.h) or Device.screen:getHeight()
    local x0, y0 = math.max(0, x), math.max(0, y)
    local x1, y1 = math.min(screen_w, x + w), math.min(screen_h, y + h)
    if x1 <= x0 or y1 <= y0 then return nil end
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

local function rolling_boxes_for_match(ui, first, last)
    local document = ui.document
    local ok, boxes = pcall(document.getScreenBoxesFromPositions,
        document, first.pos0, last.pos1, true)
    if not ok or type(boxes) ~= "table" then return {} end
    local visible = {}
    for _, box in ipairs(boxes) do
        local clipped = clip_screen_box(ui, box)
        if clipped then visible[#visible + 1] = clipped end
    end
    return visible
end

local function paging_boxes_for_match(ui, tokens, first_index, last_index)
    local grouped = {}
    local current
    local previous_box
    for index = first_index, last_index do
        local token = tokens[index]
        local box = token.box
        if box ~= previous_box then
            if not current or current.page ~= token.page or current.line ~= token.line then
                current = {
                    page = token.page,
                    line = token.line,
                    x0 = box.x0,
                    y0 = box.y0,
                    x1 = box.x1,
                    y1 = box.y1,
                }
                grouped[#grouped + 1] = current
            else
                current.x0 = math.min(current.x0, box.x0)
                current.y0 = math.min(current.y0, box.y0)
                current.x1 = math.max(current.x1, box.x1)
                current.y1 = math.max(current.y1, box.y1)
            end
            previous_box = box
        end
    end
    local visible = {}
    for _, box in ipairs(grouped) do
        local page_box = Geom:new{
            x = box.x0,
            y = box.y0,
            w = box.x1 - box.x0,
            h = box.y1 - box.y0,
        }
        local ok, screen_box = pcall(ui.view.pageToScreenTransform,
            ui.view, box.page, page_box)
        if ok then
            local clipped = clip_screen_box(ui, screen_box)
            if clipped then visible[#visible + 1] = clipped end
        end
    end
    return visible
end

local function index_review_tokens(tokens)
    local text, starts, finishes = {}, {}, {}
    local byte = 1
    for index, token in ipairs(tokens) do
        text[#text + 1] = token.char
        starts[byte] = index
        byte = byte + #token.char
        finishes[byte - 1] = index
    end
    return table.concat(text), starts, finishes
end

local function build_review_hit_regions(ui, expected_state)
    local viewport = review_viewport_key(ui)
    if ui._wereadlite_review_hit_regions_state == expected_state
            and ui._wereadlite_review_hit_regions_viewport == viewport
            and type(ui._wereadlite_review_hit_regions) == "table" then
        return ui._wereadlite_review_hit_regions, true
    end
    if not ui.document or not ui.view then
        return {}, false
    end

    local tokens, mode = visible_review_tokens(ui)
    if not tokens then
        Log.warn("reading", "review_hit_regions_unavailable", { viewport = viewport })
        return {}, false
    end
    local visible_text, starts, finishes = index_review_tokens(tokens)
    local regions, matched = {}, 0
    for _, mark in ipairs(Reader.review_marks or {}) do
        local wanted = normalized_review_text(mark.text)
        local boxes, search_at = {}, 1
        while wanted ~= "" do
            local first_byte, last_byte = visible_text:find(wanted, search_at, true)
            if not first_byte then break end
            local first_index, last_index = starts[first_byte], finishes[last_byte]
            if first_index and last_index then
                local found
                if mode == "rolling" then
                    found = rolling_boxes_for_match(ui, tokens[first_index], tokens[last_index])
                else
                    found = paging_boxes_for_match(ui, tokens, first_index, last_index)
                end
                for _, box in ipairs(found) do boxes[#boxes + 1] = box end
            end
            search_at = last_byte + 1
        end
        if #boxes > 0 then
            matched = matched + 1
            regions[mark.id] = boxes
        end
    end
    ui._wereadlite_review_hit_regions = regions
    ui._wereadlite_review_hit_regions_state = expected_state
    ui._wereadlite_review_hit_regions_viewport = viewport
    Log.dbg("reading", "review_hit_regions_built", {
        mode = mode,
        marks = #(Reader.review_marks or {}),
        matched = matched,
        tokens = #tokens,
    })
    return regions, true
end

local function install_review_touch_zone(expected_path, expected_state)
    local ui = active_reader_ui()
    if not ui or type(ui.registerTouchZones) ~= "function" or not ui.view or not ui.document then
        Log.warn("reading", "review_touch_register_fail", { has_ui = ui ~= nil })
        return false
    end
    if expected_state and Reading.state ~= expected_state then
        Log.dbg("reading", "review_touch_stale", { reason = "state" })
        return false
    end
    if expected_path and tostring(ui.document.file or "") ~= tostring(expected_path) then
        Log.dbg("reading", "review_touch_stale", {
            reason = "document",
            expected = expected_path,
            current = ui.document.file,
        })
        return false
    end
    clear_legacy_review_overlay(ui)
    if #(Reader.review_marks or {}) == 0 then
        Log.dbg("reading", "review_touch_skip", { reason = "no_marks" })
        return false
    end
    local already_registered = ui._wereadlite_review_touch_registered
    if not already_registered and type(ui.checkRegisterTouchZone) == "function" then
        local check_ok, check_result = pcall(ui.checkRegisterTouchZone, ui, REVIEW_TOUCH_ZONE_ID)
        already_registered = check_ok and check_result
        if already_registered then
            ui._wereadlite_review_touch_registered = true
        end
    end
    if already_registered then
        -- Do not keep a zone installed with stale overrides. This is needed
        -- both after a hot reload and when a reader module re-registers its
        -- native zones during a chapter switch.
        Log.dbg("reading", "review_touch_reregister", { marks = #(Reader.review_marks or {}) })
        if not unregister_review_touch_zone(ui, "refresh_priority") then
            return false
        end
    end

    local function handler(ges)
        -- The handler is owned by one ReaderUI instance, but the singleton can
        -- change after a chapter switch.  Never use a captured/stale document
        -- for coordinate conversion or review lookup.
        local current_ui = active_reader_ui()
        Log.dbg("reading", "review_tap_event", {
            has_pos = ges and ges.pos ~= nil,
            same_ui = current_ui == ui,
        })
        if current_ui ~= ui or not Reading.is_active()
                or not current_ui.view or not current_ui.document
                or (expected_state and Reading.state ~= expected_state)
                or (expected_path and tostring(current_ui.document.file or "") ~= tostring(expected_path)) then
            Log.dbg("reading", "review_touch_stale", { reason = "handler" })
            return nil
        end
        if not ges or not ges.pos then
            return nil
        end

        local regions = build_review_hit_regions(current_ui, expected_state)
        local tapped_mark
        for _, mark in ipairs(Reader.review_marks or {}) do
            local hit = false
            for _, box in ipairs(regions[mark.id] or {}) do
                if inside_screen_box(ges.pos, box, 0) then
                    hit = true
                    break
                end
            end
            if hit then
                if tapped_mark and tapped_mark.id ~= mark.id then
                    Log.warn("reading", "review_tap_ambiguous", {
                        first = tapped_mark.id,
                        second = mark.id,
                        x = ges.pos.x,
                        y = ges.pos.y,
                    })
                    return nil
                end
                tapped_mark = mark
            end
        end
        if tapped_mark then
            Log.info("reading", "review_tap", {
                id = tapped_mark.id,
                x = ges.pos.x,
                y = ges.pos.y,
                reviews = #(tapped_mark.reviews or {}),
            })
            prepare_review_comments(tapped_mark.reviews)
            return true
        end
        -- Returning nil is essential: the normal reader paging touch zones
        -- must still receive an ordinary tap after this zone declines it.
        return nil
    end

    local ok, err = pcall(ui.registerTouchZones, ui, {{
        id = REVIEW_TOUCH_ZONE_ID,
        ges = "tap",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        overrides = REVIEW_TOUCH_OVERRIDES,
        handler = handler,
    }})
    if not ok then
        Log.warn("reading", "review_touch_register_fail", { err = err })
        return false
    end
    ui._wereadlite_review_touch_registered = true
    ensure_review_touch_priority(ui)
    -- The HTML span is only a rendering marker. Build native text geometry
    -- after ReaderReady so touch hit testing follows the actual layout,
    -- including phrases split across multiple HTML spans.
    UIManager:nextTick(function()
        local current_ui = active_reader_ui()
        if current_ui == ui and Reading.state == expected_state
                and current_ui.document
                and tostring(current_ui.document.file or "") == tostring(expected_path or "") then
            build_review_hit_regions(current_ui, expected_state)
        end
    end)
    Log.dbg("reading", "review_touch_registered", { marks = #(Reader.review_marks or {}) })
    return true
end

function Reading.refresh_review_hit_regions(ui)
    ui = ui or active_reader_ui()
    if not ui or ui ~= active_reader_ui() or not Reading.is_active() then
        return
    end
    ensure_review_touch_priority(ui)
    ui._wereadlite_review_hit_regions_viewport = nil
    if ui._wereadlite_review_refresh_task then
        UIManager:unschedule(ui._wereadlite_review_refresh_task)
    end
    local expected_state = Reading.state
    local function refresh_task()
        ui._wereadlite_review_refresh_task = nil
        if ui == active_reader_ui() and Reading.state == expected_state
                and Reading.is_active() then
            build_review_hit_regions(ui, expected_state)
        end
    end
    ui._wereadlite_review_refresh_task = refresh_task
    UIManager:scheduleIn(0.08, refresh_task)
end

local function open_document(path, resume, state)
    -- These HTML files are regenerated from the remote chapter. A previous
    -- KOReader sidecar must not override the position selected below.
    Reader.clear_sidecars(path)
    local ReaderUI = require("apps/reader/readerui")
    -- switchDocument creates a new ReaderUI.  Remove the old zone before the
    -- old instance starts tearing down, and install exactly one zone on the
    -- new instance after ReaderReady has completed.
    unregister_review_touch_zone(ReaderUI.instance, "document_switch")
    local function after_open()
        Reading.remove_from_history(path)
        Reader.cleanup_reading(path)
        -- ReaderUI sets its singleton instance immediately after invoking
        -- after_open_callback.  Defer one tick so both a fresh reader and a
        -- switched document register on the actual active instance (desktop
        -- mouse clicks are translated to this same `tap` gesture).
        UIManager:nextTick(function()
            install_review_touch_zone(path, state)
        end)
        if type(resume) == "table" then
            UIManager:scheduleIn(0.35, function()
                Reading.goto_resume(resume, path, state)
            end)
        end
    end
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
            -- A touch zone belongs to this ReaderUI instance.  Unregister it
            -- before KOReader tears down the instance; it must not survive a
            -- chapter switch or return to the shelf.
            unregister_review_touch_zone(self, "reader_close")
        end
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
    install_highlight_hook()
end

return Reading
