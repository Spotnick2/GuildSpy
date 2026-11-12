-- GRMClassify: Guild Roster Manager's addon messages, as counts, samples and
-- name shapes (#8). Pure: no client API, no globals written, so
-- tests/test_grmprobe.lua loads it with plain Lua 5.1.
--
-- GRM's wire, as read in R1.99521 (issue #8, findings and reopen comments):
-- a message is fields joined by "?", the first being its tag. On GRM_SYNC the
-- second is the sender's rank filter. GRMVER carries no tag ("<version>?<patchDay>").

local _, NS = ...
NS = NS or {}
local C = {}
NS.GRMClassify = C

C.PREFIXES = { "GRM_SYNC", "GRMUSER", "GRMVER", "GRM_GCHAT", "GRMACHIEV" }
local IS_PREFIX = {}
for _, p in ipairs(C.PREFIXES) do IS_PREFIX[p] = true end
function C.IsPrefix(p) return IS_PREFIX[p] == true end

-- Tags whose fields are only names, dates, epochs, ranks, versions and flags:
-- their text is kept as a sample. Every other tag (custom notes, nicknames,
-- birthdays, bans, achievement links, the bulk sync, anything unknown) can
-- carry what a player typed, and is kept as field shapes only.
C.RAW = {
    GRM_SYNC = {
        GRM_JD = true, GRM_PD = true, GRM_JDSYNCUP = true, GRM_PDSYNCUP = true,
        GRM_ADDALT = true, GRM_RMVALT = true, GRM_MAIN = true, GRM_RMVMAIN = true,
        GRM_WHOISLEADER = true, GRM_IAMLEADER = true, GRM_ELECT = true,
        GRM_ELECTINFO = true, GRM_NEWLEADER = true,
    },
    GRMUSER = { REG = true, INIT = true, REQ = true },
    GRMVER = { VER = true },
    GRM_GCHAT = { GINFOUPDATE = true },
}

-- The member a structural tag is about: its field number (tag = 1, rank filter = 2).
C.NAME_FIELD = { GRM_JD = 3, GRM_PD = 3, GRM_RMVALT = 3, GRM_MAIN = 3, GRM_RMVMAIN = 3 }

C.SAMPLES = 3       -- kept per prefix and tag
C.MAX_TEXT = 255    -- an addon message's limit

-- Fields split on "?", empty ones kept.
function C.Split(text)
    local out, pos = {}, 1
    while true do
        local i = text:find("?", pos, true)
        if not i then out[#out + 1] = text:sub(pos); return out end
        out[#out + 1] = text:sub(pos, i - 1)
        pos = i + 1
    end
end

-- A tag is short, upper case, digits and underscores; anything else is not
-- kept as a key, since it could be typed text.
function C.Tag(prefix, fields)
    if prefix == "GRMVER" then return "VER" end
    local t = fields[1]
    if type(t) == "string" and #t > 0 and #t <= 24 and t:match("^[%u%d_]+$") then return t end
    return "(other)"
end

-- A field's type and length, never its content.
function C.FieldShape(s)
    if s == "" then return "e" end
    if s == "true" or s == "false" then return "b" end
    if s:match("^%-?%d+$") then return "n" .. #s end
    return "s" .. #s
end

-- What a sample keeps of a message.
function C.Redact(prefix, tag, fields)
    local raw = C.RAW[prefix]
    if raw and raw[tag] then
        local s = table.concat(fields, "?")
        return #s > C.MAX_TEXT and s:sub(1, C.MAX_TEXT) or s
    end
    local out = { tag }
    -- GRMVER has no tag field, and an unknown first field may be text: shape it too.
    local from = (prefix == "GRMVER" or tag == "(other)") and 1 or 2
    for i = from, #fields do out[#out + 1] = C.FieldShape(fields[i]) end
    return table.concat(out, "?")
end

-- A name's shape: its words before any "-", and whether a "-Realm" follows.
-- "Kaleid Sumner" -> "2w", "Kaleid Sumner-Realm" -> "2w+realm".
function C.NameShape(name)
    if type(name) ~= "string" or name == "" then return "empty" end
    local base, realm = name:match("^([^%-]*)%-(.*)$")
    base = base or name
    local words = 0
    for _ in base:gmatch("%S+") do words = words + 1 end
    return words .. "w" .. (realm and "+realm" or "")
end

-- Whether a name is a roster name ("asis"), one once a "-Realm" is dropped
-- ("base"), or neither. roster is a set of roster names; nil or empty when
-- the roster wasn't read yet.
function C.RosterMatch(name, roster)
    if type(name) ~= "string" or name == "" then return "empty" end
    if not roster or next(roster) == nil then return "noroster" end
    if roster[name] then return "asis" end
    local base = name:match("^(.-)%-")
    if base and roster[base] then return "base" end
    return "none"
end

local function bump(t, k) t[k] = (t[k] or 0) + 1 end
local function sub(t, k)
    local v = t[k]
    if type(v) ~= "table" then v = {}; t[k] = v end
    return v
end

-- The saved table's parts, made where missing (never replaced: the probe binds them).
function C.Init(db)
    for _, k in ipairs({ "counts", "days", "samples", "senders", "senderMatch", "nameFields", "users" }) do
        sub(db, k)
    end
    db.total = db.total or 0
    db.selfEcho = db.selfEcho or 0
    db.secret = db.secret or 0
    return db
end

-- One CHAT_MSG_ADDON on a GRM prefix. ev = { prefix, text, channel, sender };
-- ctx = { now = epoch, day = "YYYY-MM-DD", roster = set, me = "First Surname" }.
-- Returns nil when not GRM's, else { tag, sample = <kept text> when this one
-- became a sample, self = true for our own echo }.
function C.Record(db, ev, ctx)
    if not C.IsPrefix(ev.prefix) or type(ev.text) ~= "string" then return nil end
    local fields = C.Split(ev.text)
    local tag = C.Tag(ev.prefix, fields)
    local plainSender = type(ev.sender) == "string" and ev.sender:gsub("%-.*$", "") or nil
    if ctx.me and plainSender == ctx.me then
        db.selfEcho = db.selfEcho + 1
        return { tag = tag, self = true }
    end
    db.total = db.total + 1
    local channel = type(ev.channel) == "string" and ev.channel or "?"
    bump(sub(sub(db.counts, ev.prefix), channel), tag)
    if ctx.day then bump(db.days, ctx.day) end
    db.first = db.first or ctx.now
    db.last = ctx.now

    local shape = C.NameShape(ev.sender)
    bump(db.senders, shape)
    bump(db.senderMatch, C.RosterMatch(ev.sender, ctx.roster))

    local nf = ev.prefix == "GRM_SYNC" and C.NAME_FIELD[tag]
    if nf then
        local name = fields[nf]
        bump(sub(db.nameFields, tag), C.NameShape(name) .. "/" .. C.RosterMatch(name, ctx.roster))
    end

    if ev.prefix == "GRMUSER" and (tag == "REG" or tag == "INIT") and type(ev.sender) == "string" then
        local u = sub(db.users, ev.sender)
        u.version, u.patchDay, u.syncRank = fields[2], fields[3], fields[4]
        u.syncEnabled, u.exportAllRanks = fields[7], fields[8]
        u.last = ctx.now
        u.count = (u.count or 0) + 1
    end

    local result = { tag = tag }
    local list = sub(db.samples, ev.prefix .. " " .. tag)
    if #list < C.SAMPLES then
        local text = C.Redact(ev.prefix, tag, fields)
        list[#list + 1] = { at = ctx.now, channel = channel, sender = shape, fields = #fields, text = text }
        result.sample = text
    end
    return result
end

-- Lines for /fp gs grm: totals, then counts per prefix, channel and tag.
function C.Summary(db)
    local lines = {}
    local users = 0
    for _ in pairs(db.users) do users = users + 1 end
    lines[#lines + 1] = ("GRM messages %d (own echo %d, secret %d), GRM users heard %d"):format(
        db.total, db.selfEcho, db.secret, users)
    local prefixes = {}
    for p in pairs(db.counts) do prefixes[#prefixes + 1] = p end
    table.sort(prefixes)
    for _, p in ipairs(prefixes) do
        local channels = {}
        for ch in pairs(db.counts[p]) do channels[#channels + 1] = ch end
        table.sort(channels)
        for _, ch in ipairs(channels) do
            local tags = {}
            for t, n in pairs(db.counts[p][ch]) do tags[#tags + 1] = t .. "=" .. n end
            table.sort(tags)
            lines[#lines + 1] = ("  %s %s: %s"):format(p, ch, table.concat(tags, " "))
        end
    end
    return lines
end

return C
