-- EventLog.lua: attributing a diff event from evidence. PURE: no WoW API.
--
-- Two kinds of evidence, one rule: an actor (or a leave's reason) is attached
-- only from a UNIQUE match inside the event's observation interval (lo, hi].
-- Ambiguity means no actor. A leave without a unique quit/kick match is
-- "reason unknown", never "quit". (docs/PLAN.md "Attribution".)
--
--   * live messages (Patterns' output, stamped with the time they arrived):
--     { at, kind, actor, target, rank };
--   * the server's event log (API.ReadEventLog, read after its burst has
--     settled): { kind, p1, p2, rank, ageHours }. Measured (70338): types
--     promote / demote / invite / join / quit / remove; promote, demote and
--     remove carry the officer in p1 and the member in p2; join and quit the
--     member in p1. Ages are whole hours.

local ADDON = ...
GuildSpy = GuildSpy or {}
local EventLog = {}
GuildSpy.EventLog = EventLog

local HOUR = 3600
-- Seconds a message may arrive AFTER the scan that saw its change (the roster
-- can update before the chat line). Never before the interval: (lo, hi + SLACK].
local SLACK = 10

-- Diff kind -> the live message kinds and server-log types that can explain it.
local LIVE = { JOIN = { JOIN = true }, REJOIN = { JOIN = true }, LEAVE = { LEAVE = true, KICK = true },
               PROMOTE = { PROMOTE = true }, DEMOTE = { DEMOTE = true }, RANK = { PROMOTE = true, DEMOTE = true } }
local LOG = { JOIN = { join = true }, REJOIN = { join = true }, LEAVE = { quit = true, remove = true },
              PROMOTE = { promote = true }, DEMOTE = { demote = true }, RANK = { promote = true, demote = true } }

local function overlaps(aLo, aHi, bLo, bHi) return aLo <= bHi and bLo <= aHi end

-- Live messages: the one whose arrival falls inside the event's interval.
-- Returns { actor, at, how, lastStep } or nil, plus "ambiguous" when several
-- matched (then no other evidence may name an actor either). A message that
-- explained an event is used up: it can't explain a later one too (unless
-- `peek`: a check that doesn't record anything).
function EventLog.MatchLive(ev, pending, peek)
    local kinds = LIVE[ev.kind]
    if not kinds then return nil end
    local found, steps = nil, 0
    for _, p in ipairs(pending) do
        if not p.used and kinds[p.kind] and p.target == ev.name and p.at > ev.lo and p.at <= ev.hi + SLACK then
            steps = steps + 1
            if not p.rank or not ev.to or ev.kind == "LEAVE" or p.rank == ev.to then
                if found then return nil, "ambiguous" end
                found = p
            end
        end
    end
    if not found then return nil end
    if not peek then found.used = true end
    return { actor = found.actor, at = found.at, approx = false,
             lastStep = (steps > 1 and ev.kind ~= "LEAVE") or nil,
             how = (found.kind == "KICK" and "kick") or (found.kind == "LEAVE" and "quit") or nil }
end

-- The server log: entries whose hour window overlaps the event's interval.
-- `now` is when the log was read. Returns { actor, at, approx, how, lastStep }.
function EventLog.MatchLog(ev, entries, now)
    local types = LOG[ev.kind]
    if not types then return nil end
    local found, sameTarget = nil, 0
    for _, e in ipairs(entries) do
        if types[e.kind] then
            local target = (e.kind == "join" or e.kind == "quit") and e.p1 or e.p2
            local actor = nil
            if e.kind ~= "join" and e.kind ~= "quit" then actor = e.p1 end
            local t = now - (e.ageHours or 0) * HOUR
            -- A whole-hour age: the event is within an hour either side of t.
            if target == ev.name and overlaps(t - HOUR, t + HOUR, ev.lo, ev.hi) then
                sameTarget = sameTarget + 1
                local rankOk = (e.kind ~= "promote" and e.kind ~= "demote") or not ev.to or e.rank == ev.to
                if rankOk then
                    if found then return nil end
                    found = { actor = actor, at = t, approx = true,
                              how = (e.kind == "remove" and "kick") or (e.kind == "quit" and "quit") or nil }
                end
            end
        end
    end
    -- Several rank steps for one net change: the evidence covers only the last.
    if found and (ev.kind == "PROMOTE" or ev.kind == "DEMOTE" or ev.kind == "RANK") and sameTarget > 1 then
        found.lastStep = true
    end
    return found
end

-- Live first (exact time), then the server log; ambiguous live evidence
-- means no actor at all.
function EventLog.Attribute(ev, pending, entries, now, peek)
    local live, why = EventLog.MatchLive(ev, pending or {}, peek)
    if live then return live end
    if why == "ambiguous" then return nil end
    return entries and EventLog.MatchLog(ev, entries, now) or nil
end
