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
-- against this session's cap (API.LevelCap). GRM's "Level Cap! Hurray!" is the model.
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

-- Text is stored canonical (as received, unescaped, #36); every rendering
-- escapes every pipe, so a "|" in a name or note can't start markup and two
-- literal pipes still show as two (#39 Codex review: a stored "||" can't tell
-- an escape from two pipes, so no run is left alone).
function Log.Esc(s)
    if type(s) ~= "string" or not s:find("|", 1, true) then return s end
    return (s:gsub("|", "||"))
end

local TEXT_FIELDS = { "name", "actor", "from", "to", "origin", "reporter" }
function Log.Safe(e)
    local view
    for _, f in ipairs(TEXT_FIELDS) do
        local v = e[f]
        if type(v) == "string" and v:find("|", 1, true) then
            view = view or setmetatable({}, { __index = e })
            view[f] = Log.Esc(v)
        end
    end
    return view or e
end

-- The entry as one line of text, without its colour.
function Log.Text(e, now)
    e = Log.Safe(e)
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
    -- An escaped pipe ("||") is text, not the start of a code (#39 review).
    s = s:gsub("||", "\1")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1")
    return (s:gsub("\1", "|"))
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
-- Who observed it, when it isn't this account (#36): nil for this account's own.
function Log.Source(e)
    if e.trust == "guild" then return "Reported by " .. tostring(e.reporter or e.origin or "a guildmate") end
    if e.here == false then return "Seen on " .. (e.origin or "your other account") end
    return nil
end

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
local rowText
-- A guildmate's report carries a mark (#36): it's their observation, not mine.
function Log.Row(e, now, classOf)
    local s = rowText(e, now, classOf)
    if e.trust == "guild" then s = s .. paint(MUTED, "  (reported)") end
    return s
end

function rowText(e, now, classOf)
    e = Log.Safe(e)
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
                and (not q or (Log.Plain(Log.Text(e, now)) .. " " .. (Log.Source(e) or "")):lower():find(q, 1, true)) then
            out[#out + 1] = e
        end
    end
    return out
end

-- Appends an event as an entry; caps are enforced here, on every append.
function Log.Add(db, gs, ev, now)
    gs.log = gs.log or {}
    db.nextSeq = (db.nextSeq or 1)
    local at = ev.at or now
    local e = { seq = db.nextSeq, at = at, approx = ev.approx, kind = ev.kind, guid = ev.guid,
                name = ev.name, class = ev.class, actor = ev.actor, from = ev.from, to = ev.to, how = ev.how,
                lastStep = ev.lastStep, days = ev.days, level = ev.level, leftAt = ev.leftAt, after = ev.lo,
                -- The observation (#36, docs/SYNC.md §1).
                uid = Log.NewUid(), lo = ev.lo, hi = ev.hi,
                obs = (ev.approx == false and ev.at) or ev.hi or at,
                origin = ev.origin or Log.Origin(), trust = "self", here = true, rev = 1, chg = Log.NextChg(gs) }
    db.nextSeq = db.nextSeq + 1
    gs.log[#gs.log + 1] = e
    Log.Prune(gs, now, e)
    return e
end

------------------------------------------------------------
-- Observations (#36, docs/SYNC.md): identity, receiving, retention
------------------------------------------------------------

Log.GUILD_MAX_ENTRIES, Log.GUILD_MAX_DAYS = 500, 60
-- What a guildmate may report (never officer notes, the MOTD or rank structure).
Log.PUBLIC_KINDS = { JOIN = true, REJOIN = true, LEAVE = true, PROMOTE = true, DEMOTE = true, RANK = true,
                     NAME = true, NOTE = true, LEVEL = true, RETURN = true }
Log.ALL_KINDS = { ONOTE = true, MOTD = true, RANKS = true }
for k in pairs(Log.PUBLIC_KINDS) do Log.ALL_KINDS[k] = true end
-- What its observer may improve later (a higher rev): the rest is the observation.
Log.MUTABLE = { "at", "approx", "actor", "how", "lastStep" }
-- What a received entry may carry: a fresh copy of these, never the table itself.
Log.FIELDS = { "uid", "rev", "kind", "guid", "name", "class", "actor", "from", "to", "how", "lastStep",
               "days", "level", "leftAt", "at", "approx", "lo", "hi", "obs", "origin" }

-- A uid is `<writer>:<n>`: writer is random per session and never stored (a
-- stored one would be copied with the file, AltStableSync's lesson).
local writer, counter = nil, 0
function Log.NewUid()
    if not writer then
        writer = string.format("%x%04x", (time and time() or 0) % 1048576, math.random(0, 65535))
    end
    counter = counter + 1
    return writer .. ":" .. counter
end

-- This client's change counter for the guild: strictly increasing, persisted,
-- and never below the clock (milliseconds): if the saved file goes back (a
-- crash before it was written, a reset guild), new changes still number above
-- any cursor a peer holds (#40 review). Account sync pages by it; wall time
-- stays for display and retention.
function Log.NextChg(gs)
    local floor = math.floor((time and time() or 0) * 1000)
    gs.nextChg = math.max((tonumber(gs.nextChg) or 0) + 1, floor)
    return gs.nextChg
end

-- The observing character: "First Surname".
function Log.Origin()
    local api = GuildSpy.API
    return api and api.PlayerFullName and api.PlayerFullName() or nil
end

-- Identity is (namespace, uid): "self" for my accounts, "g:<reporter>" for a guildmate.
function Log.Ns(e) return e.ns or "self" end
local function quotaOf(e) return e.trust == "guild" and "guild" or "self" end
local function observed(e) return tonumber(e.obs) or tonumber(e.at) or 0 end

-- Retention order (#36, SYNC.md §7): observed time, then namespace, then uid.
-- Never arrival or seq, so two accounts keep the same records.
function Log.Before(a, b)
    local oa, ob = observed(a), observed(b)
    if oa ~= ob then return oa < ob end
    local na, nb = Log.Ns(a), Log.Ns(b)
    if na ~= nb then return na < nb end
    return tostring(a.uid) < tostring(b.uid)
end

local function limits(q)
    if q == "guild" then return Log.GUILD_MAX_ENTRIES, Log.GUILD_MAX_DAYS end
    return Log.MAX_ENTRIES, Log.MAX_DAYS
end

-- For a batch of receipts (a page, #40 review): uids indexed once, counts per
-- quota kept as entries are admitted; the caller prunes once at the end.
function Log.NewBatch(gs, now)
    local b = { byUid = {}, count = { self = 0, guild = 0 }, now = now }
    for i, e in ipairs(gs.log or {}) do
        if e.uid then
            local list = b.byUid[e.uid] or {}
            list[#list + 1] = e
            b.byUid[e.uid] = list
        end
        local _, days = limits(quotaOf(e))
        if now - observed(e) <= days * 86400 then b.count[quotaOf(e)] = b.count[quotaOf(e)] + 1 end
    end
    return b
end

-- Whether a received entry keeps its place: young enough, and room in its
-- quota or newer (in retention order) than the oldest kept.
function Log.Admits(gs, e, now, batch)
    local q = quotaOf(e)
    local max, days = limits(q)
    if now - observed(e) > days * 86400 then return false end
    if batch and batch.count[q] < max then return true end
    local n, oldest = 0, nil
    for _, x in ipairs(gs.log or {}) do
        if quotaOf(x) == q and now - observed(x) <= days * 86400 then
            n = n + 1
            if not oldest or Log.Before(x, oldest) then oldest = x end
        end
    end
    return n < max or Log.Before(oldest, e)
end

-- Legacy entries (before #36) become this account's observations, observer
-- unknown (the file is account-wide); their interval is a fallback.
function Log.Migrate(gs)
    for _, e in ipairs(gs.log or {}) do
        if type(e.uid) ~= "string" then
            e.uid, e.trust, e.here, e.origin, e.ns, e.reporter = Log.NewUid(), "self", true, nil, nil, nil
            e.lo, e.hi, e.obs = e.after, e.at, e.at
            e.rev, e.chg = 1, Log.NextChg(gs)
        end
    end
end

local CONTROL = "[%z\1-\31\127]"
local function str(v, max) return v == nil or (type(v) == "string" and #v <= max and not v:find(CONTROL)) end
local function num(v) return v == nil or (type(v) == "number" and v == v and v > -1e12 and v < 1e12) end
local NO_GUID = { MOTD = true, RANKS = true }

-- A received entry's shape (#36, SYNC.md §6). One bad field refuses it.
function Log.Valid(e, via, now)
    if type(e) ~= "table" then return false, "not an entry" end
    local kinds = via == "guild" and Log.PUBLIC_KINDS or Log.ALL_KINDS
    if not kinds[e.kind] then return false, "kind" end
    if type(e.uid) ~= "string" or #e.uid > 40 or not e.uid:find("^[%w]+:%d+$") then return false, "uid" end
    if not (type(e.rev) == "number" and e.rev >= 1 and e.rev <= 1e6 and e.rev == math.floor(e.rev)) then
        return false, "rev"
    end
    if not NO_GUID[e.kind] and not (type(e.guid) == "string" and e.guid:find("^Player%-%d+%-%x+$")) then
        return false, "guid"
    end
    if not (str(e.name, 48) and str(e.actor, 48) and str(e.origin, 48) and str(e.class, 16) and str(e.how, 8)) then
        return false, "text"
    end
    -- from/to by kind (SYNC.md §6): ranks 32 B, names 48 B, notes 31 characters
    -- (UTF-8: up to 124 B); the MOTD and rank lists (my accounts only) longer.
    local size = (e.kind == "NOTE" or e.kind == "ONOTE") and 124 or e.kind == "NAME" and 48
        or (e.kind == "MOTD" or e.kind == "RANKS") and 1024 or 32
    if e.kind == "LEVEL" then
        local api = GuildSpy.API
        local cap = api and api.LevelCap and api.LevelCap() or 200
        -- Each one on its own: a list with a nil first would skip the check (#39 Codex review).
        local function level(v) return type(v) == "number" and v >= 1 and v <= cap and v == math.floor(v) end
        if not (level(e.from) and level(e.to)) then return false, "level" end
    elseif not (str(e.from, size) and str(e.to, size)) then
        return false, "text"
    end
    if not (num(e.at) and num(e.lo) and num(e.hi) and num(e.obs) and num(e.days) and num(e.level) and num(e.leftAt)) then
        return false, "number"
    end
    if type(e.at) ~= "number" or type(e.obs) ~= "number" then return false, "time" end
    if e.lo and e.hi and e.lo > e.hi then return false, "interval" end
    local _, days = limits(via == "guild" and "guild" or "self")
    for _, t in ipairs({ e.obs, e.at, e.hi }) do
        if t and (t > now + 600 or t < now - days * 86400) then return false, "time" end
    end
    if e.approx ~= nil and type(e.approx) ~= "boolean" then return false, "approx" end
    if e.lastStep ~= nil and type(e.lastStep) ~= "boolean" then return false, "lastStep" end
    return true
end

-- Receiving one entry (#36, SYNC.md §2). via "acct" (proven by LibAccountSync)
-- or "guild" (sender = the GUILD transport name). Returns the entry and what
-- happened ("added", "updated", "superseded"), or nil and why not.
function Log.Receive(db, gs, inc, via, sender, now, batch)
    if type(inc) ~= "table" then return nil, "not an entry" end
    local ns
    if via == "guild" then
        ns = "g:" .. tostring(sender)
    elseif via == "acct" then
        ns = (type(inc.ns) == "string" and inc.ns:find("^g:.+")) and inc.ns or "self"
    else
        return nil, "via"
    end
    -- A guildmate's report, direct or forwarded by my other account, keeps the
    -- guild rules: only what that reporter could have sent (#39 review).
    local rules = ns == "self" and "acct" or "guild"
    local ok, why = Log.Valid(inc, rules, now)
    if not ok then return nil, why end
    if ns ~= "self" and (type(inc.origin) ~= "string" or inc.origin ~= ns:sub(3)) then
        return nil, "not the sender's"
    end
    gs.log = gs.log or {}
    local existing, twin, twinAt
    local same = batch and (batch.byUid[inc.uid] or {}) or gs.log
    for i, e in ipairs(same) do
        if e.uid == inc.uid then
            local ens = Log.Ns(e)
            if ens == ns then existing = e
            elseif ns == "self" and e.trust == "guild" and e.origin == inc.origin then twin, twinAt = e, i
            elseif ns ~= "self" and ens == "self" and e.origin == inc.origin then
                return nil, "known"                           -- a guild copy of my own: mine stands
            end
        end
    end
    -- Supersession first: my account's copy replaces a guild copy of the same
    -- observation, whatever the revisions, inheriting nothing.
    if existing then
        if inc.rev > (existing.rev or 1) then
            for _, f in ipairs(Log.MUTABLE) do existing[f] = inc[f] end
            existing.rev, existing.chg = inc.rev, Log.NextChg(gs)
            return existing, "updated"
        end
        return nil, "known"
    end
    local e = {}
    for _, f in ipairs(Log.FIELDS) do e[f] = inc[f] end
    e.after, e.here = e.lo, false
    if ns == "self" then
        e.trust = "self"
    else
        e.trust, e.ns, e.reporter = "guild", ns, ns:sub(3)
    end
    if twin then
        for i, x in ipairs(gs.log) do if x == twin then twinAt = i; break end end
        table.remove(gs.log, twinAt)
    end
    if not Log.Admits(gs, e, now, batch) then
        if twin then table.insert(gs.log, twinAt, twin) end
        return nil, "full"                                    -- not offered again (non-backfill, SYNC.md §7)
    end
    db.nextSeq = db.nextSeq or 1
    e.seq, db.nextSeq = db.nextSeq, db.nextSeq + 1
    e.chg = Log.NextChg(gs)
    gs.log[#gs.log + 1] = e
    if batch then
        local list = batch.byUid[e.uid] or {}
        list[#list + 1] = e
        batch.byUid[e.uid] = list
        if not twin then batch.count[quotaOf(e)] = batch.count[quotaOf(e)] + 1 end
    else
        Log.Prune(gs, now)
    end
    return e, twin and "superseded" or "added"
end

-- Each quota keeps its newest in retention order (#36): my accounts' 1500 /
-- 180 days, guildmates' reports 500 / 60 days. The log keeps its order.
-- `keep`: an observation this account has just made and already shown; it is
-- never the one evicted, even if its observed time is older (#39 review).
-- Usually one entry is over: one linear pass each, no sort (#39 review).
function Log.Prune(gs, now, keep)
    local log = gs.log or {}
    local alive, byQuota = {}, { self = {}, guild = {} }
    for _, e in ipairs(log) do
        local max, days = limits(quotaOf(e))
        if now - observed(e) <= days * 86400 or e == keep then
            alive[#alive + 1] = e
            local list = byQuota[quotaOf(e)]
            list[#list + 1] = e
        end
    end
    local drop = {}
    for q, list in pairs(byQuota) do
        local max = limits(q)
        for _ = 1, #list - max do
            local oldest
            for _, e in ipairs(list) do
                if not drop[e] and e ~= keep and (not oldest or Log.Before(e, oldest)) then oldest = e end
            end
            if not oldest then break end
            drop[oldest] = true
        end
    end
    if #alive == #log and next(drop) == nil then return end
    local kept = {}
    for _, e in ipairs(alive) do if not drop[e] then kept[#kept + 1] = e end end
    gs.log = kept
end

-- Fills in what later evidence tells about an entry already recorded.
function Log.Enrich(e, attr, gs)
    local was = { e.actor, e.how, e.lastStep, e.at, e.approx }
    if attr.actor and not e.actor then e.actor = attr.actor end
    if attr.how and not e.how then e.how = attr.how end
    if attr.lastStep then e.lastStep = true end
    if attr.at and e.approx ~= false then e.at, e.approx = attr.at, attr.approx end
    -- Its observer improved it: a new revision, so my other accounts get it (#36).
    local now = { e.actor, e.how, e.lastStep, e.at, e.approx }
    for i = 1, 5 do
        if was[i] ~= now[i] then
            e.rev = (e.rev or 1) + 1
            if gs then e.chg = Log.NextChg(gs) end
            return
        end
    end
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
        if e.here == false then
            new = false
        elseif e.kind == "ONOTE" then
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
