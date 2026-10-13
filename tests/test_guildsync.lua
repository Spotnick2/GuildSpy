-- GuildSync.lua (#38): sync with guildmates over GUILD addon messages. Several
-- protocol cores (guildmates) on one simulated GUILD channel that delivers
-- their queued messages in turns, then the shell on the stubs' scripted
-- ChatThrottleLib.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

loadAddon()
local GSync, Log, Wire = GuildSpy.GuildSync, GuildSpy.Log, GuildSpy.Wire
local KEY = "Parse Partout-Forever"
local clock = time()
local timers = {}
local clients, order = {}, {}
local RANKS = { ["Ann Lee"] = 1, ["Bo Kay"] = 3, ["Cy Dee"] = 4, ["Di Fox"] = 4 }

local function after(s, fn) timers[#timers + 1] = { at = clock + s, fn = fn } end
-- Moves the clock, running timers in order; deliver() between them.
local deliver
local function advance(s)
    deliver()
    local target = clock + s
    while true do
        local best, bi
        for i, t in ipairs(timers) do if t.at <= target and (not best or t.at < best.at) then best, bi = t, i end end
        if not best then break end
        -- Everything due at that moment runs before anything is heard: simultaneous.
        clock = math.max(clock, best.at)
        local due = {}
        for i = #timers, 1, -1 do
            if timers[i].at == best.at then table.insert(due, 1, table.remove(timers, i)) end
        end
        for _, t in ipairs(due) do t.fn() end
        deliver()
    end
    clock = target
    deliver()
end

local function client(name, opts)
    opts = opts or {}
    local c = { name = name, key = KEY, db = { nextSeq = 1 }, gs = { log = {}, members = {} }, out = {}, added = {},
                accept = opts.accept or "chat", minRank = opts.minRank, jitter = opts.jitter or 2, heardFrom = {} }
    c.core = GSync.NewCore({
        db = c.db,
        gs = function(k) if k == c.key then return c.gs end end,
        key = function() return c.key end,
        me = function() return name end,
        now = function() return clock end,
        send = function(text, ok) c.out[#c.out + 1] = { text = text, ok = ok } end,
        after = after,
        random = function() return c.jitter end,
        rankOf = function(n) return RANKS[n] end,
        minRank = function() return c.minRank end,
        accept = function() return c.accept end,
        onReceived = function(added) for _, e in ipairs(added) do c.added[#c.added + 1] = e end end,
    })
    clients[name] = c
    order[#order + 1] = c
    return c
end
-- In turns: each round, every guildmate's next queued message leaves (checked
-- just before, as the shell's queue does), then all of them are heard by
-- everyone in the same guild, the sender too (the server echoes it). Messages
-- of one round crossed on the channel.
local log = {}
function deliver()
    while true do
        local round = {}
        for _, c in ipairs(order) do
            local m = table.remove(c.out, 1)
            while m and not m.ok() do m = table.remove(c.out, 1) end
            if m then round[#round + 1] = { c = c, m = m } end
        end
        if #round == 0 then return end
        for _, r in ipairs(round) do
            log[#log + 1] = { from = r.c.name, kind = (Wire.Read(r.m.text)), text = r.m.text }
            assert(#r.m.text <= 255, "a message over 255 bytes")
        end
        for _, r in ipairs(round) do
            for _, d in ipairs(order) do
                if d.key == r.c.key then d.core:OnMessage(r.m.text, r.c.name) end
            end
        end
    end
end
local function sent(from, kind)
    local n = 0
    for _, m in ipairs(log) do if (not from or m.from == from) and (not kind or m.kind == kind) then n = n + 1 end end
    return n
end
-- An observation of this character's own.
local seen = 0
local function observe(c, extra)
    seen = seen + 1
    local ev = { kind = "LEVEL", guid = string.format("Player-1-%08X", 100 + seen), name = "Member " .. seen,
                 from = 10, to = 11, lo = clock - 3600 + seen, hi = clock - 60 + seen, origin = c.name }
    for k, v in pairs(extra or {}) do ev[k] = v end
    local e = Log.Add(c.db, c.gs, ev, clock)
    e.origin = c.name
    return e
end
local function reports(c, from)
    local n = 0
    for _, e in ipairs(c.gs.log) do if e.trust == "guild" and (not from or e.reporter == from) then n = n + 1 end end
    return n
end
local function reset()
    timers, clients, order, log = {}, {}, {}, {}
    clock = clock + 10000
end

do  -- An ask, an answer: Bo's own observations reach Ann as Bo's reports.
    reset()
    local ann, bo = client("Ann Lee"), client("Bo Kay")
    for _ = 1, 3 do observe(bo) end
    observe(bo, { kind = "ONOTE", from = "a", to = "b", guid = "Player-1-00000F01", name = "Hidden" })
    local imported = observe(bo); imported.here = false                         -- from my other account
    local other = observe(bo); other.origin = "Bo Alt"                          -- my alt's, on this account
    local legacy = observe(bo); legacy.origin = nil
    ann.core:Hello()
    deliver()
    eq(sent("Ann Lee", "H"), 1, "after the first scan: hello")
    eq(sent("Ann Lee", "Q"), 1, "...and one ask")
    eq(sent("Bo Kay", "A"), 0, "the answer waits its jitter")
    advance(3)
    eq(sent("Bo Kay", "A"), 1, "then Bo answers")
    eq(sent("Bo Kay", "E"), 3, "...only what this character saw itself, in public kinds")
    eq(sent("Bo Kay", "D"), 1, "...then done")
    eq(reports(ann, "Bo Kay"), 3, "Ann keeps them as Bo's reports")
    eq(#ann.added, 3, "...each announced once")
    local e = ann.added[1]
    check(e.trust == "guild" and e.origin == "Bo Kay" and e.here == false, "...guild trust, Bo's, not seen here")
    check(type(e.obs) == "number" and e.obs == e.hi, "...its observed time from its times")
    eq(reports(bo), 0, "Ann has nothing of her own: Bo gets nothing")
    -- Ann's own echo is ignored.
    ann.core:OnMessage(Wire.Message("H"), "Ann Lee")
    eq(#ann.core.ask, 0, "her own hello, echoed back, asks nobody")
    ann.core:OnMessage(Wire.Message("H"), "Ann Lee-Forever")
    eq(#ann.core.ask, 0, "...nor with a realm added, should the live client add one")
    local before = sent("Bo Kay", "A")
    bo.core:OnMessage(Wire.Message("Q", { "r:1", clock - 86400, "Bo Kay-Forever", "" }), "Ann Lee")
    advance(5)
    eq(sent("Bo Kay", "A"), before + 1, "an ask to Bo with a realm is Bo's to answer")
end

do  -- Everyone hears an answer: a second ask in the minute is answered by it.
    reset()
    local ann, bo, cy = client("Ann Lee"), client("Bo Kay"), client("Cy Dee")
    for _ = 1, 2 do observe(bo) end
    ann.core:Hello()
    advance(3)
    eq(reports(cy, "Bo Kay"), 2, "Cy, listening, keeps Bo's answer to Ann too")
    cy.core:Hello()
    advance(10)
    eq(sent("Bo Kay", "A"), 1, "Cy's ask within the minute: no second answer")
    advance(GSync.ANSWER_GAP)
    clock = clock + 1
    cy.core.lastQ = nil
    cy.core:Ask()
    advance(10)
    eq(sent("Bo Kay", "A"), 2, "after the minute, Bo answers again")
    eq(reports(cy, "Bo Kay"), 2, "...nothing new: repeats are absorbed")
end

do  -- Two who could answer: the later one stops; at the same moment, the first name carries on.
    reset()
    local ann = client("Ann Lee")
    local bo, cy = client("Bo Kay", { jitter = 2 }), client("Cy Dee", { jitter = 5 })
    observe(bo); observe(cy)
    ann.core:Hello()
    advance(10)
    eq(sent("Bo Kay", "A"), 1, "Bo, first, answers")
    eq(sent("Cy Dee", "A"), 0, "Cy heard Bo's answer before its own: no answer")
    reset()
    ann = client("Ann Lee")
    bo, cy = client("Bo Kay", { jitter = 3 }), client("Cy Dee", { jitter = 3 })
    for _ = 1, 4 do observe(bo); observe(cy) end
    ann.core:Hello()
    advance(10)
    eq(sent("Bo Kay", "A") + sent("Cy Dee", "A"), 2, "both answer at the same moment")
    eq(sent("Cy Dee", "E"), 0, "Cy hears Bo (first alphabetically) and stops before any entry")
    eq(sent("Bo Kay", "E"), 4, "Bo carries on")
    eq(reports(ann, "Cy Dee"), 0, "...Ann has only Bo's")
end

do  -- A long answer: 40, then the rest when Ann asks Bo for it.
    reset()
    local ann, bo = client("Ann Lee"), client("Bo Kay")
    for _ = 1, 50 do observe(bo) end
    ann.core:Hello()
    advance(10)
    eq(sent("Bo Kay", "E"), GSync.PER_ANSWER, "an answer holds at most 40")
    eq(#ann.core.ask, 1, "Bo's done says more: Ann will ask Bo")
    advance(30)
    eq(sent("Ann Lee", "Q"), 1, "...not before the gap between asks")
    advance(GSync.Q_GAP)
    for _ = 1, 3 do ann.core:Tick(); advance(5) end
    eq(sent("Ann Lee", "Q"), 2, "then one ask, to Bo, from where he stopped")
    local qs = {}
    for _, m in ipairs(log) do if m.kind == "Q" then qs[#qs + 1] = select(2, Wire.Read(m.text)) end end
    check(qs[2][3] == "Bo Kay" and qs[2][4] ~= "" and qs[2][2] == qs[1][2], "...with the first ask's start, minutes later")
    eq(reports(ann, "Bo Kay"), 50, "...and Ann has all 50")
    eq(#ann.core.ask, 0, "...nothing left to ask")
end

do  -- A guildmate who logs in later says hello: those who haven't heard from them ask them.
    reset()
    local ann, di = client("Ann Lee"), client("Di Fox")
    ann.core:Hello()
    advance(10)
    observe(di)
    di.core:Hello()
    advance(10)
    eq(#ann.core.ask, 1, "Ann heard Di's hello: Di is to be asked")
    advance(GSync.Q_GAP)
    ann.core:Tick()
    advance(10)
    eq(reports(ann, "Di Fox"), 1, "Ann asked Di directly and has Di's observation")
    local q = log[#log - 3]
    local kind, f = Wire.Read(q.text)
    check(kind == "Q" and f[3] == "Di Fox", "...a directed ask")
    -- Di answers someone else's ask after Ann's hello: heard by Ann, so Di isn't asked again.
    local ed = client("Ed Lin")
    RANKS["Ed Lin"] = 4
    observe(ed)
    ann.core:OnMessage(Wire.Message("H"), "Ed Lin")
    eq(#ann.core.ask, 1, "(Ed said hello: to be asked)")
    ann.core:OnMessage(Wire.Message("A", { "zz:1" }), "Ed Lin")
    eq(#ann.core.ask, 0, "Ed answered an ask Ann heard: not asked again")
    -- Someone else directed: not mine to answer.
    local bo = client("Bo Kay")
    observe(bo)
    local before = sent("Bo Kay", "A")
    bo.core:OnMessage(Wire.Message("Q", { "x:1", clock - 86400, "Di Fox", "" }), "Ann Lee")
    advance(10)
    eq(sent("Bo Kay", "A"), before, "an ask for Di isn't Bo's to answer")
end

do  -- A guild change: an answer in progress stops; what's queued never leaves.
    reset()
    local ann, bo = client("Ann Lee"), client("Bo Kay")
    for _ = 1, 5 do observe(bo) end
    ann.core:Hello()
    deliver()
    clock = clock + 3
    timers[1].fn(); table.remove(timers, 1)            -- Bo's answer queues, nothing delivered yet
    check(#bo.out >= 6, "(Bo's answer is queued)")
    bo.key = "Other Guild-Forever"
    bo.core:GuildChanged()
    deliver()
    eq(sent("Bo Kay"), 0, "Bo changed guild: nothing of the queued answer leaves")
    eq(reports(ann, "Bo Kay"), 0, "...Ann gets nothing")
end

do  -- Whom Ann accepts: her roster, her rank setting, her report setting, a share each.
    reset()
    local ann, bo = client("Ann Lee", { minRank = 2 }), client("Bo Kay")
    observe(bo)
    ann.core:Hello(); advance(10)
    eq(reports(ann), 0, "Bo's rank (3) is below what Ann accepts (2 and up): refused")
    reset()
    ann, bo = client("Ann Lee", { accept = "never" }), client("Bo Kay")
    observe(bo)
    ann.core:Hello(); advance(10)
    eq(reports(ann), 0, "reports set to Never: nothing kept")
    reset()
    ann = client("Ann Lee")
    local eve = client("Eve Stranger")                  -- not in Ann's roster
    observe(eve)
    ann.core:Hello(); advance(10)
    eq(reports(ann), 0, "a sender not in Ann's roster: refused")
    reset()
    local was = GSync.PER_REPORTER
    GSync.PER_REPORTER = 3
    ann, bo = client("Ann Lee"), client("Bo Kay")
    for _ = 1, 45 do observe(bo) end
    ann.core:Hello(); advance(10)
    eq(reports(ann, "Bo Kay"), 3, "at most PER_REPORTER from one guildmate a session")
    eq(#ann.core.ask, 0, "...and their continuation isn't asked for")
    GSync.PER_REPORTER = was
end

do  -- Limits: one ask per 2 minutes; an entry too long for one message isn't sent.
    reset()
    local ann = client("Ann Lee")
    check(ann.core:Ask(), "an ask")
    check(not ann.core:Ask(), "...a second within 2 minutes: refused")
    clock = clock + GSync.Q_GAP
    check(ann.core:Ask(), "...after it: fine")
    local big = { uid = "abcdef:1", rev = 1, kind = "NOTE", guid = "Player-1-00000001", name = "Ann Lee",
                  from = string.rep("\195\169", 60), to = string.rep("\195\169", 60), at = clock, lo = clock - 60, hi = clock }
    check(GSync.EntryMessage("q:1", big) == nil, "a note pair over 255 bytes in one message: not sent")
    big.from, big.to = "old note", "new note"
    check(GSync.EntryMessage("q:1", big), "...a usual one fits")
    -- What goes on the wire round-trips, and nothing more.
    local reader = Wire.ReadEntry((select(3, Wire.Read(GSync.EntryMessage("q:1", big))))[1], { uid = true, kind = true, from = true }, GSync.ALIAS)
    check(reader.uid == "abcdef:1" and reader.kind == "NOTE" and reader.from == "old note" and reader.to == nil,
        "short names on the wire read back to the allowed fields")
end

------------------------------------------------------------
-- The shell: the prefix, one message at a time, report lines, settings
------------------------------------------------------------
do
    local G = { name = "Parse Partout", realm = "Forever", myRank = 1, ranks = { "Guild Master", "Officer", "Member" },
                members = { { name = "Fizzle Sprocketwhistle", rank = 1, level = 30, class = "MAGE", online = true,
                              guid = "Player-1-00000001", note = "" },
                            { name = "Bo Kay", rank = 2, level = 30, class = "ROGUE", online = true,
                              guid = "Player-1-00000002", note = "" } },
                events = {}, eventNames = true, motd = "", canViewOfficerNote = false }
    loadAddon({ setup = function() WoW.guild = G end })
    local GSync, Log, Wire = GuildSpy.GuildSync, GuildSpy.Log, GuildSpy.Wire      -- this load's
    WoW.fire("PLAYER_LOGIN")
    check(WoW.prefixes.GuildSpy, "the prefix is registered at login")
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    WoW.advance(30)
    local T = GSync._test
    eq(#WoW.ctlHeld, 1, "after the first scan: one message handed to ChatThrottleLib")
    eq(#T.queue(), 1, "...the next waits in our queue")
    check((Wire.Read(WoW.ctlHeld[1].text)) == "H" and WoW.ctlHeld[1].chattype == "GUILD", "...the hello, to GUILD")
    WoW.ctlDeliver(1)
    eq(#WoW.ctlHeld, 1, "once it left, the next is handed over")
    eq((Wire.Read(WoW.ctlHeld[1].text)), "Q", "...the ask")
    WoW.ctlDeliver()
    eq(#WoW.addonSent, 2, "both sent, in order")

    -- Bo's answer: six of his own observations, from a rank I accept.
    local gs = GuildSpy.Scanner.Current()
    local now = time()
    local function bo(i)
        return { uid = "bo" .. i .. ":" .. i, rev = 1, kind = "LEVEL", guid = string.format("Player-1-%08X", 500 + i),
                 name = "Member " .. i, from = 20, to = 21, at = now - 600, lo = now - 660, hi = now - 600 }
    end
    local function hear(text) WoW.fire("CHAT_MSG_ADDON", "GuildSpy", text, "GUILD", "Bo Kay", "Bo Kay", 0, 0, "", 0) end
    WoW.chat = {}
    hear(Wire.Message("A", { "x:1" }))
    for i = 1, 6 do hear(GSync.EntryMessage("x:1", bo(i))) end
    hear(Wire.Message("D", { "x:1", "" }))
    local got = 0
    for _, e in ipairs(gs.log) do if e.reporter == "Bo Kay" then got = got + 1 end end
    eq(got, 6, "Bo's six observations are kept as his reports")
    WoW.advance(GSync.QUIET + 1)
    local lines, more, hint = 0, false, 0
    for _, l in ipairs(WoW.chat) do
        if l:find("(reported by Bo Kay)", 1, true) then lines = lines + 1 end
        if l:find("+1 more from guildmates", 1, true) then more = true end
        if l:find("/gspy options", 1, true) then hint = hint + 1 end
    end
    eq(lines, GSync.MAX_LINES, "in chat: at most five lines")
    check(more, "...then +1 more")
    eq(hint, 1, "...and, the first time, how to turn them off")
    WoW.chat = {}
    hear(GSync.EntryMessage("x:1", bo(7)))
    WoW.advance(GSync.QUIET + 1)
    hint = 0
    for _, l in ipairs(WoW.chat) do if l:find("/gspy options", 1, true) then hint = hint + 1 end end
    check(#WoW.chat == 1 and hint == 0, "the next batch: its line, no hint again")

    -- The settings.
    local O = GuildSpy.Options
    check(O.Set("reports", "log"), "reports: only in the log")
    WoW.chat = {}
    hear(GSync.EntryMessage("x:1", bo(8)))
    WoW.advance(GSync.QUIET + 1)
    eq(#WoW.chat, 0, "...kept, no chat line")
    check(O.Set("reports", "never"), "reports: never")
    local before = #gs.log
    hear(GSync.EntryMessage("x:1", bo(9)))
    eq(#gs.log, before, "...not kept")
    local all = Log.Filter(gs, { hideReports = true }, time())
    local tab = Log.Filter(gs, { category = "reports", hideReports = true }, time())
    local inAll = 0
    for _, e in ipairs(all) do if e.trust == "guild" then inAll = inAll + 1 end end
    check(inAll == 0 and #tab == 8, "...the reports already kept leave All, and stay under Reports")
    check(not O.Set("reports", "sometimes"), "a value no page offers is refused")
    O.Set("reports", "chat")
    eq(GuildSpyDB.settings.reports, nil, "back to the default: nothing saved")
    check(O.Set("reportRank", 1), "accept from Officer and up")
    eq(GSync.MinRank(), 1, "...saved")
    check(not O.Set("reportRank", 5), "...a rank this guild doesn't have: refused")
    before = #gs.log
    hear(GSync.EntryMessage("x:1", bo(10)))
    eq(#gs.log, before, "Bo (Member, rank 2) is now below what I accept")
    O.Set("reportRank", -1)
    eq(GuildSpyDB.settings.reportRank, nil, "every rank again: nothing saved")
    GuildSpyDB.settings.reports, GuildSpyDB.settings.reportRank, GuildSpyDB.settings.shareGuild = "loud", 42, "yes"
    O.Validate(GuildSpyDB.settings)
    check(GuildSpyDB.settings.reports == nil and GuildSpyDB.settings.reportRank == nil and GuildSpyDB.settings.shareGuild == nil,
        "saved values no page could set are dropped")

    -- The Sharing page.
    local sharing = O._test.sharing
    sharing:Show()
    local rr = sharing.controls.reportRank.radios
    check(rr[1]:IsShown() and rr[2].text:GetText() == "Guild Master and up" and rr[4]:IsShown() and not rr[5]:IsShown(),
        "rank choices: every rank, then this guild's three ranks")
    check(sharing.guildStatus:GetText():find("1 guildmate with GuildSpy heard this session", 1, true),
        "the status: Bo heard")

    -- A guild change: what's queued never leaves; one message at most was in flight.
    for i = 1, 4 do
        Log.Add(GuildSpyDB, gs, { kind = "LEVEL", guid = string.format("Player-1-%08X", 780 + i), name = "Mine " .. i,
                                  from = 1, to = 2, lo = time() - 60, hi = time() }, time())
    end
    local sentBefore = #WoW.addonSent
    hear(Wire.Message("Q", { "bq:1", time() - 86400, "", "" }))
    WoW.advance(GSync.JITTER_MAX + 1)
    check(#WoW.ctlHeld == 1 and #T.queue() >= 4, "my answer: one handed over, the rest queued")
    local real = GuildSpy.Scanner.Current
    GuildSpy.Scanner.Current = function() return real(), "Other Guild-Forever" end
    T.tick()
    local old = 0
    for _, m in ipairs(T.queue()) do
        local k = Wire.Read(m.text)
        if k == "E" or k == "D" or k == "A" then old = old + 1 end
    end
    eq(old, 0, "a guild change drops the queued answer (the new guild gets its own hello)")
    WoW.ctlDeliver()
    local kinds = {}
    for i = sentBefore + 1, #WoW.addonSent do kinds[#kinds + 1] = (Wire.Read(WoW.addonSent[i].message)) end
    eq(table.concat(kinds, ","), "A,H", "...of the answer, only the message in flight left")
    GuildSpy.Scanner.Current = real
    T.tick()

    -- A message ChatThrottleLib never reports doesn't stop the queue for good.
    hear(Wire.Message("Q", { "bq:2", time() - 86400, "Fizzle Sprocketwhistle", "" }))
    WoW.advance(2)
    check(#WoW.ctlHeld == 1 and #T.queue() > 0, "(an answer under way)")
    WoW.ctlHeld = {}                                       -- lost without its callback
    WoW.advance(GSync.STUCK + GSync.TICK)
    check(#WoW.ctlHeld == 1, "after a minute without news, the next is handed over")
    WoW.ctlDeliver()

    -- An answer of mine stops at once when one from a name before mine is heard.
    T.tick()
    WoW.ctlDeliver()
    sentBefore = #WoW.addonSent
    hear(Wire.Message("Q", { "bq:4", time() - 86400, "", "" }))
    WoW.advance(GSync.JITTER_MAX + 1)
    check(#WoW.ctlHeld == 1 and #T.queue() >= 3, "(my answer: its first message out, the rest queued)")
    WoW.fire("CHAT_MSG_ADDON", "GuildSpy", Wire.Message("A", { "bq:4" }), "GUILD", "Al Bee", "Al Bee", 0, 0, "", 0)
    WoW.ctlDeliver()
    kinds = {}
    for i = sentBefore + 1, #WoW.addonSent do kinds[#kinds + 1] = (Wire.Read(WoW.addonSent[i].message)) end
    eq(table.concat(kinds, ","), "A", "Al Bee answered too, and comes first: nothing more of mine leaves")

    -- The log's Reports tab: reports only; my own observations stay out of it.
    local own = 0
    for _, e in ipairs(Log.Filter(gs, { category = "reports" }, time())) do if e.trust ~= "guild" then own = own + 1 end end
    eq(own, 0, "the Reports tab holds no observation of mine")

    -- At most a guild's ten ranks are offered.
    local ranks = gs.ranks
    gs.ranks = {}
    for i = 1, 12 do gs.ranks[i] = "Rank " .. i end
    local item
    for _, it in ipairs(O.SHARING) do if it.key == "reportRank" then item = it end end
    eq(#item.choices(), O.MAX_RANKS + 1, "every rank, then at most ten")
    gs.ranks = ranks

    -- No hello before this session's first complete scan.
    local ready = GuildSpy.Scanner.Ready
    local core = T.core()
    core.said = nil
    GuildSpy.Scanner.Ready = function() return false end
    T.tick()
    check(core.said == nil, "no complete scan yet: no hello")
    GuildSpy.Scanner.Ready = ready
    T.tick()
    check(core.said ~= nil, "...then hello")
    WoW.ctlDeliver()

    -- Sharing off: nothing heard, nothing sent.
    O.Set("shareGuild", false)
    eq(GuildSpyDB.settings.shareGuild, false, "share with guildmates: off, saved")
    before = #gs.log
    hear(GSync.EntryMessage("x:1", bo(11)))
    eq(#gs.log, before, "...a guildmate's entry isn't taken")
    sentBefore = #WoW.addonSent
    hear(Wire.Message("Q", { "bq:3", time() - 86400, "", "" }))
    WoW.advance(GSync.JITTER_MAX + GSync.TICK)
    WoW.ctlDeliver()
    eq(#WoW.addonSent, sentBefore, "...an ask isn't answered")
    eq(O.GuildLines()[1], "Off.", "...the status says so")
    T.core().said = nil
    T.tick()
    check(T.core().said == nil, "...and no hello")
    O.Set("shareGuild", true)
end

done("test_guildsync")
