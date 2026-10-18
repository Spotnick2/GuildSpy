-- #59: one row per change when several observers recorded it. Storage keeps
-- every record (#42); the window, its counts and its New marker fold them.
-- The owner's log: Mside Divine's join three times (two of my accounts and a
-- guildmate), Zoruka "6 -> 10" next to "9 -> 10".
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

loadAddon()
local Log = GuildSpy.Log
local NOW = time()
local H = 3600
local MSIDE, ZORUKA = "Player-4620-018F91A2", "Player-4618-00C6CDD5"

local seq = 0
-- A stored record. Default: Mside's join, noticed here by a scan.
local function rec(t)
    seq = seq + 1
    local e = { seq = seq, uid = "u:" .. seq, rev = 1, kind = "JOIN", guid = MSIDE, name = "Mside Divine",
                class = "PALADIN", to = "Initiate", at = NOW - 13 * H, lo = NOW - 16 * H, hi = NOW - 13 * H,
                approx = true, trust = "self", here = true, origin = "Drakuza Memphisto" }
    for k, v in pairs(t or {}) do e[k] = v end
    if e.trust == "guild" then e.ns, e.reporter, e.here = "g:" .. e.origin, e.origin, false end
    return e
end
local function report(t)
    t = t or {}
    t.trust, t.origin = "guild", t.origin or "Lejeupeutu Sortirasti"
    return rec(t)
end
local function rows(gs, opts) return Log.Filter(gs, opts or {}, NOW) end

do  -- The case from the game: three observers of one join, their windows overlapping.
    local a = rec({ lo = NOW - 16 * H, hi = NOW - 13 * H })
    local b = rec({ here = false, origin = "Cowruzo Kashmere", lo = NOW - 20 * H, hi = NOW - 13.5 * H })
    local c = report({ lo = NOW - 22 * H, hi = NOW - 0.5 * H })
    local gs = { log = { a, b, c } }
    local out, groups = rows(gs)
    eq(#out, 1, "three records of one join: one row")
    check(out[1] == a, "...led by this account's, the finest of mine")
    eq(#groups[a].members, 3, "...the group holds all three")
    check(not Log.Row(Log.View(groups[a], a), NOW):find("reported", 1, true), "...not marked reported: the lead is mine")
    eq(#gs.log, 3, "...and storage keeps every record")
    eq(#rows(gs, { category = "reports" }), 1, "the Reports tab shows the change once")
    check(rows(gs, { category = "reports" })[1] == c, "...as its report")
    eq(#rows(gs, { query = "lejeupeutu" }), 1, "a search on the reporter finds the change")
    check(rows(gs, { query = "lejeupeutu" })[1] == a, "...shown as the row the window has")
    eq(#rows(gs, { hideReports = true }), 1, "reports hidden: still one row")
    eq(#select(2, rows(gs, { hideReports = true }))[a].members, 2, "...with no report in it")
end

do  -- Disjoint windows: two changes, not one.
    local gs = { log = { rec({ lo = NOW - 40 * H, hi = NOW - 30 * H }), rec({ lo = NOW - 10 * H, hi = NOW - 5 * H }) } }
    eq(#rows(gs), 2, "two joins whose windows don't meet: two rows")
end

do  -- Never a chain through a broad record (Codex, #59): A and C are different edits.
    local a = rec({ kind = "NOTE", from = "a", to = "b", lo = NOW - 600, hi = NOW - 480 })
    local b = rec({ kind = "NOTE", from = "a", to = "b", lo = NOW - 540, hi = NOW - 120, here = false, origin = "Alt" })
    local c = rec({ kind = "NOTE", from = "a", to = "b", lo = NOW - 180, hi = NOW - 60, here = false, origin = "Other" })
    local gs = { log = { a, b, c } }
    eq(#rows(gs), 2, "A~B and B~C but not A~C: two rows")
    local _, of = Log.Groups(gs, function() return true end)
    check(of[a] == of[b] and of[c] ~= of[a], "...B with A, the earliest start; C alone")
end

do  -- Before #36 a record has no window: it stays alone.
    local gs = { log = { rec({ lo = false, hi = false, kind = "PROMOTE", from = "Initiate", to = "Member" }),
                         rec({ lo = false, hi = false, kind = "PROMOTE", from = "Initiate", to = "Member" }) } }
    for _, e in ipairs(gs.log) do e.lo, e.hi = nil, nil end
    eq(#rows(gs), 2, "two records with no window: two rows (no guessed slack)")
end

do  -- One account's join is another's rejoin, which carries the rank once left (Roster.Apply).
    local gs = { log = { rec(), rec({ kind = "REJOIN", from = "Member", leftAt = NOW - 40 * H, here = false, origin = "Alt" }) } }
    eq(#rows(gs), 1, "a join and a rejoin (from the rank left) of one change: one row (#61 review)")
end

do  -- A note may hold "|": "a|b" -> "c" and "a" -> "b|c" are two edits (#61 review).
    local gs = { log = { rec({ kind = "NOTE", from = "a|b", to = "c" }),
                         rec({ kind = "NOTE", from = "a", to = "b|c", here = false, origin = "Alt" }) } }
    eq(#rows(gs), 2, "two notes whose fields only differ by where a pipe is: two rows")
end

do  -- Exact times: two clients receive one message a little apart.
    local gs = { log = { rec({ approx = false, at = NOW - 100 }), rec({ approx = false, at = NOW - 70, here = false, origin = "Alt" }) } }
    eq(#rows(gs), 1, "exact times 30 s apart: one row")
    gs = { log = { rec({ approx = false, at = NOW - 1000 }), rec({ approx = false, at = NOW - 100, here = false, origin = "Alt" }) } }
    eq(#rows(gs), 2, "exact times 15 min apart: two rows")
end

do  -- Another character with the same name (deleted and made again): another GUID.
    local gs = { log = { rec(), rec({ guid = "Player-4620-01000001", here = false, origin = "Alt" }) } }
    eq(#rows(gs), 2, "the same name, two GUIDs: two rows")
end

do  -- Level-ups: the same member and level, whatever the windows.
    local wide = rec({ kind = "LEVEL", guid = ZORUKA, name = "Zoruka Mortalis", from = 6, to = 10,
                       lo = NOW - 13.4 * H, hi = NOW - 11 * H, at = NOW - 11 * H })
    local step = rec({ kind = "LEVEL", guid = ZORUKA, name = "Zoruka Mortalis", from = 9, to = 10,
                       lo = NOW - 11.5 * H - 35, hi = NOW - 11.5 * H, at = NOW - 11.5 * H, here = false, origin = "Zoruka Mortalis" })
    local gs = { log = { wide, step } }
    local out, groups = rows(gs)
    eq(#out, 1, "6 -> 10 and 9 -> 10: one row")
    check(out[1] == step, "...led by the finer record")
    local text = Log.Plain(Log.Row(Log.View(groups[step], step), NOW))
    check(text:find("leveled from 6 to 10", 1, true), "...reading from the lowest level: " .. text)
    eq(step.from, 9, "...the stored record untouched")
    -- A guildmate's lower start isn't shown as mine.
    local low = report({ kind = "LEVEL", guid = ZORUKA, name = "Zoruka Mortalis", from = 4, to = 10,
                         lo = NOW - 20 * H, hi = NOW - 11 * H, at = NOW - 11 * H })
    gs = { log = { wide, step, low } }
    out, groups = rows(gs)
    eq(groups[out[1]].from, 6, "a report's 4 -> 10 doesn't lower my row's start")
    gs = { log = { low, report({ kind = "LEVEL", guid = ZORUKA, name = "Zoruka Mortalis", from = 9, to = 10,
                                 origin = "Ann Lee", lo = NOW - 12 * H, hi = NOW - 11 * H }) } }
    out, groups = rows(gs)
    eq(groups[out[1]].from, 4, "only reports: their lowest start")
    eq(#rows({ log = { wide, rec({ kind = "LEVEL", guid = ZORUKA, from = 10, to = 11 }) } }), 2,
        "a different level: another row")
end

do  -- New: only while every record of the change is new.
    local old = rec({ seq = 1 })
    local late = report({ seq = 9 })
    local gs = { log = { old, late } }
    eq(#Log.NewCounts(gs, 5, false, false), 0, "a late report of a join already seen isn't new")
    local _, groups = rows(gs, { category = "reports" })
    eq(groups[late].seq, 1, "...not in the Reports tab either")
    local fresh = { log = { rec({ seq = 20 }), rec({ seq = 21, here = false, origin = "Alt" }), report({ seq = 22 }) } }
    local c = Log.NewCounts(fresh, 5, false, false)
    eq(#c, 1, "three new records of one join...")
    eq(c[1].n, 1, "...count as one join")
    check(Log.NewSummary(fresh, 5, false):find("1", 1, true), "...in the summary")
end

done("test_fold")
