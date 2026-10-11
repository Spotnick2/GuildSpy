-- Probe.lua: phase 0's measurements (docs/FOREVER-PROBE.md). For measuring only.
--
-- Nothing in GuildSpy may read a guild tuple by position before this has
-- measured it on the live client. `/gspy probe` dumps what the roster, the
-- ranks, the event log, C_Club and the ERR_GUILD_* strings look like into
-- GuildSpyDB.probe; a /reload writes it to
-- WTF\Account\<acct>\SavedVariables\GuildSpy.lua, to be read from disk.
--
-- Always on (cheap, capped): a timeline of the guild events from login, with
-- how complete the roster was at each GUILD_ROSTER_UPDATE (GuildSpyDB.probeLog).
-- `/gspy probe watch` also records every CHAT_MSG_SYSTEM line, to catch the
-- real text of joins, leaves, kicks and promotions when they happen.

local ADDON = ...
GuildSpy = GuildSpy or {}
local API = GuildSpy.API
local Probe = {}
GuildSpy.Probe = Probe

local MAX_POSITIONS = 24      -- tuple positions examined (Retail's roster tuple has 17)
local LOG_CAP = 300           -- probeLog entries kept
local TIMELINE_SECONDS = 180  -- roster completeness is timed for this long after login
local ICON = "Interface\\Icons\\INV_Misc_Spyglass_03"

-- The localized system strings GRM parses (GRM_Core.lua:16294-16755), and the
-- friend online/offline ones it uses to trigger a roster refresh.
Probe.GLOBALS = {
    "ERR_GUILD_JOIN_S", "ERR_GUILD_LEAVE_S", "ERR_GUILD_QUIT_S", "ERR_GUILD_REMOVE_SS",
    "ERR_GUILD_REMOVE_SELF", "ERR_GUILD_PROMOTE_SSS", "ERR_GUILD_DEMOTE_SSS",
    "ERR_GUILD_INVITE_S", "ERR_GUILD_DISBANDED", "ERR_GUILD_LEADER_CHANGED_SS",
    "ERR_FRIEND_ONLINE_SS", "ERR_FRIEND_OFFLINE_S", "GUILD_MOTD_TEMPLATE",
}

local function g(name) return rawget(_G, name) end

-- A value as text for chat: strings quoted, so "" and nil differ.
local function show(v)
    if type(v) == "string" then return '"' .. v .. '"' end
    return tostring(v)
end

local function packText(p)
    if p.missing then return "(function missing)" end
    if not p.ok then return "(error: " .. tostring(p[1]) .. ")" end
    local parts = {}
    for i = 1, p.n do parts[i] = i .. "=" .. show(p[i]) end
    return "n=" .. p.n .. (p.n > 0 and ("  " .. table.concat(parts, "  ")) or "")
end

-- A packed pcall result as saved data: the values without the ok flag.
local function packData(p)
    if p.missing then return { missing = true } end
    if not p.ok then return { error = tostring(p[1]) } end
    local t = { n = p.n }
    for i = 1, p.n do t[i] = p[i] end
    return t
end

local function rosterRow(i) return API.Pack(g("GetGuildRosterInfo"), i) end

local function isGuid(v) return type(v) == "string" and v:find("^Player%-") ~= nil end

-- Walks the whole roster: how many rows answer, and per tuple position the
-- types seen and how many values look like a player GUID. That finds the GUID
-- (and every other field) without assuming Retail's order.
function Probe.Survey(total)
    local s = { rows = 0, named = 0, positions = {}, guidPos = nil, uniqueGuids = 0 }
    local seen = {}
    for k = 1, MAX_POSITIONS do s.positions[k] = { string = 0, number = 0, boolean = 0, ["nil"] = 0, guid = 0 } end
    for i = 1, total or 0 do
        local p = rosterRow(i)
        if p.ok then
            s.rows = s.rows + 1
            if type(p[1]) == "string" and p[1] ~= "" then s.named = s.named + 1 end
            for k = 1, MAX_POSITIONS do
                local v = p[k]
                local pos = s.positions[k]
                local t = type(v)
                if pos[t] then pos[t] = pos[t] + 1 end
                if isGuid(v) then
                    pos.guid = pos.guid + 1
                    if not seen[v] then seen[v] = true; s.uniqueGuids = s.uniqueGuids + 1 end
                end
            end
        end
    end
    local best = 0
    for k = 1, MAX_POSITIONS do
        if s.positions[k].guid > best then best, s.guidPos = s.positions[k].guid, k end
    end
    return s
end

local function numMembers()
    local p = API.Pack(g("GetNumGuildMembers"))
    return p, (p.ok and type(p[1]) == "number") and p[1] or 0
end

-- The roster's state right now, small enough to log at every update.
local function snapshotCounts()
    local p, total = numMembers()
    local s = Probe.Survey(total)
    local withGuid = s.guidPos and s.positions[s.guidPos].guid or 0
    return {
        total = total, online = p.ok and p[2] or nil, third = p.ok and p[3] or nil,
        rows = s.rows, named = s.named, guidPos = s.guidPos, withGuid = withGuid,
        uniqueGuids = s.uniqueGuids,
    }
end

local function scalarsOf(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do
        local tv = type(v)
        if tv == "string" or tv == "number" or tv == "boolean" then out[k] = v end
    end
    return out
end

local function log(entry)
    local db = GuildSpyDB
    if not db then return end
    db.probeLog = db.probeLog or {}
    entry.t = time()
    entry.dt = Probe.loginAt and (GetTime() - Probe.loginAt) or nil
    table.insert(db.probeLog, entry)
    while #db.probeLog > LOG_CAP do table.remove(db.probeLog, 1) end
end

-- The full dump. Prints a summary; the details are in GuildSpyDB.probe.
function Probe.Run()
    local out = { build = API.ClientBuild(), version = API.AddOnVersion(ADDON), at = time() }
    GuildSpyDB.probe = out
    local function say(msg) print("|cff7fd4ffGuildSpy probe:|r " .. msg) end

    out.inGuild = API.Pack(g("IsInGuild"))[1]
    out.guildInfo = packData(API.Pack(g("GetGuildInfo"), "player"))
    local nm, total = numMembers()
    out.numMembers = packData(nm)
    out.showOffline = packData(API.Pack(g("GetGuildRosterShowOffline")))
    out.canViewOfficerNote = API.CanViewOfficerNote()
    local cgi = g("C_GuildInfo") or {}
    out.isGuildOfficer = packData(API.Pack(cgi.IsGuildOfficer))
    out.motd = packData(API.Pack(cgi.GetMOTD))
    out.icon = packData(API.Pack(g("GetFileIDFromPath"), ICON))
    out.player = API.PlayerFullName()

    say("build " .. tostring(out.build) .. ", in guild: " .. tostring(out.inGuild))
    say("GetGuildInfo: " .. packText(API.Pack(g("GetGuildInfo"), "player")))
    say("GetNumGuildMembers: " .. packText(nm) .. "   show offline: " .. packText(API.Pack(g("GetGuildRosterShowOffline"))))
    say("CanViewOfficerNote: " .. tostring(out.canViewOfficerNote))

    -- Ranks.
    local nr = API.Pack(g("GuildControlGetNumRanks"))
    out.ranks = { num = packData(nr), names = {} }
    local numRanks = (nr.ok and type(nr[1]) == "number") and nr[1] or 0
    for i = 1, numRanks do out.ranks.names[i] = packData(API.Pack(g("GuildControlGetRankName"), i)) end
    local rn = {}
    for i = 1, numRanks do rn[i] = i .. "=" .. show(out.ranks.names[i][1]) end
    say("ranks (" .. numRanks .. "): " .. table.concat(rn, ", "))

    -- The roster: a survey of every row, then whole tuples for a few.
    local s = Probe.Survey(total)
    out.survey = s
    say(string.format("roster: %d rows answer of %d, %d named, GUID-like at position %s (%d unique)",
        s.rows, total, s.named, tostring(s.guidPos), s.uniqueGuids))
    local types = {}
    for k = 1, MAX_POSITIONS do
        local p = s.positions[k]
        if p.string + p.number + p.boolean > 0 then
            types[#types + 1] = string.format("%d:%s%s%s", k,
                p.string > 0 and "s" or "", p.number > 0 and "n" or "", p.boolean > 0 and "b" or "")
        end
    end
    say("tuple positions (s/n/b): " .. table.concat(types, " "))

    out.rows = {}
    local picks, me = {}, nil
    for i = 1, math.min(3, total) do picks[#picks + 1] = i end
    for i = math.max(4, total - 2), total do picks[#picks + 1] = i end
    for i = 1, total do
        local p = rosterRow(i)
        if p.ok and out.player and p[1] and tostring(p[1]):find(out.player, 1, true) == 1 then me = i; break end
    end
    if me then picks[#picks + 1] = me end
    for _, i in ipairs(picks) do
        local row = { index = i, info = packData(rosterRow(i)),
                      lastOnline = packData(API.Pack(g("GetGuildRosterLastOnline"), i)) }
        out.rows[#out.rows + 1] = row
        say("row " .. i .. (i == me and " (you)" or "") .. ": " .. packText(rosterRow(i)))
        say("   last online: " .. packText(API.Pack(g("GetGuildRosterLastOnline"), i)))
    end

    -- C_Club's view of the same guild.
    local club = g("C_Club") or {}
    local cid = API.Pack(club.GetGuildClubId)
    out.club = { clubId = packData(cid) }
    if cid.ok and cid[1] then
        local mem = API.Pack(club.GetClubMembers, cid[1])
        local list = (mem.ok and type(mem[1]) == "table") and mem[1] or {}
        out.club.count = #list
        out.club.members = {}
        for i = 1, math.min(3, #list) do
            local info = API.Pack(club.GetMemberInfo, cid[1], list[i])
            out.club.members[i] = (info.ok and type(info[1]) == "table") and scalarsOf(info[1]) or packData(info)
        end
        say("C_Club: guild club " .. tostring(cid[1]) .. ", " .. #list .. " members (3 dumped)")
    else
        say("C_Club: no guild club id (" .. packText(cid) .. ")")
    end

    -- The localized strings the live parser will be built from.
    out.globals = {}
    for _, name in ipairs(Probe.GLOBALS) do
        local v = g(name)
        out.globals[name] = v == nil and "(missing)" or v
    end
    say("ERR_GUILD_PROMOTE_SSS = " .. show(g("ERR_GUILD_PROMOTE_SSS")))

    -- The event log answers asynchronously, in a burst of GUILD_EVENT_LOG_UPDATE
    -- (about 55 in a second, measured on 70338): ask, and dump once it settles.
    -- The first dump, taken on the first update, had every name nil: the names
    -- may arrive later in the burst.
    Probe.wantEventLog = true
    Probe.eventLogUpdates = 0          -- count this probe's burst, not the session's
    local q = API.Pack(g("QueryGuildEventLog"))
    out.queryEventLog = packData(q)
    API.RequestRoster()
    if Probe.Professions then Probe.Professions(out) end
    say("event log requested; full dump in GuildSpyDB.probe (/reload, then read SavedVariables\\GuildSpy.lua)")
end

-- Every entry of the event log, and how many carry names. `/gspy probe log`
-- runs it again later, to see whether names fill in over time.
function Probe.DumpEventLog()
    local out = GuildSpyDB and GuildSpyDB.probe
    if not out then return end
    local n = API.Pack(g("GetNumGuildEvents"))
    local count = (n.ok and type(n[1]) == "number") and n[1] or 0
    out.eventLog = { num = packData(n), entries = {}, named = 0, at = time(),
                     updates = Probe.eventLogUpdates, byType = {} }
    -- "Named" means every name the type needs: actor and member for promote,
    -- demote, remove and invite; the member for join and quit. "" is no name.
    local function has(v) return type(v) == "string" and v ~= "" end
    for i = 1, count do
        local e = API.Pack(g("GetGuildEventInfo"), i)
        out.eventLog.entries[i] = packData(e)
        if e.ok and type(e[1]) == "string" then
            local both = e[1] ~= "join" and e[1] ~= "quit"
            local complete = has(e[2]) and (not both or has(e[3]))
            if complete then out.eventLog.named = out.eventLog.named + 1 end
            local bt = out.eventLog.byType[e[1]] or { count = 0, named = 0 }
            bt.count = bt.count + 1
            if complete then bt.named = bt.named + 1 end
            bt.sample = bt.sample or packData(e)
            out.eventLog.byType[e[1]] = bt
        end
    end
    local types = {}
    for t, bt in pairs(out.eventLog.byType) do types[#types + 1] = t .. " " .. bt.named .. "/" .. bt.count end
    table.sort(types)
    print("|cff7fd4ffGuildSpy probe:|r event log: " .. count .. " entries, " .. out.eventLog.named
        .. " with every name they need (" .. table.concat(types, ", ") .. ")")
end

-- Dump once the burst has been quiet for EVENT_LOG_SETTLE seconds.
local EVENT_LOG_SETTLE = 3
function Probe.EventLogUpdated()
    Probe.eventLogUpdates = (Probe.eventLogUpdates or 0) + 1
    if not Probe.wantEventLog then return end
    Probe.eventLogGen = (Probe.eventLogGen or 0) + 1
    local gen = Probe.eventLogGen
    C_Timer.After(EVENT_LOG_SETTLE, function()
        if gen ~= Probe.eventLogGen or not Probe.wantEventLog then return end
        Probe.wantEventLog = nil
        Probe.DumpEventLog()
    end)
end

function Probe.ToggleWatch()
    GuildSpyDB.probeWatch = not GuildSpyDB.probeWatch or nil
    print("|cff7fd4ffGuildSpy probe:|r recording every system message: " .. (GuildSpyDB.probeWatch and "on" or "off"))
end

-- Events. The timeline is always on for TIMELINE_SECONDS after login.
local frame = CreateFrame("Frame")
Probe.frame = frame
Probe.EVENTS = { "PLAYER_LOGIN", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "GUILD_RANKS_UPDATE",
                 "GUILD_MOTD", "GUILD_EVENT_LOG_UPDATE", "CHAT_MSG_SYSTEM" }
Probe.refused = {}
for _, e in ipairs(Probe.EVENTS) do
    if not API.RegisterEvent(frame, e) then Probe.refused[#Probe.refused + 1] = e end
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        Probe.loginAt = GetTime()
        if GuildSpyDB then GuildSpyDB.probeLog = {} end   -- one session's timeline
        log({ e = event, refused = #Probe.refused > 0 and table.concat(Probe.refused, ",") or nil })
        return
    end
    if event == "CHAT_MSG_SYSTEM" then
        if GuildSpyDB and GuildSpyDB.probeWatch then log({ e = event, msg = (...) }) end
        return
    end
    if event == "GUILD_EVENT_LOG_UPDATE" then
        Probe.EventLogUpdated()   -- counted, not logged: it comes in bursts of dozens
        return
    end
    local timed = Probe.loginAt and (GetTime() - Probe.loginAt) <= TIMELINE_SECONDS
    if not timed then return end
    local entry = { e = event, arg = (...) }
    if event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        local c = snapshotCounts()
        for k, v in pairs(c) do entry[k] = v end
        entry.guild = (API.Pack(g("GetGuildInfo"), "player"))[1]
    end
    log(entry)
end)

GuildSpy._test = GuildSpy._test or {}
GuildSpy._test.Probe = { isGuid = isGuid, packText = packText }

-- For ProbeProfessions.lua.
Probe.g, Probe.show, Probe.packText, Probe.packData, Probe.scalarsOf, Probe.log =
    g, show, packText, packData, scalarsOf, log
