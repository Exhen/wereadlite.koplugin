local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local Log = require("wereadlite.log")
local Skill = require("wereadlite.skill")

local SkillView = {}

local MODE_LABEL = {
    weekly = "本周",
    monthly = "本月",
    annually = "今年",
    overall = "总计",
}

local function show_error(status, err)
    local text = "请求失败"
    if status == "auth_expired" then
        text = "登录已过期，请重新扫码"
    elseif status == "offline" then
        text = "网络不可用"
    elseif err and tostring(err) ~= "" then
        local msg = tostring(err)
        if not msg:find("^%s*<") and #msg < 80 then
            text = msg
        end
    end
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 2,
    })
end

local function with_busy(text, work)
    local info = InfoMessage:new{ text = text }
    UIManager:show(info)
    local function done(ok, result, status, err)
        UIManager:close(info)
        if not ok then
            Log.warn("skill_view", "work", { err = tostring(result) })
            UIManager:show(InfoMessage:new{
                text = "出错了，请稍后再试",
                timeout = 2,
            })
            return
        end
        if result == false then
            show_error(status, err)
        end
    end
    local ok, err = pcall(work, function(result, status, err)
        done(true, result, status, err)
    end)
    if not ok then
        done(false, err)
    end
end

local function fmt_rating(value)
    value = tonumber(value) or 0
    if value <= 0 then
        return ""
    end
    if value > 10 then
        return string.format("%.1f", value / 10)
    end
    return string.format("%.1f", value)
end

local function fmt_seconds(sec)
    sec = math.floor(tonumber(sec) or 0)
    if sec < 0 then
        sec = 0
    end
    local hours = math.floor(sec / 3600)
    local minutes = math.floor((sec % 3600) / 60)
    if hours > 0 and minutes > 0 then
        return string.format("%d 小时 %d 分钟", hours, minutes)
    end
    if hours > 0 then
        return string.format("%d 小时", hours)
    end
    if minutes > 0 then
        return string.format("%d 分钟", minutes)
    end
    if sec > 0 then
        return string.format("%d 秒", sec)
    end
    return "0 分钟"
end

local function show_text(title, text)
    UIManager:show(TextViewer:new{
        title = title,
        text = text,
        justified = false,
        alignment = "left",
        auto_para_direction = false,
    })
end

local function show_book_list(result, opts)
    opts = type(opts) == "table" and opts or {}
    local books = result.books or {}
    if #books == 0 then
        UIManager:show(InfoMessage:new{
            text = opts.empty_message or "暂无相关图书",
            timeout = 2,
        })
        return
    end
    local dialog
    local function row_for(book)
        local subtitle = book.author or ""
        local rating = fmt_rating(book.rating)
        if rating ~= "" then
            subtitle = subtitle ~= "" and (subtitle .. "  " .. rating) or rating
        end
        local label = book.title or ""
        if subtitle ~= "" then
            label = label .. "\n" .. subtitle
        end
        if (book.soldout or 0) == 1 then
            label = label .. "  [下架]"
        end
        return {
            {
                text = label,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    local BookDetail = require("wereadlite.book_detail")
                    BookDetail.show(book)
                end,
            },
        }
    end
    local buttons = {}
    for _, book in ipairs(books) do
        buttons[#buttons + 1] = row_for(book)
    end
    dialog = ButtonDialog:new{
        title = opts.title or string.format("为您找到 %d 本", #books),
        title_align = "center",
        use_info_style = false,
        rows_per_page = 6,
        buttons = buttons,
    }
    UIManager:show(dialog)
    if result.upgrade_info then
        UIManager:show(InfoMessage:new{
            text = "Skill 接口有更新，部分功能可能异常",
            timeout = 2,
        })
    end
end

local function show_search_results(result)
    show_book_list(result, {
        title = string.format("为您找到 %d 本", #(result.books or {})),
        empty_message = string.format("没有找到与“%s”相关的结果", result.keyword or ""),
    })
end

function SkillView.show_book_detail(book)
    if type(book) ~= "table" then
        return
    end
    local BookDetail = require("wereadlite.book_detail")
    BookDetail.show(book)
end

function SkillView.run_search(keyword, on_result)
    keyword = tostring(keyword or ""):match("^%s*(.-)%s*$") or ""
    if keyword == "" then
        UIManager:show(InfoMessage:new{
            text = "请输入关键词",
            timeout = 1.5,
        })
        return
    end
    with_busy("正在搜索…", function(finish)
        Skill.search_async(keyword, { scope = 10, count = 10 }, function(result, status, err)
            if not result then
                finish(false, status, err)
                return
            end
            if type(on_result) == "function" then
                on_result(result)
            else
                show_search_results(result)
            end
            finish(true)
        end)
    end)
end

function SkillView.show_search(on_search)
    local dialog
    dialog = InputDialog:new{
        title = "搜索书籍",
        input_hint = "书名、作者或 ISBN",
        buttons = {
            {
                {
                    text = "取消",
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "搜索",
                    is_enter_default = true,
                    callback = function()
                        local keyword = dialog:getInputText()
                        UIManager:close(dialog)
                        if type(on_search) == "function" then
                            on_search(keyword)
                        else
                            SkillView.run_search(keyword)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function as_list(value)
    if type(value) ~= "table" then
        return {}
    end
    if value[1] ~= nil then
        return value
    end
    local list = {}
    for _, item in pairs(value) do
        list[#list + 1] = item
    end
    return list
end

local function format_stats(mode, data)
    data = type(data) == "table" and data or {}
    local lines = { (MODE_LABEL[mode] or "本月") .. "阅读" }
    lines[#lines + 1] = ""
    lines[#lines + 1] = "总时长    " .. fmt_seconds(data.totalReadTime)
    if data.readDays ~= nil then
        lines[#lines + 1] = "阅读天数  " .. tostring(data.readDays) .. " 天"
    end
    if data.dayAverageReadTime ~= nil then
        lines[#lines + 1] = "日均时长  " .. fmt_seconds(data.dayAverageReadTime)
    end
    local compare = tonumber(data.compare)
    if compare then
        local pct = math.floor(compare * 100 + (compare >= 0 and 0.5 or -0.5))
        if pct > 0 then
            lines[#lines + 1] = "较上期    日均增长 " .. pct .. "%"
        elseif pct < 0 then
            lines[#lines + 1] = "较上期    日均下降 " .. math.abs(pct) .. "%"
        end
    end
    if data.preferTimeWord and data.preferTimeWord ~= "" then
        lines[#lines + 1] = "偏好时段  " .. tostring(data.preferTimeWord)
    end
    if data.preferCategoryWord and data.preferCategoryWord ~= "" then
        lines[#lines + 1] = tostring(data.preferCategoryWord)
    end
    if data.rank and data.rank.text and data.rank.text ~= "" then
        lines[#lines + 1] = tostring(data.rank.text)
    end

    local stats = as_list(data.readStat)
    if #stats > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "阅读统计"
        for _, item in ipairs(stats) do
            if type(item) == "table" then
                local name = tostring(item.stat or "")
                local counts = tostring(item.counts or "")
                if name ~= "" and counts ~= "" then
                    lines[#lines + 1] = name .. "  " .. counts
                end
            end
        end
    end

    local longest = as_list(data.readLongest)
    if #longest > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "阅读时长排行"
        for i, item in ipairs(longest) do
            if type(item) == "table" then
                local book = type(item.book) == "table" and item.book or {}
                local album = type(item.albumInfo) == "table" and item.albumInfo or {}
                local title = book.title or album.title or album.name or "未命名"
                lines[#lines + 1] = string.format("%d. %s  %s", i, title, fmt_seconds(item.readTime))
            end
        end
    end

    local categories = as_list(data.preferCategory)
    if #categories > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "阅读偏好"
        for _, item in ipairs(categories) do
            if type(item) == "table" then
                local name = item.categoryTitle or item.parentCategoryTitle
                if name and name ~= "" then
                    local extra = {}
                    if item.readingCount then
                        extra[#extra + 1] = tostring(item.readingCount) .. " 本"
                    end
                    if item.readingTime then
                        extra[#extra + 1] = fmt_seconds(item.readingTime)
                    end
                    local suffix = #extra > 0 and ("  " .. table.concat(extra, " · ")) or ""
                    lines[#lines + 1] = tostring(name) .. suffix
                end
            end
        end
    end

    local authors = as_list(data.preferAuthor)
    if #authors > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "偏好作者"
        for _, item in ipairs(authors) do
            if type(item) == "table" then
                local name = tostring(item.name or "")
                if name ~= "" then
                    local extra = {}
                    if item.count then
                        extra[#extra + 1] = tostring(item.count) .. " 本"
                    end
                    if item.readTime and item.readTime ~= "" then
                        extra[#extra + 1] = tostring(item.readTime)
                    end
                    local suffix = #extra > 0 and ("  " .. table.concat(extra, " · ")) or ""
                    lines[#lines + 1] = name .. suffix
                end
            end
        end
    end

    return table.concat(lines, "\n")
end

function SkillView.run_stats(mode)
    mode = mode or "monthly"
    with_busy("正在获取阅读统计…", function(finish)
        Skill.readdata_async(mode, function(data, status, err)
            if not data then
                finish(false, status, err)
                return
            end
            show_text((MODE_LABEL[mode] or "阅读") .. "阅读", format_stats(mode, data))
            if data.upgrade_info then
                UIManager:show(InfoMessage:new{
                    text = "Skill 接口有更新，部分功能可能异常",
                    timeout = 2,
                })
            end
            finish(true)
        end)
    end)
end

function SkillView.show_stats()
    local dialog
    local function pick(mode, label)
        return {
            text = label,
            callback = function()
                UIManager:close(dialog)
                SkillView.run_stats(mode)
            end,
        }
    end
    dialog = ButtonDialog:new{
        title = "阅读统计",
        title_align = "center",
        use_info_style = false,
        buttons = {
            { pick("weekly", "本周"), pick("monthly", "本月") },
            { pick("annually", "今年"), pick("overall", "总计") },
        },
    }
    UIManager:show(dialog)
end

return SkillView
