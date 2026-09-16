local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DoubleSpinWidget = require("ui/widget/doublespinwidget")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local Config = require("wereadlite.config")
local Log = require("wereadlite.log")

local Settings = {
    GRID_ROWS_MIN = 3,
    GRID_ROWS_MAX = 6,
    GRID_COLS_MIN = 4,
    GRID_COLS_MAX = 7,
    GRID_ROWS_DEFAULT = 4,
    GRID_COLS_DEFAULT = 5,
    CARD_RADIUS_MIN = 0,
    CARD_RADIUS_MAX = 24,
    CARD_RADIUS_DEFAULT = 0,
    GRID_FONT_MIN = 12,
    GRID_FONT_MAX = 28,
    GRID_FONT_DEFAULT = 18,
    IMAGE_CONCURRENCY_MIN = 1,
    IMAGE_CONCURRENCY_MAX = 8,
    IMAGE_CONCURRENCY_DEFAULT = 4,
    MAX_SEGMENTS_MIN = 1,
    MAX_SEGMENTS_MAX = 30,
    MAX_SEGMENTS_DEFAULT = 3,
}

local store

local function settings_path()
    local ok, path = pcall(function()
        return DataStorage:getSettingsDir() .. "/" .. (Config.SETTINGS_FILE or "wereadlite.lua")
    end)
    if ok and path then
        return path
    end
    return "wereadlite.lua"
end

local function clamp(value, min, max, fallback)
    value = tonumber(value)
    if not value then
        return fallback
    end
    return math.max(min, math.min(max, math.floor(value)))
end

function Settings.load()
    if not store then
        store = LuaSettings:open(settings_path())
        Log.dbg("settings", "load", { path = settings_path() })
        -- Bump when shipping a new default shelf layout so old installs pick it up once.
        local LAYOUT_PRESET = 2
        local current = tonumber(store:readSetting("layout_preset")) or 0
        if current < LAYOUT_PRESET then
            store:saveSetting("grid_rows", Settings.GRID_ROWS_DEFAULT)
            store:saveSetting("grid_cols", Settings.GRID_COLS_DEFAULT)
            store:delSetting("grid_tile_order")
            store:delSetting("last_read_span")
            store:delSetting("user_span")
            store:delSetting("clock_span")
            store:delSetting("text_stats_span")
            store:delSetting("chart_stats_span")
            store:saveSetting("layout_preset", LAYOUT_PRESET)
            store:flush()
            Log.info("settings", "layout_preset", { preset = LAYOUT_PRESET })
        end
    end
    return store
end

local function normalize_grid(rows, cols)
    rows = clamp(rows, Settings.GRID_ROWS_MIN, Settings.GRID_ROWS_MAX, Settings.GRID_ROWS_DEFAULT)
    cols = clamp(cols, Settings.GRID_COLS_MIN, Settings.GRID_COLS_MAX, Settings.GRID_COLS_DEFAULT)
    if cols < rows then
        cols = math.min(Settings.GRID_COLS_MAX, rows)
    end
    if cols < rows then
        rows = math.max(Settings.GRID_ROWS_MIN, cols)
    end
    return rows, cols
end

function Settings.grid_size()
    local data = Settings.load()
    return normalize_grid(data:readSetting("grid_rows"), data:readSetting("grid_cols"))
end

function Settings.grid_rows()
    local rows = Settings.grid_size()
    return rows
end

function Settings.grid_cols()
    local _, cols = Settings.grid_size()
    return cols
end

function Settings.skill_apikey()
    local data = Settings.load()
    local key = tostring(data:readSetting("skill_apikey") or "")
    if key:match("^wrk%-") then
        return key
    end
end

function Settings.set_skill_apikey(key)
    local data = Settings.load()
    key = tostring(key or "")
    if key == "" then
        data:delSetting("skill_apikey")
    else
        data:saveSetting("skill_apikey", key)
    end
    data:flush()
    Log.dbg("settings", "skill_apikey", { set = key ~= "", len = #key })
end

function Settings.load_review_comments()
    local data = Settings.load()
    local value = data:readSetting("load_review_comments")
    return value ~= nil and (value == true or value == 1) or false
end

function Settings.set_load_review_comments(enabled)
    local data = Settings.load()
    data:saveSetting("load_review_comments", enabled and true or false)
    data:flush()
    Log.info("settings", "load_review_comments", { enabled = enabled and true or false })
end

local function show_toggle_dialog(title, current, apply, on_changed)
    local dialog
    local function pick(value, label)
        local text = label
        if current == value then
            text = text .. "  · 当前"
        end
        return {
            text = text,
            callback = function()
                UIManager:close(dialog)
                apply(value)
                if on_changed then
                    on_changed()
                end
            end,
        }
    end
    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        use_info_style = false,
        buttons = {
            { pick(true, "开"), pick(false, "关") },
        },
    }
    UIManager:show(dialog)
end

function Settings.show_review_comments_dialog(on_changed)
    show_toggle_dialog(
        "划线与想法",
        Settings.load_review_comments(),
        Settings.set_load_review_comments,
        on_changed
    )
end

function Settings.load_review_avatars()
    local data = Settings.load()
    local value = data:readSetting("load_review_avatars")
    if value == nil then
        return true
    end
    return value == true or value == 1
end

function Settings.set_load_review_avatars(enabled)
    local data = Settings.load()
    data:saveSetting("load_review_avatars", enabled and true or false)
    data:flush()
    Log.info("settings", "load_review_avatars", { enabled = enabled and true or false })
end

function Settings.show_review_avatars_dialog(on_changed)
    show_toggle_dialog(
        "评论头像",
        Settings.load_review_avatars(),
        Settings.set_load_review_avatars,
        on_changed
    )
end

function Settings.show_chapter_load_progress()
    local data = Settings.load()
    local value = data:readSetting("show_chapter_load_progress")
    if value == nil then
        return true
    end
    return value == true or value == 1
end

function Settings.set_show_chapter_load_progress(enabled)
    local data = Settings.load()
    data:saveSetting("show_chapter_load_progress", enabled and true or false)
    data:flush()
    Log.info("settings", "show_chapter_load_progress", { enabled = enabled and true or false })
end

function Settings.show_chapter_load_progress_dialog(on_changed)
    show_toggle_dialog(
        "加载进度条",
        Settings.show_chapter_load_progress(),
        Settings.set_show_chapter_load_progress,
        on_changed
    )
end

function Settings.prefetch_next_chapter()
    local data = Settings.load()
    local value = data:readSetting("prefetch_next_chapter")
    return value ~= nil and (value == true or value == 1) or false
end

function Settings.set_prefetch_next_chapter(enabled)
    enabled = enabled and true or false
    local data = Settings.load()
    data:saveSetting("prefetch_next_chapter", enabled)
    data:flush()
    if not enabled then
        -- Stop pending work immediately when the user disables prefetching.
        local ok, Reader = pcall(require, "wereadlite.kindle.reader")
        if ok and Reader and type(Reader.cancel_prefetch) == "function" then
            pcall(Reader.cancel_prefetch)
        end
        local ok_reading, Reading = pcall(require, "wereadlite.reading")
        if ok_reading and Reading and type(Reading.cancel_prefetch) == "function" then
            pcall(Reading.cancel_prefetch)
        end
    end
    Log.info("settings", "prefetch_next_chapter", { enabled = enabled })
    return enabled
end

function Settings.show_prefetch_next_chapter_dialog(on_changed)
    local current = Settings.prefetch_next_chapter()
    local dialog
    if current then
        dialog = ConfirmBox:new{
            name = "wereadlite_prefetch_next_chapter",
            text = "关闭后，翻到下一章时将按需加载内容。",
            ok_text = "关闭预加载",
            cancel_text = "保持开启",
            ok_callback = function()
                Settings.set_prefetch_next_chapter(false)
                if on_changed then on_changed() end
            end,
        }
    else
        dialog = ConfirmBox:new{
            name = "wereadlite_prefetch_next_chapter",
            text = "开启预加载可能会导致翻页时偶尔卡顿，是否开启？",
            ok_text = "开启预加载",
            cancel_text = "保持关闭",
            ok_callback = function()
                Settings.set_prefetch_next_chapter(true)
                if on_changed then on_changed() end
            end,
        }
    end
    UIManager:show(dialog)
end

function Settings.image_concurrency()
    local data = Settings.load()
    return clamp(
        data:readSetting("image_concurrency"),
        Settings.IMAGE_CONCURRENCY_MIN,
        Settings.IMAGE_CONCURRENCY_MAX,
        Settings.IMAGE_CONCURRENCY_DEFAULT
    )
end

function Settings.set_image_concurrency(value)
    value = clamp(
        value,
        Settings.IMAGE_CONCURRENCY_MIN,
        Settings.IMAGE_CONCURRENCY_MAX,
        Settings.IMAGE_CONCURRENCY_DEFAULT
    )
    local data = Settings.load()
    data:saveSetting("image_concurrency", value)
    data:flush()
    Log.info("settings", "image_concurrency", { value = value })
    return value
end

function Settings.show_image_concurrency_dialog()
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = "图片下载并发",
        info_text = "同时下载书内图片的数量，网络较差时可调低",
        value = Settings.image_concurrency(),
        value_min = Settings.IMAGE_CONCURRENCY_MIN,
        value_max = Settings.IMAGE_CONCURRENCY_MAX,
        default_value = Settings.IMAGE_CONCURRENCY_DEFAULT,
        value_step = 1,
        value_hold_step = 2,
        precision = "%d",
        ok_text = "应用",
        cancel_text = "取消",
        ok_always_enabled = true,
        default_text = "恢复默认 4",
        callback = function(spin)
            Settings.set_image_concurrency(spin.value)
        end,
    })
end

function Settings.max_segments_per_load()
    local data = Settings.load()
    return clamp(
        data:readSetting("max_segments_per_load"),
        Settings.MAX_SEGMENTS_MIN,
        Settings.MAX_SEGMENTS_MAX,
        Settings.MAX_SEGMENTS_DEFAULT
    )
end

function Settings.set_max_segments_per_load(value)
    value = clamp(
        value,
        Settings.MAX_SEGMENTS_MIN,
        Settings.MAX_SEGMENTS_MAX,
        Settings.MAX_SEGMENTS_DEFAULT
    )
    local data = Settings.load()
    data:saveSetting("max_segments_per_load", value)
    data:flush()
    Log.info("settings", "max_segments_per_load", { value = value })
    return value
end

function Settings.show_max_segments_per_load_dialog()
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = "章节分段上限",
        info_text = "超大章节每次最多下载的段数。读到本段末尾会自动续载后续分段。默认 3。",
        value = Settings.max_segments_per_load(),
        value_min = Settings.MAX_SEGMENTS_MIN,
        value_max = Settings.MAX_SEGMENTS_MAX,
        default_value = Settings.MAX_SEGMENTS_DEFAULT,
        value_step = 1,
        value_hold_step = 3,
        precision = "%d",
        ok_text = "应用",
        cancel_text = "取消",
        ok_always_enabled = true,
        default_text = "恢复默认 3",
        callback = function(spin)
            Settings.set_max_segments_per_load(spin.value)
        end,
    })
end

function Settings.card_radius()
    local data = Settings.load()
    return clamp(
        data:readSetting("card_radius"),
        Settings.CARD_RADIUS_MIN,
        Settings.CARD_RADIUS_MAX,
        Settings.CARD_RADIUS_DEFAULT
    )
end

function Settings.set_card_radius(value)
    value = clamp(
        value,
        Settings.CARD_RADIUS_MIN,
        Settings.CARD_RADIUS_MAX,
        Settings.CARD_RADIUS_DEFAULT
    )
    local data = Settings.load()
    data:saveSetting("card_radius", value)
    data:flush()
    Log.info("settings", "card_radius", { value = value })
    return value
end

function Settings.show_card_radius_dialog(on_changed)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = "框线圆角",
        info_text = "宫格卡片边框圆角，0 为直角",
        value = Settings.card_radius(),
        value_min = Settings.CARD_RADIUS_MIN,
        value_max = Settings.CARD_RADIUS_MAX,
        default_value = Settings.CARD_RADIUS_DEFAULT,
        value_step = 1,
        value_hold_step = 4,
        precision = "%d",
        ok_text = "应用",
        cancel_text = "取消",
        ok_always_enabled = true,
        default_text = "恢复直角",
        callback = function(spin)
            local old = Settings.card_radius()
            local value = Settings.set_card_radius(spin.value)
            if value ~= old and on_changed then
                on_changed()
            end
        end,
    })
end

Settings.TILE_IDS = { "clock", "recent", "user", "text_stats", "chart_stats", "recommend" }

Settings.TILE_LABEL = {
    recent = "上次阅读",
    user = "账号",
    clock = "时钟",
    text_stats = "文字统计",
    chart_stats = "图表统计",
    recommend = "为你推荐",
}

local TILE_SPAN_KEY = {
    recent = "last_read_span",
    user = "user_span",
    clock = "clock_span",
    text_stats = "text_stats_span",
    chart_stats = "chart_stats_span",
    recommend = "recommend_span",
}

local TILE_ID_SET = {
    recent = true,
    user = true,
    clock = true,
    text_stats = true,
    chart_stats = true,
    recommend = true,
}

-- Default for 4×5: 时钟1 + 上次阅读3 + 账号1 | 文字统计2 + 图表统计3 | 为你推荐4
local TILE_SPAN_DEFAULT = {
    clock = 1,
    recent = 3,
    user = 1,
    text_stats = 2,
    chart_stats = 3,
    recommend = 5,
}

local TILE_SPAN_MIN = {
    recommend = 2,
}

local function tile_span_min(id)
    return TILE_SPAN_MIN[id] or 1
end

function Settings.default_tile_span(id)
    local cols = Settings.grid_cols()
    local preferred = TILE_SPAN_DEFAULT[id] or 1
    return math.max(tile_span_min(id), math.min(preferred, cols))
end

function Settings.tile_span(id)
    local cols = Settings.grid_cols()
    local key = TILE_SPAN_KEY[id]
    if not key then
        return 1
    end
    local data = Settings.load()
    return clamp(data:readSetting(key), tile_span_min(id), cols, Settings.default_tile_span(id))
end

function Settings.set_tile_span(id, span)
    local key = TILE_SPAN_KEY[id]
    if not key then
        return Settings.tile_span(id)
    end
    local cols = Settings.grid_cols()
    span = clamp(span, tile_span_min(id), cols, Settings.default_tile_span(id))
    local data = Settings.load()
    data:saveSetting(key, span)
    data:flush()
    Log.info("settings", "tile_span", { id = id, span = span, cols = cols })
    return span
end

function Settings.user_span()
    return Settings.tile_span("user")
end

function Settings.last_read_span_max()
    return Settings.grid_cols()
end

function Settings.header_last_span()
    return Settings.tile_span("recent")
end

function Settings.last_read_span()
    return Settings.tile_span("recent")
end

function Settings.set_last_read_span(span)
    return Settings.set_tile_span("recent", span)
end

function Settings.text_stats_span()
    return Settings.tile_span("text_stats")
end

function Settings.chart_stats_span()
    return Settings.tile_span("chart_stats")
end

function Settings.recommend_span()
    return Settings.tile_span("recommend")
end

function Settings.tile_order()
    local data = Settings.load()
    local saved = data:readSetting("grid_tile_order")
    local seen = {}
    local order = {}
    local function add(id)
        id = tostring(id or "")
        if TILE_ID_SET[id] and not seen[id] then
            order[#order + 1] = id
            seen[id] = true
        end
    end
    if type(saved) == "string" then
        for id in saved:gmatch("[^,]+") do
            add(id)
        end
    elseif type(saved) == "table" then
        for _, id in ipairs(saved) do
            add(id)
        end
    end
    local tile_pos = {}
    for i, tid in ipairs(Settings.TILE_IDS) do
        tile_pos[tid] = i
    end
    for _, id in ipairs(Settings.TILE_IDS) do
        if not seen[id] then
            local def_idx = tile_pos[id]
            local after = 0
            for i, tid in ipairs(order) do
                if (tile_pos[tid] or 99) < def_idx then
                    after = i
                end
            end
            table.insert(order, after + 1, id)
            seen[id] = true
        end
    end
    return order
end

function Settings.set_tile_order(order)
    local seen = {}
    local clean = {}
    for _, id in ipairs(order or {}) do
        id = tostring(id or "")
        if TILE_ID_SET[id] and not seen[id] then
            clean[#clean + 1] = id
            seen[id] = true
        end
    end
    for _, id in ipairs(Settings.TILE_IDS) do
        if not seen[id] then
            clean[#clean + 1] = id
        end
    end
    local data = Settings.load()
    data:saveSetting("grid_tile_order", table.concat(clean, ","))
    data:flush()
    Log.info("settings", "tile_order", { order = table.concat(clean, ",") })
    return clean
end

function Settings.move_tile(id, delta)
    local order = Settings.tile_order()
    local idx
    for i, item in ipairs(order) do
        if item == id then
            idx = i
            break
        end
    end
    if not idx then
        return order
    end
    local other = idx + (tonumber(delta) or 0)
    if other < 1 or other > #order then
        return order
    end
    order[idx], order[other] = order[other], order[idx]
    return Settings.set_tile_order(order)
end

function Settings.hidden_tiles()
    local data = Settings.load()
    local saved = data:readSetting("grid_tile_hidden")
    local hidden = {}
    if type(saved) == "string" then
        for id in saved:gmatch("[^,]+") do
            if TILE_ID_SET[id] then
                hidden[id] = true
            end
        end
    elseif type(saved) == "table" then
        for _, id in ipairs(saved) do
            id = tostring(id or "")
            if TILE_ID_SET[id] then
                hidden[id] = true
            end
        end
    end
    return hidden
end

function Settings.tile_enabled(id)
    id = tostring(id or "")
    if not TILE_ID_SET[id] then
        return false
    end
    return not Settings.hidden_tiles()[id]
end

function Settings.set_tile_enabled(id, enabled)
    id = tostring(id or "")
    if not TILE_ID_SET[id] then
        return false
    end
    local hidden = Settings.hidden_tiles()
    if enabled then
        hidden[id] = nil
    else
        hidden[id] = true
    end
    local parts = {}
    for _, tid in ipairs(Settings.TILE_IDS) do
        if hidden[tid] then
            parts[#parts + 1] = tid
        end
    end
    local data = Settings.load()
    if #parts == 0 then
        data:delSetting("grid_tile_hidden")
    else
        data:saveSetting("grid_tile_hidden", table.concat(parts, ","))
    end
    data:flush()
    Log.info("settings", "tile_enabled", { id = id, enabled = enabled and true or false })
    return enabled and true or false
end

function Settings.visible_tiles()
    local out = {}
    for _, id in ipairs(Settings.tile_order()) do
        if Settings.tile_enabled(id) then
            out[#out + 1] = id
        end
    end
    return out
end

function Settings.show_tile_enabled_dialog(on_changed)
    local dialog
    local buttons = {}
    for _, id in ipairs(Settings.TILE_IDS) do
        local enabled = Settings.tile_enabled(id)
        local label = Settings.TILE_LABEL[id] or id
        local tile_id = id
        buttons[#buttons + 1] = {
            {
                text = string.format("%s  %s", label, enabled and "开" or "关"),
                callback = function()
                    UIManager:close(dialog)
                    Settings.set_tile_enabled(tile_id, not enabled)
                    if on_changed then
                        on_changed()
                    end
                    Settings.show_tile_enabled_dialog(on_changed)
                end,
            },
        }
    end
    dialog = ButtonDialog:new{
        title = "宫格功能卡片",
        title_align = "center",
        use_info_style = false,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Settings.pack_tiles()
    local cols = Settings.grid_cols()
    local rows = Settings.grid_rows()
    local order = Settings.visible_tiles()
    local placed = {}
    local books = {}
    local row, col, used = 0, 0, 0
    local capacity = rows * cols
    local n = #order

    local function skip_rest_of_row()
        if row >= rows then
            return
        end
        if col > 0 and col < cols then
            used = used + (cols - col)
            col = cols
        end
        if col >= cols then
            row = row + 1
            col = 0
        end
    end

    local function fill_row()
        while col < cols and used < capacity and row < rows do
            books[#books + 1] = { row = row, col = col }
            col = col + 1
            used = used + 1
        end
        if col >= cols then
            row = row + 1
            col = 0
        end
    end

    for i, id in ipairs(order) do
        if row >= rows or used >= capacity then
            break
        end
        local remaining_tiles = n - i + 1
        local remaining_cells = capacity - used
        local leftover_for_later = remaining_tiles - 1
        local max_keep = remaining_cells - leftover_for_later
        if max_keep < 1 then
            break
        end
        local preferred = Settings.tile_span(id)
        local span = math.min(preferred, cols, max_keep)
        local remain_row = cols - col
        if span > remain_row then
            local can_wrap = row + 1 < rows
            local skipped = remain_row
            local max_after = (remaining_cells - skipped) - leftover_for_later
            if can_wrap and max_after >= 1 then
                skip_rest_of_row()
                remaining_cells = capacity - used
                max_keep = remaining_cells - leftover_for_later
                if max_keep < 1 then
                    break
                end
                span = math.min(preferred, cols, max_keep)
            else
                span = math.min(span, remain_row, max_keep)
            end
        end
        span = math.max(1, math.min(span, cols - col, max_keep))
        if span < 1 then
            break
        end
        placed[#placed + 1] = { id = id, row = row, col = col, span = span }
        col = col + span
        used = used + span
        if col >= cols then
            row = row + 1
            col = 0
        end
    end
    -- Books start on the first row that has no functional cards.
    if col > 0 then
        skip_rest_of_row()
    end
    while row < rows and used < capacity do
        fill_row()
    end
    return placed, books
end

function Settings.show_tile_menu(id, on_changed)
    if not TILE_ID_SET[id] then
        return
    end
    local cols = Settings.grid_cols()
    local current = Settings.tile_span(id)
    local order = Settings.tile_order()
    local idx = 1
    for i, item in ipairs(order) do
        if item == id then
            idx = i
            break
        end
    end
    local dialog
    local buttons = {}
    local function pick_span(n)
        local label = string.format("%d 格", n)
        if n == current then
            label = label .. "  · 当前"
        end
        return {
            text = label,
            callback = function()
                UIManager:close(dialog)
                local old = Settings.tile_span(id)
                local span = Settings.set_tile_span(id, n)
                if span ~= old and on_changed then
                    on_changed("span", id, span)
                end
            end,
        }
    end
    for n = tile_span_min(id), cols do
        buttons[#buttons + 1] = { pick_span(n) }
    end
    buttons[#buttons + 1] = {
        {
            text = "前移",
            enabled = idx > 1,
            callback = function()
                UIManager:close(dialog)
                Settings.move_tile(id, -1)
                if on_changed then
                    on_changed("move", id, -1)
                end
            end,
        },
        {
            text = "后移",
            enabled = idx < #order,
            callback = function()
                UIManager:close(dialog)
                Settings.move_tile(id, 1)
                if on_changed then
                    on_changed("move", id, 1)
                end
            end,
        },
    }
    dialog = ButtonDialog:new{
        title = Settings.TILE_LABEL[id] or "宫格",
        title_align = "center",
        use_info_style = false,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Settings.first_page_books()
    local _, books = Settings.pack_tiles()
    return #books
end

function Settings.page_books()
    return Settings.grid_rows() * Settings.grid_cols()
end

function Settings.set_grid(rows, cols)
    rows, cols = normalize_grid(rows, cols)
    local data = Settings.load()
    data:saveSetting("grid_rows", rows)
    data:saveSetting("grid_cols", cols)
    data:flush()
    Log.info("settings", "grid", { rows = rows, cols = cols })
    return rows, cols
end

function Settings.show_grid_dialog(on_changed)
    local rows0, cols0 = Settings.grid_size()
    local widget = DoubleSpinWidget:new{
        title_text = "宫格布局",
        info_text = "列数必须大于等于行数。（Tips：在宫格卡片中按可以调整位置和大小）",
        left_text = "行数",
        right_text = "列数",
        left_min = Settings.GRID_ROWS_MIN,
        left_max = math.min(Settings.GRID_ROWS_MAX, cols0),
        left_value = rows0,
        left_default = Settings.GRID_ROWS_DEFAULT,
        left_precision = "%d",
        right_min = math.max(Settings.GRID_COLS_MIN, rows0),
        right_max = Settings.GRID_COLS_MAX,
        right_value = cols0,
        right_default = Settings.GRID_COLS_DEFAULT,
        right_precision = "%d",
        ok_text = "应用",
        cancel_text = "取消",
        ok_always_enabled = true,
        default_text = "恢复默认 4 × 4",
        callback = function(rows, cols)
            local old_rows, old_cols = Settings.grid_rows(), Settings.grid_cols()
            rows, cols = Settings.set_grid(rows, cols)
            if (rows ~= old_rows or cols ~= old_cols) and on_changed then
                on_changed(rows, cols)
            end
        end,
    }
    local super_update = widget.update
    function widget:update(left, right)
        local rows = tonumber(left)
        local cols = tonumber(right)
        if not rows and self.left_widget then
            rows = self.left_widget:getValue()
        end
        if not cols and self.right_widget then
            cols = self.right_widget:getValue()
        end
        rows = rows or self.left_value
        cols = cols or self.right_value
        rows, cols = normalize_grid(rows, cols)
        self.left_min = Settings.GRID_ROWS_MIN
        self.left_max = math.min(Settings.GRID_ROWS_MAX, cols)
        self.right_min = math.max(Settings.GRID_COLS_MIN, rows)
        self.right_max = Settings.GRID_COLS_MAX
        self.left_value = rows
        self.right_value = cols
        super_update(self, rows, cols)
    end
    UIManager:show(widget)
end

function Settings.show_book_title()
    local data = Settings.load()
    local value = data:readSetting("show_book_title")
    if value == false or value == 0 or value == "0" or value == "false" then
        return false
    end
    return true
end

function Settings.set_show_book_title(value)
    value = value and true or false
    local data = Settings.load()
    data:saveSetting("show_book_title", value)
    data:flush()
    Log.info("settings", "show_book_title", { value = value })
    return value
end

-- Base size for grid meta text (maps to former xx_smallinfofont ≈ 18).
function Settings.grid_font_size()
    local data = Settings.load()
    return clamp(
        data:readSetting("grid_font_size"),
        Settings.GRID_FONT_MIN,
        Settings.GRID_FONT_MAX,
        Settings.GRID_FONT_DEFAULT
    )
end

function Settings.set_grid_font_size(value)
    value = clamp(
        value,
        Settings.GRID_FONT_MIN,
        Settings.GRID_FONT_MAX,
        Settings.GRID_FONT_DEFAULT
    )
    local data = Settings.load()
    data:saveSetting("grid_font_size", value)
    data:flush()
    Log.info("settings", "grid_font_size", { value = value })
    return value
end

-- kind: "meta" | "body" | "title"
function Settings.grid_face(kind)
    local Font = require("ui/font")
    local base = Settings.grid_font_size()
    local size = base
    if kind == "body" then
        size = base + 2
    elseif kind == "title" then
        size = base + 6
    end
    return Font:getFace("infofont", size)
end

function Settings.show_grid_font_dialog(on_changed)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = "宫格字号",
        info_text = "调整首页宫格内文字大小（书名、功能卡片等）",
        value = Settings.grid_font_size(),
        value_min = Settings.GRID_FONT_MIN,
        value_max = Settings.GRID_FONT_MAX,
        default_value = Settings.GRID_FONT_DEFAULT,
        value_step = 1,
        value_hold_step = 2,
        precision = "%d",
        ok_text = "应用",
        cancel_text = "取消",
        ok_always_enabled = true,
        default_text = string.format("恢复默认 %d", Settings.GRID_FONT_DEFAULT),
        callback = function(spin)
            local old = Settings.grid_font_size()
            local value = Settings.set_grid_font_size(spin.value)
            if value ~= old and on_changed then
                on_changed()
            end
        end,
    })
end

function Settings.show_book_title_dialog(on_changed)
    show_toggle_dialog(
        "显示书名",
        Settings.show_book_title(),
        Settings.set_show_book_title,
        on_changed
    )
end

function Settings.show_logout_dialog(on_logout)
    local dialog
    dialog = ButtonDialog:new{
        name = "wereadlite_logout",
        title = "退出登录？",
        title_align = "center",
        use_info_style = false,
        buttons = {
            {
                {
                    text = "取消",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "退出",
                    callback = function()
                        UIManager:close(dialog)
                        Settings.set_skill_apikey("")
                        local Session = require("wereadlite.session")
                        Session.clear_auth()
                        Log.info("settings", "logout")
                        if type(on_logout) == "function" then
                            on_logout()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

local function yn(on)
    return on and "开" or "关"
end

local function show_button_dialog(title, rows, name)
    local menu
    local buttons = {}
    for _, row in ipairs(rows or {}) do
        buttons[#buttons + 1] = {
            {
                text = row.text,
                callback = function()
                    UIManager:close(menu)
                    if row.callback then
                        row.callback()
                    end
                end,
            },
        }
    end
    menu = ButtonDialog:new{
        name = name or "wereadlite_settings",
        title = title,
        title_align = "center",
        use_info_style = false,
        buttons = buttons,
    }
    UIManager:show(menu)
end

local function back_row(label, reopen)
    return {
        text = "‹  " .. tostring(label or "返回"),
        callback = reopen,
    }
end

function Settings.show_shelf_menu(on_changed, ctx)
    ctx = ctx or {}
    show_button_dialog("首页布局", {
        back_row("设置", function()
            Settings.show_menu(ctx.on_changed, ctx.on_search, ctx.on_logout)
        end),
        {
            text = string.format("宫格行列   %d × %d", Settings.grid_rows(), Settings.grid_cols()),
            callback = function()
                Settings.show_grid_dialog(on_changed)
            end,
        },
        {
            text = "功能卡片",
            callback = function()
                Settings.show_tile_enabled_dialog(on_changed)
            end,
        },
        {
            text = string.format("显示书名   %s", yn(Settings.show_book_title())),
            callback = function()
                Settings.show_book_title_dialog(on_changed)
            end,
        },
        {
            text = string.format("宫格字号   %d", Settings.grid_font_size()),
            callback = function()
                Settings.show_grid_font_dialog(on_changed)
            end,
        },
        {
            text = string.format("框线圆角   %d", Settings.card_radius()),
            callback = function()
                Settings.show_card_radius_dialog(on_changed)
            end,
        },
    }, "wereadlite_settings_shelf")
end

function Settings.show_reading_menu(on_changed, ctx)
    ctx = ctx or {}
    show_button_dialog("阅读体验", {
        back_row("设置", function()
            Settings.show_menu(ctx.on_changed, ctx.on_search, ctx.on_logout)
        end),
        {
            text = string.format("划线与想法   %s", yn(Settings.load_review_comments())),
            callback = function()
                Settings.show_review_comments_dialog(on_changed)
            end,
        },
        {
            text = string.format("评论头像   %s", yn(Settings.load_review_avatars())),
            callback = function()
                Settings.show_review_avatars_dialog(on_changed)
            end,
        },
        {
            text = string.format("加载进度条   %s", yn(Settings.show_chapter_load_progress())),
            callback = function()
                Settings.show_chapter_load_progress_dialog(on_changed)
            end,
        },
        {
            text = string.format("预加载下一章   %s", yn(Settings.prefetch_next_chapter())),
            callback = function()
                Settings.show_prefetch_next_chapter_dialog(on_changed)
            end,
        },
        {
            text = string.format("图片并发   %d", Settings.image_concurrency()),
            callback = function()
                Settings.show_image_concurrency_dialog()
            end,
        },
        {
            text = string.format("章节分段上限   %d", Settings.max_segments_per_load()),
            callback = function()
                Settings.show_max_segments_per_load_dialog()
            end,
        },
    }, "wereadlite_settings_reading")
end

function Settings.show_discover_menu(ctx)
    ctx = ctx or {}
    local SkillView = require("wereadlite.skill_view")
    show_button_dialog("发现", {
        back_row("设置", function()
            Settings.show_menu(ctx.on_changed, ctx.on_search, ctx.on_logout)
        end),
        {
            text = "书籍搜索",
            callback = function()
                if type(ctx.on_search) == "function" then
                    ctx.on_search()
                else
                    SkillView.show_search()
                end
            end,
        },
        {
            text = "阅读统计",
            callback = function()
                SkillView.show_stats()
            end,
        },
    }, "wereadlite_settings_discover")
end

function Settings.show_menu(on_changed, on_search, on_logout)
    local ctx = {
        on_changed = on_changed,
        on_search = on_search,
        on_logout = on_logout,
    }
    show_button_dialog("设置", {
        {
            text = "首页布局 ›",
            callback = function()
                Settings.show_shelf_menu(on_changed, ctx)
            end,
        },
        {
            text = "阅读体验 ›",
            callback = function()
                Settings.show_reading_menu(on_changed, ctx)
            end,
        },
        {
            text = "发现 ›",
            callback = function()
                Settings.show_discover_menu(ctx)
            end,
        },
        {
            text = "退出登录",
            callback = function()
                Settings.show_logout_dialog(on_logout)
            end,
        },
    }, "wereadlite_settings_root")
end

return Settings
