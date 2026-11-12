-- GuildSpyProbe's GRMClassify (#8): GRM's addon messages -> counts, samples,
-- name shapes. Pure: loaded with every client global forbidden. The module's
-- wiring (GuildSpyProbe.lua) needs ForeverProbe and is checked in game; its
-- offline test waits for the move onto WowTestKit (#68).
dofile("tests/harness.lua")
local chunk = assert(loadfile("Tools/GuildSpyProbe/GRMClassify.lua"))
setfenv(chunk, newPureEnv())
local NS = {}
chunk("GuildSpyProbe", NS)
local C = NS.GRMClassify
check(C ~= nil, "GRMClassify sets NS.GRMClassify")

-- Split keeps empty fields.
local f = C.Split("GRM_JD?5?Kaleid Sumner?20261101?1762000000")
eq(#f, 5, "split: five fields")
eq(f[3], "Kaleid Sumner", "...the name with its space")
eq(#C.Split("REQ?"), 2, "a trailing ? leaves an empty field")
eq(#C.Split("a??b"), 3, "...and between two")

-- Tags.
eq(C.Tag("GRM_SYNC", { "GRM_JD" }), "GRM_JD", "a GRM_SYNC tag")
eq(C.Tag("GRMVER", { "R1.99521", "1762300000" }), "VER", "GRMVER has no tag of its own")
eq(C.Tag("GRM_SYNC", { "hello there" }), "(other)", "typed text is never a key")
eq(C.Tag("GRM_SYNC", { string.rep("A", 25) }), "(other)", "...nor an over-long word")

-- Shapes and names.
eq(C.FieldShape(""), "e", "empty field")
eq(C.FieldShape("20261101"), "n8", "a date's shape")
eq(C.FieldShape("true"), "b", "a flag")
eq(C.FieldShape("Hello you"), "s9", "text: type and length only")
eq(C.NameShape("Kaleid Sumner"), "2w", "First Surname")
eq(C.NameShape("Kaleid Sumner-Realm"), "2w+realm", "...with a realm")
eq(C.NameShape("Kaleid-Area52"), "1w+realm", "a Retail-style name")
eq(C.NameShape(nil), "empty", "no name")

local roster = { ["Kaleid Sumner"] = true }
eq(C.RosterMatch("Kaleid Sumner", roster), "asis", "a roster name as is")
eq(C.RosterMatch("Kaleid Sumner-Realm", roster), "base", "...once the realm is dropped")
eq(C.RosterMatch("Bo Kay", roster), "none", "not in the roster")
eq(C.RosterMatch("Bo Kay", {}), "noroster", "the roster not read yet")

-- Redaction: structural tags kept, typed text reduced to shapes.
eq(C.Redact("GRM_SYNC", "GRM_JD", C.Split("GRM_JD?5?Kaleid Sumner?20261101?1762000000")),
   "GRM_JD?5?Kaleid Sumner?20261101?1762000000", "a join date is kept as is")
eq(C.Redact("GRM_SYNC", "GRM_NN", C.Split("GRM_NN?5?Kaleid Sumner?Kal the Bold?1?x")),
   "GRM_NN?n1?s13?s12?n1?s1", "a nickname: shapes only")
eq(C.Redact("GRM_SYNC", "GRM_CNOTE1", C.Split("GRM_CNOTE1?5?Kaleid~|~1762~|~my secret note")),
   "GRM_CNOTE1?n1?s30", "a custom note: shapes only")
eq(C.Redact("GRMVER", "VER", C.Split("R1.99521?1762300000")), "R1.99521?1762300000", "the version kept")
eq(C.Redact("GRMACHIEV", "(other)", C.Split("|cffffff00|Hachievement:1|h[x]|h|r")),
   "(other)?s34", "an achievement link: unknown tag, the first field kept as a shape")

-- Record.
local db = C.Init({})
local ctx = { now = 1000, day = "2026-11-11", roster = roster, me = "Koma Kino" }
local r = C.Record(db, { prefix = "GRM_SYNC", text = "GRM_JD?5?Kaleid Sumner?20261101?1762000000",
                         channel = "GUILD", sender = "Kaleid Sumner" }, ctx)
eq(r.tag, "GRM_JD", "record: the tag")
eq(r.sample, "GRM_JD?5?Kaleid Sumner?20261101?1762000000", "...the first is a sample")
eq(db.total, 1, "...counted")
eq(db.counts.GRM_SYNC.GUILD.GRM_JD, 1, "...per prefix, channel and tag")
eq(db.days["2026-11-11"], 1, "...per day")
eq(db.senders["2w"], 1, "...the sender's shape")
eq(db.senderMatch.asis, 1, "...matched to the roster")
eq(db.nameFields.GRM_JD["2w/asis"], 1, "...and the member name inside")
eq(db.samples["GRM_SYNC GRM_JD"][1].sender, "2w", "a sample keeps the sender's shape, not the name")

for _ = 1, 4 do
    C.Record(db, { prefix = "GRM_SYNC", text = "GRM_JD?5?Kaleid Sumner?20261101?1762000000",
                   channel = "GUILD", sender = "Kaleid Sumner" }, ctx)
end
eq(#db.samples["GRM_SYNC GRM_JD"], C.SAMPLES, "samples capped per tag")
eq(db.counts.GRM_SYNC.GUILD.GRM_JD, 5, "...counts are not")

r = C.Record(db, { prefix = "GRM_SYNC", text = "GRM_JD?5?x?1?2", channel = "GUILD", sender = "Koma Kino" }, ctx)
check(r.self, "our own echo is flagged")
eq(db.selfEcho, 1, "...counted apart")
eq(db.total, 5, "...and not in the total")
C.Record(db, { prefix = "GRM_SYNC", text = "GRM_JD?5?x?1?2", channel = "GUILD", sender = "Koma Kino-Realm" }, ctx)
eq(db.selfEcho, 2, "our echo with a realm too")

eq(C.Record(db, { prefix = "GSPY", text = "x", channel = "GUILD", sender = "A B" }, ctx), nil,
   "another addon's prefix is ignored")

-- GRM users from REG.
C.Record(db, { prefix = "GRMUSER", text = "REG?R1.99521?1762300000?2?true?false?true?false",
               channel = "GUILD", sender = "Gal Orey" }, ctx)
local u = db.users["Gal Orey"]
eq(u and u.version, "R1.99521", "a GRM user's version")
eq(u.syncEnabled, "true", "...sync on")
eq(u.exportAllRanks, "false", "...all ranks off")
eq(u.count, 1, "...heard once")

-- Summary.
local lines = C.Summary(db)
check(lines[1]:find("GRM messages 6", 1, true) ~= nil, "summary total: " .. lines[1])
check(lines[1]:find("GRM users heard 1", 1, true) ~= nil, "...and users")

-- Init keeps what's there (the probe binds these tables).
local before = db.counts
C.Init(db)
check(db.counts == before, "Init never replaces a table")

done("test_grmprobe")
