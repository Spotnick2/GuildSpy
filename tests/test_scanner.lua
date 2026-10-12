-- The live shell, end to end through the client model: the login digest,
-- live lines with their officer, offline attribution from the server log,
-- officer-note privacy, /reload, the completeness gate, a guild switch.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function member(name, rank, guid, extra)
    local r = { name = name, rank = rank, level = 30, class = "MAGE", online = true, guid = guid, note = "" }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end
local function newGuild()
    return { name = "Parse Partout", realm = "Forever", myRank = 3,
             ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" },
             members = { member("Fizzle Sprocketwhistle", 3, "Player-1-00000001"),
                         member("Ann Lee", 3, "Player-1-00000002", { onote = "main tank" }),
                         member("Bo Kay", 4, "Player-1-00000003"),
                         member("Enzo Matrix", 0, "Player-1-00000004") },
             events = {}, eventNames = true, motd = "hello", canViewOfficerNote = false }
end
local function find(name)
    for i, m in ipairs(WoW.guild.members) do if m.name == name then return m, i end end
end
local function chatHas(text)
    for _, line in ipairs(WoW.chat) do if line:find(text, 1, true) then return line end end
end
-- The client's login: PLAYER_LOGIN, the roster arrives, the event log's burst.
local function login(db, guild)
    loadAddon({ db = db, setup = function() WoW.guild = guild end })
    WoW.fire("PLAYER_LOGIN")
    WoW.fire("GUILD_MOTD", guild.motd)                    -- measured: 1.3 s after login
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    for _ = 1, 5 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
end
local function rosterUpdate() WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3) end

-- First login ever: a silent baseline, one "now watching" line.
local G = newGuild()
login(nil, G)
WoW.advance(4)
check(chatHas("now watching Parse Partout (4 members)"), "the baseline is announced")
local db = GuildSpyDB
local gs = db.guilds["Parse Partout-Forever"]
check(gs and gs.observedAt, "the guild's state is saved under name-realm")
eq(#gs.log, 0, "nothing logged for a baseline")

-- Live: a promotion message, then the roster: one line, with the officer.
WoW.chat = {}
WoW.fire("CHAT_MSG_SYSTEM", "Enzo Matrix has promoted Bo Kay to Member.")
find("Bo Kay").rank = 3
rosterUpdate()
local line = chatHas("promoted")
check(line and line:find("Enzo Matrix promoted Bo Kay from Initiate to Member", 1, true), "live line names the officer")
eq(#gs.log, 1, "logged once")
eq(gs.log[1].approx, false, "...at the message's exact time")

-- Live: a kick is confirmed on the first missing scan, with its officer.
WoW.chat = {}
WoW.fire("CHAT_MSG_SYSTEM", "Bo Kay has been kicked out of the guild by Enzo Matrix.")
local _, bi = find("Bo Kay")
table.remove(WoW.guild.members, bi)
rosterUpdate()
check(chatHas("Bo Kay was kicked by Enzo Matrix"), "a kick, at once, with the officer")
check(gs.formers["Player-1-00000003"], "kept as a former member")

-- Levels and notes fire no message: the poll finds them.
WoW.chat = {}
find("Ann Lee").level = 31
find("Ann Lee").note = "healer"
rosterUpdate()
check(chatHas("Ann Lee reached level 31"), "a level-up line")
check(chatHas("Ann Lee's note"), "a note line")

-- Log out. While away: Ann promoted by Enzo, a newcomer, Bo back. Then log in.
local seqBefore = db.nextSeq
local saved = GuildSpyDB
local away = newGuild()
away.members = WoW.guild.members
find("Ann Lee").level = 31
WoW.epoch = WoW.epoch + 5 * 3600
local G2 = newGuild()
G2.members = {}
for _, m in ipairs(away.members) do G2.members[#G2.members + 1] = m end
G2.members[2] = member("Ann Lee", 2, "Player-1-00000002", { level = 31, note = "healer", onote = "main tank" })
G2.members[#G2.members + 1] = member("Cy Dee", 4, "Player-1-00000005")
G2.members[#G2.members + 1] = member("Bo Kay", 4, "Player-1-00000003")
-- The server log, oldest first, read once the burst settles (names then present).
G2.events = { { "promote", "Enzo Matrix", "Ann Lee", "Veteran", 0, 0, 0, 2 },
              { "join", "Cy Dee", nil, "", 0, 0, 0, 1 } }
local epochAtLogin = WoW.epoch
WoW.chat = {}
loadAddon({ db = saved, setup = function() WoW.guild = G2; WoW.epoch = epochAtLogin end })
WoW.fire("PLAYER_LOGIN")
WoW.fire("GUILD_ROSTER_UPDATE", false)
WoW.advance(2.5)
eq(#WoW.chat, 0, "no digest before the server log has settled")
for _ = 1, 5 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(4)
local summary = chatHas("since")
check(summary and summary:find("1 joined", 1, true) and summary:find("1 rejoined", 1, true)
    and summary:find("1 promoted", 1, true), "one digest, summarised: " .. tostring(summary))
check(chatHas("Enzo Matrix promoted Ann Lee from Veteran to Officer") == nil, "(Veteran -> Officer isn't what happened)")
check(chatHas("Enzo Matrix promoted Ann Lee from Member to Veteran"), "the offline promotion names its officer, from the log")
check(chatHas("Bo Kay rejoined the guild"), "a rejoin")
local promo
for _, e in ipairs(GuildSpyDB.guilds["Parse Partout-Forever"].log) do if e.kind == "PROMOTE" and e.name == "Ann Lee" then promo = e end end
eq(promo.approx, true, "an offline promotion's time is approximate")
-- No per-event spam for catch-up: the digest is the summary plus details.
local promotedLines = 0
for _, l in ipairs(WoW.chat) do if l:find("promoted Ann Lee", 1, true) then promotedLines = promotedLines + 1 end end
eq(promotedLines, 1, "each catch-up change shown once")

-- /reload: nothing new, nothing replayed.
WoW.chat = {}
local keep = GuildSpyDB
loadAddon({ db = keep, setup = function() WoW.guild = G2 end })
WoW.fire("PLAYER_LOGIN")
WoW.fire("GUILD_ROSTER_UPDATE", false)
for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(10)
eq(#WoW.chat, 0, "a /reload prints nothing")

-- Officer notes: an officer sees the change; a non-officer alt never sees the entry.
G2.canViewOfficerNote = true
rosterUpdate()                                        -- seeds the readable baseline
WoW.chat = {}
find("Ann Lee").onote = "raid lead"
rosterUpdate()
check(chatHas("Ann Lee's officer note"), "an officer sees an officer-note change")
G2.canViewOfficerNote = false
rosterUpdate()
WoW.chat = {}
WoW.slash("/gspy log 50")
check(chatHas("officer note") == nil, "a non-officer's /gspy log hides it")
check(chatHas("reached level 31"), "...but shows the rest")
WoW.chat = {}
rosterUpdate()
eq(#WoW.chat, 0, "a non-officer's empty slot is not an officer-note change")

-- Rights revoked, no scan since: hidden at once (asked at display time).
G2.canViewOfficerNote = true
WoW.chat = {}
WoW.slash("/gspy log 50")
check(chatHas("officer note"), "an officer's /gspy log shows it")
G2.canViewOfficerNote = false
WoW.chat = {}
WoW.slash("/gspy log 50")
check(chatHas("officer note") == nil, "rights revoked: hidden without waiting for a scan")

-- The completeness gate: an incomplete roster is not diffed, and is reported after 5 tries.
WoW.chat = {}
local rows = G2.members
G2.members = { rows[1], rows[2] }
rawset(_G, "GetNumGuildMembers", function() return #rows, 1 end)  -- the total says more rows exist
for _ = 1, 5 do rosterUpdate() end
check(chatHas("can't read the whole guild roster"), "a persistent incomplete roster is reported")
check(chatHas("left") == nil and chatHas("no longer") == nil, "...and nobody is declared gone")
G2.members = rows
rawset(_G, "GetNumGuildMembers", nil)
dofile("tests/wow_stubs.lua")   -- restore the stubs' functions (the strict _G stays)

-- A guild switch: the other guild gets its own baseline, its own state.
local other = newGuild()
other.name = "Other Guild"
WoW.chat = {}
loadAddon({ db = GuildSpyDB, setup = function() WoW.guild = other end })
WoW.fire("PLAYER_LOGIN")
WoW.fire("GUILD_ROSTER_UPDATE", false)
for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(10)
check(chatHas("now watching Other Guild"), "another guild: a fresh baseline")
check(GuildSpyDB.guilds["Parse Partout-Forever"] ~= nil, "...and the first guild's state is kept")

-- A damaged saved file: an unreadable record means a fresh baseline, never a Lua error.
local broken = { version = 1, guilds = { ["Other Guild-Forever"] = {
    observedAt = 1, members = { ["Player-1-00000002"] = { name = "Ann Lee", rank = 2, lastSeenAt = "soon" } },   -- a text time
    log = { { seq = 1, at = 1790000000, kind = "JOIN", name = "x" }, "garbage", { kind = 5 } },
    formers = { G = "garbage" } } } }
WoW.chat = {}
loadAddon({ db = broken, setup = function() WoW.guild = other end })
WoW.fire("PLAYER_LOGIN")
WoW.fire("GUILD_ROSTER_UPDATE", false)
for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
local ok = pcall(WoW.advance, 10)
check(ok, "a damaged snapshot doesn't error")
check(chatHas("now watching Other Guild"), "...it is rebuilt as a baseline")
eq(#GuildSpyDB.guilds["Other Guild-Forever"].log, 1, "...unreadable log entries dropped, the good one kept")

-- At login, a promotion made during a rank restructure is confirmed from the
-- server log: the first scan waits for the log instead of suppressing it.
local R = newGuild()
loadAddon({ setup = function() WoW.guild = R end })
WoW.fire("PLAYER_LOGIN"); WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(30)
local saved2 = GuildSpyDB
WoW.epoch = WoW.epoch + 3600
local R2 = newGuild()
R2.ranks = { "Guild Master", "Officer", "Raider", "Veteran", "Member", "Initiate" }   -- a rank added
R2.members = { member("Fizzle Sprocketwhistle", 4, "Player-1-00000001"),
               member("Ann Lee", 2, "Player-1-00000002"),                             -- Member -> Raider
               member("Bo Kay", 5, "Player-1-00000003"),
               member("Enzo Matrix", 0, "Player-1-00000004") }
R2.events = { { "promote", "Enzo Matrix", "Ann Lee", "Raider", 0, 0, 0, 0 } }
local ep = WoW.epoch
WoW.chat = {}
loadAddon({ db = saved2, setup = function() WoW.guild = R2; WoW.epoch = ep end })
WoW.fire("PLAYER_LOGIN")
WoW.fire("GUILD_ROSTER_UPDATE", false)
WoW.advance(3)                                       -- roster settled: the first scan holds
for _ = 1, 5 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(5)                                       -- log settled: the held scan runs
check(chatHas("Enzo Matrix promoted Ann Lee from Member to Raider"), "confirmed from the log at login")
check(chatHas("1 rank changes"), "...alongside the structure change")

-- The log is asked for only when something waits on it.
local queries = 0
local realQuery = QueryGuildEventLog
rawset(_G, "QueryGuildEventLog", function() queries = queries + 1 end)
WoW.advance(130)
eq(queries, 0, "a quiet poll doesn't ask for the server log")
WoW.fire("CHAT_MSG_SYSTEM", "Enzo Matrix has promoted Bo Kay to Member.")
WoW.advance(2)
eq(queries, 1, "a guild message does")
rawset(_G, "QueryGuildEventLog", realQuery)

-- An empty MOTD at login is "not loaded yet", not a change.
WoW.chat = {}
WoW.fire("GUILD_MOTD", "")
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
WoW.fire("GUILD_MOTD", R2.motd)
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
check(chatHas("message of the day") == nil, "no MOTD noise from an unloaded MOTD")

-- A new MOTD comes from GUILD_MOTD; C_GuildInfo.GetMOTD is never called (#16).
WoW.chat = {}
WoW.motdReads = 0
R2.motd = "raid at 8"
WoW.fire("GUILD_MOTD", R2.motd)
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
check(chatHas("raid at 8"), "the event's MOTD is reported")
eq(WoW.motdReads, 0, "...and the protected GetMOTD was never called")

-- A rank index the rank table doesn't have yet: the roster is incomplete.
WoW.chat = {}
local n0 = #GuildSpyDB.guilds["Parse Partout-Forever"].log
R2.members[3].rank = 9
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
eq(#GuildSpyDB.guilds["Parse Partout-Forever"].log, n0, "no entry from a roster ahead of its rank table")
R2.members[3].rank = 5

-- Officer notes keep their own digest boundary across alts.
local gs2 = GuildSpyDB.guilds["Parse Partout-Forever"]
R2.canViewOfficerNote = true
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)          -- seed
local saved3 = GuildSpyDB
-- Offline: the note changes; a non-officer alt logs in first, then the officer.
find("Ann Lee").onote = "x"
R2.members[2].onote = "officer only"
R2.canViewOfficerNote = false
loadAddon({ db = saved3, setup = function() WoW.guild = R2 end })
WoW.fire("PLAYER_LOGIN"); WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(5)
-- (the alt can't read it, so the change isn't even recorded yet; the officer records it)
R2.canViewOfficerNote = true
WoW.chat = {}
loadAddon({ db = GuildSpyDB, setup = function() WoW.guild = R2 end })
WoW.fire("PLAYER_LOGIN"); WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(5)
check(chatHas("officer note"), "the officer gets the officer-note change")
-- A recorded officer-note entry shown to nobody yet: a non-officer digest passes it, the officer still gets it.
local gs3 = GuildSpyDB.guilds["Parse Partout-Forever"]
local entry = { seq = GuildSpyDB.nextSeq, at = WoW.epoch, kind = "ONOTE", name = "Ann Lee", from = "a", to = "b" }
GuildSpyDB.nextSeq = GuildSpyDB.nextSeq + 1
table.insert(gs3.log, entry)
local L = GuildSpy.Log
local _, top, topOnote = L.Digest(gs3, false, WoW.epoch)
gs3.shownSeq = top
eq(topOnote, nil, "a non-officer moves no officer-note boundary")
local lines = L.Digest(gs3, true, WoW.epoch)
check(#lines > 0 and lines[2]:find("officer note", 1, true), "the officer's next digest still has it")

-- "Show offline members" off: GuildSpy pauses and says so; nobody is declared gone.
WoW.chat = {}
local n1 = #GuildSpyDB.guilds["Parse Partout-Forever"].log
R2.hideOffline = true
for _ = 1, 3 do WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(40) end
check(chatHas("Show Offline Members"), "show offline off: paused, and said so")
local warned = 0
for _, l in ipairs(WoW.chat) do if l:find("Show Offline Members", 1, true) then warned = warned + 1 end end
eq(warned, 1, "...once")
eq(#GuildSpyDB.guilds["Parse Partout-Forever"].log, n1, "...and nothing recorded")
R2.hideOffline = nil

-- Two members share a name and both change: one message credits neither.
WoW.chat = {}
local t1 = member("Sam Mahra", 5, "Player-1-00000010")
local t2 = member("Sam Mahra", 5, "Player-2-00000011")
table.insert(R2.members, t1); table.insert(R2.members, t2)
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
WoW.fire("CHAT_MSG_SYSTEM", "Enzo Matrix has promoted Sam Mahra to Member.")
t1.rank, t2.rank = 4, 4
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
check(chatHas("Enzo Matrix promoted Sam Mahra") == nil, "a shared name: no officer credited")
check(chatHas("Sam Mahra was promoted"), "...the promotions are still reported")

-- One member, two changes in one scan: still one member, the officer still named.
WoW.chat = {}
WoW.fire("CHAT_MSG_SYSTEM", "Enzo Matrix has promoted Ann Lee to Officer.")
local ann = find("Ann Lee")
ann.rank, ann.level = 1, ann.level + 1
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
check(chatHas("Enzo Matrix promoted Ann Lee"), "a promotion plus a level-up: the officer is still named")

-- The officer-note boundary never jumps an unseen officer-note entry.
local gsb = { log = { { seq = 10, kind = "ONOTE" }, { seq = 11, kind = "NOTE" }, { seq = 12, kind = "ONOTE" } },
              shownOnoteSeq = 5 }
GuildSpy.Scanner.SeenOnote(gsb, 12)
eq(gsb.shownOnoteSeq, 5, "seq 10 unseen: the boundary stays")
GuildSpy.Scanner.SeenOnote(gsb, 10)
eq(gsb.shownOnoteSeq, 10, "seq 10 seen: the boundary moves to it")

-- A switch to another guild in the same session, before its GUILD_MOTD:
-- the old guild's text never lands in the new guild's state (#17 review).
WoW.fire("GUILD_MOTD", R2.motd)                       -- this guild's text is cached
WoW.chat = {}
local third = newGuild()
third.name, third.motd = "Third Guild", "third's own motd"
WoW.guild = third
WoW.fire("PLAYER_GUILD_UPDATE")
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(25)
local tg = GuildSpyDB.guilds["Third Guild-Forever"]
check(tg and tg.observedAt, "the new guild is baselined")
eq(tg and tg.motd, nil, "...without the old guild's MOTD")
WoW.fire("GUILD_MOTD", third.motd)
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
eq(tg.motd, "third's own motd", "its own MOTD arrives")
check(chatHas("message of the day") == nil, "...seeded silently, not reported as new")
WoW.guild = R2
WoW.fire("PLAYER_GUILD_UPDATE")
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(25)

-- Status and rebaseline answer.
WoW.chat = {}
WoW.slash("/gspy status")
check(chatHas("Parse Partout-Forever"), "status names the guild")
WoW.slash("/gspy rebaseline")
eq(GuildSpyDB.guilds["Parse Partout-Forever"].observedAt, nil, "rebaseline forgets the snapshot")

done("test_scanner")
