-- EventLog: attribution only from a unique match inside the interval. Pure.
dofile("tests/harness.lua")
local EventLog = loadPure(newPureEnv(), "EventLog.lua").EventLog

local T = 1790000000
local H = 3600

-- Live messages.
local ev = { kind = "PROMOTE", name = "Ann Lee", to = "Veteran", lo = T, hi = T + 60 }
local function promo(at, actor, rank)
    return { at = at, kind = "PROMOTE", actor = actor or "Enzo Matrix", target = "Ann Lee", rank = rank or "Veteran" }
end
local function liveFresh() return { promo(T + 30) } end
local live = liveFresh()
local a = EventLog.MatchLive(ev, live)
eq(a and a.actor, "Enzo Matrix", "a live message names the officer")
eq(a.approx, false, "...at an exact time")
eq(a.at, T + 30, "...the message's")
eq(EventLog.MatchLive(ev, live), nil, "a message that explained one event can't explain another")
eq(EventLog.MatchLive({ kind = "PROMOTE", name = "Ann Lee", to = "Veteran", lo = T + 100, hi = T + 160 }, liveFresh()), nil,
    "outside the interval: no match")
-- (lo, hi]: never before lo, even by a second; a little after hi is a late chat line.
eq(EventLog.MatchLive({ kind = "PROMOTE", name = "Ann Lee", to = "Veteran", lo = T + 30, hi = T + 90 }, liveFresh()), nil,
    "exactly at lo belongs to the previous interval")
check(EventLog.MatchLive({ kind = "PROMOTE", name = "Ann Lee", to = "Veteran", lo = T + 29, hi = T + 29 }, liveFresh()),
    "a second after hi: the chat line came after the roster")
eq(EventLog.MatchLive({ kind = "PROMOTE", name = "Ann Lee", to = "Officer", lo = T, hi = T + 60 }, liveFresh()), nil,
    "another destination rank: no match")
eq(EventLog.MatchLive({ kind = "DEMOTE", name = "Ann Lee", to = "Veteran", lo = T, hi = T + 60 }, liveFresh()), nil,
    "another kind: no match")
check(EventLog.MatchLive(ev, liveFresh(), true) and EventLog.MatchLive(ev, liveFresh(), true), "a peek uses nothing up")
local peeked = liveFresh()
EventLog.MatchLive(ev, peeked, true)
check(EventLog.MatchLive(ev, peeked), "...the message still explains the event after a peek")
-- Two promotions to the same rank in one interval: ambiguous, no actor.
local twice = { promo(T + 30), promo(T + 40, "Soul Light") }
local none, why = EventLog.MatchLive(ev, twice)
eq(none, nil, "two candidates: no actor")
eq(why, "ambiguous", "...and it says so")
-- Ambiguous live evidence is not overruled by the server log.
eq(EventLog.Attribute(ev, { promo(T + 30), promo(T + 40, "Soul Light") },
    { { kind = "promote", p1 = "Enzo Matrix", p2 = "Ann Lee", rank = "Veteran", ageHours = 0 } }, T + 60), nil,
    "ambiguous live evidence: the log can't name an actor either")
-- Two live steps for one net change: the final officer, marked as the last step only.
a = EventLog.MatchLive(ev, { promo(T + 10, "Soul Light", "Member"), promo(T + 20, "Enzo Matrix", "Veteran") })
eq(a.actor, "Enzo Matrix", "the step to the final rank")
eq(a.lastStep, true, "...marked as the last step")
-- Leaves.
local kick = { { at = T + 10, kind = "KICK", actor = "Enzo Matrix", target = "Bo Kay" } }
a = EventLog.MatchLive({ kind = "LEAVE", name = "Bo Kay", lo = T, hi = T + 60 }, kick)
eq(a.how, "kick", "a kick")
eq(a.actor, "Enzo Matrix", "...by whom")
a = EventLog.MatchLive({ kind = "LEAVE", name = "Bo Kay", lo = T, hi = T + 60 },
    { { at = T + 10, kind = "LEAVE", target = "Bo Kay" } })
eq(a.how, "quit", "a leave message is a quit")

-- The server log (read at T + 10 h; ages in whole hours).
local now = T + 10 * H
local log = {
    { kind = "promote", p1 = "Enzo Matrix", p2 = "Ann Lee", rank = "Veteran", ageHours = 9 },
    { kind = "remove", p1 = "Enzo Matrix", p2 = "Bo Kay", rank = "", ageHours = 5 },
    { kind = "quit", p1 = "Cy Dee", ageHours = 5 },
    { kind = "join", p1 = "Di Ek", rank = "", ageHours = 2 },
}
a = EventLog.MatchLog({ kind = "PROMOTE", name = "Ann Lee", to = "Veteran", lo = T, hi = T + 8 * H }, log, now)
eq(a and a.actor, "Enzo Matrix", "the log names the officer of an offline promotion")
eq(a.approx, true, "...at an approximate time")
a = EventLog.MatchLog({ kind = "LEAVE", name = "Bo Kay", lo = T + 4 * H, hi = T + 6 * H }, log, now)
eq(a.how, "kick", "remove is a kick")
eq(a.actor, "Enzo Matrix", "...by whom")
a = EventLog.MatchLog({ kind = "LEAVE", name = "Cy Dee", lo = T + 4 * H, hi = T + 6 * H }, log, now)
eq(a.how, "quit", "quit is a quit")
eq(a.actor, nil, "...with no actor")
eq(EventLog.MatchLog({ kind = "LEAVE", name = "Zed Ox", lo = T, hi = now }, log, now), nil,
    "no entry: reason unknown, never 'quit'")
eq(EventLog.MatchLog({ kind = "LEAVE", name = "Bo Kay", lo = T + 8 * H, hi = now }, log, now), nil,
    "an entry far outside the interval doesn't count")
-- Names missing (read before the burst settled): nothing matches.
eq(EventLog.MatchLog({ kind = "PROMOTE", name = "Ann Lee", to = "Veteran", lo = T, hi = now },
    { { kind = "promote", rank = "Veteran", ageHours = 9 } }, now), nil, "a nameless log attributes nothing")
-- Two promotions for one net change: the actor of the step to the final rank, marked.
local steps = {
    { kind = "promote", p1 = "Soul Light", p2 = "Ann Lee", rank = "Member", ageHours = 6 },
    { kind = "promote", p1 = "Enzo Matrix", p2 = "Ann Lee", rank = "Veteran", ageHours = 5 },
}
a = EventLog.MatchLog({ kind = "PROMOTE", name = "Ann Lee", to = "Veteran", lo = T, hi = now }, steps, now)
eq(a.actor, "Enzo Matrix", "the last step's officer")
eq(a.lastStep, true, "...marked as the last step only")

-- Attribute: live first, then the log.
a = EventLog.Attribute({ kind = "PROMOTE", name = "Ann Lee", to = "Veteran", lo = T, hi = T + 60 }, liveFresh(), log, now)
eq(a.approx, false, "live wins")

done("test_eventlog")
