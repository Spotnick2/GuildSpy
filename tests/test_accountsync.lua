-- AccountSync.lua (#37): sync between my own accounts. Two protocol cores (two
-- accounts) on one test network that can drop or hold messages, then the shell
-- on a scripted LibAccountSync (wow_stubs), as AltStable's tests do.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

loadAddon()
local AS, Log, Wire = GuildSpy.AccountSync, GuildSpy.Log, GuildSpy.Wire
local KEY = "Parse Partout-Forever"
local clock = 1790000000
local net = {}
local clients = {}

local function client(name, guid, key)
    local c = { name = name, guid = guid, key = key, db = { nextSeq = 1 }, gs = { log = {} }, added = {} }
    c.core = AS.NewCore({
        db = c.db,
        gs = function(k) if k == c.key then return c.gs end end,
        key = function() return c.key end,
        now = function() return clock end,
        send = function(to, text)
            if c.notReady and c.notReady[to] then return false end   -- the library's "not ready" (0)
            net[#net + 1] = { to = to, from = c, text = text }
            return true
        end,
        onReceived = function(added) for _, e in ipairs(added) do c.added[#c.added + 1] = e end end,
        onChanged = function() c.changed = (c.changed or 0) + 1 end,
    })
    clients[guid] = c
    return c
end
-- Deliver what's queued (and what that triggers); `drop(m)` true loses a message.
local function pump(drop)
    local n = 0
    while #net > 0 do
        local m = table.remove(net, 1)
        n = n + 1
        assert(n < 1000, "the network never went quiet")
        if not (drop and drop(m)) then
            clients[m.to].core:OnMessage(m.text, { guid = m.from.guid, name = m.from.name })
        end
    end
end
local function kindOf(m) return (Wire.Read(m.text)) end
-- Each sees the other as a proven peer.
local function meet(a, b)
    a.core:Discover({ { guid = b.guid, name = b.name } })
    b.core:Discover({ { guid = a.guid, name = a.name } })
end
local function observe(c, ev)
    c.gs.log = c.gs.log or {}
    local e = Log.Add(c.db, c.gs, ev, clock)
    e.origin = c.name
    return e
end
local function find(c, name)
    for _, e in ipairs(c.gs.log) do if e.name == name then return e end end
end
local function join(name, n, extra)
    local ev = { kind = "JOIN", guid = string.format("Player-1-%08X", n), name = name, lo = clock - 60, hi = clock }
    for k, v in pairs(extra or {}) do ev[k] = v end
    return ev
end

-- Two accounts in the same guild: each gets the other's observations.
do
    net, clients = {}, {}
    local A = client("Alt One", "Player-1-0000000A", KEY)
    local B = client("Alt Two", "Player-1-0000000B", KEY)
    observe(A, join("Seen By A", 1))
    observe(B, join("Seen By B", 2))
    meet(A, B)
    pump()
    local got = find(A, "Seen By B")
    check(got, "A gets B's observation")
    check(got and got.trust == "self" and got.here == false and got.origin == "Alt Two",
        "...as one of my accounts', not this one's")
    check(find(B, "Seen By A"), "and B gets A's")
    eq(#A.added, 1, "A is told one arrived")
    check(A.gs.peerMark[B.guid] >= find(B, "Seen By B").chg, "A's cursor for B is past B's observation")
    eq(A.core.peers[B.guid].syncedAt, clock, "...and B is marked synced")

    -- An idle poll: nothing new, nothing re-sent.
    clock = clock + AS.POLL
    A.core:Tick(); B.core:Tick()
    pump()
    eq(#A.added, 1, "an idle poll brings nothing again")

    -- Enrichment on B is a new revision: the next poll carries it.
    local mine = find(B, "Seen By B")
    Log.Enrich(mine, { actor = "Enzo Matrix" }, B.gs)
    clock = clock + AS.POLL
    A.core:Tick()
    pump()
    eq(find(A, "Seen By B").actor, "Enzo Matrix", "B's later enrichment reaches A")
    eq(#A.added, 1, "...as an update, not a new entry")
    local changes = A.changed
    Log.Enrich(mine, { how = "quit" }, B.gs)
    clock = clock + AS.POLL
    A.core:Tick()
    pump()
    eq(A.changed, changes + 1, "an update-only page still tells the window to redraw (#40 review)")

    -- B's saved file went back (a crash before it was written): its counter
    -- restarts low, but new changes still number above A's cursor (#40 review).
    B.gs.nextChg = 1
    WoW.advance(2)
    observe(B, join("After A Rewind", 16))
    clock = clock + AS.POLL
    A.core:Tick()
    pump()
    check(find(A, "After A Rewind"), "after B's counter went back, B's new observation still reaches A")
end

-- Officer notes go between my accounts; guildmates' reports stay theirs.
do
    net, clients = {}, {}
    local A = client("Alt One", "Player-1-0000000A", KEY)
    local B = client("Alt Two", "Player-1-0000000B", KEY)
    observe(B, { kind = "ONOTE", guid = "Player-1-00000003", name = "Officer Noted", from = "", to = "raid lead",
                 lo = clock - 60, hi = clock })
    local rep = Log.Receive(B.db, B.gs, { uid = "zz:1", rev = 1, kind = "LEVEL", guid = "Player-1-00000004",
        name = "Reported", from = 29, to = 30, at = clock - 30, obs = clock - 30, lo = clock - 90, hi = clock - 30,
        origin = "Bo Kay" }, "guild", "Bo Kay", clock)
    check(rep, "(B holds Bo Kay's report)")
    meet(A, B)
    pump()
    local on = find(A, "Officer Noted")
    check(on and on.kind == "ONOTE" and on.to == "raid lead", "an officer note reaches my other account")
    local r = find(A, "Reported")
    check(r and r.trust == "guild" and r.reporter == "Bo Kay" and r.ns == "g:Bo Kay",
        "a guildmate's report forwarded by my account is still that guildmate's")
end

-- Paging: many entries, small pages, all of them, cursor at the end.
do
    net, clients = {}, {}
    local saved = AS.PAGE_BYTES
    AS.PAGE_BYTES = 600
    local A = client("Alt One", "Player-1-0000000A", KEY)
    local B = client("Alt Two", "Player-1-0000000B", KEY)
    for i = 1, 30 do observe(B, join("Paged " .. i, 100 + i)) end
    meet(A, B)
    local pages = 0
    pump(function(m) if kindOf(m) == "PAGE" and m.to == A.guid then pages = pages + 1 end return false end)
    check(pages > 2, "(several pages: " .. pages .. ")")
    local n = 0
    for _, e in ipairs(A.gs.log) do if e.name:find("^Paged ") then n = n + 1 end end
    eq(n, 30, "every entry arrives, over several pages")
    eq(A.gs.peerMark[B.guid], B.gs.nextChg, "...cursor at the end")
    AS.PAGE_BYTES = saved
end

-- A lost page: the cursor waits; the timeout asks the same again.
do
    net, clients = {}, {}
    local A = client("Alt One", "Player-1-0000000A", KEY)
    local B = client("Alt Two", "Player-1-0000000B", KEY)
    observe(B, join("Lost Once", 7))
    meet(A, B)
    local dropped = false
    pump(function(m)
        if not dropped and kindOf(m) == "PAGE" and m.to == A.guid then dropped = true; return true end
    end)
    check(dropped and not find(A, "Lost Once"), "(the page to A was lost)")
    eq(A.gs.peerMark[B.guid], nil, "the cursor didn't move")
    A.core:Tick()
    pump()
    check(not find(A, "Lost Once"), "before the timeout, nothing is asked again")
    clock = clock + AS.TIMEOUT
    A.core:Tick()
    pump()
    check(find(A, "Lost Once"), "after the timeout, the same request brings it")
end

-- Only the answer to the request in flight counts.
do
    net, clients = {}, {}
    local A = client("Alt One", "Player-1-0000000A", KEY)
    local B = client("Alt Two", "Player-1-0000000B", KEY)
    observe(B, join("First", 8))
    meet(A, B)
    local held
    pump(function(m)
        if not held and kindOf(m) == "PAGE" and m.to == A.guid then held = m; return true end
    end)
    clock = clock + AS.TIMEOUT
    A.core:Tick()
    pump()
    check(find(A, "First"), "(the retry's page arrived)")
    observe(B, join("Second", 9))
    local markBefore = A.gs.peerMark[B.guid]
    -- The old, held page arrives late: another rid.
    A.core:OnMessage(held.text, { guid = B.guid, name = B.name })
    eq(A.gs.peerMark[B.guid], markBefore, "a late page for an old request is ignored")
    -- A stale page while a newer request is in flight is ignored too.
    observe(B, join("Third", 12))
    clock = clock + AS.POLL
    local stale
    A.core:Tick()
    pump(function(m)
        if not stale and kindOf(m) == "PAGE" and m.to == A.guid then stale = m; return true end
    end)
    clock = clock + AS.TIMEOUT
    A.core:Tick()                                   -- a new request (new rid) goes out
    local inFlight = net
    net = {}
    -- A page can outlast the timeout (#40 review): the late one still continues
    -- from A's cursor, so it counts; the retry's page, now behind, doesn't.
    A.core:OnMessage(stale.text, { guid = B.guid, name = B.name })
    check(find(A, "Third"), "a late page that continues from the cursor is taken")
    local mark = A.gs.peerMark[B.guid]
    net = inFlight
    pump()
    local thirds = 0
    for _, e in ipairs(A.gs.log) do if e.name == "Third" then thirds = thirds + 1 end end
    eq(thirds, 1, "...and the retry's page, now behind the cursor, adds nothing")
    eq(A.gs.peerMark[B.guid], mark, "...nor moves the cursor back")
    -- A page for an older cursor never moves the cursor back.
    A.core:OnMessage(Wire.Message("PAGE", { "99", KEY, 0, 5, 0 }, {}), { guid = B.guid, name = B.name })
    eq(A.gs.peerMark[B.guid], mark, "a page for an older cursor is ignored")
    -- One request in flight: a CAP meanwhile doesn't start another.
    observe(B, join("Fourth", 13))
    clock = clock + AS.POLL
    A.core:Tick()
    local reqs = 0
    for _, m in ipairs(net) do if kindOf(m) == "REQ" then reqs = reqs + 1 end end
    A.core:OnMessage(Wire.Message("CAP", { KEY }), { guid = B.guid, name = B.name })
    local after = 0
    for _, m in ipairs(net) do if kindOf(m) == "REQ" then after = after + 1 end end
    eq(after, reqs, "a CAP while a request is in flight asks nothing more")
    pump()
    -- A peer A heard but couldn't ask yet (the library not ready): its page is ignored.
    local D = client("Alt Four", "Player-1-0000000D", KEY)
    A.notReady = { [D.guid] = true }
    A.core:OnMessage(Wire.Message("CAP", { KEY, "1" }), { guid = D.guid, name = D.name })
    A.notReady = nil
    net = {}
    A.core:OnMessage(Wire.Message("PAGE", { "1", KEY, 0, 99, 0 }, {}), { guid = D.guid, name = D.name })
    eq(A.gs.peerMark[D.guid], nil, "a page from a peer A never asked is ignored")
    -- A page from someone A never asked.
    local C = client("Alt Three", "Player-1-0000000C", KEY)
    A.core:OnMessage(Wire.Message("PAGE", { "1", KEY, 0, 99, 0 }, {}), { guid = C.guid, name = C.name })
    eq(A.gs.peerMark[C.guid], nil, "a page nobody asked for is ignored")
end

-- The library says "not ready" at first (#40 review): the CAP isn't counted as
-- sent, and goes again on the next pass; CAPs repeat until each has heard the other.
do
    net, clients = {}, {}
    local A = client("Alt One", "Player-1-0000000A", KEY)
    local B = client("Alt Two", "Player-1-0000000B", KEY)
    observe(B, join("After Handshake", 14))
    A.notReady = { [B.guid] = true }
    A.core:Discover({ { guid = B.guid, name = B.name } })
    eq(#net, 0, "A's first CAP isn't taken by the library")
    eq(A.core.peers[B.guid].capSentAt, nil, "...and isn't counted as sent")
    A.notReady = nil
    clock = clock + 10
    A.core:Discover({ { guid = B.guid, name = B.name } })
    B.core:Discover({ { guid = A.guid, name = A.name } })
    pump()
    check(find(A, "After Handshake"), "once ready, the CAP goes and the sync happens")
    check(A.core.peers[B.guid].heardUs and B.core.peers[A.guid].heardUs, "each has heard the other's CAP")
    -- B's CAP to A is lost: B says it hasn't heard A, so A tells it again.
    net, clients = {}, {}
    local C = client("Alt One", "Player-1-0000000A", KEY)
    local D = client("Alt Two", "Player-1-0000000B", KEY)
    observe(C, join("Seen By C", 15))
    C.core:Discover({ { guid = D.guid, name = D.name } })
    D.core:Discover({ { guid = C.guid, name = C.name } })
    pump(function(m) return m.from == C and kindOf(m) == "CAP" and not m.seenOnce and true end)  -- C's first CAP lost
    clock = clock + 10
    C.core:Discover({ { guid = D.guid, name = D.name } })
    pump()
    check(find(D, "Seen By C"), "a lost CAP is sent again until heard, and the sync follows")
end

-- Same guild only.
do
    net, clients = {}, {}
    local A = client("Alt One", "Player-1-0000000A", KEY)
    local B = client("Alt Two", "Player-1-0000000B", "Another Guild-Forever")
    observe(B, join("Other Guild", 10))
    meet(A, B)
    local asked = 0
    pump(function(m) if kindOf(m) == "REQ" and m.from == A then asked = asked + 1 end return false end)
    eq(asked, 0, "A doesn't even ask an account in another guild")
    local reqs = 0
    for _, m in ipairs(net) do if kindOf(m) == "REQ" then reqs = reqs + 1 end end
    check(not find(A, "Other Guild"), "in different guilds, nothing syncs")
    -- A request for another guild is ignored.
    B.core:OnMessage(Wire.Message("REQ", { "5", KEY, 0 }), { guid = A.guid, name = A.name })
    eq(#net, 0, "B ignores a request for a guild it isn't in")
    -- No guild: nothing either.
    B.key = nil
    B.core:OnMessage(Wire.Message("REQ", { "6", KEY, 0 }), { guid = A.guid, name = A.name })
    eq(#net, 0, "...nor when it is in none")
end

-- A guild change drops what's in flight.
do
    net, clients = {}, {}
    local A = client("Alt One", "Player-1-0000000A", KEY)
    local B = client("Alt Two", "Player-1-0000000B", KEY)
    observe(B, join("Before Change", 11))
    meet(A, B)
    local held
    pump(function(m)
        if not held and kindOf(m) == "PAGE" and m.to == A.guid then held = m; return true end
    end)
    A.key = "New Guild-Forever"
    A.core:GuildChanged()
    A.core:OnMessage(held.text, { guid = B.guid, name = B.name })
    check(not find(A, "Before Change"), "a page for the old guild arriving after a change is ignored")
    -- Both now in the new guild: a pull starts at once, not after the old request's timeout.
    B.key = "New Guild-Forever"
    B.gs = { log = {} }
    A.gs = { log = {} }
    A.core:OnMessage(Wire.Message("CAP", { "New Guild-Forever" }), { guid = B.guid, name = B.name })
    local asked = false
    for _, m in ipairs(net) do if kindOf(m) == "REQ" and m.to == B.guid then asked = true end end
    check(asked, "after a guild change, the new guild is asked at once")
    net = {}
end

-- The shell: the library, the catch-up line, the setting, the Sharing page.
do
    loadAddon()
    WoW.fire("PLAYER_LOGIN")
    local inst = WoW.las and WoW.las.instances[1]
    check(inst and inst.opts.addon == "GuildSpy" and inst.opts.messages == true, "the library instance: tag GuildSpy, messages mode")
    check(inst.opts.store() == GuildSpyDB.accountSync and type(GuildSpyDB.accountSync) == "table",
        "...its store in GuildSpyDB.accountSync")
    check(GuildSpy.AccountSync._test.core(), "...and the protocol runs")

    -- The library's own stored switch says off, ours on: ours wins at start (#40 review).
    loadAddon({ setup = function() WoW.lasStoredOff = true end })
    WoW.fire("PLAYER_LOGIN")
    eq(WoW.las.instances[1].enabled, true, "our setting (on) is passed to the library at start")

    -- A library copy without messages mode: no sync at all.
    loadAddon({ setup = function() WoW.lasSnapshots = true end })
    WoW.fire("PLAYER_LOGIN")
    eq(GuildSpy.AccountSync._test.core(), nil, "an older library (snapshots only): sync stays off")

    -- No library: nothing else breaks.
    loadAddon({ setup = function() WoW.noAccountSync = true end })
    WoW.fire("PLAYER_LOGIN")
    eq(GuildSpy.AccountSync._test.core(), nil, "no library: no sync, no error")
end

do  -- A real exchange through the shell: the catch-up line, once, batched.
    local G = { name = "Parse Partout", realm = "Forever", myRank = 1, ranks = { "GM", "Member" },
                members = { { name = "Fizzle Sprocketwhistle", rank = 1, level = 30, class = "MAGE", online = true,
                              guid = "Player-1-00000001", note = "" } },
                events = {}, eventNames = true, motd = "", canViewOfficerNote = false }
    loadAddon({ setup = function() WoW.guild = G end })
    WoW.fire("PLAYER_LOGIN")
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    WoW.advance(25)
    local A = GuildSpy.AccountSync
    local core = A._test.core()
    local gs = GuildSpyDB.guilds[KEY]
    -- The other account, as a second core on a private store, answering through the fake library.
    local bdb, bgs = { nextSeq = 1 }, { log = {} }
    local now = function() return time() end
    local B
    B = AS.NewCore({ db = bdb, gs = function(k) if k == KEY then return bgs end end, key = function() return KEY end,
        now = now, send = function(_, text) WoW.lasDeliver(text, { guid = "Player-1-0000000B", name = "Alt Two" }); return true end })
    local t0 = time()
    for i = 1, 3 do Log.Add(bdb, bgs, join("From Alt " .. i, 200 + i, { lo = t0 - 60, hi = t0 }), t0) end
    Log.Add(bdb, bgs, { kind = "ONOTE", guid = "Player-1-00000300", name = "Hidden Note", from = "", to = "x",
                        lo = time() - 60, hi = time() }, time())
    -- Our sends go to B.
    WoW.lasPeers = { { guid = "Player-1-0000000B", name = "Alt Two", proven = "bnet" } }
    local delivered = 0
    local function route()
        while #WoW.lasSent > delivered do
            delivered = delivered + 1
            local m = WoW.lasSent[delivered]
            B:OnMessage(m.payload, { guid = "Player-1-00000001", name = "Fizzle Sprocketwhistle" })
        end
    end
    WoW.chat = {}
    A._test.tick()
    route(); route()
    local n = 0
    for _, e in ipairs(gs.log) do if e.name and e.name:find("^From Alt") then n = n + 1 end end
    eq(n, 3, "the other account's entries arrive through the library")
    local line
    for _, l in ipairs(WoW.chat) do if l:find("from your other account", 1, true) then line = l end end
    check(not line, "no line yet: it waits for a quiet spell")
    WoW.advance(AS.QUIET + 1)
    for _, l in ipairs(WoW.chat) do if l:find("from your other account", 1, true) then line = l end end
    check(line and Log.Plain(line):find("3 changes from your other account", 1, true),
        "one catch-up line, counting what this character can see (the officer note isn't counted)")
    local lines = 0
    for _, l in ipairs(WoW.chat) do if l:find("from your other account", 1, true) then lines = lines + 1 end end
    eq(lines, 1, "...only one")

    -- The Sharing page: the status of the other account, and the switch.
    local O = GuildSpy.Options
    local status = table.concat(O.SharingLines(), "\n")
    check(status:find("Alt Two: synced", 1, true), "the Sharing page shows the other account, synced")
    local sharing = O._test.sharing
    sharing:Show()
    check(sharing.controls.syncAccounts.check:GetChecked(), "the switch is on by default")
    O.Set("syncAccounts", false)
    eq(GuildSpyDB.settings.syncAccounts, false, "off: saved")
    eq(WoW.las.instances[#WoW.las.instances].enabled, false, "...and the library told")
    eq(O.SharingLines()[1], "Off.", "...the status says so")
    local before, sent = #gs.log, #WoW.lasSent
    Log.Add(bdb, bgs, join("While Off", 299, { lo = time() - 60, hi = time() }), time())
    WoW.lasDeliver(Wire.Message("REQ", { "9", KEY, 0 }), { guid = "Player-1-0000000B", name = "Alt Two" })
    WoW.lasDeliver(Wire.Message("CAP", { KEY }), { guid = "Player-1-0000000B", name = "Alt Two" })
    A._test.tick()
    eq(#WoW.lasSent, sent, "off: a request goes unanswered, and nothing is asked")
    eq(#gs.log, before, "...nothing taken")
    O.Set("syncAccounts", true)
end

done("test_accountsync")
