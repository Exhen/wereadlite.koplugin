local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Log = require("wereadlite.log")
local Skill = require("wereadlite.skill")
local Shelf = require("wereadlite.kindle.shelf")

local BookDetail = {}

local function merge_book(base, extra)
    base = type(base) == "table" and base or {}
    extra = type(extra) == "table" and extra or {}
    local out = {}
    for k, v in pairs(base) do
        out[k] = v
    end
    for k, v in pairs(extra) do
        if v ~= nil and v ~= "" and v ~= 0 then
            out[k] = v
        end
    end
    return out
end

function BookDetail.resolve_owned(book)
    book = type(book) == "table" and book or {}
    local book_id = tostring(book.bookId or "")
    if book_id == "" then
        return book
    end
    for _, owned in ipairs(Shelf.books or {}) do
        if tostring(owned.bookId or "") == book_id then
            return merge_book(book, owned)
        end
    end
    return book
end

function BookDetail.enrich_reader_param(book)
    book = type(book) == "table" and book or {}
    if (not book.reader_param or book.reader_param == "") and book.reader_url and book.reader_url ~= "" then
        local bc = book.reader_url:match("[?&]v=([%w_%-]+)")
        if bc and bc ~= "" then
            book.reader_param = bc
        end
    end
    return book
end

function BookDetail.can_read(book)
    book = BookDetail.enrich_reader_param(BookDetail.resolve_owned(book))
    return book.reader_param and book.reader_param ~= ""
end

function BookDetail.start_reading(book)
    book = BookDetail.enrich_reader_param(BookDetail.resolve_owned(book))
    local Reading = require("wereadlite.reading")
    if book.reader_param and book.reader_param ~= "" then
        Reading.open_book(book)
        return true
    end
    if book.reader_url and book.reader_url ~= "" then
        Reading.open_url(book.reader_url, book, { resume = true })
        return true
    end
    UIManager:show(InfoMessage:new{
        text = "暂无法打开此书",
        timeout = 2,
    })
    return false
end

local function show_error(status, err)
    local text = "加载详情失败"
    if status == "auth_expired" then
        text = "登录已过期，请重新登录"
    elseif status == "offline" then
        text = "网络不可用"
    elseif err and tostring(err) ~= "" and #tostring(err) < 60 then
        text = tostring(err)
    end
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 2,
    })
end

function BookDetail.show(book)
    if type(book) ~= "table" then
        return
    end
    book = BookDetail.resolve_owned(book)
    local book_id = tostring(book.bookId or "")
    local dialog
    local fetch_gen = 0

    local function open_dialog(full_book)
        full_book = BookDetail.enrich_reader_param(BookDetail.resolve_owned(full_book))
        if dialog and not dialog._closed and type(dialog.update_book) == "function" then
            dialog:update_book(full_book)
            return
        end
        if dialog and dialog._closed then
            dialog = nil
        end
        local BookDetailDialog = require("wereadlite.book_detail_dialog")
        dialog = BookDetailDialog:new{
            book = full_book,
            on_close_callback = function()
                fetch_gen = fetch_gen + 1
                dialog = nil
            end,
        }
        UIManager:show(dialog)
    end

    if book.title and book.title ~= "" then
        open_dialog(book)
    end

    if book_id == "" then
        if not dialog then
            open_dialog(book)
        end
        return
    end

    fetch_gen = fetch_gen + 1
    local gen = fetch_gen
    local busy
    if not dialog then
        busy = InfoMessage:new{ text = "正在加载详情…" }
        UIManager:show(busy)
    end

    Skill.book_info_async(book_id, function(data, status, err)
        if gen ~= fetch_gen then
            if busy then
                UIManager:close(busy)
            end
            return
        end
        if busy then
            UIManager:close(busy)
            busy = nil
        end
        -- Only abort when an existing dialog was closed; busy-only path has
        -- dialog == nil and must still open after a successful fetch.
        if dialog and dialog._closed then
            dialog = nil
            return
        end
        if data then
            open_dialog(merge_book(book, data))
            return
        end
        if dialog and not dialog._closed then
            Log.warn("book_detail", "fetch_failed_keep_local", { book_id = book_id, status = status })
            return
        end
        if book.title and book.title ~= "" then
            Log.warn("book_detail", "fallback_local", { book_id = book_id, status = status })
            open_dialog(book)
            return
        end
        show_error(status, err)
    end)
end

return BookDetail
