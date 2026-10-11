-- Log.lua: what happened, kept per guild, shown in chat and in the digest.
--
-- Entries are stored as data and rendered to text when shown (so a later
-- wording change rewrites old entries too):
--   { seq, at, approx, kind, guid, name, class, actor, from, to, how,
--     lastStep, days, level, leftAt }
-- seq is monotonic account-wide (GuildSpyDB.nextSeq); the digest's boundary
-- is a seq, never a time (docs/PLAN.md "Login digest").

local ADDON = ...
GuildSpy = GuildSpy or {}
local Log = {}
GuildSpy.Log = Log

Log.MAX_ENTRIES = 1500
Log.MAX_DAYS = 180
Log.DIGEST_LINES = 8

-- GRM's palette (GRM_Core.lua:1187).
Log.COLORS = {
    JOIN = "80ff00", REJOIN = "80ff00", LEAVE = "a0a0a0", PROMOTE = "ffe900", DEMOTE = "e8630c",
    RANK = "ffffff", RANKS = "ffffff", LEVEL = "3d9bff", NOTE = "ff99ff", ONOTE = "ff18ed",
    NAME = "e6d19e", RETURN = "00ffde", MOTD = "00ccff",
}
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

-- Appends an event as an entry; caps are enforced here, on every append.
function Log.Add(db, gs, ev, now)
    gs.log = gs.log or {}
    db.nextSeq = (db.nextSeq or 1)
    local e = { seq = db.nextSeq, at = ev.at or now, approx = ev.approx, kind = ev.kind, guid = ev.guid,
                name = ev.name, class = ev.class, actor = ev.actor, from = ev.from, to = ev.to, how = ev.how,
                lastStep = ev.lastStep, days = ev.days, level = ev.level, leftAt = ev.leftAt }
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
-- important first. Returns the lines (nothing new: an empty list) and the
-- highest seq shown.
function Log.Digest(gs, canViewOfficer, now)
    local fresh, counts, top = {}, {}, gs.shownSeq or 0
    for _, e in ipairs(gs.log or {}) do
        if e.seq > (gs.shownSeq or 0) then
            if e.seq > top then top = e.seq end
            if Log.Visible(e, canViewOfficer) then
                fresh[#fresh + 1] = e
                counts[e.kind] = (counts[e.kind] or 0) + 1
            end
        end
    end
    if #fresh == 0 then return {}, top end
    local parts = {}
    for _, s in ipairs(Log.SUMMARY) do
        if counts[s[1]] then parts[#parts + 1] = counts[s[1]] .. " " .. s[2] end
    end
    local since = gs.shownAt and (" since " .. Log.Ago(now - gs.shownAt) .. " ago") or ""
    local lines = { "|cff7fd4ffGuildSpy|r" .. since .. ": " .. table.concat(parts, ", ") }
    table.sort(fresh, function(a, b)
        local pa, pb = Log.PRIORITY[a.kind] or 99, Log.PRIORITY[b.kind] or 99
        if pa ~= pb then return pa < pb end
        return a.seq < b.seq
    end)
    for i = 1, math.min(Log.DIGEST_LINES, #fresh) do lines[#lines + 1] = "  " .. Log.Line(fresh[i], now) end
    if #fresh > Log.DIGEST_LINES then
        lines[#lines + 1] = "  ... and " .. (#fresh - Log.DIGEST_LINES) .. " more: /gspy log"
    end
    return lines, top
end
