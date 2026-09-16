--[[--
Official interruptible HTTP (KOReader #5002 / Trapper pattern).

When the UI is already inside `Trapper:wrap`, run a blocking `Client.request`
via `Trapper:dismissableRunInSubprocess` (same approach as newsdownloader,
wikipedia, assistant.koplugin).

Outside a Trapper wrap, fall back to callback-style `Http.request` (our
async_http subprocess poller — the non-blocking equivalent for plugins that
must keep a free UIManager loop).
]]

local Client = require("wereadlite.kindle.client")
local Http = require("wereadlite.async_http")
local Log = require("wereadlite.log")

local TrapHttp = {}

local function trapper()
    local ok, Trapper = pcall(require, "ui/trapper")
    if ok and Trapper and type(Trapper.dismissableRunInSubprocess) == "function" then
        return Trapper
    end
end

--- Blocking, dismissable request (parent must be Trapper-wrapped).
-- @return text, status, err, code, headers  (same as Client.request)
function TrapHttp.request_dismissable(opts, trap_widget)
    opts = opts or {}
    local Trapper = trapper()
    if not Trapper then
        return Client.request(opts)
    end
    if type(Trapper.isWrapped) == "function" and not Trapper:isWrapped() then
        Log.dbg("trap_http", "unwrapped_fallback_blocking")
        return Client.request(opts)
    end
    local completed, text, status, err, code, headers = Trapper:dismissableRunInSubprocess(function()
        return Client.request(opts)
    end, trap_widget == nil and true or trap_widget)
    if not completed then
        return nil, "cancelled", "Interrupted by user", 0, nil
    end
    return text, status, err, code, headers
end

--- Async request with callback(res) — always uses Http.request (subprocess/curl).
function TrapHttp.request(opts, callback)
    return Http.request(opts, callback)
end

return TrapHttp
