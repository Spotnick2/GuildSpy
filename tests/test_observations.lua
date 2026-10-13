-- #36: observations (docs/SYNC.md, phase 1, no transport): identity,
-- provenance, receiving, retention, migration, display safety.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

loadAddon()
local Log = GuildSpy.Log
local NOW = 1790000000
local DAY = 86400

local function store() return { nextSeq = 1 }, { log = {} } end
-- A received entry as a peer would send it (a fresh table each time).
local function obs(t)
    local e = { uid = "abc:1", rev = 1, kind = "LEVEL", guid = "Player-1-0000000A", name = "Ann Lee",
                from = 29, to = 30, at = NOW - 3600, obs = NOW - 3600, lo = NOW - 3700, hi = NOW - 3600,
                origin = "Bo Kay" }
    for k, v in pairs(t or {}) do e[k] = v end
    return e
end
local function count(gs) return #gs.log end

-- Own observations: Log.Add gives identity and provenance.
do
    local db, gs = store()
    local e = Log.Add(db, gs, { kind = "JOIN", guid = "Player-1-00000001", name = "Cy", lo = NOW - 60, hi = NOW }, NOW)
    check(type(e.uid) == "string" and e.uid:find("^%w+:%d+$"), "an own entry gets a uid")
    check(e.trust == "self" and e.here == true and e.rev == 1, "...trust self, here, rev 1")
    eq(e.origin, "Fizzle Sprocketwhistle", "...observed by this character")
    check(e.lo == NOW - 60 and e.hi == NOW and e.obs == NOW, "...its interval, observed at hi")
    local e2 = Log.Add(db, gs, { kind = "JOIN", guid = "Player-1-00000002", name = "Di", lo = NOW - 60, hi = NOW,
                                 at = NOW - 30, approx = false }, NOW)
    eq(e2.obs, NOW - 30, "an exact time at creation is the observed time")
    local e3 = Log.Add(db, gs, { kind = "JOIN", guid = "Player-1-00000003", name = "Ed", lo = NOW - 900, hi = NOW - 500,
                                 at = NOW - 3600, approx = true }, NOW)
    eq(e3.obs, NOW - 500, "a time to the hour isn't exact: the observed time is the interval's end")
    local e4 = Log.Add(db, gs, { kind = "JOIN", guid = "Player-1-00000004", name = "Flo", lo = NOW - 900, hi = NOW - 400 }, NOW)
    eq(e4.obs, NOW - 400, "a scan-noticed change: observed at the interval's end, not when logged")
    check(e2.uid ~= e.uid and e2.chg > e.chg, "uids differ; the change counter rises")
    -- Enrichment by its observer: a new revision and change; observed time stays.
    local chg = e.chg
    Log.Enrich(e, { actor = "Enzo Matrix", at = NOW - 45, approx = false }, gs)
    check(e.rev == 2 and e.chg > chg, "enriching it bumps rev and chg")
    eq(e.obs, NOW, "...and never moves its observed time (retention order stays)")
    local rev = e.rev
    Log.Enrich(e, { actor = "Someone Else" }, gs)
    eq(e.rev, rev, "nothing new: no new revision")
end

-- Receiving: namespaces, forgery, supersession.
do
    local db, gs = store()
    -- From a guildmate: only what that character saw.
    local e, why = Log.Receive(db, gs, obs({ origin = "Bo Kay" }), "guild", "Mallory Vex", NOW)
    check(not e and why == "not the sender's", "a guild copy whose origin isn't the sender is refused")
    e, why = Log.Receive(db, gs, obs(), "guild", "Bo Kay", NOW)
    check(e and why == "added", "Bo's own report is added")
    check(e.trust == "guild" and e.reporter == "Bo Kay" and e.ns == "g:Bo Kay" and e.here == false,
        "...as Bo's report, not this account's")
    eq(Log.Source(e), "Reported by Bo Kay", "...and says so")
    check(e.seq == 1 and e.chg == 1, "...with a local seq and change")
    e, why = Log.Receive(db, gs, obs(), "guild", "Bo Kay", NOW)
    check(not e and why == "known", "the same report again: ignored")
    e, why = Log.Receive(db, gs, obs({ rev = 2, actor = "Enzo Matrix" }), "guild", "Bo Kay", NOW)
    check(e and why == "updated" and e.actor == "Enzo Matrix" and e.rev == 2, "Bo's higher revision updates Bo's report")

    -- Someone reusing Bo's visible uid stays in their own namespace.
    e, why = Log.Receive(db, gs, obs({ origin = "Mallory Vex", rev = 99, actor = "Fake" }), "guild", "Mallory Vex", NOW)
    check(e and e.ns == "g:Mallory Vex", "a colliding uid from another reporter is that reporter's own record")
    local bo
    for _, x in ipairs(gs.log) do if x.ns == "g:Bo Kay" then bo = x end end
    eq(bo.actor, "Enzo Matrix", "...and never rewrites Bo's")

    -- My own observation can't be touched from GUILD.
    local mine = Log.Add(db, gs, { kind = "PROMOTE", guid = "Player-1-0000000B", name = "Cy", from = "Initiate",
                                   to = "Member", lo = NOW - 120, hi = NOW - 60 }, NOW)
    local forged = obs({ uid = mine.uid, rev = 999, kind = "PROMOTE", guid = "Player-1-0000000B", name = "Cy",
                         from = "Initiate", to = "Member", actor = "Fake Officer", approx = false,
                         origin = mine.origin })
    e, why = Log.Receive(db, gs, forged, "guild", mine.origin, NOW)
    check(not e and why == "known", "a guild copy of my own observation is ignored")
    check(mine.rev == 1 and mine.actor == nil, "...my observation is unchanged")
    forged.origin = "Mallory Vex"
    e = Log.Receive(db, gs, forged, "guild", "Mallory Vex", NOW)
    check(e and e.ns == "g:Mallory Vex" and mine.actor == nil, "a forged higher rev of my uid lands in the forger's namespace")
end

do  -- Supersession: my other account's copy replaces a guild copy of the same observation.
    local db, gs = store()
    local g = Log.Receive(db, gs, obs({ uid = "w9:4", rev = 3, origin = "Alt Two", actor = "Claimed" }), "guild", "Alt Two", NOW)
    check(g and g.trust == "guild", "(seen first from GUILD, as Alt Two's report)")
    local a, why = Log.Receive(db, gs, obs({ uid = "w9:4", rev = 1, origin = "Alt Two" }), "acct", nil, NOW)
    check(a and why == "superseded", "then my account's copy, even at a lower rev, supersedes it")
    check(a.trust == "self" and a.here == false and a.actor == nil, "...as mine, inheriting nothing")
    eq(count(gs), 1, "...one record left")
    eq(Log.Source(a), "Seen on Alt Two", "...seen on my other character")
end

do  -- Account forwarding keeps a guild report a guild report, and its text identical.
    local db, gs = store()
    local note = obs({ uid = "q1:7", kind = "NOTE", from = "a|b", to = "x||y |cffff0000red", origin = "Bo Kay" })
    note.from, note.to = "old", "x|y |cffff0000red"
    local g = Log.Receive(db, gs, note, "guild", "Bo Kay", NOW)
    eq(g.to, "x|y |cffff0000red", "text is stored as received (canonical)")
    -- My other account forwards it: same namespace, same text.
    local db2, gs2 = store()
    local fwd = {}
    for _, f in ipairs(Log.FIELDS) do fwd[f] = g[f] end
    fwd.ns = g.ns
    local f1 = Log.Receive(db2, gs2, fwd, "acct", nil, NOW)
    check(f1 and f1.trust == "guild" and f1.ns == "g:Bo Kay" and f1.reporter == "Bo Kay",
        "forwarded by my account, it stays Bo's report")
    eq(f1.to, g.to, "...with identical text")
    local db3, gs3 = store()
    local again = {}
    for _, f in ipairs(Log.FIELDS) do again[f] = f1[f] end
    again.ns = f1.ns
    eq(Log.Receive(db3, gs3, again, "acct", nil, NOW).to, g.to, "...after another hop too")
    -- Shown, a "|" is escaped: no markup from someone else's text.
    local row = Log.Row(g, NOW)
    check(row:find("x||y ||cffff0000red", 1, true), "displayed, the text's | is escaped")
    check(Log.Line(g, NOW):find("x||y ||cffff0000red", 1, true), "...in chat too")
    check(Log.Plain(row):find("(reported)", 1, true), "a guildmate's report is marked in the window")
    local own = Log.Add(db, gs, { kind = "JOIN", guid = "Player-1-00000001", name = "Mine", lo = NOW - 60, hi = NOW }, NOW)
    check(not Log.Plain(Log.Row(own, NOW)):find("reported", 1, true), "...my own isn't")
end

do  -- Validation: one bad field refuses the entry.
    local db, gs = store()
    local bad = {
        { "kind", obs({ kind = "ONOTE", from = "a", to = "b" }), "guild" },
        { "kind", obs({ kind = "MOTD", guid = nil, from = "a", to = "b" }), "guild" },
        { "guid", obs({ guid = "Creature-1-2" }), "guild" },
        { "uid", obs({ uid = "bad uid" }), "guild" },
        { "rev", obs({ rev = 0 }), "guild" },
        { "level", obs({ to = 400 }), "guild" },
        { "text", obs({ name = "A\nB" }), "guild" },
        { "text", obs({ kind = "NOTE", from = "", to = string.rep("x", 200) }), "guild" },
        { "interval", obs({ lo = NOW, hi = NOW - 10 }), "guild" },
        { "time", obs({ obs = NOW + 3600 }), "guild" },
        { "time", obs({ obs = NOW - 61 * DAY, at = NOW - 61 * DAY, hi = NOW - 61 * DAY, lo = NOW - 62 * DAY }), "guild" },
    }
    for _, b in ipairs(bad) do
        local e, why = Log.Receive(db, gs, b[2], b[3], "Bo Kay", NOW)
        check(not e and why == b[1], "refused: " .. b[1] .. " (" .. tostring(why) .. ")")
    end
    -- An old lower bound is fine: a long absence.
    local e = Log.Receive(db, gs, obs({ lo = NOW - 300 * DAY }), "guild", "Bo Kay", NOW)
    check(e, "an old lo is fine (a long absence before the observation)")
    -- My accounts may share officer notes and the MOTD.
    e = Log.Receive(db, gs, obs({ uid = "z:1", kind = "ONOTE", from = "", to = "raid lead" }), "acct", nil, NOW)
    check(e and e.kind == "ONOTE", "an officer note from my other account is accepted")
    check(not Log.Visible(e, false) and Log.Visible(e, true), "...and still shown only to a character that can read it")
end

do  -- Retention: deterministic, namespaced tie-break, non-backfill, quotas apart.
    local saved = { Log.GUILD_MAX_ENTRIES, Log.MAX_ENTRIES }
    Log.GUILD_MAX_ENTRIES = 2
    local db, gs = store()
    local function rep(sender, uid, t)
        return Log.Receive(db, gs, obs({ uid = uid, origin = sender, obs = t, at = t, hi = t, lo = t - 60 }), "guild", sender, NOW)
    end
    check(rep("Ann Lee", "a:1", NOW - 300), "report 1 kept")
    check(rep("Bo Kay", "b:1", NOW - 200), "report 2 kept")
    local e, why = rep("Cy Dee", "c:1", NOW - 400)
    check(not e and why == "full", "an older report into a full quota is refused, not swapped in")
    check(rep("Cy Dee", "c:2", NOW - 100), "a newer one evicts the oldest")
    local names = {}
    for _, x in ipairs(gs.log) do names[#names + 1] = x.reporter end
    eq(table.concat(names, ","), "Bo Kay,Cy Dee", "...the oldest observation went")
    -- Ties: same time, the namespace decides, the same way on every account.
    local db2, gs2 = store()
    local function tie(order)
        local d, g = store()
        for _, s in ipairs(order) do
            Log.Receive(d, g, obs({ uid = "u:1", origin = s, obs = NOW - 50, at = NOW - 50, hi = NOW - 50, lo = NOW - 60 }), "guild", s, NOW)
        end
        Log.Receive(d, g, obs({ uid = "u:2", origin = "Zed Zee", obs = NOW - 10, at = NOW - 10, hi = NOW - 10, lo = NOW - 20 }), "guild", "Zed Zee", NOW)
        local kept = {}
        for _, x in ipairs(g.log) do kept[#kept + 1] = x.reporter end
        table.sort(kept)
        return table.concat(kept, ",")
    end
    eq(tie({ "Ann Lee", "Bo Kay" }), tie({ "Bo Kay", "Ann Lee" }), "a tie in time keeps the same record whatever the arrival order")
    Log.GUILD_MAX_ENTRIES, Log.MAX_ENTRIES = saved[1], saved[2]

    -- Guild reports never push out my own observations.
    Log.GUILD_MAX_ENTRIES, Log.MAX_ENTRIES = 1, 2
    local db3, gs3 = store()
    Log.Add(db3, gs3, { kind = "JOIN", guid = "Player-1-00000001", name = "A", lo = NOW - 900, hi = NOW - 800 }, NOW)
    Log.Add(db3, gs3, { kind = "JOIN", guid = "Player-1-00000002", name = "B", lo = NOW - 700, hi = NOW - 600 }, NOW)
    for i = 1, 5 do
        Log.Receive(db3, gs3, obs({ uid = "r:" .. i, origin = "Bo Kay", obs = NOW - i, at = NOW - i, hi = NOW - i, lo = NOW - i - 5 }), "guild", "Bo Kay", NOW)
    end
    local own, reports = 0, 0
    for _, x in ipairs(gs3.log) do if x.trust == "guild" then reports = reports + 1 else own = own + 1 end end
    check(own == 2 and reports == 1, "five reports keep their own quota; my two observations stay")
    Log.GUILD_MAX_ENTRIES, Log.MAX_ENTRIES = saved[1], saved[2]
end

do  -- Migration: legacy entries become mine, observer unknown, once.
    local gs = { log = { { seq = 1, at = NOW - 100, kind = "JOIN", guid = "Player-1-00000001", name = "Old", after = NOW - 200 } } }
    Log.Migrate(gs)
    local e = gs.log[1]
    check(type(e.uid) == "string" and e.trust == "self" and e.here == true, "a legacy entry gets a uid, as mine")
    check(e.origin == nil, "...its observer unknown")
    check(e.lo == NOW - 200 and e.hi == NOW - 100 and e.obs == NOW - 100, "...a fallback interval")
    local uid = e.uid
    Log.Migrate(gs)
    eq(e.uid, uid, "...and only once")
    eq(Log.Source(e), nil, "...shown as this account's own")
end

do  -- Imports never enter the login digest; my own do.
    local db, gs = store()
    gs.shownSeq = 0
    Log.Add(db, gs, { kind = "JOIN", guid = "Player-1-00000001", name = "Mine", lo = NOW - 60, hi = NOW }, NOW)
    Log.Receive(db, gs, obs(), "guild", "Bo Kay", NOW)
    Log.Receive(db, gs, obs({ uid = "z:9", origin = "Alt Two" }), "acct", nil, NOW)
    local lines = Log.Digest(gs, false, NOW)
    local text = table.concat(lines, "\n")
    check(text:find("Mine joined", 1, true), "the digest has my own")
    check(not text:find("Ann Lee", 1, true), "...and none of the imports")
    -- A reported level-cap doesn't play the summary's fanfare: the summary is about my own scans.
    local db2, gs2 = store()
    gs2.shownSeq = 0
    Log.Receive(db2, gs2, obs({ uid = "cap:1", from = 59, to = 60 }), "guild", "Bo Kay", NOW)
    local lines2 = Log.Digest(gs2, false, NOW)
    eq(#lines2, 0, "a reported cap level-up isn't in the summary")
    -- Search finds a report by its reporter.
    local found = Log.Filter(gs, { query = "bo kay" }, NOW)
    check(#found == 1 and found[1].reporter == "Bo Kay", "search finds a report by who reported it")
end

-- #39 review --------------------------------------------------------------

do  -- A new own observation is never the one evicted, even with an older observed time.
    local saved = Log.MAX_ENTRIES
    Log.MAX_ENTRIES = 2
    local db, gs = store()
    Log.Add(db, gs, { kind = "JOIN", guid = "Player-1-00000001", name = "A", lo = NOW - 200, hi = NOW - 100 }, NOW)
    Log.Add(db, gs, { kind = "JOIN", guid = "Player-1-00000002", name = "B", lo = NOW - 100, hi = NOW - 50 }, NOW)
    local late = Log.Add(db, gs, { kind = "LEAVE", guid = "Player-1-00000003", name = "C",
                                   lo = NOW - 90000, hi = NOW - 86400 }, NOW)
    local names = {}
    for _, x in ipairs(gs.log) do names[#names + 1] = x.name end
    eq(table.concat(names, ","), "B,C", "a confirmed departure with an older observed time stays; the oldest other goes")
    check(late.seq and late == gs.log[2], "...it is the entry just shown")
    Log.MAX_ENTRIES = saved
end

do  -- A guild report forwarded by my account keeps the guild rules.
    local db, gs = store()
    local function fwd(t)
        local e = obs(t)
        e.ns = "g:Bo Kay"
        return Log.Receive(db, gs, e, "acct", nil, NOW)
    end
    local e, why = fwd({ uid = "f:1", kind = "ONOTE", from = "", to = "secret" })
    check(not e and why == "kind", "a forwarded 'report' of an officer note is refused (Bo could never send one)")
    e, why = fwd({ uid = "f:2", origin = "Someone Else" })
    check(not e and why == "not the sender's", "a forwarded report whose observer isn't its reporter is refused")
    e = fwd({ uid = "f:3" })
    check(e and e.reporter == "Bo Kay", "a proper forwarded report is kept")
end

do  -- Escaping is idempotent; search finds text with a pipe.
    eq(Log.Esc("a|b"), "a||b", "a lone | is escaped")
    eq(Log.Esc("a||b"), "a||b", "an already escaped || is left as is")
    eq(Log.Esc("a|||b"), "a||||b", "an odd run is completed")
    eq(Log.Plain("x||y ||cffff0000red"), "x|y |cffff0000red", "plain text keeps escaped pipes as text")
    local db, gs = store()
    Log.Receive(db, gs, obs({ uid = "p:1", kind = "NOTE", from = "", to = "x|y" }), "guild", "Bo Kay", NOW)
    eq(#Log.Filter(gs, { query = "x|y" }, NOW), 1, "searching for a note with a pipe finds it")
end

do  -- Tighter validation.
    local db, gs = store()
    local cases = {
        { "rev", obs({ uid = "v:1", rev = 1e7 }) },
        { "rev", obs({ uid = "v:2", rev = math.huge }) },
        { "text", obs({ uid = "v:3", kind = "PROMOTE", from = "Member", to = string.rep("r", 33) }) },
        { "text", obs({ uid = "v:4", kind = "NAME", from = "Ann Lee", to = string.rep("n", 49) }) },
        { "level", obs({ uid = "v:5", from = 60, to = 61 }) },
    }
    for _, c in ipairs(cases) do
        local e, why = Log.Receive(db, gs, c[2], "guild", "Bo Kay", NOW)
        check(not e and why == c[1], "refused: " .. c[1] .. " (" .. tostring(why) .. ")")
    end
    check(Log.Receive(db, gs, obs({ uid = "v:6", kind = "PROMOTE", from = "Member", to = "Raider" }), "guild", "Bo Kay", NOW),
        "a normal rank change passes")
end

do  -- A guild report with a damaged identity is dropped at load, never migrated as mine.
    local now = time()
    local saved = { guilds = { ["Parse Partout-Forever"] = { log = {
        { seq = 1, at = now - 60, kind = "JOIN", guid = "Player-1-00000009", name = "Fake",
          trust = "guild", ns = "g:Bo Kay", uid = 12345, reporter = "Bo Kay", origin = "Bo Kay" },
        { seq = 2, at = now - 50, kind = "JOIN", guid = "Player-1-00000008", name = "Real",
          trust = "guild", ns = "g:Bo Kay", uid = "w:1", reporter = "Bo Kay", origin = "Bo Kay" },
        { seq = 3, at = now - 40, kind = "JOIN", guid = "Player-1-00000007", name = "Mine" },
    } } } }
    loadAddon({ db = saved, setup = function()
        WoW.guild = { name = "Parse Partout", realm = "Forever", myRank = 3, ranks = { "GM", "Member" },
                      members = { { name = "Fizzle Sprocketwhistle", rank = 1, level = 30, class = "MAGE",
                                    online = true, guid = "Player-1-00000001", note = "" } },
                      events = {}, eventNames = true, motd = "", canViewOfficerNote = false }
    end })
    WoW.fire("PLAYER_LOGIN")
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    WoW.advance(25)
    local gs = saved.guilds["Parse Partout-Forever"]
    local names = {}
    for _, x in ipairs(gs.log) do names[#names + 1] = x.name .. ":" .. tostring(x.trust) end
    eq(table.concat(names, ","), "Real:guild,Mine:self", "the damaged report is dropped; the good one and mine stay")
end

done("test_observations")
