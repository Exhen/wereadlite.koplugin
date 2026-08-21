local UIManager = require("ui/uimanager")
local Config = require("wereadlite.config")
local CookieStore = require("wereadlite.cookie_store")
local Paths = require("wereadlite.paths")
local Log = require("wereadlite.log")

local Http = {
    POLL = 0.3,
}

local job_seq = 0
local CURL

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
    }
    for _, name in ipairs(names) do
        if exists(name) then
            CURL = name
            return CURL
        end
    end
    local pipe = io.popen("command -v curl 2>/dev/null")
    if pipe then
        local found = pipe:read("*l")
        pipe:close()
        if found and found ~= "" and exists(found) then
            CURL = found
            return CURL
        end
    end
    CURL = false
    return nil
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
    if text:find("timeout", 1, true)
        or text:find("Timed out", 1, true)
        or text:find("closed", 1, true)
        or text:find("refused", 1, true) then
        return "offline"
    end
    return "http_error"
end

local function kill_job(job)
    if not job or job.killed then
        return
    end
    job.killed = true
    local pid = tonumber((read_file(job.pid_path) or ""):match("%d+"))
    if pid then
        os.execute("pkill -9 -P " .. tostring(pid) .. " >/dev/null 2>&1")
        os.execute("kill -9 " .. tostring(pid) .. " >/dev/null 2>&1")
    end
end

local function finish(job)
    if job.done then
        return
    end
    job.done = true
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
        writeout = writeout,
        exit = exit_code,
        status = status,
        bytes = #body,
        header = last_status_line(headers),
        err = (#err_text > 0) and err_text:gsub("[%c]", " "):sub(1, 180) or nil,
    })
    if status ~= "ok" then
        Log.http_error(job.method, job.url, {
            code = code,
            writeout = writeout,
            exit = exit_code,
            status = status,
            err = err_text,
            status_line = last_status_line(headers),
            bytes = #body,
            body = body,
            content_type = header_field(headers, "content-type"),
        })
    end
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

local function arm(job)
    UIManager:scheduleIn(Http.POLL, function()
        if job.cancelled then
            kill_job(job)
            Paths.remove_tree(job.dir)
            return
        end
        if exit_ready(job.exit_path) then
            finish(job)
            return
        end
        if os.time() >= job.deadline then
            Log.warn("http", "curl_timeout", { url = job.url })
            kill_job(job)
            job.done = true
            if job.callback then
                job.callback({
                    ok = false,
                    body = "",
                    code = 0,
                    status = "offline",
                    err = "timeout",
                })
            end
            Paths.remove_tree(job.dir)
            return
        end
        arm(job)
    end)
end

local function write_config(job, opts)
    local lines = {
        "url = " .. cfg_quote(opts.url),
        "user-agent = " .. cfg_quote(opts.user_agent or Config.KINDLE_UA),
        "output = " .. cfg_quote(job.body_path),
        "dump-header = " .. cfg_quote(job.header_path),
        "max-time = " .. tostring(job.timeout or opts.timeout or 15),
        "connect-timeout = " .. tostring(math.min(8, tonumber(job.timeout or opts.timeout) or 15)),
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

function Http.available()
    return find_curl() ~= nil
end

function Http.cancel(job)
    if not job then
        return
    end
    job.cancelled = true
    job.done = true
    kill_job(job)
    Paths.remove_tree(job.dir)
end

local function fail_res(err, status)
    return {
        ok = false,
        body = "",
        code = 0,
        status = status or "http_error",
        err = err or "http_error",
        headers = "",
    }
end

local function nap()
    local ok, socket = pcall(require, "socket")
    if ok and socket and type(socket.sleep) == "function" then
        socket.sleep(0.05)
        return
    end
    os.execute("sleep 0.05 >/dev/null 2>&1")
end

local function launch(opts, callback)
    opts = opts or {}
    local curl = find_curl()
    if not curl then
        Log.warn("http", "no_curl")
        return nil, fail_res("curl missing", "offline")
    end
    if not opts.url or opts.url == "" then
        return nil, fail_res("empty url")
    end
    job_seq = job_seq + 1
    local root = plugin_cache_dir()
    mkdir(root)
    -- Include pid + random so forked image workers never share the same job dir.
    local pid = 0
    pcall(function()
        local ffi = require("ffi")
        ffi.cdef[[int getpid(void);]]
        pid = tonumber(ffi.C.getpid()) or 0
    end)
    local dir = string.format("%s/%d-%d-%d-%d", root, os.time(), job_seq, pid, math.random(100000, 999999))
    mkdir(dir)
    local timeout = math.max(3, tonumber(opts.timeout) or 15)
    local method = opts.method or (opts.body and "POST" or "GET")
    local job = {
        url = opts.url,
        method = method,
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
    remove_file(job.body_path)
    remove_file(job.header_path)
    remove_file(job.code_path)
    remove_file(job.exit_path)
    remove_file(job.pid_path)
    remove_file(job.err_path)
    local ok, err = write_config(job, opts)
    if not ok then
        Log.warn("http", "cfg_fail", { err = err })
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

function Http.request(opts, callback)
    local job, fail = launch(opts, callback)
    if not job then
        if callback then
            UIManager:nextTick(function()
                callback(fail)
            end)
        end
        return nil
    end
    arm(job)
    return job
end

function Http.request_sync(opts)
    local result
    local job, fail = launch(opts, function(res)
        result = res
    end)
    if not job then
        return fail
    end
    while not job.done do
        if exit_ready(job.exit_path) then
            finish(job)
            break
        end
        if os.time() >= job.deadline then
            Log.warn("http", "curl_timeout", { url = job.url })
            kill_job(job)
            job.done = true
            result = fail_res("timeout", "offline")
            Paths.remove_tree(job.dir)
            break
        end
        nap()
    end
    return result or fail_res("no result", "offline")
end

Http.find_curl = find_curl

return Http
