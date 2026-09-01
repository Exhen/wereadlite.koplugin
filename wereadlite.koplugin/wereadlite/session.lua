local CookieStore = require("wereadlite.cookie_store")
local Log = require("wereadlite.log")

local Session = {}

function Session.has_auth()
    return CookieStore.has_auth()
end

function Session.cookie_header()
    return CookieStore.header()
end

function Session.display_name()
    return CookieStore.display_name()
end

function Session.clear_auth()
    Log.info("session", "clear_auth")
    return CookieStore.clear()
end

-- Login flow should call this after a successful QR / Set-Cookie exchange.
function Session.save_from_set_cookie(raw)
    return CookieStore.merge_set_cookie(raw, "login")
end

function Session.save_from_header(text)
    return CookieStore.replace_header(text, "login")
end

-- The web reader's skey/sfs values may be rotated while the device sleeps.
-- Refreshing them is deliberately separate from clearing authentication: a
-- failed refresh must not turn a transient network problem into a logout.
function Session.refresh_async(on_done)
    local Shelf = require("wereadlite.kindle.shelf")
    return Shelf.refresh_session(on_done, false)
end

function Session.cancel_refresh()
    local ok, Shelf = pcall(require, "wereadlite.kindle.shelf")
    if ok and Shelf and type(Shelf.cancel_session_refresh) == "function" then
        return Shelf.cancel_session_refresh()
    end
end

return Session
