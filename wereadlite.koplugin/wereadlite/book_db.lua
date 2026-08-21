local Json = require("wereadlite.json")
local Log = require("wereadlite.log")

local BookDb = {}
BookDb.FILE_NAME = "books.sqlite3"

local function as_text(value)
    if value == nil or type(value) == "boolean" then
        return ""
    end
    if type(value) == "table" then
        return tostring(value.title or value.name or "")
    end
    return tostring(value)
end

local function as_int(value)
    return tonumber(value) or 0
end

local function mkdir(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs and lfs.attributes(path, "mode") ~= "directory" then
        lfs.mkdir(path)
    end
end

function BookDb.path()
    local dir = require("wereadlite.paths").data_dir()
    mkdir(dir)
    return dir .. "/" .. BookDb.FILE_NAME
end

local function open()
    local ok_mod, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_mod or not SQ3 then
        return nil, "sqlite unavailable"
    end
    local ok_open, conn = pcall(SQ3.open, BookDb.path())
    if not ok_open or not conn then
        return nil, conn or "sqlite open failed"
    end
    pcall(conn.exec, conn, "PRAGMA busy_timeout=5000;")
    pcall(conn.exec, conn, "PRAGMA journal_mode=TRUNCATE;")
    pcall(conn.exec, conn, "PRAGMA synchronous=NORMAL;")
    local ok_schema, schema_err = pcall(conn.exec, conn, [[
            CREATE TABLE IF NOT EXISTS book_info (
                book_id TEXT PRIMARY KEY NOT NULL,
                title TEXT,
                author TEXT,
                translator TEXT,
                cover TEXT,
                isbn TEXT,
                publisher TEXT,
                format TEXT,
                intro TEXT,
                category TEXT,
                total_words INTEGER,
                json TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS last_read (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                book_id TEXT,
                title TEXT,
                author TEXT,
                cover TEXT,
                reader_param TEXT,
                chapter_title TEXT,
                json TEXT,
                updated_at INTEGER NOT NULL
            );
        ]])
    if not ok_schema then
        pcall(conn.close, conn)
        return nil, schema_err
    end
    return conn
end

function BookDb.save(info)
    if type(info) ~= "table" then
        return nil, "invalid bookInfo"
    end
    local book_id = as_text(info.bookId or info.book_id)
    if book_id == "" or book_id == "nil" then
        return nil, "missing bookId"
    end
    local encoded, encode_err = Json.encode(info)
    if not encoded then
        encoded = "{}"
        Log.warn("bookdb", "json", { err = encode_err })
    end
    local conn, err = open()
    if not conn then
        return nil, err
    end
    local ok, result = pcall(function()
        local stmt = conn:prepare([[
            INSERT OR REPLACE INTO book_info(
                book_id, title, author, translator, cover, isbn, publisher,
                format, intro, category, total_words, json, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        stmt:bind(
            book_id,
            as_text(info.title),
            as_text(info.author),
            as_text(info.translator),
            as_text(info.cover),
            as_text(info.isbn),
            as_text(info.publisher),
            as_text(info.format),
            as_text(info.intro),
            as_text(info.category),
            as_int(info.totalWords or info.total_words),
            encoded,
            os.time()
        ):step()
        stmt:close()
        return true
    end)
    pcall(conn.close, conn)
    if not ok then
        Log.warn("bookdb", "save", { err = result })
        return nil, result
    end
    Log.dbg("bookdb", "saved", { book_id = book_id, title = as_text(info.title) })
    return true
end

function BookDb.get(book_id)
    book_id = as_text(book_id)
    if book_id == "" then
        return nil
    end
    local conn, err = open()
    if not conn then
        return nil, err
    end
    local ok, result = pcall(function()
        local stmt = conn:prepare("SELECT json FROM book_info WHERE book_id = ? LIMIT 1")
        local row = stmt:bind(book_id):step()
        stmt:close()
        if not row or not row[1] then
            return nil
        end
        return Json.decode(row[1])
    end)
    pcall(conn.close, conn)
    if not ok then
        return nil, result
    end
    return result
end

function BookDb.save_last_read(book, extra)
    book = type(book) == "table" and book or {}
    extra = extra or {}
    local info = type(extra.book_info) == "table" and extra.book_info or {}
    local row = {
        bookId = book.bookId or info.bookId or info.book_id,
        title = book.title or info.title,
        author = book.author or info.author,
        cover = book.cover or info.cover,
        reader_param = book.reader_param,
        chapter_title = extra.chapter_title or (book.chapter_title or ""),
    }
    local book_id = as_text(row.bookId)
    if book_id == "" or book_id == "nil" then
        return nil, "missing bookId"
    end
    local encoded = Json.encode(row) or "{}"
    local conn, err = open()
    if not conn then
        return nil, err
    end
    local ok, result = pcall(function()
        local stmt = conn:prepare([[
            INSERT OR REPLACE INTO last_read(
                id, book_id, title, author, cover, reader_param, chapter_title, json, updated_at
            ) VALUES(1, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        stmt:bind(
            book_id,
            as_text(row.title),
            as_text(row.author),
            as_text(row.cover),
            as_text(row.reader_param),
            as_text(row.chapter_title),
            encoded,
            os.time()
        ):step()
        stmt:close()
        return true
    end)
    pcall(conn.close, conn)
    if not ok then
        Log.warn("bookdb", "last_read", { err = result })
        return nil, result
    end
    return true
end

function BookDb.get_last_read()
    local conn, err = open()
    if not conn then
        return nil, err
    end
    local ok, result = pcall(function()
        local stmt = conn:prepare([[
            SELECT book_id, title, author, cover, reader_param, chapter_title
            FROM last_read WHERE id = 1 LIMIT 1
        ]])
        local row = stmt:step()
        stmt:close()
        if not row or not row[1] then
            return nil
        end
        return {
            bookId = as_text(row[1]),
            title = as_text(row[2]),
            author = as_text(row[3]),
            cover = as_text(row[4]),
            reader_param = as_text(row[5]),
            chapter_title = as_text(row[6]),
        }
    end)
    pcall(conn.close, conn)
    if not ok then
        return nil, result
    end
    if result and result.bookId ~= "" then
        return result
    end
end

return BookDb
