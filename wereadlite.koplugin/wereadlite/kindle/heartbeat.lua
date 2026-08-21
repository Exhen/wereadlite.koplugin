local UIManager = require("ui/uimanager")
local Config = require("wereadlite.config")
local Client = require("wereadlite.kindle.client")
local Json = require("wereadlite.json")
local Log = require("wereadlite.log")

local Heartbeat = {
    INTERVAL = 30,
}

local generation = 0
local task
local last_report
local enc_cache_path
local enc_cache_text
pcall(math.randomseed, os.time())

local function now_seconds()
    local ok, socket = pcall(require, "socket")
    if ok and socket and type(socket.gettime) == "function" then
        return socket.gettime()
    end
    return os.time()
end

local function utf8_len(text)
    text = tostring(text or "")
    local n, i = 0, 1
    while i <= #text do
        local b = text:byte(i)
        if not b then
            break
        elseif b < 128 then
            i = i + 1
        elseif b < 224 then
            i = i + 2
        elseif b < 240 then
            i = i + 3
        else
            i = i + 4
        end
        n = n + 1
    end
    return n
end

local function utf8_sub(text, from, to)
    text = tostring(text or "")
    from = math.max(1, tonumber(from) or 1)
    to = tonumber(to) or from
    local n, i, start_i = 0, 1, nil
    local out_to = to
    while i <= #text do
        n = n + 1
        local b = text:byte(i)
        local step = 1
        if b >= 240 then
            step = 4
        elseif b >= 224 then
            step = 3
        elseif b >= 192 then
            step = 2
        end
        if n == from then
            start_i = i
        end
        if n == out_to then
            if start_i then
                return text:sub(start_i, i + step - 1)
            end
            return ""
        end
        i = i + step
    end
    if start_i then
        return text:sub(start_i)
    end
    return ""
end

local function plain_text(html)
    html = tostring(html or "")
    html = html:gsub("<script.-</script>", "")
    html = html:gsub("<style.-</style>", "")
    html = html:gsub("<[^>]+>", "")
    html = html:gsub("&nbsp;", " "):gsub("&#160;", " ")
    html = html:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    html = html:gsub("%s+", "")
    return html
end

local function enc_text(state)
    local path = state and state.html_enc_path
    if not path or path == "" then
        return ""
    end
    if enc_cache_path == path and enc_cache_text then
        return enc_cache_text
    end
    local file = io.open(path, "rb")
    if not file then
        return ""
    end
    local html = file:read("*a") or ""
    file:close()
    enc_cache_path = path
    enc_cache_text = plain_text(html)
    return enc_cache_text
end

local function chapter_progress()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok and ReaderUI and ReaderUI.instance
    if not ui then
        return 0
    end
    local footer = ui.view and ui.view.footer
    local percent = footer and tonumber(footer.percent_finished)
    if percent then
        return percent
    end
    if ui.document and ui.document.getCurrentPage and ui.document.getPageCount then
        local page = tonumber(ui.document:getCurrentPage()) or 1
        local pages = tonumber(ui.document:getPageCount()) or 1
        if pages > 0 then
            return page / pages
        end
    end
    return 0
end

local function snippet(text, offset)
    local len = utf8_len(text)
    if len <= 0 then
        return ""
    end
    offset = math.max(0, math.min(len - 1, tonumber(offset) or 0))
    local start = offset + 1
    local piece = utf8_sub(text, start, start + 17)
    if piece == "" then
        piece = utf8_sub(text, 1, 18)
    end
    return piece
end

function Heartbeat.payload(state, reading_seconds)
    state = state or Heartbeat.state
    if type(state) ~= "table" then
        return nil, "no state"
    end
    local book_id = tostring(state.book_id or "")
    local uid = tonumber(state.cur and state.cur.uid) or tostring(state.cur and state.cur.uid or "")
    local idx = tonumber(state.cur and state.cur.idx) or 0
    local token = tostring(state.token or "")
    if book_id == "" or book_id == "nil" or token == "" then
        return nil, "missing bookread context"
    end
    local percent = chapter_progress()
    if percent < 0 then
        percent = 0
    elseif percent > 1 then
        percent = 1
    end
    local text = enc_text(state)
    local chars = utf8_len(text)
    local offset = math.floor(percent * math.max(0, chars - 1) + 0.5)
    local now = now_seconds()
    local ts = math.floor(now * 1000)
    local ct = math.floor(now)
    local rt = math.max(1, math.floor(tonumber(reading_seconds) or Heartbeat.INTERVAL))
    return {
        b = book_id,
        c = uid,
        ci = idx,
        co = offset,
        sm = snippet(text, offset),
        pr = math.floor(percent * 100 + 0.5),
        rt = rt,
        ts = ts,
        rn = math.random(1, 999),
        tk = token,
        ct = ct,
    }
end

function Heartbeat.report(reading_seconds)
    local payload, err = Heartbeat.payload(Heartbeat.state, reading_seconds)
    if not payload then
        Log.dbg("heartbeat", "skip", { err = err })
        return nil, err
    end
    local body, encode_err = Json.encode(payload)
    if not body then
        Log.warn("heartbeat", "json", { err = encode_err })
        return nil, encode_err
    end
    local referer = Heartbeat.state and Heartbeat.state.url or Config.READER_URL
    local _, status, detail = Client.request({
        url = Config.BOOKREAD_URL,
        method = "POST",
        body = body,
        origin = Config.ORIGIN,
        referer = referer,
        accept = "*/*",
        timeout = 10,
    })
    if status ~= "ok" then
        Log.warn("heartbeat", "request", { status = status, err = detail })
        return nil, status, detail
    end
    Log.dbg("heartbeat", "ok", {
        book_id = payload.b,
        uid = payload.c,
        rt = payload.rt,
        pr = payload.pr,
        co = payload.co,
    })
    return true
end

local function schedule(my_gen)
    local function tick()
        if my_gen ~= generation then
            return
        end
        pcall(Heartbeat.report, Heartbeat.INTERVAL)
        last_report = now_seconds()
        if my_gen ~= generation then
            return
        end
        task = tick
        UIManager:scheduleIn(Heartbeat.INTERVAL, tick)
    end
    task = tick
    UIManager:scheduleIn(Heartbeat.INTERVAL, tick)
end

function Heartbeat.stop(flush)
    local elapsed = last_report and (now_seconds() - last_report) or 0
    local state = Heartbeat.state
    Log.dbg("heartbeat", "stop", { flush = flush == true, elapsed = elapsed })
    generation = generation + 1
    if task then
        UIManager:unschedule(task)
        task = nil
    end
    if flush and state and elapsed >= 5 then
        Heartbeat.state = state
        pcall(Heartbeat.report, elapsed)
    end
    Heartbeat.state = nil
    last_report = nil
    enc_cache_path = nil
    enc_cache_text = nil
end

function Heartbeat.start(state)
    Heartbeat.stop(true)
    if type(state) ~= "table" or tostring(state.token or "") == "" then
        return
    end
    Heartbeat.state = state
    last_report = now_seconds()
    schedule(generation)
    Log.dbg("heartbeat", "start", {
        book_id = state.book_id,
        uid = state.cur and state.cur.uid,
        has_token = state.token ~= nil and state.token ~= "",
    })
end

return Heartbeat
