-- Roster.lua: the guild diff. PURE: no WoW API (tests load it with every
-- global forbidden). docs/PLAN.md "Scan pipeline" is the contract; each rule
-- below closed a failure found in review.
--
-- Roster.Apply(state, scan, now, opts) compares a COMPLETE roster scan with
-- the saved state of one guild, updates the state in place, and returns the
-- changes as events:
--   { kind, guid, name, from, to, lo, hi, needsConfirm, days }
-- where (lo, hi] is the observation interval the change happened in.
--
-- state: GuildSpyDB.guilds[key] (see docs/PLAN.md "Storage"). scan: from
-- API.ReadRoster: { members = { [guid] = { name, rank (0-based), level,
-- class, note, onote (nil: unreadable), online, lastOnlineHours } },
-- ranks = { 1-based names }, canViewOfficer, motd }.
--
-- opts: levelMin (report a level-up from this level, default 10),
-- returnDays (default 14), departSeconds (default 30), and two callbacks the
-- shell answers from its evidence (live messages, the server log):
--   confirmLeave(name, lo, hi) -> true: a departure is confirmed on its first
--     missing scan instead of waiting for a second one;
--   confirmRank(kind, name, toRankName, lo, hi) -> true: a rank change found
--     while the rank STRUCTURE changed is real (otherwise suppressed).

local ADDON = ...
GuildSpy = GuildSpy or {}
local Roster = {}
GuildSpy.Roster = Roster

local HOUR, DAY = 3600, 86400
-- Last-online is whole hours, rounded down (an hour of slack), and a month is
-- counted as 730 h where the client may count calendar months (up to ~2% off).
local MONTH_WOBBLE = 0.02

Roster.KINDS = { "JOIN", "REJOIN", "LEAVE", "PROMOTE", "DEMOTE", "RANK", "RANKS", "NOTE", "ONOTE",
                 "LEVEL", "NAME", "RETURN", "MOTD" }

local function lastSeen(m, now)
    if m.online then return now end
    if type(m.lastOnlineHours) == "number" then return now - m.lastOnlineHours * HOUR end
    return nil
end

local function sameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

local function indexOf(list, v)
    local found
    for i, x in ipairs(list) do
        if x == v then
            if found then return nil end   -- a duplicated name is ambiguous
            found = i
        end
    end
    return found
end

local function record(m, now)
    return { name = m.name, rank = m.rank, level = m.level, class = m.class, note = m.note,
             onote = m.onote, online = m.online, lastSeenAt = lastSeen(m, now), seenAt = now }
end

-- The first complete observation of a guild: stored, nothing reported.
local function baseline(state, scan, now)
    state.members = {}
    for guid, m in pairs(scan.members) do state.members[guid] = record(m, now) end
    state.ranks = scan.ranks
    state.motd = scan.motd
    state.onoteBaselineAt = scan.canViewOfficer and now or nil
    state.observedAt = now
    state.formers = state.formers or {}
end

function Roster.NeedsBaseline(state) return state.observedAt == nil or state.members == nil end

-- Whether any member is waiting for a second scan to confirm their departure.
function Roster.HasMissing(state)
    for _, m in pairs(state.members or {}) do if m.missingSince then return true end end
    return false
end

function Roster.Apply(state, scan, now, opts)
    opts = opts or {}
    local events = {}
    if Roster.NeedsBaseline(state) then
        baseline(state, scan, now)
        return events, true
    end
    local levelMin = opts.levelMin or 10
    local returnSecs = (opts.returnDays or 14) * DAY
    local departSecs = opts.departSeconds or 30
    local prevObs = state.observedAt
    local oldRanks, newRanks = state.ranks or {}, scan.ranks
    state.formers = state.formers or {}

    local function add(e)
        e.lo = e.lo or prevObs
        e.hi = e.hi or now
        events[#events + 1] = e
    end

    -- Rank structure first: a renamed, added or removed rank must not read as
    -- a wave of promotions.
    local structure = not sameList(oldRanks, newRanks)
    -- During a structure change, a member's move is reported only if evidence
    -- confirms it, and evidence names a member, not a GUID: it may confirm a
    -- name only one changed member carries (connected realms repeat names).
    local rankCandidates = {}
    if structure then
        add({ kind = "RANKS", from = table.concat(oldRanks, ", "), to = table.concat(newRanks, ", ") })
        for guid, cur in pairs(scan.members) do
            local prev = state.members[guid]
            if prev and not prev.rankLost and oldRanks[prev.rank + 1] ~= newRanks[cur.rank + 1] then
                rankCandidates[cur.name] = (rankCandidates[cur.name] or 0) + 1
            end
        end
    end

    for guid, cur in pairs(scan.members) do
        local prev = state.members[guid]
        if not prev then
            local former = state.formers[guid]
            if former then
                add({ kind = "REJOIN", guid = guid, name = cur.name, from = former.rankName,
                      to = newRanks[cur.rank + 1], leftAt = former.leftAt })
                state.formers[guid] = nil
            else
                add({ kind = "JOIN", guid = guid, name = cur.name, to = newRanks[cur.rank + 1] })
            end
            state.members[guid] = record(cur, now)
        else
            -- Back after one missing scan: never gone.
            prev.missingSince, prev.missingAfter = nil, nil
            -- Their rank was lost to a structure change while they were missing:
            -- adopt the current one, report nothing.
            if prev.rankLost then prev.rank, prev.rankLost = cur.rank, nil end

            if prev.name ~= cur.name then
                add({ kind = "NAME", guid = guid, name = cur.name, from = prev.name, to = cur.name })
                prev.name = cur.name
            end

            if prev.rank ~= cur.rank or structure then
                local fromName, toName = oldRanks[prev.rank + 1], newRanks[cur.rank + 1]
                if not structure then
                    add({ kind = cur.rank < prev.rank and "PROMOTE" or "DEMOTE", guid = guid, name = cur.name,
                          from = fromName, to = toName })
                elseif fromName ~= toName then
                    -- Compare by name across the old and new structure; report only
                    -- what the shell can confirm (a message or the server log).
                    local was = fromName and indexOf(newRanks, fromName)
                    local kind = (was == nil) and "RANK" or (cur.rank + 1 < was and "PROMOTE" or "DEMOTE")
                    local confirmed = opts.confirmRank and rankCandidates[cur.name] == 1
                        and opts.confirmRank(kind, cur.name, toName, prevObs, now)
                    if confirmed then
                        add({ kind = kind, guid = guid, name = cur.name, from = fromName, to = toName })
                    end
                end
                prev.rank = cur.rank
            end

            if type(cur.level) == "number" and type(prev.level) == "number" and cur.level > prev.level then
                local milestone = math.floor(cur.level / 10) > math.floor(prev.level / 10)
                if cur.level >= levelMin or milestone then
                    add({ kind = "LEVEL", guid = guid, name = cur.name, from = prev.level, to = cur.level })
                end
            end
            prev.level = cur.level
            prev.class = cur.class

            if (prev.note or "") ~= (cur.note or "") then
                add({ kind = "NOTE", guid = guid, name = cur.name, from = prev.note or "", to = cur.note or "" })
            end
            prev.note = cur.note

            -- Officer notes: unreadable is not empty. Only a character that can
            -- read them compares or updates them; the first readable value seeds.
            if scan.canViewOfficer and cur.onote ~= nil then
                if prev.onote ~= nil and prev.onote ~= cur.onote then
                    add({ kind = "ONOTE", guid = guid, name = cur.name, from = prev.onote, to = cur.onote })
                end
                prev.onote = cur.onote
            end

            -- Back after a long absence: only with proof. This member's own last
            -- observation (not the guild's: they may have been missing from it)
            -- must already have shown N days away, and this one real activity.
            -- Activity means they logged in since we last looked at them: online
            -- now, or last online more recently than our last look (by a margin
            -- for the whole-hour rounding). A wobble in a month-sized total is not.
            local seen = lastSeen(cur, now)
            local seenAt = prev.seenAt or prevObs
            if seen and prev.lastSeenAt then
                local awayProven = (not prev.online) and (seenAt - prev.lastSeenAt) >= returnSecs
                local active = cur.online
                    or (type(cur.lastOnlineHours) == "number"
                        and cur.lastOnlineHours * HOUR * (1 + MONTH_WOBBLE) + HOUR < now - seenAt)
                if awayProven and active then
                    add({ kind = "RETURN", guid = guid, name = cur.name,
                          days = math.floor((seenAt - prev.lastSeenAt) / DAY) })
                end
            end
            if seen and (not prev.lastSeenAt or seen > prev.lastSeenAt) then prev.lastSeenAt = seen end
            prev.online = cur.online
            prev.seenAt = now
        end
    end

    -- Departures: two complete scans, unless a message confirms it. A message
    -- names a member, not a GUID: it confirms only a name no other missing
    -- member shares.
    local missingNames = {}
    for guid, prev in pairs(state.members) do
        if not scan.members[guid] then missingNames[prev.name] = (missingNames[prev.name] or 0) + 1 end
    end
    for guid, prev in pairs(state.members) do
        if not scan.members[guid] then
            if not prev.missingSince then
                prev.missingSince, prev.missingAfter = now, prevObs
            end
            local lo, hi = prev.missingAfter, prev.missingSince
            local confirmed = opts.confirmLeave and missingNames[prev.name] == 1
                and opts.confirmLeave(prev.name, lo, hi)
            if confirmed or (now - prev.missingSince) >= departSecs then
                local rankName = (not prev.rankLost) and oldRanks[(prev.rank or 0) + 1] or nil
                add({ kind = "LEAVE", guid = guid, name = prev.name, from = rankName,
                      level = prev.level, class = prev.class, lo = lo, hi = hi })
                state.formers[guid] = { name = prev.name, leftAt = hi, rankName = rankName, level = prev.level }
                state.members[guid] = nil
            end
        end
    end

    -- Members still missing keep rank INDICES into the old structure: move them
    -- to the new one by name, or mark the rank lost (never a false change).
    if structure then
        for guid, prev in pairs(state.members) do
            if not scan.members[guid] and not prev.rankLost then
                local name = oldRanks[(prev.rank or 0) + 1]
                local idx = name and indexOf(newRanks, name)
                if idx then prev.rank = idx - 1 else prev.rankLost = true end
            end
        end
    end

    if scan.motd ~= nil then
        if state.motd ~= nil and state.motd ~= scan.motd then
            add({ kind = "MOTD", from = state.motd, to = scan.motd })
        end
        state.motd = scan.motd
    end

    state.ranks = newRanks
    state.observedAt = now
    if scan.canViewOfficer then state.onoteBaselineAt = now end
    return events, false
end

-- Caps: formers at most `max` (default 500) and `days` old (default 365).
function Roster.PruneFormers(state, now, max, days)
    local list = {}
    for guid, f in pairs(state.formers or {}) do
        if now - (f.leftAt or 0) > (days or 365) * DAY then state.formers[guid] = nil
        else list[#list + 1] = { guid = guid, at = f.leftAt or 0 } end
    end
    max = max or 500
    if #list > max then
        table.sort(list, function(a, b) return a.at < b.at end)
        for i = 1, #list - max do state.formers[list[i].guid] = nil end
    end
end
