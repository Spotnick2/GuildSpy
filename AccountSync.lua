-- AccountSync.lua: sync between my own accounts (#37, docs/SYNC.md §4), over
-- LibAccountSync-1.0 (Battle.net game data, ownership proven by the library).
--
-- The protocol is a core with no client calls of its own (AS.NewCore): it is
-- given a clock, a send function and the store, so two cores (two accounts)
-- run side by side in the tests. The shell at the bottom ties one core to the
-- library, the scanner's guild and the catch-up line.
--
-- Messages (Wire.lua), all to one peer (SendTo, never a broadcast):
--   CAP  <guildKey> <heard>                 my current guild ("" when none); heard: 1 once I
--                                           have its CAP, so CAPs repeat until both heard
--   REQ  <rid> <guildKey> <cursor>          "your entries with chg > cursor"
--   PAGE <rid> <guildKey> <cursor> <next> <more>, then entries
-- Same guild only (owner): a peer is pulled only when its CAP names my guild;
-- a REQ or PAGE for another guild is ignored; a guild change drops what's in
-- flight. One page in flight per peer; a PAGE counts only if it continues from
-- my stored cursor for that peer and guild (a late page still does; one for an
-- older cursor doesn't), and only from a peer I've asked; the cursor moves only
-- when a whole page arrived.

local ADDON = ...
GuildSpy = GuildSpy or {}
local AS = {}
GuildSpy.AccountSync = AS

local Wire, Log = GuildSpy.Wire, GuildSpy.Log

AS.TAG = "GuildSpy"
AS.PAGE_BYTES = 6000        -- entries per page, encoded: about 30 game-data frames, under 10 s
                            -- at ChatThrottleLib's 800 B/s (the library carries up to 16 KB)
AS.TIMEOUT = 90             -- seconds a request may stay unanswered (a page is slow over Battle.net)
AS.POLL = 300               -- a pull per peer this often
AS.CAP_EVERY = 300          -- our CAP to a peer at most this often (sooner when our guild changed)

-- What an entry carries on the wire: Log.FIELDS and its namespace. Never seq,
-- chg, here, trust or reporter: those are the receiver's (SYNC.md §2).
AS.FIELDS = {}
for _, f in ipairs(Log.FIELDS) do AS.FIELDS[#AS.FIELDS + 1] = f end
AS.FIELDS[#AS.FIELDS + 1] = "ns"
local ALLOWED = {}
for _, f in ipairs(AS.FIELDS) do ALLOWED[f] = true end

------------------------------------------------------------
-- The core
------------------------------------------------------------

local Core = {}
Core.__index = Core

-- o: db (GuildSpyDB-shaped), gs(key) -> that guild's state, key() -> my
-- current guild key or nil, now(), send(guid, text) -> true when handed to
-- the wire, onReceived(added, key) (optional), onChanged() (optional: any
-- entry added or updated), onStatus() (optional: a peer synced, came, went or
-- named another guild).
function AS.NewCore(o)
    return setmetatable({ o = o, peers = {}, rid = 0 }, Core)
end

function Core:peer(guid, name)
    local p = self.peers[guid]
    if not p then
        p = { guid = guid }
        self.peers[guid] = p
    end
    if name then p.name = name end
    return p
end

-- Our CAP; recorded as sent only when the library took it (it answers "not
-- ready" until the peer's handshake is done, #40 review).
function Core:sendCap(p)
    local key = self.o.key() or ""
    if self.o.send(p.guid, Wire.Message("CAP", { key, p.guild ~= nil and "1" or "0" })) then
        p.capSentAt, p.capKey = self.o.now(), key
    end
end

-- Whether to send our CAP now: never sent, our guild changed, it hasn't
-- confirmed hearing ours (again after 10 s), or it's been a while.
function Core:capDue(p, now)
    if not p.capSentAt or p.capKey ~= (self.o.key() or "") then return true end
    if not p.heardUs and now - p.capSentAt >= 10 then return true end
    return now - p.capSentAt >= AS.CAP_EVERY
end

-- The library's current peers: a CAP to each we haven't told our guild
-- lately (or since it changed); peers that left are forgotten.
function Core:Discover(list)
    local now, key, seen = self.o.now(), self.o.key() or "", {}
    for _, s in ipairs(list or {}) do
        if type(s) == "table" and type(s.guid) == "string" then
            seen[s.guid] = true
            local fresh = not self.peers[s.guid]
            local p = self:peer(s.guid, s.name)
            if fresh then self:status() end
            if self:capDue(p, now) then self:sendCap(p) end
        end
    end
    for guid in pairs(self.peers) do
        if not seen[guid] then self.peers[guid] = nil; self:status() end
    end
end

function Core:status() if self.o.onStatus then self.o.onStatus() end end

-- Ask a peer for the next page, if it shares my guild and nothing is in flight.
function Core:Pull(guid)
    local p, key = self.peers[guid], self.o.key()
    if not p or not key or p.guild ~= key then return false end
    local now = self.o.now()
    if p.out and now - p.out.at < AS.TIMEOUT then return false end
    local gs = self.o.gs(key)
    if not gs then return false end
    gs.peerMark = type(gs.peerMark) == "table" and gs.peerMark or {}
    local cursor = tonumber(gs.peerMark[guid]) or 0
    self.rid = self.rid + 1
    p.pulledAt = now
    if not self.o.send(guid, Wire.Message("REQ", { tostring(self.rid), key, cursor })) then return false end
    p.out = { rid = tostring(self.rid), key = key, cursor = cursor, at = now }
    p.asked = true
    return true
end

-- My entries with chg > cursor, in chg order, up to a page; the next cursor
-- and whether more remain. An empty page still moves the cursor to my latest
-- change, so an idle tail isn't asked again.
function AS.BuildPage(gs, cursor)
    local list = {}
    for _, e in ipairs(gs.log or {}) do
        if type(e.chg) == "number" and e.chg > cursor then list[#list + 1] = e end
    end
    table.sort(list, function(a, b) return a.chg < b.chg end)
    local lines, size, nextCursor, more = {}, 0, cursor, false
    for i, e in ipairs(list) do
        local line = Wire.Entry(e, AS.FIELDS)
        if size + #line + 1 > AS.PAGE_BYTES and #lines > 0 then more = true; break end
        lines[#lines + 1] = line
        size = size + #line + 1
        nextCursor = e.chg
        if i == #list then nextCursor = math.max(nextCursor, tonumber(gs.nextChg) or 0) end
    end
    if #list == 0 then nextCursor = math.max(cursor, tonumber(gs.nextChg) or 0) end
    return lines, nextCursor, more
end

function Core:OnMessage(text, sender)
    if type(sender) ~= "table" or type(sender.guid) ~= "string" then return end
    local kind, f, lines = Wire.Read(text)
    if not kind then return end
    local p = self:peer(sender.guid, sender.name)
    local key, now = self.o.key(), self.o.now()
    if kind == "CAP" then
        local was = p.guild
        p.guild = f[1] ~= "" and f[1] or nil
        if p.guild ~= was then self:status() end
        p.heardUs = f[2] == "1"
        -- Tell it ours if it hasn't heard it (or our guild changed).
        if not p.heardUs or self:capDue(p, now) then self:sendCap(p) end
        self:Pull(sender.guid)
    elseif kind == "REQ" then
        local rid, reqKey, cursor = f[1], f[2], tonumber(f[3])
        if not (rid and cursor and key and reqKey == key) then return end      -- same guild only
        local gs = self.o.gs(key)
        if not gs then return end
        local entries, nextCursor, more = AS.BuildPage(gs, cursor)
        self.o.send(sender.guid, Wire.Message("PAGE", { rid, key, cursor, nextCursor, more and 1 or 0 }, entries))
    elseif kind == "PAGE" then
        local pageKey, cursor, nextCursor, more = f[2], tonumber(f[3]), tonumber(f[4]), f[5] == "1"
        -- Only from a peer I've asked, for my current guild, continuing from my
        -- stored cursor: a late page for the request still counts (a page can
        -- outlast the timeout, #40 review); one for an older cursor doesn't.
        if not (p.asked and key and pageKey == key and p.guild == key and cursor and nextCursor) then return end
        local gs = self.o.gs(key)
        if not gs then return end
        gs.peerMark = type(gs.peerMark) == "table" and gs.peerMark or {}
        if cursor ~= (tonumber(gs.peerMark[sender.guid]) or 0) then return end
        local added, changed = {}, false
        local batch = Log.NewBatch(gs, now)
        for _, line in ipairs(lines) do
            local e = Wire.ReadEntry(line, ALLOWED)
            if e then
                local got, why = Log.Receive(self.o.db, gs, e, "acct", nil, now, batch)
                if got then changed = true end
                if got and (why == "added" or why == "superseded") then added[#added + 1] = got end
            end
        end
        if changed then Log.Prune(gs, now) end
        gs.peerMark[sender.guid] = nextCursor
        p.out = nil
        if #added > 0 and self.o.onReceived then self.o.onReceived(added, key) end
        if changed and self.o.onChanged then self.o.onChanged() end
        if more then
            self:Pull(sender.guid)
        else
            -- For this guild: after a guild change it no longer says synced (#40 Codex review).
            p.syncedAt, p.syncedKey = now, key
            self:status()
        end
    end
end

-- Every few seconds: a timed-out request is asked again; a quiet peer is pulled.
function Core:Tick()
    local now = self.o.now()
    for guid, p in pairs(self.peers) do
        if p.out and now - p.out.at >= AS.TIMEOUT then
            p.out = nil
            self:Pull(guid)
        elseif not p.out and p.guild and (not p.pulledAt or now - p.pulledAt >= AS.POLL) then
            self:Pull(guid)
        end
    end
end

-- My guild changed (or I left it): drop what's in flight; the next pass tells peers.
function Core:GuildChanged()
    for _, p in pairs(self.peers) do p.out = nil end
end

------------------------------------------------------------
-- The shell: the library, the scanner's guild, the catch-up line
------------------------------------------------------------

AS.TICK = 10
AS.QUIET, AS.MAX_WAIT = 10, 60      -- the catch-up line: after 10 s quiet, at most 60 s after the first

local inst, core, lastKey
local pending, firstAt, quietTimer = nil, nil, 0

local function settings() return GuildSpyDB and GuildSpyDB.settings or {} end
function AS.Enabled() return settings().syncAccounts ~= false end

local function canView() return GuildSpy.API.CanViewOfficerNote() == true end

-- One line for what arrived, batched (SYNC.md §9): the visible new entries,
-- after a quiet spell, never later than MAX_WAIT after the first.
local function flush()
    if not pending then return end
    local mine, reports = 0, 0
    for _, e in ipairs(pending) do
        -- One a later record covered isn't kept: not counted (#41).
        if not e.covered and Log.Visible(e, canView()) then
            if e.trust == "guild" then reports = reports + 1 else mine = mine + 1 end
        end
    end
    pending, firstAt = nil, nil
    if mine + reports == 0 then return end
    local parts = {}
    if mine > 0 then parts[#parts + 1] = mine .. (mine == 1 and " change" or " changes") .. " from your other account" end
    if reports > 0 then parts[#parts + 1] = reports .. (reports == 1 and " report" or " reports") .. " from guildmates" end
    print("|cff7fd4ffGuildSpy:|r " .. table.concat(parts, ", ") .. " " .. Log.OPEN_LINK)
end

local function received(added)
    pending = pending or {}
    for _, e in ipairs(added) do pending[#pending + 1] = e end
    firstAt = firstAt or time()
    quietTimer = quietTimer + 1
    local mine = quietTimer
    C_Timer.After(AS.QUIET, function() if mine == quietTimer then flush() end end)
    if time() - firstAt >= AS.MAX_WAIT then flush() end
end

-- The status the Sharing page shows: { { name, syncedAt, guild } } and whether it runs.
function AS.Status()
    local out = {}
    for _, p in pairs(core and core.peers or {}) do
        out[#out + 1] = { name = p.name or "?", syncedAt = p.syncedAt, syncedKey = p.syncedKey, guild = p.guild }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out, inst ~= nil and AS.Enabled()
end

function AS.SetEnabled(on)
    settings().syncAccounts = on and true or false
    if inst and inst.SetEnabled then pcall(inst.SetEnabled, on and true or false) end
    if not on and core then core.peers = {} end
end

local function tick()
    if not (inst and core and AS.Enabled()) then return end
    local key = core.o.key()
    if key ~= lastKey then
        lastKey = key
        core:GuildChanged()
        core:status()
    end
    local ok, list = pcall(inst.Peers)
    core:Discover(ok and list or {})
    core:Tick()
    if firstAt and time() - firstAt >= AS.MAX_WAIT then flush() end
end

local function start()
    if inst then return end
    local ok, lib = pcall(LibStub, "LibAccountSync-1.0")
    if not (ok and lib and lib.New) then return end
    local made, i = pcall(lib.New, lib, {
        addon = AS.TAG,
        store = function() return GuildSpyDB and GuildSpyDB.accountSync end,
        maxPayload = 16384,
        messages = true,
    })
    -- Messages mode only: an older copy would give snapshots and drop requests.
    if not (made and type(i) == "table" and i.messages == true and i.SendTo) then return end
    inst = i
    core = AS.NewCore({
        db = GuildSpyDB,
        gs = function(key)
            local gs, k = GuildSpy.Scanner.Current()
            if gs and k == key then return gs end
        end,
        key = function() return select(2, GuildSpy.Scanner.Current()) end,
        now = time,
        send = function(guid, text)
            local ok, n = pcall(inst.SendTo, guid, text)
            return ok and n == 1                               -- 0: not ready yet; nil: not sent
        end,
        onReceived = received,
        onChanged = function() if GuildSpy.UI and GuildSpy.UI.Refresh then GuildSpy.UI.Refresh() end end,
        onStatus = function() if GuildSpy.Options and GuildSpy.Options.RefreshSharing then GuildSpy.Options.RefreshSharing() end end,
    })
    inst.OnMessage(function(payload, sender) if AS.Enabled() then core:OnMessage(payload, sender) end end)
    -- One switch: ours, passed on either way (the library keeps its own copy, #40 review).
    if inst.SetEnabled then pcall(inst.SetEnabled, AS.Enabled()) end
    C_Timer.NewTicker(AS.TICK, tick)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", start)

AS._test = { core = function() return core end, inst = function() return inst end, flush = flush, tick = tick }
