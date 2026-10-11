-- Compat.lua: GuildSpy.API, the only route to client APIs that moved or may be
-- absent on Forever (Vanilla content on the Retail codebase). Nothing here is
-- put in _G. Helpers lifted from ..\Gnomesweeper\Compat.lua and
-- ..\AltStable\Compat.lua; lift more from there rather than rewriting them.
--
-- Guild API shapes (GetGuildRosterInfo's tuple, GetGuildEventInfo's) are NOT
-- measured yet: phase 0's /gspy probe measures them (docs/FOREVER-PROBE.md).
-- Until then nothing reads them by position except the probe, which dumps
-- every position it finds.

local ADDON = ...
GuildSpy = GuildSpy or {}
local API = {}
GuildSpy.API = API

-- The client build the notes and stubs describe: the API dump the tests check
-- against (C:\Projects\WoW\References\forever-api-1.60.1.70338.md).
GuildSpy.MEASURED_ON_BUILD = "1.60.1.70338"

-- The running client's "version.build", e.g. "1.60.1.70338".
function API.ClientBuild()
    local version, build = GetBuildInfo()
    if type(version) ~= "string" then return nil end
    return version .. "." .. tostring(build)
end

-- The addon's version from its TOC, or "dev" for an unpackaged copy (the
-- packager replaces the "@" .. "project-version@" token in every file it ships,
-- so the check is for an "@", never for the whole token).
function API.AddOnVersion(addon)
    local ns = rawget(_G, "C_AddOns")
    local get = (type(ns) == "table" and ns.GetAddOnMetadata) or rawget(_G, "GetAddOnMetadata")
    if type(get) ~= "function" then return "dev" end
    local ok, v = pcall(get, addon, "Version")
    if not ok or type(v) ~= "string" or v == "" or v:find("@", 1, true) then return "dev" end
    return v
end

-- The player's full name, with the surname every Forever character has.
-- Lifted from AltStable's API.PlayerFullName (measured on 69977 and 70009): on
-- 70009+ the surname is UnitName's SECOND return, the slot documented as the
-- realm. A first return that already has a space is a whole name.
function API.PlayerFullName()
    local name, second = UnitName("player")
    if type(name) ~= "string" or name == "" then return nil end
    if name:find(" ") then return name end
    if type(second) == "string" and second ~= "" then
        return name .. " " .. second
    end
    return name
end

-- Every return of fn(...), packed with its count: tuples with nils in them
-- must never be measured with #.
function API.Pack(fn, ...)
    if type(fn) ~= "function" then return { n = 0, missing = true } end
    local function pack(ok, ...)
        return { n = select("#", ...), ok = ok, ... }
    end
    return pack(pcall(fn, ...))
end

-- Asks the server for a fresh roster. The global GuildRoster is gone on
-- Forever; C_GuildInfo.GuildRoster is the replacement (API dump line 1784).
function API.RequestRoster()
    local ns = rawget(_G, "C_GuildInfo")
    if type(ns) == "table" and type(ns.GuildRoster) == "function" then
        pcall(ns.GuildRoster)
        return true
    end
    return false
end

-- Whether this character can read officer notes. The global is gone; the
-- C_GuildInfo one returns a bool (API dump line 1773). nil: unknown.
function API.CanViewOfficerNote()
    local ns = rawget(_G, "C_GuildInfo")
    if type(ns) ~= "table" or type(ns.CanViewOfficerNote) ~= "function" then return nil end
    local ok, v = pcall(ns.CanViewOfficerNote)
    if not ok then return nil end
    return v == true
end

-- Registers an event, reporting a refusal instead of throwing: an unknown name
-- throws on this client, and a false return is a refusal too (porting guide).
function API.RegisterEvent(frame, event)
    local ok, res = pcall(frame.RegisterEvent, frame, event)
    return ok and res ~= false
end
