-- GuildSync.lua: sync with guildmates over GUILD addon messages (#38,
-- docs/SYNC.md §5). Best effort: what arrives is what online guildmates saw.
--
-- A protocol core with no client calls (it takes a clock, a send, a timer and
-- the store, so several run side by side in the tests), then the shell: the
-- prefix, ChatThrottleLib behind our own one-at-a-time queue, the settings,
-- the report lines.
--
-- Messages (Wire, one header line, at most one entry line, 255 bytes):
--   H                         hello: once per session, after my first complete scan
--   Q qid since resp cursor   ask: everyone (resp ""), or one responder (its continuation)
--   A qid                     I'm answering
--   E qid  + one entry        one of my own observations
--   D qid cursor              done; a cursor when more remain (ask me for it)

GuildSpy = GuildSpy or {}
local GSync = {}
GuildSpy.GuildSync = GSync
local Log, Wire = GuildSpy.Log, GuildSpy.Wire

GSync.PREFIX = "GuildSpy"
GSync.DAYS = 14                      -- what a Q asks for
GSync.Q_GAP = 120                    -- at most one Q per 2 minutes
GSync.ANSWER_GAP = 60                -- one answer to everyone per minute: later asks are heard in it
GSync.JITTER_MIN, GSync.JITTER_MAX = 2, 8
GSync.PER_ANSWER = 40
GSync.PER_REPORTER = 200             -- admitted per guildmate per session
GSync.MAX_BYTES = 255                -- C_ChatInfo.SendAddonMessage's limit

-- What goes on the wire, with a short name each. Never seq, chg, here, trust,
-- reporter or ns; origin is the sender (the transport proves it, §5) and obs
-- follows from the times.
GSync.FIELDS = { "uid", "rev", "kind", "guid", "name", "class", "actor", "from", "to", "how", "lastStep",
                 "days", "level", "leftAt", "at", "approx", "lo", "hi" }
GSync.ALIAS = { uid = "u", rev = "r", kind = "k", guid = "g", name = "n", class = "c", actor = "a",
                from = "f", to = "t", how = "w", lastStep = "l", days = "d", level = "v", leftAt = "x",
                at = "T", approx = "p", lo = "L", hi = "H" }
local ALLOWED = {}
for _, k in ipairs(GSync.FIELDS) do ALLOWED[k] = true end

local function observed(e) return tonumber(e.obs) or tonumber(e.at) or 0 end
-- A name without a realm: measured, a GUILD sender has none (Gnomesweeper, 70205),
-- but if the live client adds one, my own echo must still be mine (SYNC.md §5).
local function plain(name) return type(name) == "string" and (name:gsub("%-.*$", "")) or nil end
GSync.Plain = plain

-- What I may send: my own observations, made by this character, in public
-- kinds (never officer notes, the MOTD, the rank list, legacy entries or
-- what my other accounts or guildmates saw).
function GSync.Exportable(e, me)
    return type(e) == "table" and type(e.uid) == "string" and e.trust == "self" and e.here == true
        and me ~= nil and e.origin == me and Log.PUBLIC_KINDS[e.kind] == true
end

-- Newest first, by (observed time, uid); a cursor is the last one sent.
local function before(a, b)
    local oa, ob = observed(a), observed(b)
    if oa ~= ob then return oa > ob end
    return a.uid > b.uid
end
local function cursorOf(e) return string.format("%d", observed(e)) .. "," .. e.uid end
local function afterCursor(e, cursor)
    if not cursor or cursor == "" then return true end
    local t, uid = cursor:match("^(%-?%d+),(.+)$")
    t = tonumber(t)
    if not t then return false end
    local o = observed(e)
    return o < t or (o == t and e.uid < uid)
end

-- One E message for an entry, or nil when it doesn't fit.
function GSync.EntryMessage(qid, e)
    local text = Wire.Message("E", { qid }, { Wire.Entry(e, GSync.FIELDS, GSync.ALIAS) })
    if #text > GSync.MAX_BYTES then return nil end
    return text
end

-- Whether I have anything for an ask (no encoding, no sort: #43 review).
function GSync.Has(gs, me, since, cursor)
    for _, e in ipairs(gs and gs.log or {}) do
        if GSync.Exportable(e, me) and observed(e) >= since and afterCursor(e, cursor) then return true end
    end
    return false
end

-- My answer: up to PER_ANSWER messages ({ text, sig }) since `since`, after
-- `cursor`; the next cursor when more remain.
function GSync.Pick(gs, me, qid, since, cursor)
    local list = {}
    for _, e in ipairs(gs and gs.log or {}) do
        if GSync.Exportable(e, me) and observed(e) >= since and afterCursor(e, cursor) then list[#list + 1] = e end
    end
    table.sort(list, before)
    local out, last = {}, nil
    for i, e in ipairs(list) do
        if #out >= GSync.PER_ANSWER then return out, last and cursorOf(last) end
        local text = GSync.EntryMessage(qid, e)
        if text then out[#out + 1] = { text = text, sig = GSync.Sig(e) } end   -- one that doesn't fit isn't sent (§5)
        last = e
    end
    return out, nil
end

------------------------------------------------------------
-- The core
------------------------------------------------------------

local Core = {}
Core.__index = Core

-- o: db, gs(key), key(), me(), now(), send(text, ok) (queued; ok() is asked
-- again just before it leaves), after(seconds, fn), random(lo, hi),
-- accepts(name) (a guildmate whose reports I take: roster, rank, setting),
-- onReceived(added, key), onChanged(), onStatus() (a guildmate heard) (all optional).
function GSync.NewCore(o)
    return setmetatable({ o = o, myQ = {}, qs = {}, sigs = {}, answers = {}, answered = {}, heard = {},
                          ask = {}, admitted = {}, said = nil, lastQ = nil, lastAnswer = nil, deferred = nil }, Core)
end

-- One change, whoever saw it: what a responder skips when another already sent it.
function GSync.Sig(e)
    return table.concat({ tostring(e.guid), tostring(e.kind), tostring(e.from), tostring(e.to) }, "\31")
end

-- What a Q asks for: the last 14 days. (SYNC.md had "or since my oldest entry
-- if newer": it would keep a new user from what happened just before, and an
-- answer is the newest 40 anyway.)
function Core:since()
    return math.floor(self.o.now() - GSync.DAYS * 86400)
end

-- A Q, if the gap allows: to everyone (responder nil), or to one responder
-- (from a cursor, with the ask's own start).
function Core:Ask(responder, cursor, since)
    local key = self.o.key()
    if not key then return false end
    local now = self.o.now()
    if self.lastQ and now - self.lastQ < GSync.Q_GAP then return false end
    if not self.o.gs(key) then return false end
    local qid = Log.NewUid()
    since = since or self:since()
    self.myQ[qid] = { responder = responder, key = key, since = since, cursor = cursor }
    self.lastQ = now
    self.o.send(Wire.Message("Q", { qid, since, responder or "", cursor or "" }),
        function() return self.o.key() == key end)
    return true
end

-- After my first complete scan in a guild: hello, and the ask to everyone,
-- queued first: an ask the gap refuses now goes at the next tick (#43 review).
function Core:Hello()
    local key = self.o.key()
    if not key or self.said == key then return end
    self.said = key
    self.o.send(Wire.Message("H"), function() return self.o.key() == key end)
    table.insert(self.ask, 1, { everyone = true })
    self:Tick()
end

-- Someone to ask directly (heard but not answered, or a continuation).
function Core:want(name, cursor, since)
    for _, w in ipairs(self.ask) do
        if w.name == name then
            if cursor then w.cursor, w.since = cursor, since end
            return
        end
    end
    self.ask[#self.ask + 1] = { name = name, cursor = cursor, since = since }
end
local function drop(list, name)
    for i = #list, 1, -1 do
        if list[i].name == name and not list[i].cursor then table.remove(list, i) end
    end
end

-- Every few seconds: the next ask, when the gap allows.
function Core:Tick()
    local w = self.ask[1]
    if w and self.said and self:Ask(w.name, w.cursor, w.since) then table.remove(self.ask, 1) end
end

-- My guild changed (or I left it): everything bound to the old one goes.
function Core:GuildChanged()
    for _, ans in pairs(self.answers) do ans.stopped = true end
    self.myQ, self.qs, self.sigs, self.answers, self.answered, self.heard, self.ask = {}, {}, {}, {}, {}, {}, {}
    self.said, self.lastAnswer, self.deferred = nil, nil, nil
end

function Core:OnMessage(text, sender)
    local me = self.o.me()
    if type(sender) ~= "string" or sender == "" or plain(sender) == plain(me) then return end   -- our own echo
    local key = self.o.key()
    if not key then return end
    local kind, f, lines = Wire.Read(text)
    if not kind then return end
    if not self.heard[sender] then
        self.heard[sender] = true
        if self.o.onStatus then self.o.onStatus() end
    end
    if kind == "H" then
        if not self.answered[sender] then self:want(sender) end
    elseif kind == "Q" then
        local qid, since = f[1], tonumber(f[2])
        if qid and since then self.qs[qid] = { since = since, cursor = f[4] or "" } end
        self:onQ(key, sender, f)
    elseif kind == "E" then
        self:onE(key, sender, f, lines)
    elseif kind == "D" then
        -- The end of an answer, to my ask or one I heard. Complete, from the
        -- start of at least my 14 days: I have all of theirs. Cut short: ask
        -- them for the rest (#43 review: an A alone proved nothing).
        local qid, cursor = f[1], f[2]
        local q = qid and (self.myQ[qid] or self.qs[qid])
        if not (q and self.said) then return end
        if cursor == nil or cursor == "" then
            if q.since <= self:since() + GSync.Q_GAP then
                self.answered[sender] = true
                drop(self.ask, sender)
            end
        elseif (self.admitted[sender] or 0) < GSync.PER_REPORTER then
            self:want(sender, cursor, q.since)
        end
    end
end

function Core:onQ(key, sender, f)
    local me = self.o.me()
    local qid, since, responder, cursor = f[1], tonumber(f[2]), f[3] or "", f[4] or ""
    if not (qid and since) then return end
    local directed = responder ~= ""
    if directed and plain(responder) ~= plain(me) then return end
    local gs = self.o.gs(key)
    if not gs or not GSync.Has(gs, me, since, cursor) then return end
    local now = self.o.now()
    if not directed and self.lastAnswer and now - self.lastAnswer < GSync.ANSWER_GAP then
        -- One answer to everyone a minute: an ask during it is answered when
        -- the minute ends, not dropped (#43 review: the asker may not have
        -- heard the last one).
        local d = self.deferred
        if d then
            if since < d.since then d.qid, d.since = qid, since end
            return
        end
        d = { qid = qid, since = since, key = key }
        self.deferred = d
        self.o.after(self.lastAnswer + GSync.ANSWER_GAP - now, function()
            if self.deferred ~= d then return end
            self.deferred = nil
            self:schedule(d.key, d.qid, d.since, "", false)
        end)
        return
    end
    self:schedule(key, qid, since, cursor, directed)
end

-- An answer after a jitter (a direct ask: one second). Every guildmate with
-- entries answers: each has only what it saw itself (#43 review).
function Core:schedule(key, qid, since, cursor, directed)
    local ans = { qid = qid, key = key, directed = directed }
    self.answers[qid] = ans
    if not directed then self.lastAnswer = self.o.now() end
    local wait = directed and 1 or self.o.random(GSync.JITTER_MIN, GSync.JITTER_MAX)
    self.o.after(wait, function() self:answer(ans, since, cursor) end)
end

function Core:answer(ans, since, cursor)
    local key = ans.key
    if ans.stopped or self.o.key() ~= key then return end          -- my guild changed
    local gs = self.o.gs(key)
    if not gs then return end
    local list, nextCursor = GSync.Pick(gs, self.o.me(), ans.qid, since, cursor)
    if #list == 0 then return end
    -- Each message asks again just before it leaves: still this guild; an
    -- entry, also not already sent in this answer by another guildmate.
    local function ok() return not ans.stopped and self.o.key() == key end
    local heard = self.sigs
    self.o.send(Wire.Message("A", { ans.qid }), ok)
    for _, item in ipairs(list) do
        self.o.send(item.text, function() return ok() and not (heard[ans.qid] and heard[ans.qid][item.sig]) end)
    end
    self.o.send(Wire.Message("D", { ans.qid, nextCursor or "" }), ok)
end

-- An entry from a guildmate: any answer counts (everyone hears it), from
-- someone I accept, within their share of the session.
function Core:onE(key, sender, f, lines)
    local qid = f[1]
    local e = qid and lines and lines[1] and Wire.ReadEntry(lines[1], ALLOWED, GSync.ALIAS)
    if not e then return end
    -- Sent in this answer: another responder doesn't send it again.
    self.sigs[qid] = self.sigs[qid] or {}
    self.sigs[qid][GSync.Sig(e)] = true
    if not self.o.accepts(sender) then return end
    if (self.admitted[sender] or 0) >= GSync.PER_REPORTER then return end
    e.origin = sender
    e.obs = (e.approx == false and e.at) or e.hi or e.at
    local gs = self.o.gs(key)
    if not gs then return end
    local got, why = Log.Receive(self.o.db, gs, e, "guild", sender, self.o.now())
    if not got then return end
    self.admitted[sender] = (self.admitted[sender] or 0) + 1
    if why ~= "updated" and self.o.onReceived then self.o.onReceived({ got }, key) end
    if self.o.onChanged then self.o.onChanged() end
end

-- Guildmates heard this session (any GuildSpy message), for the Sharing page.
function Core:Heard()
    local n = 0
    for _ in pairs(self.heard) do n = n + 1 end
    return n
end

------------------------------------------------------------
-- The shell: the prefix, the queue, the settings, the report lines
------------------------------------------------------------

GSync.TICK = 10
GSync.QUIET, GSync.MAX_LINES = 10, 5
GSync.REPORT_MODES = { chat = true, log = true, never = true }

local core, registered
local queue, inflight, pumping, token = {}, false, false, 0
GSync.STUCK = 60                     -- a message ChatThrottleLib never reported: let the queue move on
local pending = nil

local function settings() return GuildSpyDB and GuildSpyDB.settings or {} end
function GSync.Enabled() return settings().shareGuild ~= false end
function GSync.ReportsMode()
    local m = settings().reports
    return GSync.REPORT_MODES[m] and m or "chat"
end
local function key() return select(2, GuildSpy.Scanner.Current()) end
-- "Accept reports from" is a rank of a guild: kept per guild (#43 review).
function GSync.MinRank()
    local t, k = settings().reportRanks, key()
    local r = type(t) == "table" and k and t[k]
    return type(r) == "number" and r or nil
end
local function me() return GuildSpy.API.PlayerFullName() end

-- A sender's rank in my roster (index, 0 the guild master), by name.
local function rankOf(name)
    local gs = GuildSpy.Scanner.Current()
    local want = plain(name)
    for _, m in pairs(gs and gs.members or {}) do
        if type(m) == "table" and plain(m.name) == want and type(m.rank) == "number" then return m.rank end
    end
    return nil
end

-- Whose reports I take, however they come (here, or forwarded by my other
-- account, #43 review): the setting, my roster, the rank.
function GSync.Accepts(name)
    if GSync.ReportsMode() == "never" then return false end
    local rank = rankOf(name)
    if rank == nil then return false end
    local min = GSync.MinRank()
    return not (min and rank > min)
end

-- ChatThrottleLib holds what it's given and sends it later without asking us.
-- So it gets one message at a time, the next only from the previous one's
-- callback, after that message's own check (still this guild, the answer not
-- stopped): a guild change leaves at most one message in flight (round 3).
local function pump()
    if pumping then return end
    pumping = true
    while not inflight and #queue > 0 do
        local m = table.remove(queue, 1)
        if m.ok() then
            local ctl = rawget(_G, "ChatThrottleLib")
            inflight = time()
            -- Only this message's callback frees the queue: one that comes after
            -- the timeout let another go must not let a third (#43 review).
            token = token + 1
            local mine = token
            local ok = pcall(ctl.SendAddonMessage, ctl, "NORMAL", GSync.PREFIX, m.text, "GUILD", nil, "GuildSpyGuild",
                function()
                    if mine ~= token then return end
                    inflight = false
                    pump()
                end)
            if not ok and mine == token then inflight = false end
        end
    end
    pumping = false
end

local function send(text, ok)
    local ctl = rawget(_G, "ChatThrottleLib")
    if not (ctl and ctl.SendAddonMessage) then return end           -- never unpaced
    queue[#queue + 1] = { text = text, ok = ok }
    pump()
end

-- Guildmates' reports in chat, by the setting: after a quiet spell, at most
-- MAX_LINES, then "+N more"; the first time, how to turn them off.
local function flush()
    if not pending then return end
    local list = pending
    pending = nil
    if GSync.ReportsMode() ~= "chat" then return end
    local canView = GuildSpy.API.CanViewOfficerNote() == true
    local shown = {}
    for _, e in ipairs(list) do
        if not e.covered and Log.Visible(e, canView) then shown[#shown + 1] = e end
    end
    if #shown == 0 then return end
    local now = time()
    for i = 1, math.min(GSync.MAX_LINES, #shown) do
        local e = shown[i]
        print("|cff7fd4ffGuildSpy:|r " .. Log.Line(e, now) .. " |cff8f8f8f(reported by "
            .. Log.Esc(tostring(e.reporter)) .. ")|r")
    end
    if #shown > GSync.MAX_LINES then
        print("|cff7fd4ffGuildSpy:|r +" .. (#shown - GSync.MAX_LINES) .. " more from guildmates " .. Log.OPEN_LINK)
    end
    if not settings().reportsHinted then
        settings().reportsHinted = true
        print("|cff7fd4ffGuildSpy:|r these come from guildmates with GuildSpy. Show them only in the log, or not at all: /gspy options, Sharing.")
    end
end

-- One timer for a batch: it waits again while entries keep coming (#43 review).
local quietUntil
local function wait()
    C_Timer.After(math.max(0, quietUntil - time()) + 0.1, function()
        if not quietUntil then return end
        if time() < quietUntil then return wait() end
        quietUntil = nil
        flush()
    end)
end
local function received(added)
    pending = pending or {}
    for _, e in ipairs(added) do pending[#pending + 1] = e end
    local waiting = quietUntil ~= nil
    quietUntil = time() + GSync.QUIET
    if not waiting then wait() end
end

-- The window redraws once for a run of entries, not once each.
local refreshing = false
local function changed()
    if refreshing then return end
    refreshing = true
    C_Timer.After(0.5, function()
        refreshing = false
        if GuildSpy.UI and GuildSpy.UI.Refresh then GuildSpy.UI.Refresh() end
    end)
end

-- For the Sharing page: guildmates with GuildSpy heard this session, and whether it runs.
function GSync.Status()
    return core and core:Heard() or 0, core ~= nil and GSync.Enabled()
end

function GSync.SetEnabled(on)
    settings().shareGuild = on and true or false
    if not on then
        queue = {}
        if core then core:GuildChanged() end
    end
end

local lastKey
local function tick()
    if not core then return end
    if inflight and time() - inflight >= GSync.STUCK then
        token = token + 1
        inflight = false
        pump()
    end
    local k = key()
    if k ~= lastKey then
        lastKey = k
        queue = {}                                           -- what was queued for the old guild
        core:GuildChanged()
        if GuildSpy.Options and GuildSpy.Options.RefreshSharing then GuildSpy.Options.RefreshSharing() end
    end
    if not (k and GSync.Enabled()) then return end
    if GuildSpy.Scanner.Ready() then core:Hello() end
    core:Tick()
end

local function start()
    if core then return end
    if not registered then
        local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, GSync.PREFIX)
        registered = ok and result or false
    end
    core = GSync.NewCore({
        db = GuildSpyDB,
        gs = function(k)
            local gs, current = GuildSpy.Scanner.Current()
            if gs and current == k then return gs end
        end,
        key = key, me = me, now = time,
        send = send,
        after = function(s, fn) C_Timer.After(s, fn) end,
        random = function(lo, hi) return math.random(lo, hi) end,
        accepts = GSync.Accepts,
        onReceived = received,
        onChanged = changed,
        onStatus = function() if GuildSpy.Options and GuildSpy.Options.RefreshSharing then GuildSpy.Options.RefreshSharing() end end,
    })
    C_Timer.NewTicker(GSync.TICK, tick)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, prefix, text, channel, sender)
    if event == "PLAYER_LOGIN" then
        start()
    elseif prefix == GSync.PREFIX and channel == "GUILD" and core and GSync.Enabled() then
        core:OnMessage(text, sender)
    end
end)

GSync._test = { core = function() return core end, queue = function() return queue end,
                inflight = function() return inflight end, flush = flush, tick = tick }
