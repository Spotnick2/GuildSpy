-- Log.lua: what happened, kept per guild, shown in chat and in the digest.
--
-- Entries are stored as data and rendered to text when shown (so a later
-- wording change rewrites old entries too):
--   { seq, at, approx, kind, guid, name, class, actor, from, to, how,
--     lastStep, days, level, leftAt, after }
-- approx: false = exact (a live system message), true = to the hour (the
-- guild event log), nil = when a scan noticed it; `after` is the previous
-- scan's time, so a scan-noticed change happened in (after, at].
-- seq is monotonic account-wide (GuildSpyDB.nextSeq); the digest's boundary
-- is a seq, never a time (docs/PLAN.md "Login digest").

local ADDON = ...
GuildSpy = GuildSpy or {}
local Log = {}
GuildSpy.Log = Log

Log.MAX_ENTRIES = 1500
Log.MAX_DAYS = 180
Log.DIGEST_LINES = 8
-- A chat link that opens the log window (UI.lua handles "addon:guildspy").
Log.OPEN_LINK = "|Haddon:guildspy:log|h|cff7fd4ff[open log]|r|h"

-- GRM's palette (GRM_Core.lua:1187).
Log.COLORS = {
    JOIN = "80ff00", REJOIN = "80ff00", LEAVE = "a0a0a0", PROMOTE = "ffe900", DEMOTE = "e8630c",
    RANK = "ffffff", RANKS = "ffffff", LEVEL = "3d9bff", NOTE = "ff99ff", ONOTE = "ff18ed",
    NAME = "e6d19e", RETURN = "00ffde", MOTD = "00ccff",
}
-- Reaching the level cap (#34): a LEVEL entry to the cap, decided when shown
-- (so a new cap re-reads old entries). GRM's "Level Cap! Hurray!" is the model.
Log.CAP_COLOR = "ffd100"
function Log.IsCap(e)
    if e.kind ~= "LEVEL" then return false end
    local api = GuildSpy.API
    local cap = api and api.LevelCap and api.LevelCap()
    return cap ~= nil and e.to == cap
end

-- Digest order: membership, then rank, then notes, then levels.
Log.PRIORITY = { LEAVE = 1, JOIN = 2, REJOIN = 2, PROMOTE = 3, DEMOTE = 3, RANK = 3, RANKS = 3, NAME = 4,
                 RETURN = 5, ONOTE = 6, NOTE = 7, MOTD = 8, LEVEL = 9 }
-- Summary words, in the order the summary lists them.
Log.SUMMARY = {
    { "JOIN", "joined" }, { "REJOIN", "rejoined" }, { "LEAVE", "left" }, { "PROMOTE", "promoted" },
    { "DEMOTE", "demoted" }, { "RANK", "changed rank" }, { "NAME", "renamed" }, { "RETURN", "came back" },
    { "NOTE", "note edits" }, { "ONOTE", "officer note edits" }, { "LEVEL", "level-ups" },
    { "RANKS", "rank changes" }, { "MOTD", "new MOTD" },
}

-- The log window's filters: each kind belongs to one.
Log.CATEGORIES = {
    { key = "members", label = "Members", empty = "membership changes", kinds = { JOIN = true, REJOIN = true, LEAVE = true, RETURN = true, NAME = true } },
    { key = "ranks", label = "Ranks", empty = "rank changes", kinds = { PROMOTE = true, DEMOTE = true, RANK = true, RANKS = true } },
    { key = "notes", label = "Notes", empty = "note changes", kinds = { NOTE = true, ONOTE = true } },
    { key = "levels", label = "Levels", empty = "level changes", kinds = { LEVEL = true } },
    { key = "motd", label = "MOTD", empty = "message-of-the-day changes", kinds = { MOTD = true } },
}

-- The window's summary line (#19): entries counted past the "new" boundary,
-- so levels read "level changes" (one entry can cover several levels).
Log.NEW_GROUPS = {
    { one = "joined", many = "joined", color = "JOIN", kinds = { JOIN = true, REJOIN = true } },
    { one = "left", many = "left", color = "LEAVE", kinds = { LEAVE = true } },
    { one = "rank change", many = "rank changes", color = "PROMOTE",
      kinds = { PROMOTE = true, DEMOTE = true, RANK = true, RANKS = true } },
    { one = "renamed", many = "renamed", color = "NAME", kinds = { NAME = true } },
    { one = "returned", many = "returned", color = "RETURN", kinds = { RETURN = true } },
    { one = "note edit", many = "note edits", color = "NOTE", kinds = { NOTE = true, ONOTE = true } },
    { one = "level change", many = "level changes", color = "LEVEL", kinds = { LEVEL = true } },
    { one = "new MOTD", many = "new MOTDs", color = "MOTD", kinds = { MOTD = true } },
}
-- The window's time scopes.
Log.SCOPES = {
    { key = "all", label = "All history" },
    { key = "today", label = "Today" },
    { key = "week", label = "Last 7 days", days = 7 },
    { key = "month", label = "Last 30 days", days = 30 },
}
-- A scan-detected change seen more than this after the previous scan has an
-- uncertain time: it happened somewhere in between.
Log.SCAN_GAP = 10 * 60

-- An officer-note entry is hidden everywhere from a character that can't
-- read officer notes, even though the account-wide log holds it.
function Log.Visible(e, canViewOfficer)
    return e.kind ~= "ONOTE" or canViewOfficer == true
end

local function who(name, class)
    local colors = rawget(_G, "RAID_CLASS_COLORS")
    local c = class and type(colors) == "table" and colors[class]
    if c and c.colorStr then return "|c" .. c.colorStr .. name .. "|r" end
    return name or "?"
end

local function quote(s) return '"' .. (s or "") .. '"' end

function Log.Ago(seconds)
    seconds = math.max(0, seconds or 0)
    local d, h, m = math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600), math.floor(seconds % 3600 / 60)
    if d > 0 then return d .. "d " .. h .. "h" end
    if h > 0 then return h .. "h " .. m .. "m" end
    return m .. "m"
end

-- The entry as one line of text, without its colour.
function Log.Text(e, now)
    local n = who(e.name, e.class)
    local k = e.kind
    local by = e.actor and (e.lastStep and (" (last step by " .. e.actor .. ")") or nil)
    if k == "JOIN" then
        return n .. " joined the guild"
    elseif k == "REJOIN" then
        return n .. " rejoined the guild" .. (e.leftAt and (" (left " .. Log.Ago((now or e.at) - e.leftAt) .. " ago"
            .. (e.from and (" as " .. e.from) or "") .. ")") or "")
    elseif k == "LEAVE" then
        local what = (e.how == "kick" and (" was kicked" .. (e.actor and (" by " .. e.actor) or "")))
            or (e.how == "quit" and " left the guild") or " is no longer in the guild"
        local detail = {}
        if e.level then detail[#detail + 1] = "level " .. e.level end
        if e.from then detail[#detail + 1] = e.from end
        return n .. what .. (#detail > 0 and (" (" .. table.concat(detail, ", ") .. ")") or "")
    elseif k == "PROMOTE" or k == "DEMOTE" or k == "RANK" then
        local verb = (k == "PROMOTE" and "promoted") or (k == "DEMOTE" and "demoted") or "moved"
        local span = " from " .. (e.from or "?") .. " to " .. (e.to or "?")
        if e.actor and not e.lastStep then return e.actor .. " " .. verb .. " " .. n .. span end
        return n .. " was " .. verb .. span .. (by or "")
    elseif k == "RANKS" then
        return "Guild ranks changed: " .. (e.to or "")
    elseif k == "NOTE" then
        return n .. "'s note: " .. quote(e.from) .. " -> " .. quote(e.to)
    elseif k == "ONOTE" then
        return n .. "'s officer note: " .. quote(e.from) .. " -> " .. quote(e.to)
    elseif k == "LEVEL" then
        local gained = (e.to or 0) - (e.from or 0)
        if Log.IsCap(e) then
            return n .. " reached |cff" .. Log.CAP_COLOR .. "level " .. tostring(e.to) .. ", the level cap!|r"
                .. (gained > 1 and (" (+" .. gained .. ")") or "")
        end
        return n .. " reached level " .. tostring(e.to) .. (gained > 1 and (" (+" .. gained .. ")") or "")
    elseif k == "NAME" then
        return who(e.from, e.class) .. " is now " .. n
    elseif k == "RETURN" then
        return n .. " is back after at least " .. tostring(e.days) .. " days away"
    elseif k == "MOTD" then
        return "New message of the day: " .. quote(e.to)
    end
    return k .. " " .. tostring(e.name)
end

function Log.Line(e, now)
    return "|cff" .. (Log.COLORS[e.kind] or "ffffff") .. Log.Text(e, now) .. "|r"
end

-- Text without colour codes (and links reduced to their text).
function Log.Plain(s)
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1"))
end

-- The local midnight that starts `now`'s day, or the day `back` days before
-- it. The calendar date decides, not 86400-second steps, and the clock-change
-- flag is left to `time` (the one of that midnight, not of now: #22 review).
function Log.Midnight(now, back)
    local t = date("*t", now)
    return time({ year = t.year, month = t.month, day = t.day - (back or 0), hour = 0, min = 0, sec = 0 })
end

-- The first time a Log.SCOPES key lets through (nil: everything).
function Log.ScopeSince(key, now)
    if key == "today" then return Log.Midnight(now) end
    for _, s in ipairs(Log.SCOPES) do
        if s.key == key and s.days then return now - s.days * 86400 end
    end
    return nil
end

-- Whether the entry's time is a guess: the hour from the guild event log, or
-- a change a scan found long after the previous one.
function Log.Approx(e)
    if e.approx ~= nil then return e.approx == true end
    return type(e.after) == "number" and (e.at or 0) - e.after > Log.SCAN_GAP
end

local function relative(at, now)
    local d = math.max(0, now - at)
    if d < 60 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    if at >= Log.Midnight(now, 1) then return "Yesterday" end
    return date("%b ", at) .. tonumber(date("%d", at))
end
Log.Relative = relative

-- The row's time: "4h ago", "about 3h ago", "Yesterday", "Oct 3". Not "~":
-- the game font draws it as a raised bar, so "~26m ago" read as a macron in game.
function Log.When(e, now)
    local s = relative(e.at or now, now)
    if Log.Approx(e) and s:find("ago", 1, true) then return "about " .. s end
    return s
end

-- What the entry's time means, for its tooltip.
function Log.Provenance(e)
    if e.approx == false then return "Exact time: seen live." end
    if e.approx == true then return "Time to the hour, from the guild event log." end
    if Log.Approx(e) then
        return "Noticed by a scan: it happened between " .. date("%Y-%m-%d %H:%M", e.after) .. " and "
            .. date("%Y-%m-%d %H:%M", e.at) .. "."
    end
    return "When a scan noticed it."
end

local MUTED, PLAIN = "8f8f8f", "ffffff"
local function paint(hex, s) return "|cff" .. hex .. s .. "|r" end
local function person(name, class)
    local colors = rawget(_G, "RAID_CLASS_COLORS")
    local c = class and type(colors) == "table" and colors[class]
    if c and c.colorStr then return "|c" .. c.colorStr .. (name or "?") .. "|r" end
    return paint(PLAIN, name or "?")
end

-- The entry as a window row: name, verb, the changed value highlighted, the
-- actor. Chat and the digest keep Log.Line. `classOf(name)` colours the
-- actor when they're a known member.
function Log.Row(e, now, classOf)
    local k, hi = e.kind, Log.COLORS[e.kind] or PLAIN
    local n = person(e.name, e.class)
    local function by()
        if not e.actor then return "" end
        local a = person(e.actor, classOf and classOf(e.actor))
        if e.lastStep then return paint(MUTED, " (last step by ") .. a .. paint(MUTED, ")") end
        return " by " .. a
    end
    if k == "JOIN" then
        return n .. " " .. paint(hi, "joined the guild")
    elseif k == "REJOIN" then
        local was = e.leftAt and paint(MUTED, " (left " .. Log.Ago((now or e.at) - e.leftAt) .. " ago"
            .. (e.from and (" as " .. e.from) or "") .. ")") or ""
        return n .. " " .. paint(hi, "rejoined the guild") .. was
    elseif k == "LEAVE" then
        local what = (e.how == "kick" and "was kicked") or (e.how == "quit" and "left the guild")
            or "is no longer in the guild"
        local detail = {}
        if e.level then detail[#detail + 1] = "level " .. e.level end
        if e.from then detail[#detail + 1] = e.from end
        return n .. " " .. paint(hi, what) .. (e.how == "kick" and by() or "")
            .. (#detail > 0 and paint(MUTED, " (" .. table.concat(detail, ", ") .. ")") or "")
    elseif k == "PROMOTE" or k == "DEMOTE" or k == "RANK" then
        local verb = (k == "PROMOTE" and "promoted") or (k == "DEMOTE" and "demoted") or "moved"
        return n .. " " .. verb .. " to " .. paint(hi, e.to or "?") .. by()
    elseif k == "RANKS" then
        return "Guild ranks changed: " .. paint(hi, e.to or "")
    elseif k == "NOTE" or k == "ONOTE" then
        local what = k == "NOTE" and "note" or "officer note"
        if (e.to or "") == "" then return n .. " " .. what .. " " .. paint(MUTED, "cleared") end
        return n .. " " .. what .. ": " .. paint(hi, quote(e.to))
    elseif k == "LEVEL" then
        local gained = (e.to or 0) - (e.from or 0)
        if Log.IsCap(e) then
            local capped = paint(Log.CAP_COLOR, "level " .. tostring(e.to) .. ", the level cap!")
            if gained > 1 then return n .. " leveled from " .. e.from .. " to " .. capped end
            return n .. " reached " .. capped
        end
        if gained > 1 then return n .. " leveled from " .. e.from .. " to " .. paint(hi, tostring(e.to)) end
        return n .. " reached level " .. paint(hi, tostring(e.to))
    elseif k == "NAME" then
        return person(e.from, e.class) .. " is now " .. n
    elseif k == "RETURN" then
        return n .. " is back after " .. paint(hi, tostring(e.days) .. "+ days")
    elseif k == "MOTD" then
        return "New MOTD: " .. paint(hi, quote(e.to))
    end
    return Log.Line(e, now)
end

-- The summary groups with entries past `since` this character may see:
-- { { n, word, color }, ... } in Log.NEW_GROUPS order.
function Log.NewCounts(gs, since, canViewOfficer)
    local out = {}
    for _, g in ipairs(Log.NEW_GROUPS) do
        local n = 0
        for _, e in ipairs(gs and gs.log or {}) do
            if e.seq > (since or 0) and g.kinds[e.kind] and Log.Visible(e, canViewOfficer) then n = n + 1 end
        end
        if n > 0 then out[#out + 1] = { n = n, word = n == 1 and g.one or g.many, color = Log.COLORS[g.color] } end
    end
    return out
end

-- "New: 2 joined · 1 left · 12 level changes", or "No new activity". With
-- `limit`, only the first `limit` groups, then "+N more" (N entries), so a
-- line too long for the panel still counts everything (#22 review).
function Log.NewSummary(gs, since, canViewOfficer, limit)
    local parts, more = {}, 0
    for i, c in ipairs(Log.NewCounts(gs, since, canViewOfficer)) do
        if limit and i > limit then
            more = more + c.n
        else
            parts[#parts + 1] = paint(c.color, tostring(c.n)) .. " " .. c.word
        end
    end
    if #parts == 0 then return paint(MUTED, "No new activity") end
    if more > 0 then parts[#parts + 1] = "+" .. more .. " more" end
    return "New: " .. table.concat(parts, paint(MUTED, "  \194\183  "))
end

-- The member's notes as they are now (the last complete scan), for a row's
-- tooltip (#25): { { label, text, color }, ... }. The officer note only while
-- this character can read it (unreadable isn't empty). An empty note, a former
-- member and a guild-wide entry give nothing.
function Log.MemberNotes(gs, e, canViewOfficer)
    local m = e.guid and type(gs.members) == "table" and gs.members[e.guid]
    if type(m) ~= "table" then return {} end
    local out = {}
    if type(m.note) == "string" and m.note ~= "" then
        out[#out + 1] = { label = "Note", text = m.note, color = Log.COLORS.NOTE }
    end
    if canViewOfficer == true and type(m.onote) == "string" and m.onote ~= "" then
        out[#out + 1] = { label = "Officer note", text = m.onote, color = Log.COLORS.ONOTE }
    end
    return out
end

-- Whether an entry belongs to the rank named `rank` (#23): its member holds
-- it now, left from it, or a rank change went from or to it. Guild-wide
-- entries (MOTD, rank structure) belong to no rank.
function Log.InRank(e, gs, rank)
    if (e.kind == "PROMOTE" or e.kind == "DEMOTE" or e.kind == "RANK") and (e.from == rank or e.to == rank) then
        return true
    end
    if e.kind == "LEAVE" and e.from == rank then return true end
    if not e.guid then return false end
    local m = type(gs.members) == "table" and gs.members[e.guid]
    if type(m) == "table" then
        return type(m.rank) == "number" and type(gs.ranks) == "table" and gs.ranks[m.rank + 1] == rank
    end
    local f = type(gs.formers) == "table" and gs.formers[e.guid]
    return type(f) == "table" and f.rankName == rank
end

-- The log window's rows: the entries this character may see, newest first,
-- in `opts.category` (a Log.CATEGORIES key; nil = all), at or after
-- `opts.since` (nil = any time) and containing `opts.query` (plain,
-- case-insensitive, matched against the shown text, so a member's name, an
-- officer's or a rank all find it), in `opts.rank` (a rank name, see
-- Log.InRank; nil = all).
function Log.Filter(gs, opts, now)
    opts = opts or {}
    local kinds
    for _, c in ipairs(Log.CATEGORIES) do
        if c.key == opts.category then kinds = c.kinds end
    end
    local q = opts.query and opts.query:lower():match("^%s*(.-)%s*$")
    if q == "" then q = nil end
    local out = {}
    local log = gs.log or {}
    for i = #log, 1, -1 do
        local e = log[i]
        if Log.Visible(e, opts.canViewOfficer) and (not kinds or kinds[e.kind])
                and (not opts.since or (e.at or 0) >= opts.since)
                and (not opts.rank or Log.InRank(e, gs, opts.rank))
                and (not q or Log.Plain(Log.Text(e, now)):lower():find(q, 1, true)) then
            out[#out + 1] = e
        end
    end
    return out
end

-- Appends an event as an entry; caps are enforced here, on every append.
function Log.Add(db, gs, ev, now)
    gs.log = gs.log or {}
    db.nextSeq = (db.nextSeq or 1)
    local e = { seq = db.nextSeq, at = ev.at or now, approx = ev.approx, kind = ev.kind, guid = ev.guid,
                name = ev.name, class = ev.class, actor = ev.actor, from = ev.from, to = ev.to, how = ev.how,
                lastStep = ev.lastStep, days = ev.days, level = ev.level, leftAt = ev.leftAt, after = ev.lo }
    db.nextSeq = db.nextSeq + 1
    gs.log[#gs.log + 1] = e
    Log.Prune(gs, now)
    return e
end

function Log.Prune(gs, now)
    local log = gs.log or {}
    local kept = {}
    for _, e in ipairs(log) do
        -- Every expired entry, not only a prefix: enriched times aren't in seq order.
        if now - (e.at or now) <= Log.MAX_DAYS * 86400 then kept[#kept + 1] = e end
    end
    if #kept > Log.MAX_ENTRIES then
        local trimmed = {}
        for i = #kept - Log.MAX_ENTRIES + 1, #kept do trimmed[#trimmed + 1] = kept[i] end
        kept = trimmed
    end
    if #kept ~= #log then gs.log = kept end
end

-- Fills in what later evidence tells about an entry already recorded.
function Log.Enrich(e, attr)
    if attr.actor and not e.actor then e.actor = attr.actor end
    if attr.how and not e.how then e.how = attr.how end
    if attr.lastStep then e.lastStep = true end
    if attr.at and e.approx ~= false then e.at, e.approx = attr.at, attr.approx end
end

-- The digest: one summary line, then up to DIGEST_LINES details, most
-- important first. Returns the lines (nothing new: an empty list), the
-- highest seq looked at, and the highest officer-note seq looked at (nil
-- when the viewer can't read officer notes).
--
-- Officer-note entries have their own boundary (shownOnoteSeq): a character
-- that can't read them moves shownSeq past them, but the next officer still
-- gets them in a digest.
function Log.Digest(gs, canViewOfficer, now)
    local fresh, counts = {}, {}
    local shown, shownOnote = gs.shownSeq or 0, gs.shownOnoteSeq or 0
    local top, topOnote = shown, canViewOfficer and shownOnote or nil
    for _, e in ipairs(gs.log or {}) do
        if e.seq > top then top = e.seq end
        local new
        if e.kind == "ONOTE" then
            new = canViewOfficer and e.seq > shownOnote
            if new and e.seq > topOnote then topOnote = e.seq end
        else
            new = e.seq > shown
        end
        if new then
            fresh[#fresh + 1] = e
            counts[e.kind] = (counts[e.kind] or 0) + 1
        end
    end
    if #fresh == 0 then return {}, top, topOnote end
    local parts = {}
    for _, s in ipairs(Log.SUMMARY) do
        if counts[s[1]] then parts[#parts + 1] = counts[s[1]] .. " " .. s[2] end
    end
    local since = gs.shownAt and (" since " .. Log.Ago(now - gs.shownAt) .. " ago") or ""
    local lines = { "|cff7fd4ffGuildSpy|r" .. since .. ": " .. table.concat(parts, ", ") .. " " .. Log.OPEN_LINK }
    -- A level-up to the cap comes before the other level-ups (#34).
    local function prio(e) return Log.IsCap(e) and (Log.PRIORITY.LEVEL - 0.5) or Log.PRIORITY[e.kind] or 99 end
    table.sort(fresh, function(a, b)
        local pa, pb = prio(a), prio(b)
        if pa ~= pb then return pa < pb end
        return a.seq < b.seq
    end)
    for i = 1, math.min(Log.DIGEST_LINES, #fresh) do lines[#lines + 1] = "  " .. Log.Line(fresh[i], now) end
    if #fresh > Log.DIGEST_LINES then
        lines[#lines + 1] = "  ... and " .. (#fresh - Log.DIGEST_LINES) .. " more " .. Log.OPEN_LINK
    end
    return lines, top, topOnote
end
