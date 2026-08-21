local Log = require("wereadlite.log")

local Paths = {}

local SOURCE = debug.getinfo(1, "S").source:gsub("^@", "")

local function lfs_mod()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok then
        return lfs
    end
end

function Paths.root()
    local src = SOURCE
    local root = src:match("(.+)/wereadlite/paths%.lua$")
    if root and root ~= "" then
        return root
    end
    return src:match("(.+)/[^/]+$") or "."
end

function Paths.ensure(dir)
    dir = tostring(dir or "")
    if dir == "" then
        return
    end
    local lfs = lfs_mod()
    if lfs then
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
        return
    end
    os.execute(string.format("mkdir -p %q", dir))
end

function Paths.remove_tree(path)
    path = tostring(path or "")
    if path == "" or path == "/" or path == "." then
        return
    end
    local lfs = lfs_mod()
    if lfs then
        local mode = lfs.attributes(path, "mode")
        if mode == "directory" then
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then
                    Paths.remove_tree(path .. "/" .. name)
                end
            end
            lfs.rmdir(path)
        elseif mode then
            os.remove(path)
        end
        return
    end
    os.execute(string.format("rm -rf %q", path))
end

function Paths.data_dir()
    local dir = Paths.root() .. "/data"
    Paths.ensure(dir)
    return dir
end

function Paths.cache_dir()
    local dir = Paths.root() .. "/cache"
    Paths.ensure(dir)
    return dir
end

function Paths.http_dir()
    local dir = Paths.cache_dir() .. "/http"
    Paths.ensure(dir)
    return dir
end

function Paths.login_dir()
    local dir = Paths.cache_dir() .. "/login"
    Paths.ensure(dir)
    return dir
end

function Paths.covers_dir()
    local dir = Paths.data_dir() .. "/covers"
    Paths.ensure(dir)
    return dir
end

function Paths.fonts_dir()
    local dir = Paths.data_dir() .. "/fonts"
    Paths.ensure(dir)
    return dir
end

function Paths.reading_dir()
    local dir = Paths.data_dir() .. "/reading"
    Paths.ensure(dir)
    return dir
end

function Paths.purge_cache()
    local cache = Paths.root() .. "/cache"
    local data = Paths.root() .. "/data"
    Paths.remove_tree(cache)
    Paths.remove_tree(data .. "/http")
    Paths.remove_tree(data .. "/login")
    Paths.ensure(Paths.cache_dir())
    Log.info("paths", "purge_cache")
end

return Paths
