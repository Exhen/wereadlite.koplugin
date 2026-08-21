local Config = require("wereadlite.config")
local Log = require("wereadlite.log")
local Settings = require("wereadlite.settings")

local Images = {}

local IMAGE_EXTS = { "jpg", "jpeg", "png", "webp", "gif" }

local function mkdir(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs then
        if lfs.attributes(path, "mode") ~= "directory" then
            lfs.mkdir(path)
        end
        return
    end
    os.execute(string.format("mkdir -p %q", path))
end

local function valid_file(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    local size = file:seek("end")
    file:close()
    return size and size >= 32
end

local function unescape_url(url)
    url = tostring(url or "")
    url = url:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&apos;", "'")
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    if url:sub(1, 2) == "//" then
        url = "https:" .. url
    end
    return url
end

local function is_remote(url)
    url = tostring(url or "")
    return url:find("^https?://") ~= nil
end

local function digest(text)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and type(sha2.md5) == "function" then
        local hex = sha2.md5(text)
        if type(hex) == "string" and hex ~= "" then
            return hex
        end
    end
    local h = 2166136261
    for i = 1, #text do
        h = (h * 16777619 + text:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

local function stem_for(cache_dir, url)
    local hex = digest(url)
    local base = url:match("([^/?#]+)$") or "img"
    base = base:gsub("%?.*$", ""):gsub("%.%w+$", ""):gsub("[^%w%-_]", "_")
    if #base > 24 then
        base = base:sub(-24)
    end
    if base == "" then
        base = "img"
    end
    return cache_dir .. "/" .. hex:sub(1, 12) .. "_" .. base
end

local function cached_path(stem)
    for _, ext in ipairs(IMAGE_EXTS) do
        local path = stem .. "." .. ext
        if valid_file(path) then
            return path
        end
    end
end

local function collect_urls(html)
    local urls, seen = {}, {}
    local function add(raw)
        raw = tostring(raw or "")
        local url = unescape_url(raw)
        if is_remote(url) and not seen[url] then
            seen[url] = true
            urls[#urls + 1] = { raw = raw, url = url }
        end
    end
    html = tostring(html or "")
    for url in html:gmatch('[sS][rR][cC]%s*=%s*"([^"]+)"') do
        add(url)
    end
    for url in html:gmatch("[sS][rR][cC]%s*=%s*'([^']+)'") do
        add(url)
    end
    for url in html:gmatch('[dD]ata%-[sS][rR][cC]%s*=%s*"([^"]+)"') do
        add(url)
    end
    for url in html:gmatch("url%(%s*&quot;([^&]+)&quot;%s*%)") do
        add(url)
    end
    for url in html:gmatch('url%(%s*"([^"]+)"%s*%)') do
        add(url)
    end
    for url in html:gmatch("url%(%s*'([^']+)'%s*%)") do
        add(url)
    end
    for url in html:gmatch("url%(%s*(https?://[^%s%)]+)%s*%)") do
        add(url)
    end
    return urls
end

local function replace_all(html, from, to)
    if from == "" or from == to then
        return html
    end
    local out, i, n = {}, 1, #from
    while true do
        local at = html:find(from, i, true)
        if not at then
            out[#out + 1] = html:sub(i)
            break
        end
        out[#out + 1] = html:sub(i, at - 1)
        out[#out + 1] = to
        i = at + n
    end
    return table.concat(out)
end

function Images.dir(book_dir)
    local path = tostring(book_dir or "") .. "/img"
    mkdir(path)
    return path
end

local function apply_local(html, item, path)
    local name = path:match("([^/]+)$") or ""
    local local_src = name ~= "" and ("img/" .. name) or path
    html = replace_all(html, item.url, local_src)
    if item.raw ~= item.url then
        html = replace_all(html, item.raw, local_src)
    end
    return html, local_src
end

local function subprocess_util()
    local ok, ffiUtil = pcall(require, "ffi/util")
    if ok and ffiUtil and type(ffiUtil.runInSubProcess) == "function"
        and type(ffiUtil.isSubProcessDone) == "function" then
        return ffiUtil
    end
end

-- Hard curl budget; fail fast so one bad URL cannot stall chapter open.
local IMAGE_TIMEOUT = 8
local WORKER_TIMEOUT_S = 10
local LOCALIZE_BUDGET_S = 25

local function sh_quote(text)
    return "'" .. tostring(text or ""):gsub("'", "'\\''") .. "'"
end

local function sniff_ext(body)
    if type(body) ~= "string" or #body < 12 then
        return nil
    end
    local b1, b2, b3, b4 = body:byte(1, 4)
    if b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then
        return "jpg"
    end
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then
        return "png"
    end
    if body:sub(1, 6) == "GIF87a" or body:sub(1, 6) == "GIF89a" then
        return "gif"
    end
    if body:sub(1, 4) == "RIFF" and body:sub(9, 12) == "WEBP" then
        return "webp"
    end
end

local function curl_bin()
    local ok, Http = pcall(require, "wereadlite.async_http")
    if ok and Http and type(Http.find_curl) == "function" then
        return Http.find_curl()
    end
end

-- Dedicated curl fetch to a unique stem path — never shares async_http job dirs
-- (forked workers previously raced on the same job_seq directory and hung).
local function download_one(url, stem, referer)
    url = tostring(url or "")
    if url == "" then
        return nil, "empty url"
    end
    local curl = curl_bin()
    if not curl then
        return nil, "no curl"
    end
    local part = stem .. ".part." .. tostring(math.random(100000, 999999))
    local hdr = part .. ".hdr"
    os.remove(part)
    os.remove(hdr)
    local cmd = table.concat({
        sh_quote(curl),
        "-L",
        "--max-redirs", "5",
        "--max-time", tostring(IMAGE_TIMEOUT),
        "--connect-timeout", "5",
        "-sS",
        "-A", sh_quote(Config.KINDLE_UA),
        "-H", sh_quote("Accept: image/avif,image/webp,image/apng,image/*,*/*;q=0.8"),
        "-e", sh_quote(referer or Config.READER_URL or Config.ORIGIN),
        "-o", sh_quote(part),
        "-D", sh_quote(hdr),
        "-w", "%{http_code}",
        sh_quote(url),
    }, " ")
    local pipe = io.popen(cmd .. " 2>/dev/null")
    if not pipe then
        return nil, "popen failed"
    end
    local writeout = tostring(pipe:read("*a") or "")
    local ok_close, _, exit_or_signal = pipe:close()
    local http_code = tonumber(writeout:match("(%d%d%d)")) or 0
    if http_code == 0 then
        local raw = io.open(hdr, "rb")
        if raw then
            local headers = raw:read("*a") or ""
            raw:close()
            for line in headers:gmatch("[^\r\n]+") do
                local n = line:match("^HTTP/[%d.]+%s+(%d%d%d)")
                if n then
                    http_code = tonumber(n) or http_code
                end
            end
        end
    end
    os.remove(hdr)
    if not ok_close and exit_or_signal then
        os.remove(part)
        return nil, "curl exit"
    end
    if http_code ~= 0 and (http_code < 200 or http_code >= 400) then
        os.remove(part)
        return nil, "http_" .. tostring(http_code)
    end
    local file = io.open(part, "rb")
    if not file then
        return nil, "missing body"
    end
    local head = file:read(32) or ""
    file:close()
    local ext = sniff_ext(head)
    if not ext then
        os.remove(part)
        return nil, "not an image"
    end
    local dest = stem .. "." .. ext
    os.remove(dest)
    local renamed = os.rename(part, dest)
    if not renamed then
        -- Cross-device fallback.
        local src = io.open(part, "rb")
        local dst = src and io.open(dest, "wb")
        if not src or not dst then
            if src then src:close() end
            if dst then dst:close() end
            os.remove(part)
            return nil, "write failed"
        end
        dst:write(src:read("*a") or "")
        src:close()
        dst:close()
        os.remove(part)
    end
    if not valid_file(dest) then
        os.remove(dest)
        return nil, "empty file"
    end
    Log.dbg("images", "download", { url = url, dest = dest })
    return dest
end

local function safe_download(url, stem, referer)
    local ok, path_or_err, err = pcall(download_one, url, stem, referer)
    if not ok then
        Log.warn("images", "download_throw", { url = url, err = path_or_err })
        return nil, path_or_err
    end
    if not path_or_err then
        Log.warn("images", "download_fail", { url = url, err = err })
        return nil, err
    end
    return path_or_err
end

local function run_jobs(jobs, concurrency, on_done, deadline)
    if #jobs == 0 then
        return
    end
    concurrency = math.max(1, tonumber(concurrency) or 1)
    deadline = tonumber(deadline) or (os.time() + LOCALIZE_BUDGET_S)
    local ffiUtil = concurrency > 1 and subprocess_util() or nil
    if not ffiUtil then
        for _, job in ipairs(jobs) do
            if os.time() >= deadline then
                Log.warn("images", "budget_skip", { url = job.url })
                pcall(on_done, job)
            else
                safe_download(job.url, job.stem, job.referer)
                local ok, err = pcall(on_done, job)
                if not ok then
                    Log.warn("images", "on_done_throw", { url = job.url, err = err })
                end
            end
        end
        return
    end
    local next_index = 1
    local running = {}
    local function sleep()
        if type(ffiUtil.usleep) == "function" then
            ffiUtil.usleep(30000)
        elseif type(ffiUtil.sleep) == "function" then
            ffiUtil.sleep(0)
        end
    end
    local function finish_job(job)
        local ok, err = pcall(on_done, job)
        if not ok then
            Log.warn("images", "on_done_throw", { url = job.url, err = err })
        end
    end
    local function kill_worker(worker)
        if worker and worker.pid and type(ffiUtil.terminateSubProcess) == "function" then
            pcall(ffiUtil.terminateSubProcess, worker.pid)
        end
    end
    local function start_one(job)
        local url, stem, referer = job.url, job.stem, job.referer
        local pid = ffiUtil.runInSubProcess(function()
            pcall(download_one, url, stem, referer)
        end)
        if not pid then
            Log.warn("images", "fork_fail", { url = url })
            safe_download(url, stem, referer)
            finish_job(job)
            return
        end
        Log.dbg("images", "worker", { pid = pid, url = url })
        running[#running + 1] = { pid = pid, job = job, started = os.time() }
    end
    while next_index <= #jobs or #running > 0 do
        local now = os.time()
        local budget_hit = now >= deadline
        while (not budget_hit) and #running < concurrency and next_index <= #jobs do
            start_one(jobs[next_index])
            next_index = next_index + 1
        end
        -- Over budget: do not start more; mark remaining as skipped.
        if budget_hit then
            while next_index <= #jobs do
                Log.warn("images", "budget_skip", { url = jobs[next_index].url })
                finish_job(jobs[next_index])
                next_index = next_index + 1
            end
        end
        if #running == 0 then
            break
        end
        local still = {}
        for _, worker in ipairs(running) do
            if ffiUtil.isSubProcessDone(worker.pid) then
                finish_job(worker.job)
            elseif (now - (worker.started or now)) >= WORKER_TIMEOUT_S or budget_hit then
                Log.warn("images", "worker_timeout", {
                    url = worker.job.url,
                    pid = worker.pid,
                    waited = now - (worker.started or now),
                    budget = budget_hit,
                })
                kill_worker(worker)
                finish_job(worker.job)
            else
                still[#still + 1] = worker
            end
        end
        running = still
        if #running > 0 then
            sleep()
        end
    end
end

function Images.localize(html, book_dir, on_progress, opts)
    html = tostring(html or "")
    opts = opts or {}
    local fetch = opts.fetch ~= false
    local urls = collect_urls(html)
    local function report(done, total)
        if type(on_progress) == "function" then
            pcall(on_progress, done, total)
        end
    end
    if #urls == 0 then
        report(0, 0)
        return html
    end
    report(0, #urls)
    local cache_dir = Images.dir(book_dir)
    local referer = Config.READER_URL or Config.ORIGIN
    local ok_count, fail_count, done = 0, 0, 0
    local jobs = {}
    for i, item in ipairs(urls) do
        item.stem = stem_for(cache_dir, item.url)
        item.referer = referer
        item.index = i
        local path = cached_path(item.stem)
        if path then
            local ok_apply, new_html = pcall(apply_local, html, item, path)
            if ok_apply then
                html = new_html
                ok_count = ok_count + 1
                Log.dbg("images", "ready", { index = i, total = #urls, src = path:match("([^/]+)$"), cached = true })
            else
                fail_count = fail_count + 1
                Log.warn("images", "apply_fail", { index = i, err = new_html })
            end
            done = done + 1
        elseif fetch then
            jobs[#jobs + 1] = item
        else
            fail_count = fail_count + 1
            done = done + 1
        end
    end
    if done > 0 then
        report(done, #urls)
    end
    if not fetch or #jobs == 0 then
        Log.info("images", "localize", {
            total = #urls,
            ok = ok_count,
            fail = fail_count,
            jobs = 0,
            fetch = fetch,
            dir = cache_dir,
        })
        return html
    end
    local concurrency = Settings.image_concurrency()
    local deadline = os.time() + LOCALIZE_BUDGET_S
    Log.info("images", "queue", {
        total = #urls,
        cached = done,
        jobs = #jobs,
        concurrency = concurrency,
        budget_s = LOCALIZE_BUDGET_S,
    })
    run_jobs(jobs, concurrency, function(item)
        local path = cached_path(item.stem)
        if path then
            local ok_apply, out_html, local_src = pcall(apply_local, html, item, path)
            if ok_apply and out_html then
                html = out_html
                ok_count = ok_count + 1
                Log.dbg("images", "ready", {
                    index = item.index,
                    total = #urls,
                    src = local_src,
                    cached = false,
                })
            else
                fail_count = fail_count + 1
                Log.warn("images", "apply_fail", {
                    index = item.index,
                    err = out_html,
                    url = item.url,
                })
            end
        else
            fail_count = fail_count + 1
            Log.warn("images", "skip", { index = item.index, total = #urls, url = item.url })
        end
        done = done + 1
        report(done, #urls)
    end, deadline)
    Log.info("images", "localize", {
        total = #urls,
        ok = ok_count,
        fail = fail_count,
        dir = cache_dir,
        concurrency = concurrency,
    })
    return html
end

return Images
