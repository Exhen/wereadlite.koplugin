local ButtonDialog = require("ui/widget/buttondialog")
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

Settings.TILE_IDS = { "clock", "recent", "user", "text_stats", "chart_stats" }

Settings.TILE_LABEL = {
    recent = "上次阅读",
    user = "账号",
    clock = "时钟",
    text_stats = "文字统计",
    chart_stats = "图表统计",
}

local TILE_SPAN_KEY = {
    recent = "last_read_span",
    user = "user_span",
    clock = "clock_span",
    text_stats = "text_stats_span",
    chart_stats = "chart_stats_span",
}

local TILE_ID_SET = {
    recent = true,
    user = true,
    clock = true,
    text_stats = true,
    chart_stats = true,
}

-- Default for 4×5: 时钟1 + 上次阅读3 + 账号1 | 文字统计2 + 图表统计3
local TILE_SPAN_DEFAULT = {
    clock = 1,
    recent = 3,
    user = 1,
    text_stats = 2,
    chart_stats = 3,
}

function Settings.default_tile_span(id)
    local cols = Settings.grid_cols()
    local preferred = TILE_SPAN_DEFAULT[id] or 1
    return math.max(1, math.min(preferred, cols))
end

function Settings.tile_span(id)
    local cols = Settings.grid_cols()
    local key = TILE_SPAN_KEY[id]
    if not key then
        return 1
    end
    local data = Settings.load()
    return clamp(data:readSetting(key), 1, cols, Settings.default_tile_span(id))
end

function Settings.set_tile_span(id, span)
    local key = TILE_SPAN_KEY[id]
    if not key then
        return Settings.tile_span(id)
    end
    local cols = Settings.grid_cols()
    span = clamp(span, 1, cols, Settings.default_tile_span(id))
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
    for n = 1, cols do
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
    local dialog
    local current = Settings.show_book_title()
    local function pick(value, label)
        local text = label
        if current == value then
            text = text .. "  · 当前"
        end
        return {
            text = text,
            callback = function()
                UIManager:close(dialog)
                local old = Settings.show_book_title()
                Settings.set_show_book_title(value)
                if old ~= value and on_changed then
                    on_changed()
                end
            end,
        }
    end
    dialog = ButtonDialog:new{
        title = "宫格布局显示书名",
        title_align = "center",
        use_info_style = false,
        buttons = {
            { pick(true, "是"), pick(false, "否") },
        },
    }
    UIManager:show(dialog)
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

function Settings.show_menu(on_changed, on_search, on_logout)
    local SkillView = require("wereadlite.skill_view")
    local menu
    menu = ButtonDialog:new{
        name = "wereadlite_settings",
        title = "设置",
        title_align = "center",
        use_info_style = false,
        buttons = {
            {
                {
                    text = string.format("宫格布局  %d × %d", Settings.grid_rows(), Settings.grid_cols()),
                    callback = function()
                        UIManager:close(menu)
                        Settings.show_grid_dialog(on_changed)
                    end,
                },
            },
            {
                {
                    text = "功能卡片",
                    callback = function()
                        UIManager:close(menu)
                        Settings.show_tile_enabled_dialog(on_changed)
                    end,
                },
            },
            {
                {
                    text = string.format("宫格显示书名  %s", Settings.show_book_title() and "是" or "否"),
                    callback = function()
                        UIManager:close(menu)
                        Settings.show_book_title_dialog(on_changed)
                    end,
                },
            },
            {
                {
                    text = string.format("宫格字号  %d", Settings.grid_font_size()),
                    callback = function()
                        UIManager:close(menu)
                        Settings.show_grid_font_dialog(on_changed)
                    end,
                },
            },
            {
                {
                    text = string.format("框线圆角  %d", Settings.card_radius()),
                    callback = function()
                        UIManager:close(menu)
                        Settings.show_card_radius_dialog(on_changed)
                    end,
                },
            },
            {
                {
                    text = string.format("图片并发  %d", Settings.image_concurrency()),
                    callback = function()
                        UIManager:close(menu)
                        Settings.show_image_concurrency_dialog()
                    end,
                },
            },
            {
                {
                    text = "书籍搜索",
                    callback = function()
                        UIManager:close(menu)
                        if type(on_search) == "function" then
                            on_search()
                        else
                            SkillView.show_search()
                        end
                    end,
                },
            },
            {
                {
                    text = "阅读统计",
                    callback = function()
                        UIManager:close(menu)
                        SkillView.show_stats()
                    end,
                },
            },
            {
                {
                    text = "退出登录",
                    callback = function()
                        UIManager:close(menu)
                        Settings.show_logout_dialog(on_logout)
                    end,
                },
            },
        },
    }
    UIManager:show(menu)
end

return Settings
