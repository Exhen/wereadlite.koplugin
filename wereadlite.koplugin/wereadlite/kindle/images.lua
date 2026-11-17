local Config = require("wereadlite.config")
local Log = require("wereadlite.log")
local Paths = require("wereadlite.paths")
local Settings = require("wereadlite.settings")
local Slice = require("wereadlite.slice")
local UIManager = require("ui/uimanager")

local Images = {}

local IMAGE_EXTS = { "jpg", "jpeg", "png", "webp", "gif" }
local sniff_ext
local replace_all
local apply_local

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

local function canonical_url(url)
    url = unescape_url(url)
    -- A fragment never changes the downloaded image.  Normalize the scheme
    -- and host as well so equivalent CSS/HTML references share one job.
    url = url:gsub("#.*$", "")
    url = url:gsub("^(https?)://([^/]+)", function(scheme, host)
        return scheme:lower() .. "://" .. host:lower()
    end)
    return url
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

-- A chapter directory is wiped when the book is left, so an image downloaded
-- for one chapter had to be fetched again on the next open.  Keep a copy under
-- cache/images/: the file name carries a hash of the URL, so entries never
-- collide.  A URL that answered "not found" is remembered too, because WeRead
-- emits background-image rules for files that are simply absent from the CDN
-- and each of those costs a round trip per chapter.
local MISS_TTL = 7 * 24 * 3600
local store_path_cache

local function store_dir()
    if not store_path_cache then
        store_path_cache = Paths.cache_dir() .. "/images"
        mkdir(store_path_cache)
    end
    return store_path_cache
end

local function base_name(stem)
    return tostring(stem or ""):match("([^/]+)$") or stem
end

local function copy_file(from, to)
    local src = io.open(from, "rb")
    if not src then
        return false
    end
    local body = src:read("*a")
    src:close()
    if not body then
        return false
    end
    local dst = io.open(to, "wb")
    if not dst then
        return false
    end
    dst:write(body)
    dst:close()
    return true
end

local function cached_path(stem)
    for _, ext in ipairs(IMAGE_EXTS) do
        local path = stem .. "." .. ext
        if valid_file(path) then
            return path
        end
    end
    local name = base_name(stem)
    for _, ext in ipairs(IMAGE_EXTS) do
        local stored = store_dir() .. "/" .. name .. "." .. ext
        if valid_file(stored) then
            -- Copy back so the chapter's relative "img/<name>" reference works.
            local path = stem .. "." .. ext
            if copy_file(stored, path) then
                return path
            end
        end
    end
end

local function recent_miss(stem)
    local file = io.open(store_dir() .. "/" .. base_name(stem) .. ".miss", "r")
    if not file then
        return false
    end
    local stamp = tonumber(file:read("*l") or "")
    file:close()
    return stamp ~= nil and os.time() - stamp < MISS_TTL
end

local function mark_miss(stem)
    local file = io.open(store_dir() .. "/" .. base_name(stem) .. ".miss", "w")
    if not file then
        return
    end
    file:write(tostring(os.time()))
    file:close()
end

-- Only a definitive answer is worth remembering; a timeout or DNS hiccup must
-- not keep an image away for a week.
local function gone_for_good(res)
    local code = tonumber(res and res.code) or 0
    return code == 404 or code == 403 or code == 410
end

local function collect_urls(html)
    local urls, seen = {}, {}
    local function add(raw, kind)
        raw = tostring(raw or "")
        local url = unescape_url(raw)
        local key = canonical_url(url)
        if is_remote(key) and key ~= "" and not seen[key] then
            seen[key] = true
            urls[#urls + 1] = { raw = raw, url = key, kind = kind }
        end
    end
    html = tostring(html or "")
    -- Most chapters have neither images nor CSS backgrounds: skip every scan
    -- below unless the document mentions something they could find.
    local lower = html:lower()
    if not lower:find("<img", 1, true) and not lower:find("background", 1, true) then
        return urls
    end
    local style_blocks = {}
    for css in html:gmatch("<[sS][tT][yY][lL][eE][^>]*>(.-)</[sS][tT][yY][lL][eE]%s*>") do
        style_blocks[#style_blocks + 1] = css
    end
    local styles = table.concat(style_blocks, "\n")
    for attrs in html:gmatch("<[iI][mM][gG]%f[%s/>]([^>]*)>") do
        local src = attrs:match('%f[%w][sS][rR][cC]%s*=%s*"([^"]+)"')
            or attrs:match("%f[%w][sS][rR][cC]%s*=%s*'([^']+)'")
        local lazy = attrs:match('%f[%w][dD]ata%-[sS][rR][cC]%s*=%s*"([^"]+)"')
            or attrs:match("%f[%w][dD]ata%-[sS][rR][cC]%s*=%s*'([^']+)'")
        add(lazy or src, "img")
    end
    -- Cache every background-image declared by WeRead.  CSS rules can be
    -- activated indirectly (pseudo elements, inherited classes, or markup
    -- added by CRE), so filtering by classes here leaves remote resources in
    -- the final document and makes the renderer try the network again.
    -- Do not require a balanced CSS rule here.  WeRead occasionally emits
    -- compressed/partial style text, and the resource must still be found
    -- and replaced when it is already present in the document.
    for background in styles:gmatch("[bB][aA][cC][kK][gG][rR][oO][uU][nN][dD]%s*%-%s*[iI][mM][aA][gG][eE]%s*:%s*[uU][rR][lL]%s*%(%s*([^)]-)%s*%)") do
        background = background:gsub("^%s*['\"]", ""):gsub("['\"]%s*$", "")
        add(background, "css")
    end
    return urls
end

local function save_image_body(stem, body)
    local ext = sniff_ext(body)
    if not ext then
        return nil, "not an image"
    end
    local path = stem .. "." .. ext
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then
        return nil, "write failed"
    end
    file:write(body)
    file:close()
    os.remove(path)
    if not os.rename(tmp, path) then
        os.remove(tmp)
        return nil, "rename failed"
    end
    copy_file(path, store_dir() .. "/" .. base_name(stem) .. "." .. ext)
    return path
end

function Images.localize_async(html, book_dir, on_progress, on_done, opts)
    html = tostring(html or "")
    opts = opts or {}
    local Http = require("wereadlite.async_http")
    local collect_started = Log.now_ms and Log.now_ms() or 0
    local urls = collect_urls(html)
    Log.info("images", "async_collect", {
        bytes = #html,
        candidates = #urls,
        elapsed_ms = collect_started > 0 and math.floor((Log.now_ms() - collect_started) + 0.5) or nil,
    })
    local state = {
        cancelled = false,
        finished = false,
        active = {},
        next_index = 1,
        done = 0,
        total = #urls,
    }

    local function report()
        if type(on_progress) == "function" then
            pcall(on_progress, state.done, state.total)
        end
    end

    local function finish()
        if state.finished or state.cancelled then
            return
        end
        state.finished = true
        if type(on_done) == "function" then
            on_done(html)
        end
    end

    function state:cancel()
        if self.cancelled or self.finished then
            return
        end
        self.cancelled = true
        for job in pairs(self.active) do
            Http.cancel(job)
        end
        self.active = {}
    end

    if #urls == 0 then
        state.done = 1
        state.total = 1
        report()
        UIManager:nextTick(finish)
        return state
    end

    local cache_dir = Images.dir(book_dir)
    local pending = {}
    for _, item in ipairs(urls) do
        item.stem = stem_for(cache_dir, item.url)
        local path = cached_path(item.stem)
        if path then
            html = apply_local(html, item, path)
            state.done = state.done + 1
        elseif recent_miss(item.stem) then
            -- Known 404: no request, the URL stays as it is in the document.
            state.done = state.done + 1
            Log.dbg("images", "skip_miss", { url = item.url })
        else
            pending[#pending + 1] = item
        end
    end
    urls = pending
    state.total = state.done + #pending
    report()
    if #pending == 0 then
        UIManager:nextTick(finish)
        return state
    end

    -- Images are small and independent; the settings default (4) parses faster
    -- than the old cap of 2 allowed.
    local concurrency = math.min(4, math.max(1, tonumber(Settings.image_concurrency()) or 1))
    local pump
    local function complete_item(item, res)
        if state.cancelled or state.finished then
            return
        end
        local path
        if res and res.ok and type(res.body) == "string" then
            path = save_image_body(item.stem, res.body)
        end
        if path then
            html = apply_local(html, item, path)
        else
            -- A failed download must not destroy the CSS declaration.  The
            -- old behavior replaced the URL with an empty string, producing
            -- background-image:url() even though no local file existed.
            -- Keep the original URL so a transient image failure cannot
            -- corrupt the chapter stylesheet.
            Log.warn("images", "async_download_fail", {
                url = item.url,
                kind = item.kind,
            })
            if gone_for_good(res) then
                mark_miss(item.stem)
            end
        end
        state.done = state.done + 1
        report()
        pump()
    end

    pump = function()
        if state.cancelled or state.finished then
            return
        end
        local active_count = 0
        for _ in pairs(state.active) do
            active_count = active_count + 1
        end
        while active_count < concurrency and state.next_index <= #urls do
            local item = urls[state.next_index]
            state.next_index = state.next_index + 1
            local job
            Log.dbg("images", "async_start", { index = state.next_index - 1, total = #urls, url = item.url })
            job = Http.request({
                url = item.url,
                timeout = tonumber(opts.timeout) or 6,
                accept = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
                referer = Config.READER_URL or Config.ORIGIN,
                user_agent = Config.KINDLE_UA,
                send_cookie = false,
                absorb_cookies = false,
            }, function(res)
                if job then
                    state.active[job] = nil
                end
                complete_item(item, res)
            end)
            if job then
                state.active[job] = true
                active_count = active_count + 1
            end
        end
        if state.done >= state.total then
            finish()
        end
    end
    UIManager:nextTick(pump)
    return state
end

replace_all = function(html, from, to)
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

-- Pixel size of an image file, for telling a one-character glyph image from a
-- real illustration.  Reads only the header.  Returns nil when unknown
-- (unsupported format, unreadable file, or remote URL left in place).
local function u16be(s, i)
    local a, b = s:byte(i, i + 1)
    if not a or not b then
        return nil
    end
    return a * 256 + b
end

local function u16le(s, i)
    local a, b = s:byte(i, i + 1)
    if not a or not b then
        return nil
    end
    return b * 256 + a
end

local function u32be(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not a or not b or not c or not d then
        return nil
    end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function u32le(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not a or not b or not c or not d then
        return nil
    end
    return ((d * 256 + c) * 256 + b) * 256 + a
end

local SOF_MARKERS = {
    [0xC0] = true, [0xC1] = true, [0xC2] = true, [0xC3] = true,
    [0xC5] = true, [0xC6] = true, [0xC7] = true,
    [0xC9] = true, [0xCA] = true, [0xCB] = true,
    [0xCD] = true, [0xCE] = true, [0xCF] = true,
}

local function jpeg_size(data)
    local i, n = 3, #data
    while i + 1 <= n do
        if data:byte(i) ~= 0xFF then
            i = i + 1
        else
            local marker = data:byte(i + 1)
            if marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
                i = i + 2
            elseif marker == 0xDA then
                return nil
            else
                local len = u16be(data, i + 2)
                if not len or len < 2 then
                    return nil
                end
                if SOF_MARKERS[marker] then
                    return u16be(data, i + 7), u16be(data, i + 5)
                end
                i = i + 2 + len
            end
        end
    end
end

local function u24le(s, i)
    local a, b, c = s:byte(i, i + 2)
    if not a or not b or not c then
        return nil
    end
    return a + b * 256 + c * 65536
end

local function webp_size(data)
    local chunk = data:sub(13, 16)
    if chunk == "VP8X" then
        -- Canvas width/height are stored minus one, 24-bit little endian each.
        local w, h = u24le(data, 25), u24le(data, 28)
        if not w or not h then
            return nil
        end
        return w + 1, h + 1
    elseif chunk == "VP8L" and data:byte(21) == 0x2F then
        local b1, b2, b3, b4 = data:byte(22, 25)
        if not b1 or not b4 then
            return nil
        end
        -- 14 bits of width-1 then 14 bits of height-1, little endian bit order.
        local value = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        return value % 16384 + 1, math.floor(value / 16384) % 16384 + 1
    elseif chunk == "VP8 " and data:byte(24) == 0x9D and data:byte(25) == 0x01 then
        local w, h = u16le(data, 27), u16le(data, 29)
        if not w or not h then
            return nil
        end
        return w % 16384, h % 16384
    end
end

function Images.pixel_size(path)
    path = tostring(path or "")
    if path == "" or path:find("^https?://") then
        return nil
    end
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read(65536) or ""
    file:close()
    -- A GIF header is the shortest of the formats handled here; each reader
    -- below rejects a header that is too short on its own.
    if #data < 13 then
        return nil
    end
    if data:byte(1) == 0x89 and data:sub(2, 4) == "PNG" then
        return u32be(data, 17), u32be(data, 21)
    elseif data:sub(1, 3) == "GIF" then
        return u16le(data, 7), u16le(data, 9)
    elseif data:byte(1) == 0xFF and data:byte(2) == 0xD8 then
        return jpeg_size(data)
    elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return webp_size(data)
    end
end

function Images.dir(book_dir)
    local path = tostring(book_dir or "") .. "/img"
    mkdir(path)
    return path
end

apply_local = function(html, item, path)
    local name = path:match("([^/]+)$") or ""
    local local_src = name ~= "" and ("img/" .. name) or path
    html = replace_all(html, item.url, local_src)
    if item.raw ~= item.url then
        html = replace_all(html, item.raw, local_src)
    end
    -- Also replace the complete CSS url() token.  This covers CSS escaping
    -- and whitespace around the URL where a plain string replacement can
    -- leave the declaration pointing at the remote resource.  Only text that
    -- replace_all left behind can match, so skip the scan when none is left.
    if html:find(item.url, 1, true) then
        local escaped = item.url:gsub("([%%%]%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
        html = html:gsub("([uU][rR][lL]%s*%(%s*['\"]?)" .. escaped .. "(['\"]?%s*%))", function(prefix, suffix)
            return prefix .. local_src .. suffix
        end)
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

sniff_ext = function(body)
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
        report(1, 1)
        return html
    end
    report(0, #urls)
    local cache_dir = Images.dir(book_dir)
    local referer = Config.READER_URL or Config.ORIGIN
    local ok_count, fail_count, done = 0, 0, 0
    local jobs = {}
    for i, item in ipairs(urls) do
        Slice.point()
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
        elseif fetch and not recent_miss(item.stem) then
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
