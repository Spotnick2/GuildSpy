-- Scanner.lua: the live shell. Watches the guild events, scans the roster
-- when it changes, feeds Roster's diff into the log with whatever evidence
-- names an actor, and prints the login digest once the picture has settled.
-- docs/PLAN.md "Scan pipeline", "Attribution", "Login digest".

local ADDON = ...
GuildSpy = GuildSpy or {}
local API, Roster, Patterns, EventLog, Log = GuildSpy.API, GuildSpy.Roster, GuildSpy.Patterns, GuildSpy.EventLog, GuildSpy.Log
local Scanner = {}
GuildSpy.Scanner = Scanner

Scanner.ROSTER_DEBOUNCE = 2     -- GUILD_ROSTER_UPDATE comes in pairs (measured)
Scanner.LOG_SETTLE = 3          -- GUILD_EVENT_LOG_UPDATE comes in bursts of ~55; names arrive with it
Scanner.POLL = 60               -- levels and notes fire no message: ask for the roster this often
Scanner.START_DELAY = 5
Scanner.FIRST_SCAN_WAIT = 20    -- the first scan of a session waits this long, at most, for the event log
Scanner.DIGEST_DEADLINE = 90    -- the digest waits for the picture to settle, at most this long
Scanner.PENDING_TTL = 600
Scanner.PENDING_MAX = 50
Scanner.ENRICH_WINDOW = 600
Scanner.WARN_AFTER = 5          -- incomplete scans in a row before saying so
Scanner.MAX_GUILDS = 5
Scanner.ATTRIBUTABLE = { JOIN = true, REJOIN = true, LEAVE = true, PROMOTE = true, DEMOTE = true, RANK = true }

local S = {}
Scanner.session = S

local function now() return time() end
local function say(msg) GuildSpy.Print(msg) end

local function db() return GuildSpyDB end

-- The log window (UI.lua, loaded later) redraws when the log, the guild or
-- the officer-note permission may have changed.
local function refreshUI()
    if GuildSpy.UI then GuildSpy.UI.Refresh() end
end
local function settings() return db().settings or {} end

-- A fresh session for the current (or no) guild: live evidence never
-- carries from one guild to another.
function Scanner.Reset()
    S.guildKey, S.state = nil, nil
    S.pending, S.enrichable = {}, {}
    S.eventLog, S.eventLogAt, S.eventLogSettled = nil, nil, false
    S.incomplete, S.warned = 0, false
    S.firstScanDone, S.digestShown, S.baselined, S.deadlinePassed = false, false, nil, false
    S.holding, S.logQueried = false, false
    S.session = (S.session or 0) + 1
    refreshUI()
end
Scanner.Reset()

local function numOrNil(v) return v == nil or type(v) == "number" end
local function strOrNil(v) return v == nil or type(v) == "string" end

-- A saved guild is checked before use: a snapshot with an unreadable record
-- is dropped (the next complete scan is a fresh baseline), unreadable log and
-- former entries are dropped. A damaged file must never stop the addon.
local function validGuild(gs)
    if type(gs.members) ~= "table" or (gs.observedAt ~= nil and type(gs.observedAt) ~= "number") then
        gs.members, gs.observedAt = nil, nil
    else
        for _, m in pairs(gs.members) do
            if type(m) ~= "table" or type(m.name) ~= "string" or type(m.rank) ~= "number"
                or not numOrNil(m.level) or not numOrNil(m.lastSeenAt) or not numOrNil(m.seenAt)
                or not numOrNil(m.missingSince) or not numOrNil(m.missingAfter)
                or not strOrNil(m.note) or not strOrNil(m.onote) then
                gs.members, gs.observedAt = nil, nil
                break
            end
        end
    end
    if type(gs.log) == "table" then
        local kept = {}
        for _, e in ipairs(gs.log) do
            if type(e) == "table" and type(e.seq) == "number" and type(e.at) == "number" and type(e.kind) == "string" then
                kept[#kept + 1] = e
            end
        end
        gs.log = kept
    end
    if type(gs.formers) == "table" then
        for guid, f in pairs(gs.formers) do
            if type(f) ~= "table" or type(f.name) ~= "string" then gs.formers[guid] = nil end
        end
    end
    if type(gs.ranks) == "table" then
        for _, r in ipairs(gs.ranks) do if type(r) ~= "string" then gs.ranks = {} break end end
    end
    if type(gs.log) ~= "table" then gs.log = {} end
    if type(gs.formers) ~= "table" then gs.formers = {} end
    if type(gs.ranks) ~= "table" then gs.ranks = {} end
    if type(gs.shownSeq) ~= "number" then gs.shownSeq = 0 end
    if gs.nextChg ~= nil and type(gs.nextChg) ~= "number" then gs.nextChg = nil end
    for _, e in ipairs(gs.log) do
        if e.uid ~= nil and type(e.uid) ~= "string" then e.uid = nil end
        if e.ns ~= nil and type(e.ns) ~= "string" then e.ns, e.trust = nil, nil end
    end
    -- Observations (#36): legacy entries get their identity once.
    Log.Migrate(gs)
    if gs.viewedSeq ~= nil and type(gs.viewedSeq) ~= "number" then gs.viewedSeq = nil end
    return gs
end

-- The saved state of one guild, made if new; at most MAX_GUILDS are kept,
-- the least recently observed dropped first.
local function guildState(key)
    local guilds = db().guilds
    if type(guilds[key]) ~= "table" then guilds[key] = {} end
    local gs = validGuild(guilds[key])
    local keys = {}
    for k, g in pairs(guilds) do if k ~= key then keys[#keys + 1] = { k = k, at = type(g) == "table" and g.observedAt or 0 } end end
    if #keys >= Scanner.MAX_GUILDS then
        table.sort(keys, function(a, b) return a.at < b.at end)
        for i = 1, #keys - Scanner.MAX_GUILDS + 1 do guilds[keys[i].k] = nil end
    end
    return gs
end

-- The roster is asked for every poll. The server log (a burst of ~55 events
-- and a 100-entry read) only when something waits on it: entries to enrich,
-- departures to confirm, or the session's first look.
function Scanner.Request(withLog)
    if not IsInGuild() then return end
    API.RequestRoster()
    if withLog or not S.eventLogSettled or #S.enrichable > 0 or (S.state and Roster.HasMissing(S.state)) then
        API.QueryEventLog()
    end
end

-- Evidence ------------------------------------------------------------------

local function prunePending(t)
    local kept = {}
    for _, p in ipairs(S.pending) do if t - p.at <= Scanner.PENDING_TTL then kept[#kept + 1] = p end end
    while #kept > Scanner.PENDING_MAX do table.remove(kept, 1) end
    S.pending = kept
end

local function attribute(ev, peek)
    return EventLog.Attribute(ev, S.pending, S.eventLogSettled and S.eventLog or nil, S.eventLogAt, peek)
end

-- Officer-note entries are shown only to a character that can read officer
-- notes NOW (asked at display time, never cached: rights can be revoked).
local function canView() return API.CanViewOfficerNote() == true end

-- Entries recorded this session without an actor get later evidence filled
-- in place: the window updates, no second chat line is printed.
-- The current guild's saved state and key (nil out of a guild): for the log window.
function Scanner.Current() return S.state, S.guildKey end

function Scanner.Enrich()
    local t, kept = now(), {}
    for _, item in ipairs(S.enrichable) do
        if t - item.recordedAt <= Scanner.ENRICH_WINDOW then
            local attr = attribute(item.ev)
            if attr then Log.Enrich(item.entry, attr, S.state) else kept[#kept + 1] = item end
        end
    end
    S.enrichable = kept
    refreshUI()
end

local parse
local function parser()
    if parse == nil then
        local globals = {}
        for _, src in ipairs(Patterns.SOURCES) do globals[src.global] = rawget(_G, src.global) end
        parse = Patterns.Build(globals) or false
    end
    return parse or nil
end

function Scanner.OnSystemMessage(msg)
    local p = parser()
    local m = p and p(msg)
    if not m then return end
    local t = now()
    if m.kind == "LEADER" then
        -- The new Guild Master is promoted and the old one demoted, in one message.
        S.pending[#S.pending + 1] = { at = t, kind = "PROMOTE", actor = m.actor, target = m.target }
        S.pending[#S.pending + 1] = { at = t, kind = "DEMOTE", actor = m.actor, target = m.actor }
    else
        m.at = t
        S.pending[#S.pending + 1] = m
    end
    prunePending(t)
    Scanner.Enrich()
    -- Look now rather than at the next poll, so the line comes with the message.
    C_Timer.After(1, function() Scanner.Request(true) end)
end

-- Scanning -------------------------------------------------------------------

local function opts()
    local st = settings()
    return {
        levelMin = st.levelMin, returnDays = st.returnDays,
        confirmLeave = function(name, lo, hi)
            return EventLog.MatchLive({ kind = "LEAVE", name = name, lo = lo, hi = hi }, S.pending, true) ~= nil
        end,
        confirmRank = function(kind, name, to, lo, hi)
            return attribute({ kind = kind, name = name, to = to, lo = lo, hi = hi }, true) ~= nil
        end,
    }
end

-- Someone reached the level cap (#34): the game's level-up fanfare, once,
-- when the setting is on. PlaySound(kit, "SFX") honours the game's sound
-- settings (Gnomesweeper measured kit IDs play on Forever; this one is picked
-- by ear in game).
Scanner.CAP_SOUND = 888
function Scanner.CapSound()
    if settings().capSound == false then return end
    if type(rawget(_G, "PlaySound")) == "function" then pcall(PlaySound, Scanner.CAP_SOUND, "SFX") end
end

function Scanner.Print(entry)
    if not S.digestShown then return end                  -- catch-up goes in the digest
    -- The fanfare is its own setting: a muted level-up line doesn't mute it (#35 review).
    if Log.IsCap(entry) then Scanner.CapSound() end
    local chat = settings().chat or {}
    if chat[entry.kind] == false then return end
    if not Log.Visible(entry, canView()) then return end
    print("|cff7fd4ffGuildSpy:|r " .. Log.Line(entry, now()))
end

-- The last GUILD_MOTD text, owned by the guild it was heard in. At login it
-- can arrive before the guild's name is known: then the first guild scanned
-- adopts it. Another guild's text is never carried into this one's state.
local function motdFor(key)
    if S.motd and S.motdKey == nil then S.motdKey = key end
    if S.motdKey == key then return S.motd end
end

-- The session for the current guild: made (and the saved state loaded) the
-- first time the guild is known, by a scan or by the event log.
local function ensureGuild()
    local key = API.GuildKey()
    if not key then return nil end
    if key ~= S.guildKey then
        Scanner.Reset()
        S.guildKey, S.state = key, guildState(key)
        Roster.PruneFormers(S.state, now())
        Log.Prune(S.state, now())
        -- Each guild session gets its own digest deadline (a later join, a guild switch).
        local session = S.session
        C_Timer.After(Scanner.DIGEST_DEADLINE, function()
            if S.session == session then Scanner.MaybeDigest(true) end
        end)
    end
    return key
end

function Scanner.Scan(force)
    if not ensureGuild() then return end
    -- The session's first scan waits for the server log (at most
    -- FIRST_SCAN_WAIT): changes found at login, a promotion during a rank
    -- restructure above all, can only be confirmed from it, and a change
    -- suppressed once is never re-examined.
    if not S.firstScanDone and not S.eventLogSettled and not force then
        if not S.logQueried then S.logQueried = true; API.QueryEventLog() end
        if not S.holding then
            S.holding = true
            local session = S.session
            C_Timer.After(Scanner.FIRST_SCAN_WAIT, function()
                if S.session == session and not S.firstScanDone then Scanner.Scan(true) end
            end)
        end
        return
    end
    local scan, why = API.ReadRoster()
    if scan then scan.motd = motdFor(S.guildKey) end
    if not scan then
        S.incomplete = S.incomplete + 1
        if why == "showOffline" then
            if not S.warnedOffline then
                S.warnedOffline = true
                say("paused: turn on \"Show Offline Members\" in the guild roster so GuildSpy can see the whole guild.")
            end
            return
        end
        if S.incomplete >= Scanner.WARN_AFTER and not S.warned then
            S.warned = true
            say("can't read the whole guild roster (" .. tostring(why) .. "). Is \"Show offline members\" on? "
                .. "/gspy rebaseline starts over if this persists.")
        end
        return
    end
    S.incomplete = 0
    local t = now()
    prunePending(t)
    local events, wasBaseline = Roster.Apply(S.state, scan, t, opts())
    if wasBaseline then S.baselined = scan.count end
    -- Names can repeat across connected realms: evidence (a message, a log
    -- row) names a member, not a GUID, so it explains a change only when one
    -- changed GUID carries that name in this scan.
    local named = {}                                  -- name -> { [guid] = true }: distinct members, not events
    for _, ev in ipairs(events) do
        if ev.guid and ev.name then
            named[ev.name] = named[ev.name] or {}
            named[ev.name][ev.guid] = true
        end
    end
    local function shared(name)
        local n = 0
        for _ in pairs(named[name] or {}) do n = n + 1 end
        return n > 1
    end
    for _, ev in ipairs(events) do
        local m = ev.guid and scan.members[ev.guid]
        if m then ev.class = m.class end
        if ev.name and shared(ev.name) then ev.sharedName = true end
        local attr = Scanner.ATTRIBUTABLE[ev.kind] and not ev.sharedName and attribute(ev)
        if attr then
            ev.actor, ev.how, ev.lastStep, ev.at, ev.approx = attr.actor, attr.how, attr.lastStep, attr.at, attr.approx
        end
        local entry = Log.Add(db(), S.state, ev, t)
        if Scanner.ATTRIBUTABLE[ev.kind] and not attr and not ev.sharedName then
            S.enrichable[#S.enrichable + 1] = { entry = entry, ev = ev, recordedAt = t }
        end
        Scanner.Print(entry)
        -- After the digest, changes are seen as they happen: the next login's
        -- digest starts after them (officer notes only for whoever can read them).
        if S.digestShown then
            S.state.shownSeq, S.state.shownAt = entry.seq, t
            if entry.kind == "ONOTE" and canView() then Scanner.SeenOnote(S.state, entry.seq) end
        end
    end
    Roster.PruneFormers(S.state, t)
    refreshUI()                -- also when nothing changed: officer-note permission may have
    S.firstScanDone = true
    -- A departure waits for a second complete scan: ask for it.
    if Roster.HasMissing(S.state) then C_Timer.After(31, Scanner.Request) end
    Scanner.MaybeDigest(false)
end

function Scanner.ReadEventLog()
    if not ensureGuild() then return end
    S.eventLog, S.eventLogAt, S.eventLogSettled = API.ReadEventLog(), now(), true
    Scanner.Enrich()
    if not S.firstScanDone then Scanner.Scan() end      -- the held first scan
    Scanner.MaybeDigest(false)
end

-- The officer-note boundary means "every officer-note entry up to here was
-- shown to someone who can read it". It moves to `seq` only if no older
-- officer-note entry past the boundary is still unseen.
function Scanner.SeenOnote(gs, seq)
    local from = gs.shownOnoteSeq or 0
    for _, e in ipairs(gs.log or {}) do
        if e.kind == "ONOTE" and e.seq > from and e.seq < seq then return end
    end
    if seq > from then gs.shownOnoteSeq = seq end
end

-- The digest ------------------------------------------------------------------

function Scanner.MaybeDigest(deadline)
    if S.digestShown or not S.state then return end
    if deadline then S.deadlinePassed = true end
    local ready = S.firstScanDone and S.eventLogSettled and not Roster.HasMissing(S.state)
    if not ready and not S.deadlinePassed then return end
    if not S.firstScanDone then return end               -- nothing to say without one scan: the next scan says it
    S.digestShown = true
    local gs, t = S.state, now()
    if settings().digest ~= false then
        if S.baselined then
            say("now watching " .. tostring(select(2, API.GuildKey()) or S.guildKey) .. " (" .. S.baselined
                .. " members). Changes from here on are reported.")
        end
    end
    local lines, top, topOnote = Log.Digest(gs, canView(), t)
    if settings().digest ~= false then
        for _, line in ipairs(lines) do print(line) end
        -- One fanfare for a summary holding any level-up to the cap, however many.
        for _, e in ipairs(gs.log or {}) do
            if e.seq > (gs.shownSeq or 0) and Log.IsCap(e) then Scanner.CapSound(); break end
        end
        if Roster.HasMissing(gs) then
            say("still confirming who left; it'll show as it's confirmed.")
        end
    end
    if top > (gs.shownSeq or 0) then gs.shownSeq, gs.shownAt = top, t end
    if topOnote and topOnote > (gs.shownOnoteSeq or 0) then gs.shownOnoteSeq = topOnote end
    if not gs.shownAt then gs.shownAt = t end
end

-- /gspy log [n]: the last n entries (default 15), oldest first.
function Scanner.PrintLog(n)
    local gs = S.state
    if not gs then say("no guild seen yet."); return end
    n = n or 15
    local shown, out = 0, {}
    for i = #gs.log, 1, -1 do
        local e = gs.log[i]
        if Log.Visible(e, canView()) then
            local src = Log.Source(e)
            table.insert(out, 1, date("%m-%d %H:%M", e.at) .. (e.approx and "~ " or "  ") .. Log.Line(e, now())
                .. (src and (" |cff8f8f8f(" .. src:sub(1, 1):lower() .. src:sub(2):gsub("|", "||") .. ")|r") or ""))
            shown = shown + 1
            if shown >= n then break end
        end
    end
    if #out == 0 then say("nothing recorded yet."); return end
    for _, line in ipairs(out) do print(line) end
end

function Scanner.Status()
    local gs = S.state
    if not gs then say("no guild seen yet."); return end
    local count = 0
    for _ in pairs(gs.members or {}) do count = count + 1 end
    say(string.format("%s: %d members, last scan %s ago, %d log entries, officer notes %s.",
        tostring(S.guildKey), count, gs.observedAt and Log.Ago(now() - gs.observedAt) or "never", #gs.log,
        canView() and "readable" or "not readable"))
end

function Scanner.Rebaseline()
    if not S.state then say("no guild seen yet."); return end
    S.state.members, S.state.observedAt = nil, nil
    say("starting over: the next complete scan is a fresh baseline (the log is kept).")
    Scanner.Request()
end

-- Events ------------------------------------------------------------------------

local frame = CreateFrame("Frame")
Scanner.frame = frame
for _, e in ipairs({ "PLAYER_LOGIN", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "GUILD_EVENT_LOG_UPDATE",
                     "CHAT_MSG_SYSTEM", "GUILD_MOTD" }) do
    API.RegisterEvent(frame, e)
end

-- Runs fn once `delay` seconds after the LAST of a burst of calls, with one
-- pending timer at a time (a 55-event burst doesn't make 55 closures).
local function settler(delay, fn)
    local last, armed = 0, false
    local function check()
        local wait = last + delay - GetTime()
        if wait > 0.01 then C_Timer.After(wait, check) else armed = false; fn() end
    end
    return function()
        last = GetTime()
        if not armed then armed = true; C_Timer.After(delay, check) end
    end
end
local rosterSettled = settler(Scanner.ROSTER_DEBOUNCE, function() Scanner.Scan() end)
local logSettled = settler(Scanner.LOG_SETTLE, function() Scanner.ReadEventLog() end)

local function poll()
    Scanner.Request()
    C_Timer.After(Scanner.POLL, poll)
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(Scanner.START_DELAY, poll)
    elseif event == "GUILD_ROSTER_UPDATE" then
        rosterSettled()
    elseif event == "GUILD_EVENT_LOG_UPDATE" then
        logSettled()
    elseif event == "PLAYER_GUILD_UPDATE" then
        -- Left or changed guild: drop this session's evidence. (A moment where the
        -- client doesn't know the guild's name yet is not a change.)
        local key = API.GuildKey()
        if not IsInGuild() or (key and S.guildKey and key ~= S.guildKey) then Scanner.Reset() end
        if not IsInGuild() then S.motd, S.motdKey = nil, nil end
    elseif event == "CHAT_MSG_SYSTEM" then
        if S.guildKey then Scanner.OnSystemMessage((...)) end
    elseif event == "GUILD_MOTD" then
        -- The MOTD's only source (#16): measured 1.3 s after login, and again on
        -- every change. "" is what it carries before it has loaded: unknown, not
        -- cleared (a guild clearing its MOTD on purpose is the rarer case).
        local text = ...
        S.motd = (type(text) == "string" and text ~= "") and text or nil
        S.motdKey = API.GuildKey()
    end
end)
