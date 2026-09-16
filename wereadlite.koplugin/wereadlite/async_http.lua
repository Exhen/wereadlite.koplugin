--[[--
Async HTTP for wereadlite — KOReader-official patterns only.

Correct approach for Kobo (and plugins generally), per koreader#5002,
newsdownloader epubdownloadbackend, and ui/trapper.lua:

1. curl background shell when a curl binary exists (Kindle / desktop).
2. Otherwise: ffiUtil.runInSubProcess + pipe (same as Trapper
   dismissableRunInSubprocess), polled via UIManager:scheduleIn.
   Inside the child: blocking socket.http / ssl.https with socketutil timeouts.

No in-process HttpAsync scheduler: concurrent non-blocking SSL on Kobo
causes wantread / handshake failures under load.

Kobo DNS note (koreader#6421/#6424): glibc caches empty resolv.conf. We
force res_init in the child and inject fallback nameservers when DHCP left
/etc/resolv.conf empty (common after USBMS).
]]

local UIManager = require("ui/uimanager")
local Config = require("wereadlite.config")
local CookieStore = require("wereadlite.cookie_store")
local Paths = require("wereadlite.paths")
local Log = require("wereadlite.log")
local Net = require("wereadlite.net")

local Http = {
    POLL = 0.25,
    -- Serial workers: one blocking LuaSocket/SSL at a time (Trapper guidance).
    MAX_WORKERS = 1,
    -- DNS/EAI_NONAME on Kobo often needs several seconds for DHCP + resolv reload.
    CONNECT_RETRIES = 4,
    CONNECT_RETRY_DELAY = 2.5,
    DNS_WAIT_MAX = 5,
    DNS_WAIT_DELAY = 2,
}

local ffiUtil
local buffer_mod
local job_seq = 0
local CURL
local active_jobs = {}
local workers_running = 0
local job_queue = {}

local function get_ffiutil()
    if ffiUtil ~= nil then
        return ffiUtil ~= false and ffiUtil or nil
    end
    local ok, mod = pcall(require, "ffi/util")
    if ok and mod
        and type(mod.runInSubProcess) == "function"
        and type(mod.isSubProcessDone) == "function"
        and type(mod.writeToFD) == "function"
        and type(mod.readAllFromFD) == "function" then
        ffiUtil = mod
        return ffiUtil
    end
    ffiUtil = false
    return nil
end

local function get_buffer()
    if buffer_mod ~= nil then
        return buffer_mod ~= false and buffer_mod or nil
    end
    local ok, mod = pcall(require, "string.buffer")
    if ok and mod and type(mod.encode) == "function" and type(mod.decode) == "function" then
        buffer_mod = mod
        return buffer_mod
    end
    buffer_mod = false
    return nil
end

local function lfs_mod()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok then
        return lfs
    end
end

local function mkdir(path)
    local lfs = lfs_mod()
    if lfs then
        if lfs.attributes(path, "mode") ~= "directory" then
            lfs.mkdir(path)
        end
        return
    end
    os.execute(string.format("mkdir -p %q", path))
end

local function exists(path)
    local lfs = lfs_mod()
    if lfs then
        return lfs.attributes(path, "mode") ~= nil
    end
    local file = io.open(path, "r")
    if not file then
        return false
    end
    file:close()
    return true
end

local function read_file(path)
    path = tostring(path or "")
    if path == "" then
        return nil
    end
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read("*a")
    file:close()
    return data
end

local function write_file(path, text)
    local file, err = io.open(path, "wb")
    if not file then
        return nil, err
    end
    file:write(text or "")
    file:close()
    return true
end

local function remove_file(path)
    os.remove(path)
end

local function exit_ready(path)
    local text = read_file(path)
    return text and text:match("%-?%d+") ~= nil
end

local function plugin_cache_dir()
    return Paths.http_dir()
end

local function find_curl()
    if CURL ~= nil then
        return CURL ~= false and CURL or nil
    end
    local names = {
        "/usr/bin/curl",
        "/bin/curl",
        "/usr/sbin/curl",
        "/mnt/us/koreader/curl",
        "/mnt/us/usbnet/bin/curl",
        "/mnt/onboard/.adds/koreader/curl",
        "/mnt/onboard/koreader/curl",
        "/mnt/external.sd/.adds/koreader/curl",
    }
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()
        if dir and dir ~= "" then
            names[#names + 1] = dir .. "/curl"
            names[#names + 1] = dir .. "/libs/curl"
        end
    end)
    for _, name in ipairs(names) do
        if exists(name) then
            CURL = name
            Log.info("http", "curl_found", { path = CURL })
            return CURL
        end
    end
    local pipe = io.popen("command -v curl 2>/dev/null")
    if pipe then
        local found = pipe:read("*l")
        pipe:close()
        if found and found ~= "" and exists(found) then
            CURL = found
            Log.info("http", "curl_found", { path = CURL })
            return CURL
        end
    end
    CURL = false
    return nil
end

local function socket_available()
    local ok_https, https = pcall(require, "ssl.https")
    if ok_https and https and type(https.request) == "function" then
        return true
    end
    local ok_http, http = pcall(require, "socket.http")
    return ok_http and http and type(http.request) == "function"
end

local function fail_res(err, status, code)
    code = tonumber(code) or 0
    return {
        ok = false,
        body = "",
        code = code,
        status = status or "offline",
        err = err or "http_error",
        headers = "",
    }
end

local function classify(code, err)
    code = tonumber(code) or 0
    local text = tostring(err or "")
    if code == 401 or code == 403 then
        return "auth_expired"
    end
    if code >= 200 and code < 400 then
        return "ok"
    end
    if code > 0 then
        return "http_error"
    end
    local lower = text:lower()
    if lower:find("timeout", 1, true)
        or lower:find("timed out", 1, true)
        or lower:find("closed", 1, true)
        or lower:find("refused", 1, true)
        or lower:find("wantread", 1, true)
        or lower:find("wantwrite", 1, true)
        or lower:find("host or service not provided", 1, true)
        or lower:find("name or service not known", 1, true)
        or lower:find("temporary failure in name resolution", 1, true)
        or lower:find("network is unreachable", 1, true)
        or lower:find("connect error", 1, true)
        or lower:find("ssl", 1, true) then
        return "offline"
    end
    return "http_error"
end

local function is_transient(res)
    if type(res) ~= "table" or res.ok then
        return false
    end
    if tonumber(res.code) and tonumber(res.code) > 0 and tonumber(res.code) < 500 then
        return false
    end
    if res.status == "offline" then
        return true
    end
    return classify(res.code, res.err) == "offline"
end

local function format_set_cookie_headers(headers)
    if type(headers) ~= "table" then
        return ""
    end
    local lines = {}
    for key, value in pairs(headers) do
        if type(key) == "string" and type(value) == "string" and key:lower() == "set-cookie" then
            lines[#lines + 1] = "Set-Cookie: " .. value
        end
    end
    return table.concat(lines, "\r\n")
end

-- Blocking LuaSocket request (must run inside a subprocess on the UI process).
local function socket_request(opts)
    local ok, Client = pcall(require, "wereadlite.kindle.client")
    if not ok or not Client or type(Client.request) ~= "function" then
        return fail_res("http client unavailable", "offline")
    end
    -- Avoid Client → Http.request_sync → curl recursion inside the worker.
    local saved = Http.has_curl
    Http.has_curl = function()
        return false
    end
    local text, status, err, code, response_headers = Client.request(opts or {})
    Http.has_curl = saved
    local headers_raw = format_set_cookie_headers(response_headers)
    if text then
        return {
            ok = true,
            body = text,
            code = tonumber(code) or 200,
            status = "ok",
            err = nil,
            headers = headers_raw,
        }
    end
    return {
        ok = false,
        body = "",
        code = tonumber(code) or 0,
        status = status or classify(0, err),
        err = err or "socket error",
        headers = headers_raw,
    }
end

local function sh_quote(text)
    return "'" .. tostring(text or ""):gsub("'", "'\\''") .. "'"
end

local function cfg_quote(text)
    return '"' .. tostring(text or ""):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function header_value(headers, name)
    if type(headers) ~= "table" then
        return nil
    end
    local target = name:lower()
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == target then
            return value
        end
    end
end

local function parse_set_cookies(raw)
    local cookies = {}
    for line in tostring(raw or ""):gmatch("[^\r\n]+") do
        local value = line:match("^[Ss][Ee][Tt]%-[Cc][Oo][Oo][Kk][Ii][Ee]:%s*(.+)$")
        if value then
            cookies[#cookies + 1] = value
        end
    end
    if #cookies == 0 then
        return nil
    end
    return table.concat(cookies, ", ")
end

local function last_http_code(headers)
    local last
    for line in tostring(headers or ""):gmatch("[^\r\n]+") do
        local n = line:match("^HTTP/[%d.]+%s+(%d%d%d)") or line:match("^HTTP/%S+%s+(%d%d%d)")
        if n then
            last = tonumber(n)
        end
    end
    return last
end

local function last_status_line(headers)
    local last
    for line in tostring(headers or ""):gmatch("[^\r\n]+") do
        if line:match("^HTTP/") then
            last = line
        end
    end
    return last
end

local function header_field(headers, name)
    name = tostring(name or ""):lower()
    for line in tostring(headers or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^([^:]+):%s*(.+)$")
        if key and key:lower() == name then
            return value
        end
    end
end

local function nap()
    local ok, socket = pcall(require, "socket")
    if ok and socket and type(socket.sleep) == "function" then
        socket.sleep(0.05)
        return
    end
    os.execute("sleep 0.05 >/dev/null 2>&1")
end

local drain_queue
local arm_subprocess
local start_subprocess_job

local function release_worker(job)
    if job and job.backend == "subprocess" and job.worker_active and not job.worker_released then
        job.worker_released = true
        workers_running = math.max(0, workers_running - 1)
        if drain_queue then
            drain_queue()
        end
    end
end

local function collect_subprocess(job)
    local util = get_ffiutil()
    if not util or not job or not job.pid then
        return
    end
    if job.read_fd then
        pcall(util.readAllFromFD, job.read_fd)
        job.read_fd = nil
    end
    if not util.isSubProcessDone(job.pid) then
        UIManager:scheduleIn(1, function()
            collect_subprocess(job)
        end)
    end
end

local function kill_job(job)
    if not job or job.killed then
        return
    end
    job.killed = true
    if job.backend == "subprocess" then
        local util = get_ffiutil()
        if util and job.pid and type(util.terminateSubProcess) == "function" then
            if not util.isSubProcessDone(job.pid) then
                pcall(util.terminateSubProcess, job.pid)
            end
        end
        collect_subprocess(job)
        release_worker(job)
        return
    end
    if not job.pid_path then
        return
    end
    local pid = tonumber((read_file(job.pid_path) or ""):match("%d+"))
    if pid then
        os.execute("pkill -9 -P " .. tostring(pid) .. " >/dev/null 2>&1")
        os.execute("kill -9 " .. tostring(pid) .. " >/dev/null 2>&1")
    end
end

local function deliver(job, res)
    if job.done then
        return
    end
    job.done = true
    active_jobs[job] = nil
    if job.cancelled then
        release_worker(job)
        return
    end
    if not res then
        res = fail_res("no result", "offline")
    end
    if job.absorb_cookies ~= false then
        local set_cookie = parse_set_cookies(res.headers)
        if set_cookie then
            CookieStore.merge_set_cookie(set_cookie, "response")
        end
    end
    Log.info("http", "done", {
        backend = job.backend,
        method = job.method,
        url = job.url,
        code = res.code,
        status = res.status,
        bytes = #(res.body or ""),
        err = res.err,
        attempt = job.attempt,
    })
    if res.ok == false then
        Log.http_error(job.method, job.url, {
            code = res.code,
            status = res.status,
            err = res.err,
            bytes = #(res.body or ""),
            body = res.body,
        })
    end
    release_worker(job)
    if job.callback then
        job.callback(res)
    end
end

local function finish_subprocess(job, res)
    if job.done or job.cancelled then
        release_worker(job)
        return
    end
    if job.backend == "task" then
        job.done = true
        active_jobs[job] = nil
        release_worker(job)
        if job.callback then
            local ok = type(res) == "table" and res.ok
            local payload = type(res) == "table" and res.result or res
            if ok == nil then
                ok = res ~= nil
            end
            job.callback(ok ~= false, payload)
        end
        return
    end
    local attempt = tonumber(job.attempt) or 1
    local max_retries = tonumber(job.opts and job.opts.connect_retries) or Http.CONNECT_RETRIES
    if is_transient(res) and attempt <= max_retries then
        local err_text = tostring(res and res.err or "")
        local dns_miss = err_text:find("host or service not provided", 1, true)
            or err_text:find("Name or service not known", 1, true)
            or err_text:find("nodename nor servname", 1, true)
        local delay = tonumber(job.opts and job.opts.connect_retry_delay) or Http.CONNECT_RETRY_DELAY
        if dns_miss then
            delay = math.max(delay, 3)
            pcall(Net.invalidate)
            pcall(Net.ensure_nameserver_fallback)
            pcall(Net.res_init, true)
        else
            pcall(Net.invalidate)
            pcall(Net.res_init, true)
        end
        Log.warn("http", "retry", {
            url = job.url,
            attempt = attempt,
            max = max_retries,
            err = res and res.err,
            dns = dns_miss and true or nil,
            delay = delay,
        })
        job.attempt = attempt + 1
        job.deadline = os.time() + (job.timeout or 15) + 20
        job.pid = nil
        job.read_fd = nil
        job.killed = nil
        release_worker(job)
        job.worker_active = nil
        job.worker_released = nil
        UIManager:scheduleIn(delay, function()
            if job.cancelled or job.done then
                return
            end
            if workers_running >= Http.MAX_WORKERS then
                job.queued = true
                job_queue[#job_queue + 1] = job
                return
            end
            workers_running = workers_running + 1
            start_subprocess_job(job)
        end)
        return
    end
    deliver(job, res)
end

arm_subprocess = function(job)
    local util = get_ffiutil()
    UIManager:scheduleIn(Http.POLL, function()
        if job.cancelled or job.done then
            if job.cancelled then
                collect_subprocess(job)
                release_worker(job)
            end
            return
        end
        if not util or not job.pid then
            finish_subprocess(job, fail_res("subprocess unavailable", "offline"))
            return
        end
        local done = util.isSubProcessDone(job.pid)
        local readable = job.read_fd and util.getNonBlockingReadSize
            and util.getNonBlockingReadSize(job.read_fd) ~= 0
        if os.time() >= job.deadline and not done and not readable then
            Log.warn("http", "timeout", { url = job.url, pid = job.pid })
            kill_job(job)
            finish_subprocess(job, fail_res("timeout", "offline"))
            return
        end
        if done or readable then
            local res
            if readable and job.read_fd then
                local output = util.readAllFromFD(job.read_fd)
                job.read_fd = nil
                local buf = get_buffer()
                if output and output ~= "" and buf then
                    local ok, packed = pcall(buf.decode, output)
                    if ok and type(packed) == "table" and packed[1] then
                        res = packed[1]
                    end
                end
            elseif job.read_fd then
                pcall(util.readAllFromFD, job.read_fd)
                job.read_fd = nil
            end
            finish_subprocess(job, res)
            if not done then
                collect_subprocess(job)
            end
            return
        end
        arm_subprocess(job)
    end)
end

start_subprocess_job = function(job)
    local util = get_ffiutil()
    local buf = get_buffer()
    local opts = job.opts or {}
    if not util or not buf then
        workers_running = math.max(0, workers_running - 1)
        deliver(job, fail_res("subprocess unavailable", "offline"))
        return
    end
    job.queued = nil

    -- Parent gate: do not fork while resolv.conf is empty (instant EAI_NONAME).
    -- Official plugins assume NetworkMgr already populated DNS; after USBMS on Kobo
    -- that is often false — wait / inject fallback before burning HTTP attempts.
    local dns_ok, dns_reason = Net.ensure_dns({ fallback = true, probe = false })
    if not dns_ok then
        local waits = tonumber(job.dns_waits) or 0
        if waits < Http.DNS_WAIT_MAX then
            job.dns_waits = waits + 1
            Log.warn("http", "dns_wait", {
                url = job.url,
                reason = dns_reason,
                wait = job.dns_waits,
                max = Http.DNS_WAIT_MAX,
            })
            workers_running = math.max(0, workers_running - 1)
            UIManager:scheduleIn(Http.DNS_WAIT_DELAY, function()
                if job.cancelled or job.done then
                    return
                end
                if workers_running >= Http.MAX_WORKERS then
                    job.queued = true
                    job_queue[#job_queue + 1] = job
                    return
                end
                workers_running = workers_running + 1
                start_subprocess_job(job)
            end)
            return
        end
        Log.warn("http", "dns_give_up", { url = job.url, reason = dns_reason })
    end

    local pid, parent_read_fd = util.runInSubProcess(function(_, child_write_fd)
        -- fork copies parent's glibc _res; reload resolv.conf in the child
        -- (official KOReader workaround, PR #15244 / #6424).
        pcall(function()
            local child_net = require("wereadlite.net")
            child_net.invalidate()
            child_net.ensure_nameserver_fallback()
            child_net.res_init(true)
        end)
        local packed
        if type(opts.task_fn) == "function" then
            local ok, result = pcall(opts.task_fn)
            packed = { ok = ok, result = result }
        else
            packed = socket_request(opts)
        end
        local ok, str = pcall(buf.encode, table.pack(packed))
        if ok and str then
            util.writeToFD(child_write_fd, str, true)
        else
            util.writeToFD(child_write_fd, "", true)
        end
    end, true)
    if not pid then
        Log.warn("http", "fork_fail", { url = job.url })
        workers_running = math.max(0, workers_running - 1)
        deliver(job, fail_res("fork failed", "offline"))
        return
    end
    job.pid = pid
    job.read_fd = parent_read_fd
    job.worker_active = true
    Log.info("http", "subprocess_start", {
        method = job.method,
        url = job.url,
        timeout = job.timeout,
        pid = pid,
        attempt = job.attempt,
    })
    arm_subprocess(job)
end

drain_queue = function()
    while workers_running < Http.MAX_WORKERS and #job_queue > 0 do
        local job = table.remove(job_queue, 1)
        if job and not job.cancelled and not job.done then
            workers_running = workers_running + 1
            start_subprocess_job(job)
        elseif job then
            active_jobs[job] = nil
        end
    end
end

local function schedule_subprocess(opts, callback)
    opts = opts or {}
    if not opts.url or opts.url == "" then
        return nil, fail_res("empty url")
    end
    if not get_ffiutil() or not get_buffer() then
        return nil, fail_res("subprocess unavailable", "offline")
    end
    local timeout = math.max(1, tonumber(opts.timeout) or 15)
    local method = opts.method or (opts.body and "POST" or "GET")
    local job = {
        url = opts.url,
        method = method,
        backend = "subprocess",
        absorb_cookies = opts.absorb_cookies,
        callback = callback,
        opts = opts,
        timeout = timeout,
        deadline = os.time() + timeout + 20,
        attempt = 1,
        cancelled = false,
        done = false,
    }
    active_jobs[job] = true
    if workers_running >= Http.MAX_WORKERS then
        job.queued = true
        job_queue[#job_queue + 1] = job
        Log.dbg("http", "queued", { url = job.url, queue = #job_queue })
        return job
    end
    workers_running = workers_running + 1
    start_subprocess_job(job)
    return job
end

-- ---- curl path (Kindle / hosts that ship curl) ----

local function write_config(job, opts)
    local lines = {
        "url = " .. cfg_quote(opts.url),
        "user-agent = " .. cfg_quote(opts.user_agent or Config.KINDLE_UA),
        "output = " .. cfg_quote(job.body_path),
        "dump-header = " .. cfg_quote(job.header_path),
        "max-time = " .. tostring(job.timeout or opts.timeout or 15),
        "connect-timeout = " .. tostring(math.min(10, tonumber(job.timeout or opts.timeout) or 15)),
        "silent",
        "show-error",
        "location",
        "max-redirs = 5",
        "header = " .. cfg_quote("Accept-Language: zh-CN,zh;q=0.9,en;q=0.8"),
        "header = " .. cfg_quote("Cache-Control: no-cache"),
        "header = " .. cfg_quote("Pragma: no-cache"),
        "header = " .. cfg_quote("Accept: " .. (opts.accept or "*/*")),
        "header = " .. cfg_quote("Referer: " .. (opts.referer or Config.LOGIN_URL)),
    }
    if opts.origin then
        lines[#lines + 1] = "header = " .. cfg_quote("Origin: " .. opts.origin)
    end
    if opts.send_cookie ~= false then
        local cookie = CookieStore.header()
        if cookie and cookie ~= "" then
            lines[#lines + 1] = "header = " .. cfg_quote("Cookie: " .. cookie)
        end
    end
    if type(opts.headers) == "table" then
        for name, value in pairs(opts.headers) do
            if value ~= nil then
                lines[#lines + 1] = "header = " .. cfg_quote(tostring(name) .. ": " .. tostring(value))
            end
        end
    end
    local method = opts.method or (opts.body and "POST" or "GET")
    if method ~= "GET" then
        lines[#lines + 1] = "request = " .. cfg_quote(method)
    end
    if opts.body then
        write_file(job.post_path, opts.body)
        if not header_value(opts.headers, "Content-Type") then
            lines[#lines + 1] = "header = " .. cfg_quote("Content-Type: application/json;charset=UTF-8")
        end
    end
    lines[#lines + 1] = ""
    return write_file(job.cfg_path, table.concat(lines, "\n"))
end

local function finish_curl(job)
    if job.done then
        return
    end
    job.done = true
    active_jobs[job] = nil
    local body = read_file(job.body_path) or ""
    local headers = read_file(job.header_path) or ""
    local err_text = read_file(job.err_path) or ""
    local exit_code = tonumber((read_file(job.exit_path) or ""):match("%-?%d+")) or -1
    local writeout = tonumber((read_file(job.code_path) or ""):match("%d+")) or 0
    local code = writeout
    if code == 0 then
        code = last_http_code(headers) or 0
    end
    if code == 0 and exit_code == 0 and #body > 0 then
        local head = body:sub(1, 200):lower()
        if head:find("<!doctype", 1, true) or head:find("<html", 1, true) or head:match("^%s*[{%[]") then
            code = 200
        end
    end
    local status = classify(code, exit_code ~= 0 and (err_text ~= "" and err_text or "curl exit") or nil)
    if exit_code == 28 or (code == 0 and exit_code ~= 0) then
        status = "offline"
    end
    Log.info("http", "curl_done", {
        method = job.method,
        url = job.url,
        code = code,
        exit = exit_code,
        status = status,
        bytes = #body,
        header = last_status_line(headers),
    })
    if job.absorb_cookies ~= false then
        local set_cookie = parse_set_cookies(headers)
        if set_cookie then
            CookieStore.merge_set_cookie(set_cookie, "response")
        end
    end
    local ok = status == "ok"
    if job.callback then
        job.callback({
            ok = ok,
            body = body,
            code = code,
            status = ok and "ok" or status,
            err = ok and nil or (status or "http_error"),
            headers = headers,
        })
    end
    Paths.remove_tree(job.dir)
end

local function arm_curl(job)
    UIManager:scheduleIn(Http.POLL, function()
        if job.cancelled then
            kill_job(job)
            active_jobs[job] = nil
            Paths.remove_tree(job.dir)
            return
        end
        if exit_ready(job.exit_path) then
            finish_curl(job)
            return
        end
        if os.time() >= job.deadline then
            Log.warn("http", "curl_timeout", { url = job.url })
            kill_job(job)
            job.done = true
            active_jobs[job] = nil
            if job.callback then
                job.callback(fail_res("timeout", "offline"))
            end
            Paths.remove_tree(job.dir)
            return
        end
        arm_curl(job)
    end)
end

local function launch_curl(opts, callback)
    opts = opts or {}
    local curl = find_curl()
    if not curl then
        return nil, fail_res("curl missing", "offline")
    end
    if not opts.url or opts.url == "" then
        return nil, fail_res("empty url")
    end
    job_seq = job_seq + 1
    local root = plugin_cache_dir()
    mkdir(root)
    local pid = 0
    pcall(function()
        local ffi = require("ffi")
        ffi.cdef[[int getpid(void);]]
        pid = tonumber(ffi.C.getpid()) or 0
    end)
    local dir = string.format("%s/%d-%d-%d-%d", root, os.time(), job_seq, pid, math.random(100000, 999999))
    mkdir(dir)
    local timeout = math.max(1, tonumber(opts.timeout) or 15)
    local method = opts.method or (opts.body and "POST" or "GET")
    local job = {
        url = opts.url,
        method = method,
        backend = "curl",
        dir = dir,
        cfg_path = dir .. "/curl.cfg",
        body_path = dir .. "/body",
        header_path = dir .. "/headers",
        code_path = dir .. "/code",
        exit_path = dir .. "/exit",
        pid_path = dir .. "/pid",
        post_path = dir .. "/post",
        err_path = dir .. "/err",
        absorb_cookies = opts.absorb_cookies,
        callback = callback,
        timeout = timeout,
        deadline = os.time() + timeout + 8,
        cancelled = false,
        done = false,
    }
    active_jobs[job] = true
    local ok, err = write_config(job, opts)
    if not ok then
        active_jobs[job] = nil
        return nil, fail_res(err)
    end
    local extra = ""
    if opts.body then
        extra = "--data-binary @" .. sh_quote(job.post_path)
    end
    local cmd = table.concat({
        "(",
        sh_quote(curl),
        "-K", sh_quote(job.cfg_path),
        "-o", sh_quote(job.body_path),
        "-D", sh_quote(job.header_path),
        "-w", sh_quote("%{http_code}"),
        extra,
        ">", sh_quote(job.code_path),
        "2>", sh_quote(job.err_path),
        ";",
        "echo $? >", sh_quote(job.exit_path),
        ") >/dev/null 2>&1 & echo $! >",
        sh_quote(job.pid_path),
    }, " ")
    Log.info("http", "curl_start", {
        method = method,
        url = opts.url,
        timeout = timeout,
    })
    os.execute(cmd)
    return job
end

local function dispatch(opts, callback)
    local curl_job = launch_curl(opts, callback)
    if curl_job then
        arm_curl(curl_job)
        return curl_job
    end
    if not socket_available() then
        if callback then
            UIManager:nextTick(function()
                callback(fail_res("no http transport", "offline"))
            end)
        end
        return nil
    end
    return schedule_subprocess(opts, callback)
end

function Http.available()
    return find_curl() ~= nil or socket_available()
end

function Http.has_curl()
    return find_curl() ~= nil
end

function Http.cancel(job)
    if not job then
        return
    end
    job.cancelled = true
    job.done = true
    active_jobs[job] = nil
    if job.backend == "pending_online" and job.child then
        Http.cancel(job.child)
        job.child = nil
    end
    if job.queued then
        for i = #job_queue, 1, -1 do
            if job_queue[i] == job then
                table.remove(job_queue, i)
            end
        end
    end
    kill_job(job)
    if job.dir then
        Paths.remove_tree(job.dir)
    end
end

function Http.cancel_all()
    local jobs = {}
    for job in pairs(active_jobs) do
        jobs[#jobs + 1] = job
    end
    for _, job in ipairs(jobs) do
        Http.cancel(job)
    end
    Log.info("http", "cancel_all", { count = #jobs })
    return #jobs
end

--- Best-effort: kill leftover curl shells under our http cache (Kindle suspend).
function Http.kill_orphans()
    local dir = Paths.http_dir()
    if not dir or dir == "" then
        return 0
    end
    local killed = 0
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs then
        local ok, iter = pcall(lfs.dir, dir)
        if ok and iter then
            for name in iter do
                if name ~= "." and name ~= ".." then
                    local pid_path = dir .. "/" .. name .. "/pid"
                    local pid = tonumber((read_file(pid_path) or ""):match("%d+"))
                    if pid then
                        os.execute("pkill -9 -P " .. tostring(pid) .. " >/dev/null 2>&1")
                        os.execute("kill -9 " .. tostring(pid) .. " >/dev/null 2>&1")
                        killed = killed + 1
                    end
                end
            end
        end
    end
    -- Fallback pattern match (BusyBox pkill on Kindle).
    os.execute("pkill -9 -f wereadlite.koplugin/.*/cache/http/ >/dev/null 2>&1")
    os.execute("pkill -9 -f wereadlite.koplugin/cache/http/ >/dev/null 2>&1")
    return killed
end

function Http.active_count()
    local count = 0
    for _ in pairs(active_jobs) do
        count = count + 1
    end
    return count
end

function Http.request(opts, callback)
    opts = opts or {}
    if opts.skip_online_check then
        return dispatch(opts, callback)
    end
    if Net.prepare_for_request() then
        return dispatch(opts, callback)
    end
    local pending = {
        url = opts.url,
        method = opts.method or (opts.body and "POST" or "GET") or "GET",
        backend = "pending_online",
        cancelled = false,
        done = false,
        child = nil,
        wait_since = os.time(),
    }
    active_jobs[pending] = true
    Log.info("http", "wait_connected", { url = opts.url, method = pending.method })
    local function finish_pending(res)
        if pending.cancelled or pending.done then
            return
        end
        pending.done = true
        active_jobs[pending] = nil
        if callback then
            callback(res or fail_res("network wait timeout", "offline"))
        end
    end
    Net.when_online(function()
        if pending.cancelled or pending.done then
            return
        end
        pending.dispatched = true
        active_jobs[pending] = nil
        local child = dispatch(opts, function(res)
            pending.done = true
            pending.child = nil
            if not pending.cancelled and callback then
                callback(res)
            end
        end)
        pending.child = child
        if not child then
            finish_pending(fail_res("request_not_started", "offline"))
        end
    end)
    -- Hard cap: never leave shelf stuck on “loading” if Wi‑Fi callbacks were dropped.
    local wait_cap = math.max(45, (Net.WAIT_TRIES or 35) * (Net.WAIT_POLL or 2) + 5)
    UIManager:scheduleIn(wait_cap, function()
        if pending.cancelled or pending.done or pending.dispatched then
            return
        end
        Log.warn("http", "wait_connected_timeout", { url = opts.url, seconds = wait_cap })
        pending.cancelled = true
        finish_pending(fail_res("network wait timeout", "offline"))
    end)
    return pending
end

--- Run an arbitrary function in a Trapper-style subprocess (Kobo / no-curl).
-- callback(ok, result) — result is task_fn's return value, or the error string.
-- Used for official httpasync.fetch_many batches without freezing the UI.
function Http.run_task(task_fn, callback, opts)
    opts = opts or {}
    callback = type(callback) == "function" and callback or function() end
    if type(task_fn) ~= "function" then
        UIManager:nextTick(function()
            callback(false, "bad task")
        end)
        return nil
    end
    if not get_ffiutil() or not get_buffer() then
        -- No fork (e.g. some desktop builds): run on next tick.
        Log.info("http", "task_inline", { label = opts.label or "task" })
        UIManager:nextTick(function()
            local ok, result = pcall(task_fn)
            callback(ok, result)
        end)
        return nil
    end
    local timeout = math.max(30, tonumber(opts.timeout) or 120)
    local job = {
        url = opts.label or "task",
        method = "TASK",
        backend = "task",
        callback = callback,
        opts = {
            task_fn = task_fn,
            timeout = timeout,
        },
        timeout = timeout,
        deadline = os.time() + timeout + 20,
        attempt = 1,
        cancelled = false,
        done = false,
    }
    active_jobs[job] = true
    local function launch()
        if job.cancelled or job.done then
            return
        end
        if workers_running >= Http.MAX_WORKERS then
            job.queued = true
            job_queue[#job_queue + 1] = job
            Log.info("http", "task_queued", { label = job.url, queue = #job_queue })
            return job
        end
        workers_running = workers_running + 1
        Log.info("http", "task_launch", { label = job.url })
        start_subprocess_job(job)
        return job
    end
    if opts.skip_online_check or Net.prepare_for_request() then
        return launch()
    end
    Log.info("http", "task_wait_connected", { label = job.url })
    Net.when_online(function()
        if not job.cancelled and not job.done then
            launch()
        end
    end)
    return job
end

function Http.request_sync(opts)
    local result
    local job = launch_curl(opts, function(res)
        result = res
    end)
    if job then
        while not job.done do
            if exit_ready(job.exit_path) then
                finish_curl(job)
                break
            end
            if os.time() >= job.deadline then
                kill_job(job)
                job.done = true
                active_jobs[job] = nil
                result = fail_res("timeout", "offline")
                Paths.remove_tree(job.dir)
                break
            end
            nap()
        end
        return result or fail_res("no result", "offline")
    end
    if socket_available() then
        Log.info("http", "socket_sync", { url = opts and opts.url })
        pcall(Net.res_init, false)
        return socket_request(opts)
    end
    return fail_res("no http transport", "offline")
end

Http.find_curl = find_curl

return Http
