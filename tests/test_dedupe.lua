-- #41: an observation my more precise ones cover isn't kept (stored, not
-- only hidden): one account saw "reached 22" and "reached 23" live, the other
-- "from 21 to 23" at its login scan.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

loadAddon()
local Log = GuildSpy.Log
local NOW = time()
local ALISSA = "Player-1-0000A115"

local function store() return { nextSeq = 1 }, { log = {} } end
-- A received entry (a fresh table each time). Default: a coarse level-up
-- noticed by a scan over the last 3 hours.
local function obs(t)
    local e = { uid = "b:1", rev = 1, kind = "LEVEL", guid = ALISSA, name = "Alissa White",
                from = 21, to = 23, at = NOW - 60, obs = NOW - 60, lo = NOW - 3 * 3600, hi = NOW - 60,
                origin = "Alt Two" }
    for k, v in pairs(t or {}) do e[k] = v end
    return e
end
-- Seen live: an exact time.
local function live(uid, from, to, at, t)
    local e = obs({ uid = uid, from = from, to = to, at = at, obs = at, lo = at - 60, hi = at, approx = false })
    for k, v in pairs(t or {}) do e[k] = v end
    return e
end
-- A kind with no from/to.
local function point(e) e.from, e.to = nil, nil; return e end
local function uids(gs)
    local out = {}
    for _, e in ipairs(gs.log) do out[#out + 1] = e.uid end
    table.sort(out)
    return table.concat(out, ",")
end

do  -- The case from the game: the fine steps are here first, the coarse one arrives.
    local db, gs = store()
    Log.Receive(db, gs, live("a:1", 21, 22, NOW - 3600), "acct", nil, NOW)
    Log.Receive(db, gs, live("a:2", 22, 23, NOW - 1320), "acct", nil, NOW)
    local seq = db.nextSeq
    local e, why = Log.Receive(db, gs, obs(), "acct", nil, NOW)
    check(not e and why == "covered", "21 to 23 arrives after 21 to 22 and 22 to 23: not kept")
    eq(db.nextSeq, seq, "...no sequence number taken")
    eq(uids(gs), "a:1,a:2", "...the two steps stay")
end

do  -- The other way round: the coarse one is here, the steps arrive in a page.
    local db, gs = store()
    Log.Receive(db, gs, obs(), "acct", nil, NOW)
    local batch = Log.NewBatch(gs, NOW)
    Log.Receive(db, gs, live("a:1", 21, 22, NOW - 3600), "acct", nil, NOW, batch)
    eq(uids(gs), "a:1,b:1", "one step isn't the whole change: the coarse record stays")
    local coarse = gs.log[1]
    Log.Receive(db, gs, live("a:2", 22, 23, NOW - 1320), "acct", nil, NOW, batch)
    eq(uids(gs), "a:1,a:2", "with both steps, the coarse record goes")
    check(coarse.covered, "...marked, so a catch-up line queued for it doesn't count it")
    eq(batch.count.self, 2, "...and the page's count follows")
    check(#(batch.byUid["b:1"] or {}) == 0 and #batch.byKey["m:" .. ALISSA] == 2, "...and its indexes")
end

do  -- The same single change: the exact one stays, whichever arrives first.
    local db, gs = store()
    Log.Receive(db, gs, obs({ uid = "b:2", from = 14, to = 15 }), "acct", nil, NOW)
    Log.Receive(db, gs, live("a:3", 14, 15, NOW - 1620), "acct", nil, NOW)
    eq(uids(gs), "a:3", "a scan's 14 to 15 goes when the live one arrives")
    local db2, gs2 = store()
    Log.Receive(db2, gs2, live("a:3", 14, 15, NOW - 1620), "acct", nil, NOW)
    local e, why = Log.Receive(db2, gs2, obs({ uid = "b:2", from = 14, to = 15 }), "acct", nil, NOW)
    check(not e and why == "covered", "...and isn't kept when it arrives second")
end

do  -- Two scans of the same change, overlapping: every account keeps the same one.
    local x = obs({ uid = "b:3", from = 14, to = 15, lo = NOW - 7200, hi = NOW - 100 })
    local y = obs({ uid = "c:3", from = 14, to = 15, lo = NOW - 5000, hi = NOW - 50, origin = "Alt Three" })
    local db1, gs1 = store()
    Log.Receive(db1, gs1, x, "acct", nil, NOW); Log.Receive(db1, gs1, obs(y), "acct", nil, NOW)
    local db2, gs2 = store()
    Log.Receive(db2, gs2, obs(y), "acct", nil, NOW); Log.Receive(db2, gs2, obs(x), "acct", nil, NOW)
    eq(uids(gs1), "c:3", "the narrower interval stays")
    eq(uids(gs2), uids(gs1), "...in either order")
    local z = obs({ uid = "d:3", from = 14, to = 15, lo = NOW - 5000, hi = NOW - 50, origin = "Alt Four" })
    Log.Receive(db1, gs1, z, "acct", nil, NOW)
    Log.Receive(db2, gs2, obs(z), "acct", nil, NOW)
    eq(uids(gs1), "c:3", "the same width: the order is total (namespace, then uid)")
    eq(uids(gs2), uids(gs1), "...the same on both")
    local db3, gs3 = store()
    Log.Receive(db3, gs3, obs(z), "acct", nil, NOW); Log.Receive(db3, gs3, obs(y), "acct", nil, NOW)
    eq(uids(gs3), "c:3", "...whichever of the two arrives first")
    gs3.log = { obs(y), obs(z) }
    for _, e in ipairs(gs3.log) do e.trust = "self" end
    Log.Dedupe(gs3)
    eq(uids(gs3), "c:3", "...and a stored pair keeps exactly one")
end

do  -- Level-ups only (owner, #42 review): kinds that can be undone keep every record.
    local db, gs = store()
    Log.Receive(db, gs, obs({ uid = "b:4", kind = "PROMOTE", from = "Member", to = "Officer" }), "acct", nil, NOW)
    Log.Receive(db, gs, live("a:4", "Member", "Officer", NOW - 1000, { kind = "PROMOTE" }), "acct", nil, NOW)
    eq(#gs.log, 2, "a promotion seen live inside a scan's span: both kept")
    local db2, gs2 = store()
    Log.Receive(db2, gs2, obs({ uid = "b:5", kind = "NOTE", from = "a", to = "b" }), "acct", nil, NOW)
    Log.Receive(db2, gs2, live("a:5", "a", "x", NOW - 2000, { kind = "NOTE" }), "acct", nil, NOW)
    Log.Receive(db2, gs2, live("a:6", "x", "b", NOW - 1000, { kind = "NOTE" }), "acct", nil, NOW)
    eq(#gs2.log, 3, "a note's a to b with a to x and x to b inside: all kept (a later b to a could make it another change)")
    local db3, gs3 = store()
    Log.Receive(db3, gs3, point(obs({ uid = "b:6", kind = "JOIN" })), "acct", nil, NOW)
    Log.Receive(db3, gs3, point(live("a:7", 1, 2, NOW - 1000, { kind = "JOIN" })), "acct", nil, NOW)
    eq(#gs3.log, 2, "the same join seen twice: both kept")
    local db4, gs4 = store()
    Log.Receive(db4, gs4, obs({ uid = "b:7", from = 14, to = 15 }), "acct", nil, NOW)
    Log.Receive(db4, gs4, live("a:8", 14, 15, NOW - 1000, { guid = "Player-1-00000B0B" }), "acct", nil, NOW)
    eq(#gs4.log, 2, "another member's level-up is another change")
end

do  -- Guildmates' level-ups (#38): one I already know isn't kept; mine are never removed.
    local function bo(e) e.origin = "Bo Kay"; return e end
    local function recv(db, gs, e)
        if e.origin == "Bo Kay" then return Log.Receive(db, gs, e, "guild", "Bo Kay", NOW) end
        return Log.Receive(db, gs, e, "acct", nil, NOW)
    end
    -- Both orders: { uids kept } must agree.
    local function both(list, expect, what)
        local got = {}
        for pass = 1, 2 do
            local db, gs = store()
            for i = (pass == 1 and 1 or #list), (pass == 1 and #list or 1), (pass == 1 and 1 or -1) do
                local c = {}
                for k, v in pairs(list[i]) do c[k] = v end
                recv(db, gs, c)
            end
            got[pass] = uids(gs)
        end
        eq(got[1], expect, what)
        eq(got[2], expect, "...in the other order too")
    end
    both({ obs({ uid = "b:8", from = 14, to = 15 }), bo(live("q:1", 14, 15, NOW - 1620)) }, "b:8",
        "Bo's exact 14 to 15, which my coarse record already shows: mine stays, Bo's isn't kept")
    both({ obs(), bo(live("q:3", 21, 22, NOW - 3600)), bo(live("q:4", 22, 23, NOW - 1320)) }, "b:1",
        "Bo's steps inside my 21 to 23: not kept")
    both({ live("a:1", 21, 22, NOW - 3600), live("a:2", 22, 23, NOW - 1320), bo(obs({ uid = "q:5" })) }, "a:1,a:2",
        "Bo's 21 to 23 when my steps show both levels")
    both({ live("a:1", 21, 22, NOW - 3600), bo(obs({ uid = "q:5" })) }, "a:1,q:5",
        "...one of the two levels only: Bo's is kept")
    both({ live("a:11", 14, 15, NOW - 1620), bo(obs({ uid = "q:2", from = 14, to = 15 })) }, "a:11",
        "my exact record covers Bo's coarse report")
    -- Between guildmates: the same level-up keeps the finest; no chains of reports.
    local function cy(e) e.origin = "Cy Dee"; return e end
    local db, gs = store()
    Log.Receive(db, gs, bo(obs({ uid = "q:6", from = 14, to = 15 })), "guild", "Bo Kay", NOW)
    Log.Receive(db, gs, cy(live("r:6", 14, 15, NOW - 1000)), "guild", "Cy Dee", NOW)
    eq(uids(gs), "r:6", "Bo and Cy report the same level-up: the finer report stays")
    local db2, gs2 = store()
    Log.Receive(db2, gs2, bo(obs({ uid = "q:7" })), "guild", "Bo Kay", NOW)
    Log.Receive(db2, gs2, cy(live("r:7", 21, 22, NOW - 3600)), "guild", "Cy Dee", NOW)
    Log.Receive(db2, gs2, cy(live("r:8", 22, 23, NOW - 1320)), "guild", "Cy Dee", NOW)
    eq(#gs2.log, 3, "Cy's steps don't remove Bo's 21 to 23 (reports never chain)")
    -- And a report never removes mine.
    local db3, gs3 = store()
    Log.Receive(db3, gs3, obs({ uid = "b:9" }), "acct", nil, NOW)
    Log.Receive(db3, gs3, bo(live("q:8", 21, 22, NOW - 3600)), "guild", "Bo Kay", NOW)
    Log.Receive(db3, gs3, bo(live("q:9", 22, 23, NOW - 1320)), "guild", "Bo Kay", NOW)
    check(uids(gs3):find("b:9", 1, true), "Bo's finer steps never remove my 21 to 23")
end

do  -- My own scan: Log.Add of a covered change keeps nothing.
    local db, gs = store()
    Log.Receive(db, gs, live("a:1", 21, 22, NOW - 3600), "acct", nil, NOW)
    Log.Receive(db, gs, live("a:2", 22, 23, NOW - 1320), "acct", nil, NOW)
    local seq = db.nextSeq
    local e = Log.Add(db, gs, { kind = "LEVEL", guid = ALISSA, name = "Alissa White", from = 21, to = 23,
                                lo = NOW - 3 * 3600, hi = NOW }, NOW)
    check(e.covered and e.seq == nil, "my login scan's 21 to 23, already covered: not kept, no seq")
    eq(db.nextSeq, seq, "...nothing allocated")
    eq(#gs.log, 2, "...the log unchanged")
    local f = Log.Add(db, gs, { kind = "LEVEL", guid = ALISSA, name = "Alissa White", from = 23, to = 24,
                                lo = NOW - 60, hi = NOW }, NOW)
    check(not f.covered and #gs.log == 3, "a new level is kept")
end

do  -- At load: what an older version kept goes.
    local db, gs = store()
    gs.log = {}
    for _, e in ipairs({ live("a:1", 21, 22, NOW - 3600), live("a:2", 22, 23, NOW - 1320), obs(),
                         obs({ uid = "b:2", from = 14, to = 15, guid = "Player-1-0000C0C0" }),
                         live("a:3", 14, 15, NOW - 1620, { guid = "Player-1-0000C0C0" }) }) do
        e.trust = "self"
        gs.log[#gs.log + 1] = e
    end
    eq(Log.Dedupe(gs), 2, "two duplicates in a stored log")
    eq(uids(gs), "a:1,a:2,a:3", "...the precise records stay")
    eq(Log.Dedupe(gs), 0, "...a second pass finds nothing")
end

-- Every order of a list (small lists).
local function orders(list)
    local out = {}
    local function go(rest, acc)
        if #rest == 0 then out[#out + 1] = acc; return end
        for i = 1, #rest do
            local r2, a2 = {}, {}
            for j, v in ipairs(rest) do if j ~= i then r2[#r2 + 1] = v end end
            for _, v in ipairs(acc) do a2[#a2 + 1] = v end
            a2[#a2 + 1] = rest[i]
            go(r2, a2)
        end
    end
    go(list, {})
    return out
end
-- The uids kept after receiving `list` in every order, and after a load-time
-- pass over all of them: one answer if they all agree, else "differs".
local function outcome(list)
    local seen
    local function note(r) if seen == nil then seen = r elseif seen ~= r then seen = "differs" end end
    for _, o in ipairs(orders(list)) do
        local db, gs = store()
        for _, e in ipairs(o) do Log.Receive(db, gs, obs(e), "acct", nil, NOW) end
        note(uids(gs))
    end
    local _, gs = store()
    for _, e in ipairs(list) do local c = obs(e); c.trust = "self"; gs.log[#gs.log + 1] = c end
    Log.Dedupe(gs)
    note(uids(gs))
    return seen
end
local T0 = NOW - 7200
local function at(min) return T0 + min * 60 end
-- A level-up observed over minutes lo..hi (exact when lo == hi).
local function lvl(uid, from, to, lo, hi)
    local e = { uid = uid, from = from, to = to, lo = at(lo), hi = at(hi), at = at(hi), obs = at(hi) }
    if lo == hi then e.approx = false end
    return e
end

do  -- The outcome doesn't depend on arrival order (#42 review): a level is reached once.
    -- Spans that overlap in a chain (A and C can't overlap): still one level-up, the finest kept.
    eq(outcome({ lvl("l:1", 14, 15, 0, 8), lvl("l:2", 14, 15, 7, 17), lvl("l:3", 14, 15, 16, 28) }), "l:1",
        "the same level-up seen three times: the finest, in every order and at load")
    eq(outcome({ lvl("l:4", 14, 15, 0, 60), lvl("l:5", 14, 15, 100, 101) }), "l:5",
        "...even when the spans don't touch")
    eq(outcome({ lvl("c:1", 21, 23, 0, 60), lvl("s:1", 21, 22, 10, 10), lvl("s:2", 22, 23, 20, 20) }), "s:1,s:2",
        "21 to 23 with both steps: the steps, in every order")
    eq(outcome({ lvl("c:1", 21, 23, 5, 60), lvl("s:1", 21, 22, 0, 6), lvl("s:2", 22, 23, 30, 31) }), "s:1,s:2",
        "...a step seen just before the coarse span still covers it")
    eq(outcome({ lvl("c:1", 21, 24, 0, 60), lvl("s:1", 21, 22, 10, 10), lvl("s:2", 23, 24, 20, 20) }), "c:1,s:1,s:2",
        "a missing step: the coarse record stays, in every order")
    eq(outcome({ lvl("c:1", 21, 23, 0, 60), lvl("s:1", 21, 22, 10, 10), lvl("s:2", 22, 23, 20, 20),
                 lvl("c:2", 21, 23, 30, 90) }), "s:1,s:2",
        "two coarse records and the steps: only the steps")
    eq(outcome({ lvl("c:1", 21, 23, 0, 10), lvl("s:1", 21, 22, 0, 30), lvl("s:2", 22, 23, 0, 40) }), "c:1,s:1,s:2",
        "steps vaguer than the coarse record don't cover it")
    eq(outcome({ lvl("c:1", 21, 23, 0, 60), lvl("s:1", 21, 22, 10, 10), lvl("s:2", 22, 24, 20, 20) }), "c:1,s:1,s:2",
        "steps that pass over the coarse record's level don't cover it")
end

do  -- Only level-ups are ever compared, whoever asks.
    local n1 = obs({ uid = "z:1", kind = "NOTE", from = "a", to = "b", trust = "self" })
    local n2 = live("z:2", "a", "b", NOW - 1000, { kind = "NOTE", trust = "self" })
    check(not Log.Covered(n1, { n1, n2 }), "Log.Covered: a note is never covered, even by a finer same change")
    check(Log.DupKey(n1) ~= Log.DupKey(n2), "Log.DupKey: notes of one member aren't grouped")
    local l1, l2 = obs({ uid = "z:3", trust = "self" }), live("z:4", 21, 23, NOW - 1000, { trust = "self" })
    eq(Log.DupKey(l1), Log.DupKey(l2), "...a member's level-ups are")
    check(Log.DupKey(live("z:5", 21, 23, NOW - 1000, { guid = "Player-1-00000B0B" })) ~= Log.DupKey(l1), "...per member")
end

do  -- The scanner: a change a poll finds, already covered by my other account's steps, prints nothing.
    local G = { name = "Parse Partout", realm = "Forever", myRank = 1, ranks = { "GM", "Member" },
                members = { { name = "Fizzle Sprocketwhistle", rank = 1, level = 30, class = "MAGE", online = true,
                              guid = "Player-1-00000001", note = "" },
                            { name = "Alissa White", rank = 1, level = 21, class = "ROGUE", online = true,
                              guid = ALISSA, note = "" } },
                events = {}, eventNames = true, motd = "", canViewOfficerNote = false }
    loadAddon({ setup = function() WoW.guild = G end })
    WoW.fire("PLAYER_LOGIN")
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    WoW.advance(100)
    local gs = GuildSpyDB.guilds["Parse Partout-Forever"]
    local t = time()
    for i, step in ipairs({ { 21, 22, t - 5 }, { 22, 23, t - 3 } }) do
        local e = live("x:" .. i, step[1], step[2], step[3])
        check(Log.Receive(GuildSpyDB, gs, e, "acct", nil, t), "(my other account's step " .. i .. " arrives)")
    end
    local seq, shown = GuildSpyDB.nextSeq, gs.shownSeq
    WoW.chat = {}
    G.members[2].level = 23
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    WoW.advance(3)
    local printed = false
    for _, l in ipairs(WoW.chat) do if l:find("Alissa White", 1, true) then printed = true end end
    check(not printed, "the poll's 21 to 23 is covered: no chat line")
    eq(#gs.log, 2, "...not kept")
    eq(GuildSpyDB.nextSeq, seq, "...no seq taken")
    eq(gs.shownSeq, shown, "...and the digest boundary doesn't move to a seq nobody has")
    G.members[2].level = 24
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    WoW.advance(3)
    printed = false
    for _, l in ipairs(WoW.chat) do if l:find("Alissa White reached level 24", 1, true) then printed = true end end
    check(printed and #gs.log == 3, "a new level is logged and printed")

    -- At load: a duplicate an older version kept goes.
    local dup = {}
    for k, v in pairs(gs.log[1]) do dup[k] = v end
    dup.uid, dup.from, dup.to, dup.lo, dup.hi, dup.at, dup.obs, dup.approx = "old:1", 21, 23, t - 600, t, t, t, nil
    dup.seq, dup.chg = 999, Log.NextChg(gs)
    table.insert(gs.log, 1, dup)
    loadAddon({ db = GuildSpyDB, setup = function() WoW.guild = G end })
    WoW.fire("PLAYER_LOGIN")
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    WoW.advance(10)
    local gs2 = GuildSpyDB.guilds["Parse Partout-Forever"]
    local left = false
    for _, e in ipairs(gs2.log) do if e.uid == "old:1" then left = true end end
    check(not left and #gs2.log == 3, "a stored 21 to 23 that the steps cover is gone after loading")
end

done("test_dedupe")
