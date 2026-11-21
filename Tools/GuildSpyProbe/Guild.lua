-- Guild.lua: phase 0's measurements (docs/FOREVER-PROBE.md), part of
-- GuildSpyProbe (/fp gs). Was GuildSpy's own Probe.lua and `/gspy probe`
-- until #67 moved it here, out of the shipped addon.
--
-- Nothing in GuildSpy may read a guild tuple by position before this has
-- measured it on the live client. `/fp gs dump` saves what the roster, the
-- ranks, the event log, C_Club and the ERR_GUILD_* strings look like into
-- GuildSpyProbeDB.dump; a /reload writes it to
-- WTF\Account\<acct>\SavedVariables\GuildSpyProbe.lua, to be read from disk.
--
-- While the probe is loaded (cheap, capped): a timeline of the guild events
-- from login, with how complete the roster was at each GUILD_ROSTER_UPDATE
-- (GuildSpyProbeDB.timeline). `/fp gs watch` also records every
-- CHAT_MSG_SYSTEM line, to catch the real text of joins, leaves, kicks and
-- promotions when they happen.
--
-- /fp steps gs guild : the whole measurement, then a /reload.

local ADDON, NS = ...
local Probe = NS.Probe
local function say(msg) Probe:Say(msg) end
local show = Probe.Show

local G = {}
NS.Guild = G

local MAX_POSITIONS = 24      -- tuple positions examined (Retail's roster tuple has 17)
local LOG_CAP = 300           -- timeline entries kept
local TIMELINE_SECONDS = 180  -- roster completeness is timed for this long after login
local EVENT_LOG_SETTLE = 3    -- seconds of quiet before the event log's burst is read
local ICON = "Interface\\Icons\\INV_Misc_Spyglass_03"

-- The localized system strings GRM parses (Core/GRM_Core.lua:9378-9840), and the
-- friend online/offline ones it uses to trigger a roster refresh.
G.GLOBALS = {
    "ERR_GUILD_JOIN_S", "ERR_GUILD_LEAVE_S", "ERR_GUILD_QUIT_S", "ERR_GUILD_REMOVE_SS",
    "ERR_GUILD_REMOVE_SELF", "ERR_GUILD_PROMOTE_SSS", "ERR_GUILD_DEMOTE_SSS",
    "ERR_GUILD_INVITE_S", "ERR_GUILD_DISBANDED", "ERR_GUILD_LEADER_CHANGED_SS",
    "ERR_FRIEND_ONLINE_SS", "ERR_FRIEND_OFFLINE_S", "GUILD_MOTD_TEMPLATE",
}

local DB          -- GuildSpyProbeDB, bound at ADDON_LOADED (GuildSpyProbe.lua)

local function g(name) return rawget(_G, name) end
local secret = NS.secret

-- Every return of fn(...), packed with its count, as the dump has always
-- saved them: { ok, n, ... }, or { missing = true }. This is the old probe's
-- API.Pack kept as a local adapter, not Probe:Try: the survey calls it for
-- every roster row, and Try's MISSING / ERROR line per row would bury the
-- console. What was missing or threw is in the dump and in packText's lines.
local function pack(fn, ...)
    if type(fn) ~= "function" then return { n = 0, missing = true } end
    local function p(ok, ...) return { n = select("#", ...), ok = ok, ... } end
    return p(pcall(fn, ...))
end

-- A value as saved data: a secret can't be stored or read back, so the dump
-- records that it was one (#79).
local function plain(v)
    if secret(v) then return "(secret)" end
    return v
end

local function packText(p)
    if p.missing then return "(function missing)" end
    if not p.ok then return "(error: " .. show(p[1], true) .. ")" end
    local parts = {}
    for i = 1, p.n do parts[i] = i .. "=" .. show(p[i]) end
    return "n=" .. p.n .. (p.n > 0 and ("  " .. table.concat(parts, "  ")) or "")
end

-- A packed pcall result as saved data: the values without the ok flag.
local function packData(p)
    if p.missing then return { missing = true } end
    if not p.ok then return { error = show(p[1], true) } end
    local t = { n = p.n }
    for i = 1, p.n do t[i] = plain(p[i]) end
    return t
end

local function scalarsOf(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do
        local tv = type(v)
        if not secret(k) and (tv == "string" or tv == "number" or tv == "boolean") then out[k] = plain(v) end
    end
    return out
end

local function rosterRow(i) return pack(g("GetGuildRosterInfo"), i) end

local function isGuid(v) return type(v) == "string" and not secret(v) and v:find("^Player%-") ~= nil end
local function isName(v) return type(v) == "string" and not secret(v) and v ~= "" end

-- Walks the whole roster: how many rows answer, and per tuple position the
-- types seen and how many values look like a player GUID. That finds the GUID
-- (and every other field) without assuming Retail's order.
function G.Survey(total)
    local s = { rows = 0, named = 0, positions = {}, guidPos = nil, uniqueGuids = 0 }
    local seen = {}
    for k = 1, MAX_POSITIONS do s.positions[k] = { string = 0, number = 0, boolean = 0, ["nil"] = 0, guid = 0 } end
    for i = 1, total or 0 do
        local p = rosterRow(i)
        if p.ok then
            s.rows = s.rows + 1
            if isName(p[1]) then s.named = s.named + 1 end
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
    local p = pack(g("GetNumGuildMembers"))
    return p, (p.ok and type(p[1]) == "number" and not secret(p[1])) and p[1] or 0
end

-- The roster's state right now, small enough to record at every update.
local function snapshotCounts()
    local p, total = numMembers()
    local s = G.Survey(total)
    local withGuid = s.guidPos and s.positions[s.guidPos].guid or 0
    return {
        total = total, online = p.ok and plain(p[2]) or nil, third = p.ok and plain(p[3]) or nil,
        rows = s.rows, named = s.named, guidPos = s.guidPos, withGuid = withGuid,
        uniqueGuids = s.uniqueGuids,
    }
end

local function record(entry)
    if not DB then return end
    entry.t = time()
    entry.dt = G.loginAt and (GetTime() - G.loginAt) or nil
    table.insert(DB.timeline, entry)
    while #DB.timeline > LOG_CAP do table.remove(DB.timeline, 1) end
end

-- GuildSpy's own version, when it's loaded next to the probe.
local function guildSpyVersion()
    local ns = g("C_AddOns")
    local get = (type(ns) == "table" and ns.GetAddOnMetadata) or g("GetAddOnMetadata")
    if type(get) ~= "function" then return nil end
    local ok, v = pcall(get, "GuildSpy", "Version")
    return ok and plain(v) or nil
end

local function build()
    local version, b = GetBuildInfo()
    if type(version) ~= "string" then return nil end
    return version .. "." .. tostring(b)
end

function G.Dump() return DB and DB.dump end

-- What a dump still waits for: the event log's burst, the crafter list, the
-- "who knows this recipe" queries. Empty once everything is in.
function G.Pending()
    local left = {}
    if G.wantEventLog then left[#left + 1] = "event log" end
    if G.ProfessionsPending then G.ProfessionsPending(left) end
    return left
end

-- The full dump. Says a summary; the details are in GuildSpyProbeDB.dump.
function G.Run()
    if not DB then say("dump: not loaded yet"); return end
    local out = { build = build(), guildSpy = guildSpyVersion(), at = time() }
    DB.dump = out

    out.inGuild = pack(g("IsInGuild"))[1]
    out.guildInfo = packData(pack(g("GetGuildInfo"), "player"))
    local nm, total = numMembers()
    out.numMembers = packData(nm)
    out.showOffline = packData(pack(g("GetGuildRosterShowOffline")))
    local cgi = g("C_GuildInfo") or {}
    out.canViewOfficerNote = packData(pack(cgi.CanViewOfficerNote))
    out.isGuildOfficer = packData(pack(cgi.IsGuildOfficer))
    out.motd = packData(pack(cgi.GetMOTD))
    out.icon = packData(pack(g("GetFileIDFromPath"), ICON))
    out.player = NS.me()

    say("dump: build " .. show(out.build, true) .. ", in guild: " .. show(out.inGuild))
    say("GetGuildInfo: " .. packText(pack(g("GetGuildInfo"), "player")))
    say("GetNumGuildMembers: " .. packText(nm) .. "   show offline: " .. packText(pack(g("GetGuildRosterShowOffline"))))
    say("C_GuildInfo.CanViewOfficerNote: " .. packText(pack(cgi.CanViewOfficerNote)))

    -- Ranks.
    local nr = pack(g("GuildControlGetNumRanks"))
    out.ranks = { num = packData(nr), names = {} }
    local numRanks = (nr.ok and type(nr[1]) == "number" and not secret(nr[1])) and nr[1] or 0
    for i = 1, numRanks do out.ranks.names[i] = packData(pack(g("GuildControlGetRankName"), i)) end
    local rn = {}
    for i = 1, numRanks do rn[i] = i .. "=" .. show(out.ranks.names[i][1]) end
    say("ranks (" .. numRanks .. "): " .. table.concat(rn, ", "))

    -- The roster: a survey of every row, then whole tuples for a few.
    local s = G.Survey(total)
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
        if p.ok and out.player and isName(p[1]) and p[1]:find(out.player, 1, true) == 1 then me = i; break end
    end
    if me then picks[#picks + 1] = me end
    for _, i in ipairs(picks) do
        local row = { index = i, info = packData(rosterRow(i)),
                      lastOnline = packData(pack(g("GetGuildRosterLastOnline"), i)) }
        out.rows[#out.rows + 1] = row
        say("row " .. i .. (i == me and " (you)" or "") .. ": " .. packText(rosterRow(i)))
        say("   last online: " .. packText(pack(g("GetGuildRosterLastOnline"), i)))
    end

    -- C_Club's view of the same guild.
    local club = g("C_Club") or {}
    local cid = pack(club.GetGuildClubId)
    out.club = { clubId = packData(cid) }
    if cid.ok and cid[1] and not secret(cid[1]) then
        local mem = pack(club.GetClubMembers, cid[1])
        local list = (mem.ok and type(mem[1]) == "table") and mem[1] or {}
        out.club.count = #list
        out.club.members = {}
        for i = 1, math.min(3, #list) do
            local info = pack(club.GetMemberInfo, cid[1], list[i])
            out.club.members[i] = (info.ok and type(info[1]) == "table") and scalarsOf(info[1]) or packData(info)
        end
        say("C_Club: guild club " .. show(cid[1]) .. ", " .. #list .. " members (3 dumped)")
    else
        say("C_Club: no guild club id (" .. packText(cid) .. ")")
    end

    -- The localized strings the live parser is built from.
    out.globals = {}
    for _, name in ipairs(G.GLOBALS) do
        local v = g(name)
        out.globals[name] = v == nil and "(missing)" or plain(v)
    end
    say("ERR_GUILD_PROMOTE_SSS = " .. show(g("ERR_GUILD_PROMOTE_SSS")))

    -- The event log answers asynchronously, in a burst of GUILD_EVENT_LOG_UPDATE
    -- (about 55 in a second, measured on 70338): ask, and dump once it settles.
    -- The first dump, taken on the first update, had every name nil: the names
    -- may arrive later in the burst.
    G.wantEventLog = true
    G.eventLogUpdates = 0          -- count this dump's burst, not the session's
    out.queryEventLog = packData(pack(g("QueryGuildEventLog")))
    Probe:Try("C_GuildInfo.GuildRoster", cgi.GuildRoster)
    if G.Professions then G.Professions(out) end
    say("event log requested; the full dump is GuildSpyProbeDB.dump (/reload, then read SavedVariables\\GuildSpyProbe.lua)")
    return out
end

-- Every entry of the event log, and how many carry names. `/fp gs eventlog`
-- runs it again later, to see whether names fill in over time.
function G.DumpEventLog()
    local out = G.Dump()
    if not out then return end
    local n = pack(g("GetNumGuildEvents"))
    local count = (n.ok and type(n[1]) == "number" and not secret(n[1])) and n[1] or 0
    out.eventLog = { num = packData(n), entries = {}, named = 0, at = time(),
                     updates = G.eventLogUpdates, byType = {} }
    -- "Named" means every name the type needs: actor and member for promote,
    -- demote, remove and invite; the member for join and quit. "" is no name.
    for i = 1, count do
        local e = pack(g("GetGuildEventInfo"), i)
        out.eventLog.entries[i] = packData(e)
        if e.ok and type(e[1]) == "string" and not secret(e[1]) then
            local both = e[1] ~= "join" and e[1] ~= "quit"
            local complete = isName(e[2]) and (not both or isName(e[3]))
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
    say("event log: " .. count .. " entries, " .. out.eventLog.named
        .. " with every name they need (" .. table.concat(types, ", ") .. ")")
end

-- Dump once the burst has been quiet for EVENT_LOG_SETTLE seconds.
function G.EventLogUpdated()
    G.eventLogUpdates = (G.eventLogUpdates or 0) + 1
    if not G.wantEventLog then return end
    G.eventLogGen = (G.eventLogGen or 0) + 1
    local gen = G.eventLogGen
    C_Timer.After(EVENT_LOG_SETTLE, function()
        if gen ~= G.eventLogGen or not G.wantEventLog then return end
        G.wantEventLog = nil
        G.DumpEventLog()
    end)
end

function G.SetWatch(on)
    if not DB then return end
    DB.watch = on or nil
    say("recording every system message: " .. (DB.watch and "on" or "off"))
end

-- Binds the saved tables (GuildSpyProbe.lua, at ADDON_LOADED).
function G.Bind(db)
    DB = db
    if type(DB.timeline) ~= "table" then DB.timeline = {} end
    if type(DB.dump) ~= "table" then DB.dump = nil end
    if DB.watch ~= true then DB.watch = nil end
end

-- `/fp gs clear`: the dump, the timeline and the watch switch.
function G.Clear()
    if not DB then return end
    DB.dump, DB.watch = nil, nil
    for i = #DB.timeline, 1, -1 do DB.timeline[i] = nil end
end

Probe:Command("dump", function() G.Run() end, "dump the guild API's shapes into GuildSpyProbeDB.dump")
Probe:Command("eventlog", function()
    if not G.Dump() then say("run /fp gs dump first"); return end
    G.DumpEventLog()
end, "read the guild event log again (names may fill in later)")
Probe:Command("watch", function(args)
    local a = (args or ""):lower()
    if a == "on" then G.SetWatch(true)
    elseif a == "off" then G.SetWatch(false)
    else G.SetWatch(not (DB and DB.watch)) end
end, "record every system message from now on: on, off, or toggle")
Probe:Command("timeline", function()
    if not DB then return end
    for _, e in ipairs(DB.timeline) do
        local parts = {}
        for k, v in pairs(e) do
            if k ~= "e" and k ~= "t" then parts[#parts + 1] = k .. "=" .. show(v, true) end
        end
        table.sort(parts)
        say(("  %s %s"):format(e.e, table.concat(parts, " ")))
    end
    say(#DB.timeline .. " timeline entries, watch " .. (DB.watch and "on" or "off"))
end, "the login timeline (roster completeness, guild events) and the watched system messages")

-- Events. The timeline is timed for TIMELINE_SECONDS after login; the system
-- messages are recorded only while watching.
local frame = CreateFrame("Frame")
Probe:RegisterEvents(frame, { "PLAYER_LOGIN", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "GUILD_RANKS_UPDATE",
                              "GUILD_MOTD", "GUILD_EVENT_LOG_UPDATE", "CHAT_MSG_SYSTEM" })
frame:SetScript("OnEvent", function(_, event, ...)
    if not DB then return end
    if event == "PLAYER_LOGIN" then
        G.loginAt = GetTime()
        for i = #DB.timeline, 1, -1 do DB.timeline[i] = nil end   -- one session's timeline
        record({ e = event })
        return
    end
    if event == "CHAT_MSG_SYSTEM" then
        if DB.watch then record({ e = event, msg = plain((...)) }) end
        return
    end
    if event == "GUILD_EVENT_LOG_UPDATE" then
        G.EventLogUpdated()   -- counted, not recorded: it comes in bursts of dozens
        return
    end
    local timed = G.loginAt and (GetTime() - G.loginAt) <= TIMELINE_SECONDS
    if not timed then return end
    local entry = { e = event, arg = plain((...)) }
    if event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        local c = snapshotCounts()
        for k, v in pairs(c) do entry[k] = v end
        entry.guild = plain(pack(g("GetGuildInfo"), "player")[1])
    end
    record(entry)
end)

-- The whole measurement as a procedure: what `/gspy probe`, `probe recipes`
-- and `probe watch` were, in order, then the /reload that writes it to disk.
-- The client-update skill asks for it on a new build.
Probe:Steps("guild", {
    title = "The guild API's shapes (docs/FOREVER-PROBE.md)",
    { text = "Log in on a character in a guild and wait about 30 s for the roster, then press Next." },
    { text = "Dump the guild API: the roster, ranks, last online, C_Club and the system strings, "
          .. "then the event log and the professions.",
      button = "Dump", run = function()
          local out = G.Run()
          if not out then return false end
          return out.inGuild, out.survey.rows, out.survey.guidPos
      end,
      check = function()
          local d = G.Dump()
          return d ~= nil and d.inGuild == true and d.survey.guidPos ~= nil, "in a guild, a GUID position found"
      end },
    { text = "Waiting for the event log and the professions answers.", timeout = 60,
      wait = function()
          local left = G.Pending()
          if #left > 0 then return false, "waiting for " .. table.concat(left, ", ") end
          local d = G.Dump()
          return true, d and d.eventLog and d.eventLog.named
      end,
      check = function()
          local d = G.Dump()
          return d ~= nil and d.eventLog ~= nil, "the event log was read"
      end },
    { text = "Ask for a guildmate's recipe book. If the server answers, the Professions window opens: "
          .. "leave it, the probe reads it and closes it.",
      button = "Ask", run = function() return G.MemberRecipes() end },
    { text = "Waiting for the recipe book.", timeout = 20,
      wait = function()
          local d = G.Dump()
          local mr = d and d.memberRecipes
          if not mr then return true, "not asked" end
          if mr.done then return true, mr.inconclusive or mr.learned end
          return false, "read a few seconds after the request"
      end },
    { text = "Record every system message from now on, to catch the real text of a promotion, a "
          .. "demotion, a leave or a kick (#10)? Watch turns it on, Skip leaves it off.",
      button = "Watch", run = function() G.SetWatch(true); return true end },
    { text = "Type /reload (or press Reload now) to write the dump to disk.", reload = true },
    { text = "After the reload.", auto = true,
      run = function()
          local d = G.Dump()
          return d ~= nil, d and d.build, DB and #DB.timeline
      end,
      check = function() return G.Dump() ~= nil, "the dump is still there after the /reload" end },
    { text = "Done. With watch on, play normally: /fp gs timeline shows what was recorded, and a "
          .. "/reload saves it." },
})

-- For GuildProfessions.lua.
G.g, G.pack, G.plain, G.packText, G.packData, G.scalarsOf, G.isName = g, pack, plain, packText, packData, scalarsOf, isName
G.isGuid = isGuid
