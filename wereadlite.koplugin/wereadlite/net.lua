local Log = require("wereadlite.log")
local UIManager = require("ui/uimanager")

local Net = {}

-- glibc caches /etc/resolv.conf on first DNS use (Kobo ships pre-2.26).
-- Force a reload after DHCP/USBMS/Wi‑Fi restore so LuaSocket can resolve.
-- See: koreader#6421 / #6424 / PocketBook PR #15244.
local resolver_ready = false
local WAIT_POLL = 2
local WAIT_TRIES = 10
local RESOLV_PATH = "/etc/resolv.conf"
-- Public resolvers used only when DHCP left resolv.conf empty (common after USBMS).
local FALLBACK_NAMESERVERS = {
    "223.5.5.5", -- AliDNS
    "119.29.29.29", -- DNSPod
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

--- @treturn boolean
--- @treturn table list of nameserver IPs found in resolv.conf
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

--- If DHCP left resolv.conf empty, append public nameservers (Kobo MobileRead workaround).
-- Does not overwrite an existing non-empty nameserver list.
-- @treturn boolean wrote or already had nameserver
function Net.ensure_nameserver_fallback()
    local has, servers = Net.list_nameservers()
    if has then
        return true, servers
    end
    local existing = read_resolv() or ""
    local lines = {}
    if existing ~= "" and not existing:match("\n$") then
        existing = existing .. "\n"
    end
    lines[#lines + 1] = existing
    lines[#lines + 1] = "# wereadlite: DHCP left resolv.conf empty\n"
    for _, ip in ipairs(FALLBACK_NAMESERVERS) do
        lines[#lines + 1] = "nameserver " .. ip .. "\n"
    end
    local file, err = io.open(RESOLV_PATH, "w")
    if not file then
        Log.warn("net", "resolv_write_fail", { err = err })
        return false, {}
    end
    file:write(table.concat(lines))
    file:close()
    Log.warn("net", "resolv_fallback", { servers = table.concat(FALLBACK_NAMESERVERS, ",") })
    resolver_ready = false
    return true, FALLBACK_NAMESERVERS
end

--- Force glibc to re-read /etc/resolv.conf (KOReader PocketBook pattern).
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

local dns_cache = {} -- host -> { ip=, expires= }
local DNS_CACHE_TTL = 300
local DNS_UDP_SERVERS = {
    "223.5.5.5",
    "119.29.29.29",
    "1.1.1.1",
}

local function is_ipv4(text)
    return type(text) == "string" and text:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

local function encode_dns_name(host)
    local parts = {}
    for label in tostring(host):gmatch("[^.]+") do
        if #label > 63 then
            return nil
        end
        parts[#parts + 1] = string.char(#label) .. label
    end
    return table.concat(parts) .. "\0"
end

local function build_dns_query(host, txid)
    local qname = encode_dns_name(host)
    if not qname then
        return nil
    end
    txid = txid % 65536
    return string.char(
        math.floor(txid / 256),
        txid % 256,
        0x01, 0x00, -- RD
        0x00, 0x01, -- QDCOUNT
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00
    ) .. qname .. string.char(0x00, 0x01, 0x00, 0x01) -- A IN
end

local function skip_dns_name(data, offset)
    local n = #data
    local jumped = false
    local pos = offset
    for _ = 1, 64 do
        if pos > n then
            return nil
        end
        local len = data:byte(pos)
        if not len then
            return nil
        end
        if len == 0 then
            return jumped and offset or (pos + 1)
        end
        if len >= 0xC0 then
            if pos + 1 > n then
                return nil
            end
            if not jumped then
                return pos + 2
            end
            local ptr = ((len - 0xC0) * 256) + data:byte(pos + 1)
            pos = ptr + 1
            jumped = true
        else
            pos = pos + 1 + len
        end
    end
    return nil
end

local function parse_dns_a(data, txid)
    if type(data) ~= "string" or #data < 12 then
        return nil
    end
    local id = data:byte(1) * 256 + data:byte(2)
    if id ~= (txid % 65536) then
        return nil
    end
    local flags = data:byte(3) * 256 + data:byte(4)
    local rcode = flags % 16
    if rcode ~= 0 then
        return nil
    end
    local qdcount = data:byte(5) * 256 + data:byte(6)
    local ancount = data:byte(7) * 256 + data:byte(8)
    local pos = 13
    for _ = 1, qdcount do
        pos = skip_dns_name(data, pos)
        if not pos or pos + 4 - 1 > #data then
            return nil
        end
        pos = pos + 4
    end
    for _ = 1, ancount do
        pos = skip_dns_name(data, pos)
        if not pos or pos + 10 - 1 > #data then
            return nil
        end
        local rtype = data:byte(pos) * 256 + data:byte(pos + 1)
        local rdlength = data:byte(pos + 8) * 256 + data:byte(pos + 9)
        pos = pos + 10
        if pos + rdlength - 1 > #data then
            return nil
        end
        if rtype == 1 and rdlength == 4 then
            return string.format(
                "%d.%d.%d.%d",
                data:byte(pos),
                data:byte(pos + 1),
                data:byte(pos + 2),
                data:byte(pos + 3)
            )
        end
        pos = pos + rdlength
    end
    return nil
end

--- UDP DNS A lookup to a numeric nameserver (bypasses glibc getaddrinfo).
-- Needed on Kobo when getaddrinfo returns EAI_NONAME instantly despite a
-- populated resolv.conf (AI_ADDRCONFIG / broken nss while link looks "up").
function Net.udp_resolve(host, opts)
    host = tostring(host or "")
    if host == "" or is_ipv4(host) then
        return is_ipv4(host) and host or nil
    end
    opts = opts or {}
    local ok_sock, socket = pcall(require, "socket")
    if not ok_sock or not socket or type(socket.udp) ~= "function" then
        return nil
    end
    local servers = opts.servers or DNS_UDP_SERVERS
    local timeout = tonumber(opts.timeout) or 2
    if opts.servers == nil and opts.fast then
        servers = { DNS_UDP_SERVERS[1] }
    end
    local query_base = build_dns_query(host, 0)
    if not query_base then
        return nil
    end
    for _, server in ipairs(servers) do
        local txid = (os.time() + math.floor(socket.gettime() * 1000)) % 65536
        local query = string.char(math.floor(txid / 256), txid % 256) .. query_base:sub(3)
        local udp = socket.udp()
        if udp then
            udp:settimeout(timeout)
            local ok_bind = pcall(function()
                return udp:setsockname("*", 0)
            end)
            if ok_bind then
                local sent = udp:sendto(query, server, 53)
                if sent then
                    local data = udp:receive()
                    local ip = data and parse_dns_a(data, txid) or nil
                    udp:close()
                    if ip then
                        Log.info("net", "udp_dns_ok", { host = host, ip = ip, via = server })
                        return ip
                    end
                else
                    udp:close()
                end
            else
                pcall(function()
                    udp:close()
                end)
            end
            Log.warn("net", "udp_dns_miss", { host = host, via = server })
        end
    end
    return nil
end

--- Resolve host → IPv4. Tries glibc/LuaSocket first, then UDP DNS bypass.
function Net.resolve(host, opts)
    host = tostring(host or "")
    if host == "" then
        return nil
    end
    if is_ipv4(host) then
        return host
    end
    opts = opts or {}
    local cached = dns_cache[host]
    local now = os.time()
    if cached and cached.ip and cached.expires and cached.expires > now then
        return cached.ip
    end
    Net.res_init(true)
    local ok_sock, socket = pcall(require, "socket")
    if ok_sock and socket and socket.dns and type(socket.dns.toip) == "function" then
        local ok, ip = pcall(socket.dns.toip, host)
        if ok and is_ipv4(ip) then
            dns_cache[host] = { ip = ip, expires = now + DNS_CACHE_TTL }
            Log.info("net", "dns_ok", { host = host, ip = ip, via = "toip" })
            return ip
        end
        Log.warn("net", "dns_toip_fail", { host = host, err = tostring(ip) })
    end
    local ip = Net.udp_resolve(host, opts)
    if ip then
        dns_cache[host] = { ip = ip, expires = now + DNS_CACHE_TTL }
        return ip
    end
    Log.warn("net", "dns_fail", { host = host })
    return nil
end

--- Best-effort DNS probe (parent or child). Does not use NCSI hosts.
function Net.dns_probe(host)
    return Net.resolve(host or "weread.qq.com")
end

--- Prepare resolver for a request: linked, resolv.conf usable, glibc reloaded.
-- @treturn boolean ready
-- @treturn string|nil reason
function Net.ensure_dns(opts)
    opts = opts or {}
    if has_wifi_toggle() and not Net.is_connected() then
        return false, "offline"
    end
    local has = Net.has_nameserver()
    if not has and opts.fallback ~= false then
        Net.ensure_nameserver_fallback()
        has = Net.has_nameserver()
    end
    Net.invalidate()
    Net.res_init(true)
    if not has and not Net.has_nameserver() then
        return false, "no_nameserver"
    end
    if opts.probe then
        local host = opts.host or "weread.qq.com"
        if not Net.dns_probe(host) then
            return false, "dns_probe_fail"
        end
    end
    return true
end

function Net.is_wifi_on()
    local nm = manager()
    if not nm then
        return true
    end
    local ok, value = call(nm, "isWifiOn")
    if not ok then
        return true
    end
    if value == nil then
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

--- Ready for HTTP: have a link/IP, and reload glibc resolver.
-- Do NOT call NetworkMgr:isOnline(): it probes dns.msftncsi.com, which is often
-- unreachable in CN. When connected-but-not-NCSI, willRerunWhenOnline never
-- invokes the callback (KOReader only runs it after a Wi‑Fi bring-up), so the
-- shelf would hang forever on "http wait_online".
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

--- Call before issuing HTTP.
-- @treturn boolean ready
-- @treturn string|nil err
function Net.prepare_for_request(force)
    if not has_wifi_toggle() then
        Net.ensure_dns({ fallback = true, probe = false })
        return true
    end
    if not Net.is_connected() then
        return false, "offline"
    end
    local ok, reason = Net.ensure_dns({ fallback = true, probe = false })
    if not ok then
        return false, reason or "offline"
    end
    if force then
        Net.res_init(true)
    end
    return true
end

--- Run callback once the interface has an address; uses willRerunWhenConnected.
function Net.when_online(callback, opts)
    callback = type(callback) == "function" and callback or function() end
    opts = opts or {}
    if Net.prepare_for_request(opts.force) then
        UIManager:nextTick(callback)
        return true
    end
    local nm = manager()
    -- Prefer isConnected (IP assigned), never isOnline/NCSI.
    if not opts._poll and nm and type(nm.willRerunWhenConnected) == "function" then
        Log.info("net", "wait_online", { via = "willRerunWhenConnected" })
        local ok, will_rerun = call(nm, "willRerunWhenConnected", function()
            Net.invalidate()
            Net.ensure_dns({ fallback = true })
            callback()
        end)
        if ok and will_rerun then
            return false
        end
    end
    local tries = tonumber(opts.tries) or WAIT_TRIES
    local delay = tonumber(opts.delay) or WAIT_POLL
    local attempt = 0
    local function poll()
        attempt = attempt + 1
        Net.invalidate()
        if Net.prepare_for_request(true) then
            Log.info("net", "wait_online", { via = "poll", attempt = attempt })
            callback()
            return
        end
        if attempt >= tries then
            Log.warn("net", "wait_online_timeout", { attempt = attempt })
            -- Last resort: inject fallback DNS then proceed.
            Net.ensure_nameserver_fallback()
            Net.res_init(true)
            callback()
            return
        end
        UIManager:scheduleIn(delay, poll)
    end
    Log.info("net", "wait_online", { via = "poll", delay = delay })
    UIManager:scheduleIn(delay, poll)
    return false
end

function Net.open_wifi_menu(done)
    local nm = manager()
    if not nm then
        if done then done() end
        return false
    end
    if type(nm.reconnectOrShowNetworkMenu) == "function" then
        return call(nm, "reconnectOrShowNetworkMenu", done, true)
    end
    if type(nm.toggleWifiOn) == "function" then
        return call(nm, "toggleWifiOn", done, true, true)
    end
    if type(nm.turnOnWifi) == "function" then
        return call(nm, "turnOnWifi", done, true)
    end
    if done then done() end
    return false
end

return Net
