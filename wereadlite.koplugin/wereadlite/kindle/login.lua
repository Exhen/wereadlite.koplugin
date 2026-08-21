local Config = require("wereadlite.config")
local CookieStore = require("wereadlite.cookie_store")
local Http = require("wereadlite.async_http")
local Json = require("wereadlite.json")
local Log = require("wereadlite.log")

local Login = {}

local CONFIRM_PREFIX = "https://weread.qq.com/web/confirm?pf=2&uid="
-- getlogininfo is a server-side long-poll (~55s) that returns credentials when
-- the QR is confirmed, or {"scan":0} when the ticket expires. Short client
-- timeouts create gaps with no waiter and drop the first successful scan.
local WAIT_SECONDS = 60
local INFO_TIMEOUT = 58
local INFO_TRIES = 2
local INFO_RETRY_DELAY = 0.3

local B64 = {
    ["A"] = 0, ["B"] = 1, ["C"] = 2, ["D"] = 3, ["E"] = 4, ["F"] = 5, ["G"] = 6, ["H"] = 7,
    ["I"] = 8, ["J"] = 9, ["K"] = 10, ["L"] = 11, ["M"] = 12, ["N"] = 13, ["O"] = 14, ["P"] = 15,
    ["Q"] = 16, ["R"] = 17, ["S"] = 18, ["T"] = 19, ["U"] = 20, ["V"] = 21, ["W"] = 22, ["X"] = 23,
    ["Y"] = 24, ["Z"] = 25, ["a"] = 26, ["b"] = 27, ["c"] = 28, ["d"] = 29, ["e"] = 30, ["f"] = 31,
    ["g"] = 32, ["h"] = 33, ["i"] = 34, ["j"] = 35, ["k"] = 36, ["l"] = 37, ["m"] = 38, ["n"] = 39,
    ["o"] = 40, ["p"] = 41, ["q"] = 42, ["r"] = 43, ["s"] = 44, ["t"] = 45, ["u"] = 46, ["v"] = 47,
    ["w"] = 48, ["x"] = 49, ["y"] = 50, ["z"] = 51, ["0"] = 52, ["1"] = 53, ["2"] = 54, ["3"] = 55,
    ["4"] = 56, ["5"] = 57, ["6"] = 58, ["7"] = 59, ["8"] = 60, ["9"] = 61, ["+"] = 62, ["/"] = 63,
}

local function url_encode(text)
    return (tostring(text or ""):gsub("([^%w%-_%.~])", function(ch)
        return string.format("%%%02X", string.byte(ch))
    end))
end

local function decode_json(text)
    local data, err = Json.decode(tostring(text or ""))
    if type(data) ~= "table" then
        return nil, err or "invalid json"
    end
    return data
end

local function decode_base64(text)
    text = tostring(text or ""):gsub("%s+", "")
    local ok, mime = pcall(require, "mime")
    if ok and mime and type(mime.unb64) == "function" then
        local out = mime.unb64(text)
        if type(out) == "string" and #out > 32 then
            return out
        end
    end
    local bytes = {}
    local acc, bits = 0, 0
    for i = 1, #text do
        local ch = text:sub(i, i)
        if ch == "=" then
            break
        end
        local v = B64[ch]
        if v then
            acc = acc * 64 + v
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                bytes[#bytes + 1] = string.char(math.floor(acc / (2 ^ bits)) % 256)
                acc = acc % (2 ^ bits)
            end
        end
    end
    return table.concat(bytes)
end

local function login_dir()
    return require("wereadlite.paths").login_dir()
end

local function kindle_opts(extra)
    extra = extra or {}
    extra.referer = extra.referer or Config.LOGIN_URL
    extra.origin = extra.origin or Config.ORIGIN
    extra.user_agent = extra.user_agent or Config.KINDLE_UA
    return extra
end

local Session = {
    gen = 0,
    jobs = {},
}

local function alive(gen)
    return gen == Session.gen
end

local function track(job)
    if job then
        Session.jobs[#Session.jobs + 1] = job
    end
    return job
end

function Login.cancel()
    Session.gen = (Session.gen or 0) + 1
    for i = 1, #Session.jobs do
        Http.cancel(Session.jobs[i])
    end
    Session.jobs = {}
end

function Login.fingerprint()
    local existing = CookieStore.get("wr_fp")
    if existing and existing ~= "" then
        return existing
    end
    local seed = tostring(Config.KINDLE_UA or "") .. tostring(os.time())
    local h = 2166136261
    for i = 1, #seed do
        h = (h * 16777619 + seed:byte(i)) % 4294967296
    end
    local fp = tostring(h)
    CookieStore.set("wr_fp", fp, "login")
    return fp
end

function Login.cgi_key()
    if not Login._rng_seeded then
        Login._rng_seeded = true
        pcall(math.randomseed, os.time() + (os.clock() * 1000000))
    end
    return tostring(math.random(0, 999))
end

local function save_qr(b64)
    local bin = decode_base64(b64)
    if type(bin) ~= "string" or #bin < 32 then
        return nil, "qrcode decode failed"
    end
    local dest = login_dir() .. "/qr.png"
    local tmp = dest .. ".tmp"
    local file, err = io.open(tmp, "wb")
    if not file then
        return nil, err or "qr write failed"
    end
    file:write(bin)
    file:close()
    os.remove(dest)
    os.rename(tmp, dest)
    return dest
end

function Login.fetch_qr(on_done, on_uid)
    Login.cancel()
    local gen = Session.gen
    if not Http.available() then
        on_done("curl missing")
        return
    end
    Login.fingerprint()
    track(Http.request(kindle_opts({
        url = Config.LOGIN_GETUID_URL,
        accept = "application/json, */*",
        absorb_cookies = true,
        timeout = 12,
    }), function(res)
        if not alive(gen) then
            return
        end
        if not res or not res.ok then
            on_done((res and res.err) or "getuid failed")
            return
        end
        local data = decode_json(res.body)
        local uid = data and tostring(data.uid or "") or ""
        if uid == "" then
            on_done("empty uid")
            return
        end
        local cgi_key = Login.cgi_key()
        Log.info("login", "getuid", { ok = true })
        if type(on_uid) == "function" then
            on_uid(nil, { uid = uid, cgi_key = cgi_key })
        end
        local confirm = CONFIRM_PREFIX .. uid
        local url = string.format(
            "%s?url=%s&platform=desktop",
            Config.LOGIN_QRCODE_URL,
            url_encode(url_encode(confirm))
        )
        track(Http.request(kindle_opts({
            url = url,
            accept = "application/json, */*",
            absorb_cookies = true,
            timeout = 12,
        }), function(qr_res)
            if not alive(gen) then
                return
            end
            if not qr_res or not qr_res.ok then
                on_done((qr_res and qr_res.err) or "qrcode failed")
                return
            end
            local qr = decode_json(qr_res.body)
            if not qr or tonumber(qr.succ) ~= 1 then
                on_done("qrcode rejected")
                return
            end
            local payload = tostring(qr.data or "")
            local b64 = payload:match("^data:image/[%w%+%-]+;base64,(.+)$")
            if not b64 then
                on_done("qrcode missing image")
                return
            end
            local path, err = save_qr(b64)
            if not path then
                on_done(err)
                return
            end
            Log.info("login", "qrcode", { ok = true })
            on_done(nil, {
                uid = uid,
                cgi_key = cgi_key,
                qr_path = path,
            })
        end))
    end))
end

function Login.wait_scan(uid, cgi_key, on_done)
    uid = tostring(uid or "")
    cgi_key = tostring(cgi_key or Login.cgi_key())
    if uid == "" then
        on_done("empty uid")
        return
    end
    local gen = Session.gen
    local body = Json.encode({
        uid = uid,
        cgiKey = cgi_key,
    })
    if not body then
        on_done("encode failed")
        return
    end
    local attempt = 0
    local function poll()
        if not alive(gen) then
            return
        end
        attempt = attempt + 1
        Log.info("login", "getlogininfo", {
            attempt = attempt,
            tries = INFO_TRIES,
            timeout = INFO_TIMEOUT,
        })
        local function again(reason)
            if not alive(gen) then
                return
            end
            if attempt >= INFO_TRIES then
                on_done(reason or "timeout")
                return
            end
            local UIManager = require("ui/uimanager")
            UIManager:scheduleIn(INFO_RETRY_DELAY, poll)
        end
        track(Http.request(kindle_opts({
            url = Config.LOGIN_INFO_URL,
            method = "POST",
            body = body,
            accept = "application/json, */*",
            absorb_cookies = false,
            timeout = INFO_TIMEOUT,
        }), function(res)
            if not alive(gen) then
                return
            end
            local data = res and decode_json(res.body)
            if data and data.vid and data.skey and data.code then
                Log.info("login", "getlogininfo", { ok = true, attempt = attempt })
                on_done(nil, data)
                return
            end
            if data and tonumber(data.scan) == 0 then
                on_done("expired")
                return
            end
            -- Network blip / client abort: keep one short retry so a waiter
            -- is almost always attached for the QR lifetime.
            again((res and res.err) or "pending")
        end))
    end
    poll()
end

function Login.weblogin(info, cgi_key, on_done)
    if type(info) ~= "table" or not info.vid or not info.skey or not info.code then
        on_done("missing login info")
        return
    end
    local gen = Session.gen
    CookieStore.load(true)
    local body = Json.encode({
        vid = info.vid,
        skey = info.skey,
        code = info.code,
        isAutoLogout = info.isAutoLogout,
        pf = 2,
        cgiKey = tostring(cgi_key or Login.cgi_key()),
        fp = Login.fingerprint(),
    })
    track(Http.request(kindle_opts({
        url = Config.LOGIN_WEBLOGIN_URL,
        method = "POST",
        body = body,
        accept = "application/json, */*",
        absorb_cookies = true,
        timeout = 12,
    }), function(res)
        if not alive(gen) then
            return
        end
        if not res or not res.ok then
            on_done((res and res.err) or "weblogin failed")
            return
        end
        local data = decode_json(res.body)
        if not data or not data.vid or not (data.accessToken or data.refreshToken or data.skey) then
            on_done("weblogin rejected")
            return
        end
        CookieStore.set("wr_vid", tostring(data.vid), "login")
        local skey = data.skey or data.accessToken
        if skey then
            CookieStore.set("wr_skey", tostring(skey), "login")
        end
        if data.name or data.userName then
            CookieStore.set("wr_name", tostring(data.name or data.userName), "login")
        end
        Log.info("login", "weblogin", { ok = true })
        on_done(nil, data)
    end))
end

Login.WAIT_SECONDS = WAIT_SECONDS
Login.INFO_TIMEOUT = INFO_TIMEOUT
Login.INFO_TRIES = INFO_TRIES

return Login
