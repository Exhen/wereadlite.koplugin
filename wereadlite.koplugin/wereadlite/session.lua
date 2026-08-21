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

return Session
