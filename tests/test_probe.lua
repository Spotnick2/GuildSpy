-- /gspy probe: it must survive any guild shape (nil holes, missing functions,
-- no guild, a guild still loading) and find the GUID by looking, not assuming.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function guild(n, opts)
    local members = {}
    for i = 1, n do
        members[i] = { name = "Member" .. i .. " Surname", rank = i % 3, level = 10 + i, class = "WARRIOR",
                       note = "n" .. i, onote = "o" .. i, online = i % 2 == 0,
                       guid = "Player-1-0000" .. string.format("%04d", i), lastOnline = { 0, 0, i, 1 } }
    end
    members[n + 1] = { name = "Fizzle Sprocketwhistle", rank = 0, level = 60, class = "MAGE", online = true,
                       guid = "Player-1-00009999" }
    local g = { name = "The Cogs", realm = "Forever", ranks = { "Guild Master", "Officer", "Member" },
                members = members, canViewOfficerNote = true, motd = "hello",
                events = { { "promote", "Fizzle Sprocketwhistle", "Member1 Surname", "Officer", 0, 0, 1, 2 } } }
    for k, v in pairs(opts or {}) do g[k] = v end
    return g
end

-- A guild: the survey finds the GUID at the stub's (Retail's) position 17, unique per member.
loadAddon({ setup = function() WoW.guild = guild(6) end })
WoW.fire("PLAYER_LOGIN")
WoW.slash("/gspy probe")
local p = GuildSpyDB.probe
check(p ~= nil, "probe saved")
eq(p.survey.guidPos, 17, "GUID found at position 17 by looking")
eq(p.survey.uniqueGuids, 7, "every member's GUID counted once")
eq(p.survey.rows, 7, "every row answers")
eq(p.ranks.names[2][1], "Officer", "rank names dumped")
eq(p.globals.ERR_GUILD_PROMOTE_SSS, "%s has promoted %s to %s.", "localized strings dumped")
eq(p.globals.ERR_GUILD_QUIT_S, "(missing)", "a missing global says so")
eq(p.canViewOfficerNote, true, "officer-note permission read")
eq(WoW.rosterRequests, 1, "a roster refresh requested")
eq(WoW.eventLogQueries, 1, "the event log queried")
local you
for _, r in ipairs(p.rows) do if r.info[1] == "Fizzle Sprocketwhistle" then you = r end end
check(you ~= nil, "your own row dumped")
-- Nil holes survive: an online member's last-online tuple is empty, not an error.
eq(p.rows[2].lastOnline[1], nil, "an online member's last online is nil, not an error")
eq(p.rows[1].info.n, 17, "the whole tuple, counted with select('#')")

-- The event log arrives later and is dumped then, once.
WoW.fire("GUILD_EVENT_LOG_UPDATE")
eq(p.eventLog.num[1], 1, "event log count")
eq(p.eventLog.entries[1][1], "promote", "event log entry dumped")
eq(p.eventLog.entries[1].n, 8, "the whole event tuple")

-- The login timeline records how complete the roster was at each update.
WoW.now = 5
WoW.fire("GUILD_ROSTER_UPDATE", true)
local last = GuildSpyDB.probeLog[#GuildSpyDB.probeLog]
eq(last.e, "GUILD_ROSTER_UPDATE", "roster update logged")
eq(last.total, 7, "...with the total")
eq(last.withGuid, 7, "...and how many rows had a GUID")
eq(last.dt, 5, "...and when, from login")
WoW.now = 1000
local n = #GuildSpyDB.probeLog
WoW.fire("GUILD_ROSTER_UPDATE", true)
eq(#GuildSpyDB.probeLog, n, "the timeline stops after its window")

-- System messages only while watching.
WoW.fire("CHAT_MSG_SYSTEM", "X has joined the guild.")
eq(#GuildSpyDB.probeLog, n, "system messages ignored by default")
WoW.slash("/gspy probe watch")
WoW.fire("CHAT_MSG_SYSTEM", "X has joined the guild.")
eq(GuildSpyDB.probeLog[#GuildSpyDB.probeLog].msg, "X has joined the guild.", "recorded while watching")

-- No guild, and a guild still loading: no error, honest zeros.
loadAddon()
WoW.fire("PLAYER_LOGIN")
WoW.slash("/gspy probe")
eq(GuildSpyDB.probe.inGuild, false, "no guild")
eq(GuildSpyDB.probe.survey.rows, 0, "no rows")
loadAddon({ setup = function() WoW.guild = guild(3, { loading = true }) end })
WoW.slash("/gspy probe")
eq(GuildSpyDB.probe.survey.guidPos, nil, "no GUID position from a loading roster")

-- A client without a function: reported, not thrown.
loadAddon({ setup = function() WoW.guild = guild(2) end })
local saved = GetGuildRosterLastOnline
rawset(_G, "GetGuildRosterLastOnline", nil)
local ok = pcall(WoW.slash, "/gspy probe")
rawset(_G, "GetGuildRosterLastOnline", saved)
check(ok, "a missing function doesn't break the probe")
eq(GuildSpyDB.probe.rows[1].lastOnline.missing, true, "...and is recorded as missing")

done("test_probe")
