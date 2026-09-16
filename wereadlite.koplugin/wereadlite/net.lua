--[[--
Network helpers for wereadlite.

Official KOReader patterns only:
  - NetworkMgr:isConnected / willRerunWhenConnected (not isOnline/NCSI)
  - res_init / __res_init after Wi‑Fi restore (koreader#6421 / #6424 / PR #15244)

No custom UDP DNS resolver — LuaSocket/ssl.https own getaddrinfo.
]]

local Log = require("wereadlite.log")
local UIManager = require("ui/uimanager")

local Net = {}

local resolver_ready = false
local WAIT_POLL = 2
-- Kindle Wi‑Fi restore can exceed 45s when another plugin holds the connection.
local WAIT_TRIES = 35

Net.WAIT_POLL = WAIT_POLL
Net.WAIT_TRIES = WAIT_TRIES
local RESOLV_PATH = "/etc/resolv.conf"
-- Only when DHCP left resolv.conf empty (USBMS / failed dhcpcd).
local FALLBACK_NAMESERVERS = {
    "223.5.5.5",
    "119.29.29.29",
    "1.1.1.1",
}

local function manager()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok then
        return NetworkMgr
    end
end

local function call(nm, name, ...)
    if not nm or type(nm[name]) ~= "function" then
        return false
    end
    local ok, result = pcall(nm[name], nm, ...)
    if not ok then
        Log.warn("net", name, { err = result })
        return false
    end
    return true, result
end

local function has_wifi_toggle()
    local ok, Device = pcall(require, "device")
    if not ok or not Device or type(Device.hasWifiToggle) ~= "function" then
        return false
    end
    return Device:hasWifiToggle() == true
end

local function read_resolv()
    local file = io.open(RESOLV_PATH, "r")
    if not file then
        return nil
    end
    local text = file:read("*a")
    file:close()
    return text
end

function Net.list_nameservers()
    local text = read_resolv()
    local servers = {}
    if not text or text == "" then
        return false, servers
    end
    for line in text:gmatch("[^\r\n]+") do
        local ip = line:match("^%s*nameserver%s+(%S+)")
        if ip and ip ~= "0.0.0.0" then
            servers[#servers + 1] = ip
        end
    end
    return #servers > 0, servers
end

function Net.has_nameserver()
    local ok = Net.list_nameservers()
    return ok
end

--- If DHCP left resolv.conf empty, write public nameservers then res_init.
function Net.ensure_nameserver_fallback()
    local has, servers = Net.list_nameservers()
    if has then
        return true, servers
    end
    local existing = read_resolv() or ""
    if existing ~= "" and not existing:match("\n$") then
        existing = existing .. "\n"
    end
    local chunks = { existing, "# wereadlite: empty resolv.conf after DHCP\n" }
    for _, ip in ipairs(FALLBACK_NAMESERVERS) do
        chunks[#chunks + 1] = "nameserver " .. ip .. "\n"
    end
    local file, err = io.open(RESOLV_PATH, "w")
    if not file then
        Log.warn("net", "resolv_write_fail", { err = err })
        return false, {}
    end
    file:write(table.concat(chunks))
    file:close()
    Log.warn("net", "resolv_fallback", { servers = table.concat(FALLBACK_NAMESERVERS, ",") })
    resolver_ready = false
    return true, FALLBACK_NAMESERVERS
end

--- Force glibc to re-read /etc/resolv.conf (official KOReader workaround).
function Net.res_init(force)
    if resolver_ready and not force then
        return true
    end
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or not ffi then
        return false
    end
    pcall(ffi.cdef, [[
        int res_init(void);
        int __res_init(void);
    ]])
    local ok = pcall(function()
        return ffi.C.res_init()
    end)
    if not ok then
        ok = pcall(function()
            return ffi.C.__res_init()
        end)
    end
    if ok then
        resolver_ready = true
        local has, servers = Net.list_nameservers()
        Log.info("net", "res_init", {
            ok = true,
            has_ns = has,
            ns = has and table.concat(servers, ",") or "",
        })
        return true
    end
    Log.warn("net", "res_init", { ok = false })
    return false
end

function Net.invalidate()
    resolver_ready = false
end

function Net.is_wifi_on()
    local nm = manager()
    if not nm then
        return true
    end
    local ok, value = call(nm, "isWifiOn")
    if not ok or value == nil then
        return true
    end
    return value == true
end

function Net.is_connected()
    if not has_wifi_toggle() then
        return true
    end
    local nm = manager()
    if not nm then
        return Net.is_wifi_on()
    end
    local ok, value = call(nm, "isConnected")
    if ok and value ~= nil then
        return value == true
    end
    return Net.is_wifi_on()
end

--- Soft DNS check via LuaSocket only (no custom UDP resolver).
function Net.dns_probe(host)
    host = host or "weread.qq.com"
    local ok_sock, sock = pcall(require, "socket")
    if not ok_sock or not sock or not sock.dns or type(sock.dns.toip) ~= "function" then
        return nil
    end
    Net.res_init(true)
    local ok, ip = pcall(sock.dns.toip, host)
    if ok and type(ip) == "string" and ip ~= "" then
        Log.info("net", "dns_ok", { host = host, ip = ip, via = "toip" })
        return ip
    end
    Log.warn("net", "dns_toip_fail", { host = host, err = tostring(ip) })
    return nil
end

function Net.ensure_dns(opts)
    opts = opts or {}
    if has_wifi_toggle() and not Net.is_connected() then
        return false, "offline"
    end
    if opts.fallback ~= false then
        Net.ensure_nameserver_fallback()
    end
    Net.invalidate()
    Net.res_init(true)
    if not Net.has_nameserver() then
        return false, "no_nameserver"
    end
    -- Optional soft probe; never block the official HTTP stack on failure —
    -- dhcpcd may still be settling (see crash.log: dhcp timed out / disk full).
    if opts.probe then
        if not Net.dns_probe(opts.host or "weread.qq.com") then
            return false, "dns_probe_fail"
        end
    end
    return true
end

function Net.is_online(force)
    if not has_wifi_toggle() then
        return true
    end
    if not Net.is_connected() then
        return false
    end
    Net.res_init(force == true)
    return true
end

function Net.prepare_for_request(force)
    if not has_wifi_toggle() then
        Net.ensure_nameserver_fallback()
        Net.res_init(force == true)
        return true
    end
    if not Net.is_connected() then
        return false, "offline"
    end
    Net.ensure_nameserver_fallback()
    Net.res_init(true)
    return true
end

function Net.when_online(callback, opts)
    callback = type(callback) == "function" and callback or function() end
    opts = opts or {}
    if Net.prepare_for_request(opts.force) then
        UIManager:nextTick(callback)
        return true
    end
    local fired = false
    local function run()
        if fired then
            return
        end
        fired = true
        Net.invalidate()
        Net.ensure_nameserver_fallback()
        Net.res_init(true)
        callback()
    end
    local nm = manager()
    -- Ask KOReader to turn Wi‑Fi on, but never rely on this callback alone:
    -- when another connection attempt is ongoing, NetworkMgr drops wifi_cb (EBUSY).
    if not opts._poll and nm and type(nm.willRerunWhenConnected) == "function" then
        Log.info("net", "wait_online", { via = "willRerunWhenConnected" })
        call(nm, "willRerunWhenConnected", run)
    end
    local tries = tonumber(opts.tries) or WAIT_TRIES
    local delay = tonumber(opts.delay) or WAIT_POLL
    local attempt = 0
    local function poll()
        if fired then
            return
        end
        attempt = attempt + 1
        Net.invalidate()
        if Net.prepare_for_request(true) then
            Log.info("net", "wait_online", { via = "poll", attempt = attempt })
            run()
            return
        end
        if attempt >= tries then
            Log.warn("net", "wait_online_timeout", { attempt = attempt })
            run()
            return
        end
        UIManager:scheduleIn(delay, poll)
    end
    Log.info("net", "wait_online", { via = "poll", delay = delay })
    UIManager:scheduleIn(delay, poll)
    return false
end

--- Open Wi‑Fi UI the official way.
-- On Kobo, reconnectOrShowNetworkMenu only talks to an *already running*
-- wpa_supplicant. Calling it alone yields:
--   failed to connect to wpa_supplicant control socket .../wlan0
-- Prefer enableWifi / turnOnWifi so platform/enable-wifi.sh runs first.
function Net.open_wifi_menu(done)
    local nm = manager()
    if not nm then
        if done then done() end
        return false
    end
    if type(nm.enableWifi) == "function" then
        return call(nm, "enableWifi", done, true)
    end
    if type(nm.turnOnWifi) == "function" then
        return call(nm, "turnOnWifi", done, true)
    end
    if type(nm.toggleWifiOn) == "function" then
        return call(nm, "toggleWifiOn", done, false, true)
    end
    if type(nm.reconnectOrShowNetworkMenu) == "function" then
        return call(nm, "reconnectOrShowNetworkMenu", done, true)
    end
    if done then done() end
    return false
end

return Net
