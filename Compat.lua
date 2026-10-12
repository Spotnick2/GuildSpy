-- Compat.lua: GuildSpy.API, the only route to client APIs that moved or may be
-- absent on Forever (Vanilla content on the Retail codebase). Nothing here is
-- put in _G. Helpers lifted from ..\Gnomesweeper\Compat.lua and
-- ..\AltStable\Compat.lua; lift more from there rather than rewriting them.
--
-- Guild API shapes are measured (docs/FOREVER-PROBE.md, 1.60.1.70338), and
-- this file is the only one that knows their positions: everything else gets
-- named structs from API.ReadRoster and API.ReadEventLog.

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

-- A frame from a client template, and whether the template made it: a missing
-- template returns a bare frame, so `proof` names a field the template sets.
-- Lifted from Gnomesweeper's API.SafeFrame.
function API.SafeFrame(ftype, parent, template, proof)
    local ok, f = pcall(CreateFrame, ftype, nil, parent, template)
    if ok and f then return f, (proof == nil) or f[proof] ~= nil end
    return CreateFrame(ftype, nil, parent), false
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

local function isGuid(v) return type(v) == "string" and v:find("^Player%-") ~= nil end

-- The guild's key: "<guild name>-<guild realm>". The realm is GetGuildInfo's
-- 4th return, the GUILD's realm (it can differ from the player's). nil while
-- the client doesn't know yet, or out of a guild.
function API.GuildKey()
    if not IsInGuild() then return nil end
    local name, _, _, realm = GetGuildInfo("player")
    if type(name) ~= "string" or name == "" then return nil end
    if type(realm) ~= "string" or realm == "" then realm = GetRealmName() end
    if type(realm) ~= "string" or realm == "" then return nil end
    -- One spelling whichever source gave it ("Classic Beta PvE 2" and
    -- "ClassicBetaPvE2" are one realm), so alts never split one guild in two.
    realm = realm:gsub("[%s%-']", "")
    return name .. "-" .. realm, name
end

-- Years, months, days, hours ago -> hours. A month is counted as 730 h; the
-- client may count calendar months, so totals can wobble by about a day at a
-- month boundary. Nothing may treat a small change in a large total as a login
-- (Roster's RETURN rule compares against the time since we last looked).
local function hours(y, m, d, h)
    return (y or 0) * 8760 + (m or 0) * 730 + (d or 0) * 24 + (h or 0)
end

local function lastOnlineHours(i)
    local y, m, d, h = GetGuildRosterLastOnline(i)
    if y == nil and m == nil and d == nil and h == nil then return nil end   -- online: four nils
    return hours(y, m, d, h)
end

-- The whole roster, or nil and why it isn't complete. Measured (70338):
-- GetGuildRosterInfo returns 17 values in Retail's order, the GUID 17th, the
-- name "First Surname" with no realm, rankIndex 0-based (0 = Guild Master),
-- the officer note "" when this character can't view it (so it is reported
-- as nil here: unreadable is not empty). GuildControlGetRankName is 1-based.
function API.ReadRoster()
    -- Only "show offline members" ON was measured (70338): with it off the
    -- roster may list the online members only, and a diff would then take every
    -- offline member for a departure. Refuse; the shell tells the player. (The
    -- setting is Blizzard's guild window's, so GuildSpy doesn't flip it.)
    local showOffline = rawget(_G, "GetGuildRosterShowOffline")
    if type(showOffline) == "function" and showOffline() == false then return nil, "showOffline" end
    local total = GetNumGuildMembers()
    if type(total) ~= "number" or total <= 0 then return nil, "no members yet" end
    local numRanks = GuildControlGetNumRanks()
    if type(numRanks) ~= "number" or numRanks <= 0 then return nil, "no ranks yet" end
    local ranks = {}
    for r = 1, numRanks do
        local rn = GuildControlGetRankName(r)
        if type(rn) ~= "string" then return nil, "rank " .. r .. " not loaded" end
        ranks[r] = rn
    end
    local canView = API.CanViewOfficerNote() == true
    local members, count = {}, 0
    for i = 1, total do
        local name, _, rankIndex, level, _, _, note, onote, online, _, class,
              _, _, _, _, _, guid = GetGuildRosterInfo(i)
        if type(name) ~= "string" or name == "" or not isGuid(guid) or type(rankIndex) ~= "number" then
            return nil, "row " .. i .. " incomplete"
        end
        if members[guid] then return nil, "duplicate GUID at row " .. i end
        if rankIndex < 0 or rankIndex >= numRanks then return nil, "row " .. i .. " has a rank not loaded yet" end
        members[guid] = {
            name = name, rank = rankIndex, level = level, class = class,
            note = note or "", onote = canView and (onote or "") or nil,
            online = online == true, lastOnlineHours = (online ~= true) and lastOnlineHours(i) or nil,
        }
        count = count + 1
    end
    -- No MOTD here: C_GuildInfo.GetMOTD is protected in some state (#16), and
    -- pcall doesn't stop the block being blamed on us. The shell takes it from
    -- the GUILD_MOTD event instead.
    return { members = members, count = count, ranks = ranks, canViewOfficer = canView }
end

function API.QueryEventLog()
    if type(rawget(_G, "QueryGuildEventLog")) == "function" then pcall(QueryGuildEventLog) end
end

-- The server's guild event log, oldest first, capped at 100 (measured). Names
-- are nil until the burst of GUILD_EVENT_LOG_UPDATE has settled: read it only
-- after that. Ages are whole hours (years/months/days/hours ago).
function API.ReadEventLog()
    local n = GetNumGuildEvents()
    local out = {}
    for i = 1, (type(n) == "number" and n or 0) do
        local kind, p1, p2, rank, y, m, d, h = GetGuildEventInfo(i)
        if type(kind) == "string" then
            out[#out + 1] = { kind = kind, p1 = p1, p2 = p2, rank = rank, ageHours = hours(y, m, d, h) }
        end
    end
    return out
end
