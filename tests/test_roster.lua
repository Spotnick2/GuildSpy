-- Roster.Apply, the guild diff: loaded with every global forbidden (pure).
dofile("tests/harness.lua")
local Roster = loadPure(newPureEnv(), "Roster.lua").Roster

local RANKS = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
local T0 = 1790000000
local DAY = 86400

local function m(name, rank, level, extra)
    local r = { name = name, rank = rank, level = level or 20, class = "MAGE", note = "", online = true }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end
local function scan(members, extra)
    local s = { members = members, ranks = extra and extra.ranks or RANKS, canViewOfficer = false, motd = "hi" }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end
local function kinds(events)
    local out = {}
    for _, e in ipairs(events) do out[#out + 1] = e.kind end
    table.sort(out)
    return table.concat(out, ",")
end
local function byKind(events, k) for _, e in ipairs(events) do if e.kind == k then return e end end end

-- The first observation is a silent baseline.
local st = {}
local ev, base = Roster.Apply(st, scan({ A = m("Ann Lee", 3), B = m("Bo Kay", 4) }), T0)
eq(#ev, 0, "baseline reports nothing")
eq(base, true, "...and says it was a baseline")
eq(st.observedAt, T0, "observation time stored")

-- Join, promote, demote, level, note, name change in one scan.
ev = Roster.Apply(st, scan({
    A = m("Ann Lee", 2, 22),                    -- promoted Member -> Veteran, levelled 20 -> 22
    B = m("Bo Kayson", 4, 20, { note = "alt" }), -- renamed, note
    C = m("Cy Dee", 4, 5),                      -- joined
}), T0 + 60)
eq(kinds(ev), "JOIN,LEVEL,NAME,NOTE,PROMOTE", "every change found")
local p = byKind(ev, "PROMOTE")
eq(p.from, "Member", "promoted from the old rank's name")
eq(p.to, "Veteran", "...to the new one")
eq(p.lo, T0, "observation interval starts at the previous scan")
eq(p.hi, T0 + 60, "...and ends now")
eq(byKind(ev, "NAME").from, "Bo Kay", "the old name")
eq(byKind(ev, "JOIN").to, "Initiate", "joined at a rank (index 4, 0-based)")
ev = Roster.Apply(st, scan({ A = m("Ann Lee", 3, 22), B = m("Bo Kayson", 4, 20, { note = "alt" }),
                             C = m("Cy Dee", 4, 5) }), T0 + 120)
eq(kinds(ev), "DEMOTE", "a demotion")

-- Levels: below the threshold quiet, unless a multiple of ten is crossed.
ev = Roster.Apply(st, scan({ A = m("Ann Lee", 3, 22), B = m("Bo Kayson", 4, 20, { note = "alt" }),
                             C = m("Cy Dee", 4, 9) }), T0 + 180)
eq(#ev, 0, "5 -> 9: under the threshold")
ev = Roster.Apply(st, scan({ A = m("Ann Lee", 3, 22), B = m("Bo Kayson", 4, 20, { note = "alt" }),
                             C = m("Cy Dee", 4, 11) }), T0 + 240)
eq(kinds(ev), "LEVEL", "9 -> 11 crosses 10")

-- Departures need two complete scans, 30 s apart; one missing scan is nothing.
local three = function() return { A = m("Ann Lee", 3, 22), B = m("Bo Kayson", 4, 20, { note = "alt" }),
                                  C = m("Cy Dee", 4, 11) } end
local two = function() local t = three(); t.C = nil; return t end
ev = Roster.Apply(st, scan(two()), T0 + 300)
eq(#ev, 0, "missing once: not gone yet")
eq(st.members.C.missingSince, T0 + 300, "...but marked")
eq(Roster.HasMissing(st), true, "HasMissing says so")
ev = Roster.Apply(st, scan(three()), T0 + 310)
eq(#ev, 0, "back on the next scan: no join, no leave")
eq(st.members.C.missingSince, nil, "...and unmarked")
Roster.Apply(st, scan(two()), T0 + 400)
ev = Roster.Apply(st, scan(two()), T0 + 410)
eq(#ev, 0, "a second scan only 10 s later doesn't confirm")
ev = Roster.Apply(st, scan(two()), T0 + 440)
eq(kinds(ev), "LEAVE", "30 s later it does")
local leave = byKind(ev, "LEAVE")
eq(leave.lo, T0 + 310, "the interval is the one they vanished in")
eq(leave.hi, T0 + 400, "...not the confirming scan's")
eq(leave.from, "Initiate", "left at their rank")
check(st.formers.C ~= nil, "kept as a former member")
-- A message can confirm on the first missing scan.
Roster.Apply(st, scan(three()), T0 + 500)
eq(kinds(Roster.Apply(st, scan(three()), T0 + 510)), "", "(rejoined above; settled)")
ev = Roster.Apply(st, scan(two()), T0 + 520, { confirmLeave = function(name) return name == "Cy Dee" end })
eq(kinds(ev), "LEAVE", "confirmed at once by a message")

-- Two missing members with one name (connected realms): a message confirms neither.
local twin = {}
Roster.Apply(twin, scan({ T1 = m("Sam Mahra", 4), T2 = m("Sam Mahra", 4), K = m("Kay Oh", 4) }), T0)
ev = Roster.Apply(twin, scan({ K = m("Kay Oh", 4) }), T0 + 60, { confirmLeave = function() return true end })
eq(#ev, 0, "a shared name: no fast confirmation")
ev = Roster.Apply(twin, scan({ K = m("Kay Oh", 4) }), T0 + 120)
eq(kinds(ev), "LEAVE,LEAVE", "...both confirmed by the second scan instead")

-- Rejoin: the GUID was a former member.
ev = Roster.Apply(st, scan(three()), T0 + 600)
eq(kinds(ev), "REJOIN", "a former member is a rejoin")
eq(byKind(ev, "REJOIN").from, "Initiate", "...with the rank they left at")

-- A rank inserted in the middle: one RANKS event, no wave of demotions.
local RANKS2 = { "Guild Master", "Officer", "Raider", "Veteran", "Member", "Initiate" }
ev = Roster.Apply(st, scan({ A = m("Ann Lee", 3, 22), B = m("Bo Kayson", 4 + 1, 20, { note = "alt" }),
                             C = m("Cy Dee", 4 + 1, 11) }, { ranks = RANKS2 }), T0 + 700)
eq(kinds(ev), "RANKS", "indices shifted by an insert: only the structure change")
-- A real move during a structure change is reported only when confirmed.
local RANKS3 = { "Guild Master", "Officer", "Raider", "Veteran", "Member", "Initiate", "Alt" }
local asked
ev = Roster.Apply(st, scan({ A = m("Ann Lee", 2, 22), B = m("Bo Kayson", 5, 20, { note = "alt" }),
                             C = m("Cy Dee", 5, 11) }, { ranks = RANKS3 }), T0 + 800,
    { confirmRank = function(kind, name, to) asked = kind .. ":" .. name .. ":" .. to; return true end })
eq(asked, "PROMOTE:Ann Lee:Raider", "Veteran -> Raider asked as a promotion")
eq(kinds(ev), "PROMOTE,RANKS", "...and reported once confirmed")
ev = Roster.Apply(st, scan({ A = m("Ann Lee", 3, 22), B = m("Bo Kayson", 5, 20, { note = "alt" }),
                             C = m("Cy Dee", 5, 11) }, { ranks = RANKS }), T0 + 900,
    { confirmRank = function() return false end })
eq(kinds(ev), "RANKS", "an unconfirmed move during a structure change is suppressed")

-- Officer notes: unreadable is not empty.
local o = {}
local function om(onote) return { X = m("Xi Yu", 3, 30, { onote = onote }) } end
Roster.Apply(o, scan(om("main tank"), { canViewOfficer = true }), T0)
eq(o.members.X.onote, "main tank", "an officer seeds the note")
ev = Roster.Apply(o, scan(om(nil), { canViewOfficer = false }), T0 + 60)
eq(#ev, 0, "an alt that can't read it reports nothing")
eq(o.members.X.onote, "main tank", "...and doesn't clear it")
ev = Roster.Apply(o, scan(om("main tank"), { canViewOfficer = true }), T0 + 120)
eq(#ev, 0, "back on the officer: no false change")
ev = Roster.Apply(o, scan(om("off tank"), { canViewOfficer = true }), T0 + 180)
eq(kinds(ev), "ONOTE", "a real change is reported")
local fresh = { }
Roster.Apply(fresh, scan(om(nil), { canViewOfficer = false }), T0)
ev = Roster.Apply(fresh, scan(om("first sight"), { canViewOfficer = true }), T0 + 60)
eq(#ev, 0, "the first readable value seeds silently")

-- Back after a long absence: only with proof of the absence.
local r = {}
local away = function(hours) return { R = m("Rae Sun", 4, 30, { online = false, lastOnlineHours = hours }) } end
Roster.Apply(r, scan(away(20 * 24)), T0)                  -- seen: away 20 days
ev = Roster.Apply(r, scan({ R = m("Rae Sun", 4, 30) }), T0 + 3600)
eq(kinds(ev), "RETURN", "away 20 days, now online: back")
eq(byKind(ev, "RETURN").days, 20, "...after at least 20 days")
ev = Roster.Apply(r, scan({ R = m("Rae Sun", 4, 30) }), T0 + 7200)
eq(#ev, 0, "once per absence")
-- We were away, they weren't: no proof, no claim.
local q = {}
Roster.Apply(q, scan({ Q = m("Quo Vadis", 4, 30) }), T0)           -- online when last seen
ev = Roster.Apply(q, scan({ Q = m("Quo Vadis", 4, 30) }), T0 + 30 * DAY)
eq(#ev, 0, "a gap in OUR observation is not their absence")
-- Rounding of last-online is not a login.
local w = {}
Roster.Apply(w, scan(away(20 * 24)), T0)
ev = Roster.Apply(w, scan(away(20 * 24 + 1)), T0 + 3600 * 2)
eq(#ev, 0, "last-online moving by an hour is rounding")
ev = Roster.Apply(w, scan(away(1)), T0 + 3600 * 5)
eq(kinds(ev), "RETURN", "logged in while we weren't looking: still back")
-- A month-sized total that wobbles (calendar months vs 730 h) is not a login.
local mw = {}
Roster.Apply(mw, scan(away(743)), T0)                                   -- 0m 30d 23h
ev = Roster.Apply(mw, scan(away(730)), T0 + 3600)                       -- 1m 0d 0h, an hour later
eq(#ev, 0, "a month rollover in last-online is not a return")
-- Both away for weeks: their total, a little off, still isn't newer than our last look.
local bw = {}
Roster.Apply(bw, scan(away(30 * 24)), T0)
ev = Roster.Apply(bw, scan(away(30 * 24 + 40 * 24 - 10)), T0 + 40 * DAY)
eq(#ev, 0, "we were away as long as they were: no claim")

-- A rank inserted while a member is missing: they keep their rank by name.
local x = {}
Roster.Apply(x, scan({ A = m("Ann Lee", 3), B = m("Bo Kay", 3) }), T0)
Roster.Apply(x, scan({ A = m("Ann Lee", 3) }), T0 + 60)                        -- Bo missing once
local R4 = { "Guild Master", "Officer", "Raider", "Veteran", "Member", "Initiate" }
ev = Roster.Apply(x, scan({ A = m("Ann Lee", 4) }, { ranks = R4 }), T0 + 70)    -- insert above Member
eq(kinds(ev), "RANKS", "a structure change, Bo still missing")
eq(x.members.B.rank, 4, "Bo's index moved to Member's new place")
ev = Roster.Apply(x, scan({ A = m("Ann Lee", 4), B = m("Bo Kay", 4) }, { ranks = R4 }), T0 + 80)
eq(#ev, 0, "Bo back at Member: no false demotion")
Roster.Apply(x, scan({ A = m("Ann Lee", 4) }, { ranks = R4 }), T0 + 100)
ev = Roster.Apply(x, scan({ A = m("Ann Lee", 4) }, { ranks = R4 }), T0 + 200)
eq(byKind(ev, "LEAVE").from, "Member", "...and leaves as a Member, not the index's old meaning")

-- RETURN uses the member's own last observation, not the guild's.
local y = {}
Roster.Apply(y, scan({ Y = m("Yo Yo", 4, 30, { online = false, lastOnlineHours = 24 }) }), T0)   -- away 1 day
Roster.Apply(y, scan({}), T0 + 20 * DAY)                                           -- missing from a scan
ev = Roster.Apply(y, scan({ Y = m("Yo Yo", 4, 30) }), T0 + 20 * DAY + 10)
eq(byKind(ev, "RETURN"), nil, "missing from our scan isn't 21 days of THEIR absence")

-- MOTD.
local d = {}
Roster.Apply(d, scan({}, { motd = "old" }), T0)
eq(kinds(Roster.Apply(d, scan({}, { motd = "new" }), T0 + 60)), "MOTD", "a new MOTD")

-- Formers are capped.
local f = { formers = {} }
for i = 1, 10 do f.formers["G" .. i] = { name = "n" .. i, leftAt = T0 + i } end
f.formers.OLD = { name = "old", leftAt = T0 - 400 * DAY }
Roster.PruneFormers(f, T0 + 100, 5, 365)
local n = 0
for _ in pairs(f.formers) do n = n + 1 end
eq(n, 5, "formers capped")
eq(f.formers.OLD, nil, "...a year-old one dropped")
eq(f.formers.G10 ~= nil, true, "...the newest kept")

done("test_roster")
