-- GuildSpyProbe's guild dump (Tools/GuildSpyProbe/Guild.lua, /fp gs dump; was
-- /gspy probe until #67): it must survive any guild shape (nil holes, missing
-- functions, no guild, a guild still loading) and find the GUID by looking,
-- not assuming. Its lines go to the /fp console and GuildSpyProbeDB.log, never
-- to chat. Runs locally only (ForeverProbe is private; CI sets
-- FOREVERPROBE_OPTIONAL and this file skips).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function fp(cmd) SlashCmdList.FOREVERPROBE("gs " .. cmd) end
local function logHas(pattern)
    for _, line in ipairs(GuildSpyProbeDB.log) do if line:find(pattern, 1, true) then return true end end
    return false
end

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

-- The module: /fp gs, its saved log bound, no slash command of its own, and
-- GuildSpy no longer answers /gspy probe.
local NS = loadProbe({ setup = function() WoW.guild = guild(6) end })
local FP = ForeverProbe
eq(FP.byCmd.gs and FP.byCmd.gs.name, "GuildSpyProbe", "the probe answers /fp gs")
check(NS._test.Probe.log == GuildSpyProbeDB.log, "its ForeverProbe log is GuildSpyProbeDB.log, bound with UseLog")
eq(rawget(_G, "SLASH_GUILDSPYPROBE1"), nil, "...and it has no slash command of its own")
for _, cmd in ipairs({ "dump", "eventlog", "watch", "timeline", "recipes", "grm", "users", "samples", "state", "ask", "clear" }) do
    check(FP.byCmd.gs.commands[cmd] ~= nil, "/fp gs " .. cmd .. " exists")
end

-- A guild: the survey finds the GUID at position 17 (measured on 70338), unique per member.
WoW.fire("PLAYER_LOGIN")
fp("dump")
local p = GuildSpyProbeDB.dump
check(p ~= nil, "the dump is saved")
eq(p.build, "1.60.1.71037", "...with the build")
eq(p.survey.guidPos, 17, "GUID found at position 17 by looking")
eq(p.survey.uniqueGuids, 7, "every member's GUID counted once")
eq(p.survey.rows, 7, "every row answers")
eq(p.ranks.names[2][1], "Officer", "rank names dumped")
eq(p.globals.ERR_GUILD_PROMOTE_SSS, "%s has promoted %s to %s.", "localized strings dumped")
eq(p.globals.ERR_GUILD_QUIT_S, "(missing)", "a missing global says so")
eq(p.canViewOfficerNote[1], true, "officer-note permission read")
eq(p.player, "Fizzle Sprocketwhistle", "the player's full name, surname included")
eq(WoW.rosterRequests, 1, "a roster refresh requested")
eq(WoW.eventLogQueries, 1, "the event log queried")
local you
for _, r in ipairs(p.rows) do if r.info[1] == "Fizzle Sprocketwhistle" then you = r end end
check(you ~= nil, "your own row dumped")
-- Nil holes survive: an online member's last-online tuple is empty, not an error.
eq(p.rows[2].lastOnline[1], nil, "an online member's last online is nil, not an error")
eq(p.rows[1].info.n, 17, "the whole tuple, counted with select('#')")
check(logHas("roster: 7 rows answer of 7, 7 named, GUID-like at position 17"), "the summary is in the module's log")
eq(#WoW.chat, 0, "nothing in chat")

-- The event log arrives in a burst and is dumped once it has settled.
check(NS.Guild.Pending()[1] == "event log", "the dump waits for the event log")
for _ = 1, 20 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(1)
eq(p.eventLog, nil, "not dumped mid-burst")
WoW.fire("GUILD_EVENT_LOG_UPDATE")
WoW.advance(3)
eq(p.eventLog.num[1], 1, "event log count")
eq(p.eventLog.entries[1][1], "promote", "event log entry dumped")
eq(p.eventLog.entries[1].n, 8, "the whole event tuple")
eq(p.eventLog.named, 0, "no names, as measured")
eq(p.eventLog.updates, 21, "the burst counted")
WoW.advance(10)
WoW.guild.eventNames = true
WoW.fire("GUILD_EVENT_LOG_UPDATE")
WoW.advance(5)
eq(p.eventLog.named, 0, "a later update doesn't redump on its own")
fp("eventlog")
eq(GuildSpyProbeDB.dump.eventLog.named, 1, "/fp gs eventlog redumps, names and all")
eq(#NS.Guild.Pending(), 0, "nothing left to wait for")

-- The login timeline records how complete the roster was at each update.
WoW.now = 5
WoW.fire("GUILD_ROSTER_UPDATE", true)
local TL = GuildSpyProbeDB.timeline
local last = TL[#TL]
eq(last.e, "GUILD_ROSTER_UPDATE", "roster update recorded")
eq(last.total, 7, "...with the total")
eq(last.withGuid, 7, "...and how many rows had a GUID")
eq(last.dt, 5, "...and when, from login")

-- A secret payload (#79) is saved as a marker, never as the value.
local secret = WoW.Secret("motd")
WoW.fire("GUILD_MOTD", secret)
last = TL[#TL]
eq(last.e, "GUILD_MOTD", "a secret MOTD is on the login timeline")
eq(last.arg, "(secret)", "...as a marker, not the secret")
WoW.now = 1000
local n = #TL
WoW.fire("GUILD_ROSTER_UPDATE", true)
eq(#TL, n, "the timeline stops after its window")

-- System messages only while watching.
WoW.fire("CHAT_MSG_SYSTEM", "X has joined the guild.")
eq(#TL, n, "system messages ignored by default")
fp("watch")
eq(GuildSpyProbeDB.watch, true, "/fp gs watch turns it on")
WoW.fire("CHAT_MSG_SYSTEM", "X has joined the guild.")
eq(TL[#TL].msg, "X has joined the guild.", "recorded while watching")
WoW.fire("CHAT_MSG_SYSTEM", WoW.Secret("system"))
eq(TL[#TL].msg, "(secret)", "a secret system message is saved as a marker")
fp("timeline")
check(logHas("msg=X has joined the guild."),"/fp gs timeline shows it in the console")
fp("watch off")
eq(GuildSpyProbeDB.watch, nil, "/fp gs watch off turns it off")

-- What's saved survives a reload: the same tables are adopted, not replaced.
local db = GuildSpyProbeDB
db.watch = true
loadProbe({ db = db, setup = function() WoW.guild = guild(2) end })
check(GuildSpyProbeDB.dump ~= nil and GuildSpyProbeDB.dump.survey.rows == 7, "the dump is kept across a reload")
eq(GuildSpyProbeDB.watch, true, "...and the watch switch")
WoW.fire("PLAYER_LOGIN")
eq(#GuildSpyProbeDB.timeline, 1, "a new login starts a new timeline")

-- /fp gs clear forgets the dump, the timeline and the watch switch too.
fp("clear")
eq(GuildSpyProbeDB.dump, nil, "clear: no dump")
eq(#GuildSpyProbeDB.timeline, 0, "clear: no timeline")
eq(GuildSpyProbeDB.watch, nil, "clear: watch off")
fp("dump")
check(logHas("dump: build"), "a line written after the clear is in the saved log")
check(ForeverProbe.lines[#ForeverProbe.lines] ~= nil, "...and in the console")

-- No guild, and a guild still loading: no error, honest zeros.
loadProbe()
WoW.fire("PLAYER_LOGIN")
fp("dump")
eq(GuildSpyProbeDB.dump.inGuild, false, "no guild")
eq(GuildSpyProbeDB.dump.survey.rows, 0, "no rows")
fp("eventlog")
check(GuildSpyProbeDB.dump.eventLog ~= nil, "the event log read with no guild: empty, not an error")
loadProbe({ setup = function() WoW.guild = guild(3, { loading = true }) end })
fp("dump")
eq(GuildSpyProbeDB.dump.survey.guidPos, nil, "no GUID position from a loading roster")

-- /fp gs eventlog with no dump yet: says so, runs nothing.
loadProbe({ setup = function() WoW.guild = guild(2) end })
fp("eventlog")
eq(GuildSpyProbeDB.dump, nil, "no dump run")
check(logHas("run /fp gs dump first"), "...and it says what to do")

-- A client without a function: reported, not thrown.
local saved = GetGuildRosterLastOnline
rawset(_G, "GetGuildRosterLastOnline", nil)
local ok, err = pcall(fp, "dump")
rawset(_G, "GetGuildRosterLastOnline", saved)
check(ok, "a missing function doesn't break the dump: " .. tostring(err))
eq(GuildSpyProbeDB.dump.rows[1].lastOnline.missing, true, "...and is recorded as missing")

-- The procedure: /fp steps gs guild dumps, waits for the answers, asks for a reload.
loadProbe({ setup = function() WoW.guild = guild(4) end })
FP = ForeverProbe
WoW.fire("PLAYER_LOGIN")
check(FP.procedures["GuildSpyProbe/guild"], "procedure guild is defined")
check(FP.procedures["GuildSpyProbe/grm"], "...next to grm")
SlashCmdList.FOREVERPROBE("steps gs guild")
local rec = ForeverProbeDB.steps.records["GuildSpyProbe/guild"]
FP.Steps.Next()                                         -- 1: logged in, waited
FP.Steps.Run()                                          -- 2: the dump
eq(rec.results[2] and rec.results[2].status, "done", "step 2 dumps")
eq(rec.results[2].check, "PASS", "...in a guild, with a GUID position")
check(GuildSpyProbeDB.dump ~= nil, "...into GuildSpyProbeDB.dump")
WoW.fire("GUILD_EVENT_LOG_UPDATE")
WoW.advance(4)
FP.Steps.Poll()
eq(rec.results[3] and rec.results[3].status, "done", "step 3 completes once the event log is in")
eq(rec.results[3].check, "PASS", "...and checks it was read")
FP.Steps.Skip()                                         -- 4: the recipe book (no club here)
FP.Steps.Poll()                                         -- 5: nothing asked
eq(rec.results[5] and rec.results[5].status, "done", "step 5 doesn't wait when no book was asked for")
FP.Steps.Run()                                          -- 6: watch
eq(GuildSpyProbeDB.watch, true, "step 6 turns watching on")
SlashCmdList.FOREVERPROBE("steps stop")
eq(#WoW.chat, 0, "nothing the probe learned went to chat")

-- The GRM half (#8), wired: GRM's prefixes registered at load, one GRMUSER
-- REQ? on /fp gs ask, and the server's echo of our own message not counted.
loadProbe({ setup = function() WoW.guild = guild(2) end })
check(WoW.prefixes.GRMUSER and WoW.prefixes.GRM_SYNC, "GRM's prefixes registered at load")
fp("ask")
eq(#WoW.addonSent, 1, "/fp gs ask sends one message")
eq(WoW.addonSent[1].prefix .. " " .. WoW.addonSent[1].message .. " " .. WoW.addonSent[1].chatType,
   "GRMUSER REQ? GUILD", "...GRMUSER REQ? on the guild channel")
eq(GuildSpyProbeDB.grm.total, 0, "our own echo isn't counted as GRM traffic")
eq(GuildSpyProbeDB.grm.selfEcho, 1, "...it's counted apart")
eq(#WoW.chat, 0, "nothing in chat")

done("test_probe")
