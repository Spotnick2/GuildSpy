-- AccountSync.lua: sync between my own accounts (#37, docs/SYNC.md §4), over
-- LibAccountSync-1.0 (Battle.net game data, ownership proven by the library).
--
-- The protocol is a core with no client calls of its own (AS.NewCore): it is
-- given a clock, a send function and the store, so two cores (two accounts)
-- run side by side in the tests. The shell at the bottom ties one core to the
-- library, the scanner's guild and the catch-up line.
--
-- Messages (Wire.lua), all to one peer (SendTo, never a broadcast):
--   CAP  <guildKey>                         my current guild ("" when none)
--   REQ  <rid> <guildKey> <cursor>          "your entries with chg > cursor"
--   PAGE <rid> <guildKey> <cursor> <next> <more>, then entries
-- Same guild only (owner): a peer is pulled only when its CAP names my guild;
-- a REQ or PAGE for another guild is ignored; a guild change drops what's in
-- flight. One page in flight per peer; a PAGE counts only for the request it
-- answers (rid, guild, cursor); the cursor moves only when a whole page arrived.

local ADDON = ...
GuildSpy = GuildSpy or {}
local AS = {}
GuildSpy.AccountSync = AS

local Wire, Log = GuildSpy.Wire, GuildSpy.Log

AS.TAG = "GuildSpy"
AS.PAGE_BYTES = 12000       -- entries per page, encoded (the library carries up to 16 KB)
AS.TIMEOUT = 30             -- seconds a request may stay unanswered
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
-- current guild key or nil, now(), send(guid, text), onReceived(added, key)
-- (optional), onSynced(peer) (optional).
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

function Core:sendCap(p)
    p.capSentAt, p.capKey = self.o.now(), self.o.key() or ""
    self.o.send(p.guid, Wire.Message("CAP", { p.capKey }))
end

-- The library's current peers: a CAP to each we haven't told our guild
-- lately (or since it changed); peers that left are forgotten.
function Core:Discover(list)
    local now, key, seen = self.o.now(), self.o.key() or "", {}
    for _, s in ipairs(list or {}) do
        if type(s) == "table" and type(s.guid) == "string" then
            seen[s.guid] = true
            local p = self:peer(s.guid, s.name)
            if not p.capSentAt or p.capKey ~= key or now - p.capSentAt >= AS.CAP_EVERY then self:sendCap(p) end
        end
    end
    for guid in pairs(self.peers) do if not seen[guid] then self.peers[guid] = nil end end
end

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
    p.out = { rid = tostring(self.rid), key = key, cursor = cursor, at = now }
    p.pulledAt = now
    self.o.send(guid, Wire.Message("REQ", { p.out.rid, key, cursor }))
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
        p.guild = f[1] ~= "" and f[1] or nil
        -- Tell it ours too, unless we just did with this guild.
        if not p.capSentAt or p.capKey ~= (key or "") or now - p.capSentAt >= 60 then self:sendCap(p) end
        self:Pull(sender.guid)
    elseif kind == "REQ" then
        local rid, reqKey, cursor = f[1], f[2], tonumber(f[3])
        if not (rid and cursor and key and reqKey == key) then return end      -- same guild only
        local gs = self.o.gs(key)
        if not gs then return end
        local entries, nextCursor, more = AS.BuildPage(gs, cursor)
        self.o.send(sender.guid, Wire.Message("PAGE", { rid, key, cursor, nextCursor, more and 1 or 0 }, entries))
    elseif kind == "PAGE" then
        local rid, pageKey, cursor, nextCursor, more = f[1], f[2], tonumber(f[3]), tonumber(f[4]), f[5] == "1"
        local out = p.out
        -- Only the answer to the request in flight, for my current guild.
        if not (out and rid == out.rid and pageKey == out.key and cursor == out.cursor and key == out.key
                and nextCursor) then return end
        local gs = self.o.gs(key)
        if not gs then return end
        local added = {}
        for _, line in ipairs(lines) do
            local e = Wire.ReadEntry(line, ALLOWED)
            if e then
                local got, why = Log.Receive(self.o.db, gs, e, "acct", nil, now)
                if got and (why == "added" or why == "superseded") then added[#added + 1] = got end
            end
        end
        gs.peerMark = type(gs.peerMark) == "table" and gs.peerMark or {}
        gs.peerMark[sender.guid] = nextCursor
        p.out = nil
        if #added > 0 and self.o.onReceived then self.o.onReceived(added, key) end
        if more then
            self:Pull(sender.guid)
        else
            p.syncedAt = now
            if self.o.onSynced then self.o.onSynced(p) end
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
        if Log.Visible(e, canView()) then
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
    if GuildSpy.UI and GuildSpy.UI.Refresh then GuildSpy.UI.Refresh() end
end

-- The status the Sharing page shows: { { name, syncedAt, guild } } and whether it runs.
function AS.Status()
    local out = {}
    for _, p in pairs(core and core.peers or {}) do
        out[#out + 1] = { name = p.name or "?", syncedAt = p.syncedAt, guild = p.guild }
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
        send = function(guid, text) pcall(inst.SendTo, guid, text) end,
        onReceived = received,
        onSynced = function() if GuildSpy.Options and GuildSpy.Options.RefreshSharing then GuildSpy.Options.RefreshSharing() end end,
    })
    inst.OnMessage(function(payload, sender) if AS.Enabled() then core:OnMessage(payload, sender) end end)
    if not AS.Enabled() and inst.SetEnabled then pcall(inst.SetEnabled, false) end
    C_Timer.NewTicker(AS.TICK, tick)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", start)

AS._test = { core = function() return core end, inst = function() return inst end, flush = flush, tick = tick }
