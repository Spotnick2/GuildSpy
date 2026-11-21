-- wow_stubs.lua: GuildSpy's part of the WoW: Forever mock for Lua 5.1 unit
-- tests. dofile("tests/wow_stubs.lua") FIRST in every test; drive it via the
-- WoW table.
--
-- The mechanics are WowTestKit's core (tests/kit.lua loads it at the commit
-- and build tests/kit.pin names; its README is the reference): strict
-- globals, secrets, CreateFrame and the widget method recorder
-- (WoW.methodsCalled, checked by Kit.checkMethods in tests/test_methods.lua),
-- events checked against the build, OnShow / OnHide, timers and the clock
-- (WoW.now, WoW.advance), hooksecurefunc, print with its stray-"|" check,
-- WoW.fire. This file adds only what GuildSpy and its tests use beyond them:
-- the templates' children, the tooltip, Blizzard's list and menu mixins, the
-- recording fakes of the libraries, and the client APIs the addon reads.
--
-- AN ALLOWLIST: before stubbing a global, confirm it is in the API dump
-- (C:\Projects\WoW\References\Forever\api\, the build tests/kit.pin names)
-- and copy its signature; defining something Forever lacks lets a broken call
-- pass.
--
-- Fields that tests drive: WoW.now (GetTime), WoW.epoch (time()), frame._left /
-- frame._top (what GetLeft / GetTop answer), frame._mouseOver, and the guild:
-- WoW.guild (see "The guild" below).
dofile("tests/kit.lua")
local Methods = WoW.Methods

--------------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------------

-- What the client's templates make that the addon reaches (the field each is
-- proved by, as API.SafeFrame checks), unless the test says the template is
-- missing (WoW.missingTemplates: CreateFrame then returns a bare frame, as the
-- client does). A template font string has its font (wow-ui-source forever
-- 70959): CheckButtonTemplates.xml:8 and :54 (GameFontNormalSmall),
-- SecureUIPanelTemplates.xml:81-82 (UIPanelButtonNoTooltipTemplate's
-- ButtonText, NormalFont GameFontNormal).
local function templateFontString(w, font)
    local fs = WoW.newWidget("FontString", w)
    fs._fontTemplate = font
    return fs
end
local function unlessMissing(build)
    return function(w, t) if not WoW.missingTemplates[t] then build(w, t) end end
end
WoW.templates.UICheckButtonTemplate = unlessMissing(function(w) w.text = templateFontString(w, "GameFontNormalSmall") end)
WoW.templates.UIRadioButtonTemplate = unlessMissing(function(w) w.text = templateFontString(w, "GameFontNormalSmall") end)
WoW.templates.UIPanelButtonTemplate = unlessMissing(function(w) w.Text = templateFontString(w, "GameFontNormal") end)
WoW.templates.RightSideTabTemplate = unlessMissing(function(w) w.Icon = WoW.newWidget("Texture", w) end)   -- RightSideTab.xml's parentKey="Icon"
WoW.templates.UIPanelScrollFrameTemplate = unlessMissing(WoW.templates.UIPanelScrollFrameTemplate)        -- the core's

--------------------------------------------------------------------------------
-- Widget methods the core doesn't have, or that differ from the core's (each
-- because a test relies on it)
--------------------------------------------------------------------------------

-- The tooltip (its lines, _lines, and its owner, _owner) is the kit's
-- (WowTestKit #89): SetText is line 1, as NumLines counts it on the client.
-- A texture's coordinates (test_ui reads the class icon's).
function Methods.SetTexCoord(w, ...) w._texCoord = { ... } end
-- A FontString's text width: 7 px a visible character (colour codes take none).
function Methods.GetUnboundedStringWidth(w)
    local plain = (w._text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return #plain * 7
end
-- Blizzard's mixins, which the dump's widget walk can't see (test_methods
-- allows each pair, citing the file):
-- A WowScrollBoxList's data: the list it was given (ScrollBoxListMixin:SetDataProvider).
function Methods.SetDataProvider(w, dp) w._dataProvider = dp end
-- Its scroll position in pixels (ScrollBoxBaseMixin), clamped to the content.
function Methods.GetDerivedScrollOffset(w) return w._offset or 0 end
function Methods.ScrollToOffset(w, o)
    local n = w._dataProvider and w._dataProvider:GetSize() or 0
    local extent = w._extent or 20
    w._offset = math.max(0, math.min(o, n * extent))
end
-- A WowStyle1DropdownTemplate's menu (DropdownButtonMixin:SetupMenu): the
-- generator, run by a test with a fake root.
function Methods.SetupMenu(w, fn) w._menu = fn end

--------------------------------------------------------------------------------
-- The clock and the drivers
--------------------------------------------------------------------------------

-- WowTestKit #103: the calendar clock (time(), WoW.epoch) must move with
-- WoW.now at each timer's due time, and the kit has no calendar clock. Since
-- WowTestKit #86 the core runs each timer with GetTime() at its due time, but
-- time() would stay where the advance started: a scan stamps the wrong time,
-- and a system message falls outside the scan's interval and loses its
-- officer (test_scanner). So the clock still goes from one due time to the
-- next here, moving WoW.epoch with WoW.now, the core's WoW.advance(0) running
-- what is due at each. A 0-second ticker isn't a due time to step to: it
-- re-arms at the current time (WowTestKit #76), so the loop would never end.
-- The core fires it once in each advance(0).
local kitAdvance = WoW.advance
local function moveTo(at)
    WoW.epoch = WoW.epoch + (at - WoW.now)
    WoW.now = at
    kitAdvance(0)
end
function WoW.advance(dt)
    local target = WoW.now + dt
    while true do
        local due
        for _, t in ipairs(WoW.timers) do
            local at = t.at or t.s or 0
            if not t.cancelled and not (t.every and t.every <= 0) and at <= target and (not due or at < due) then due = at end
        end
        if not due then break end
        moveTo(math.max(due, WoW.now))
    end
    moveTo(target)
end

-- Runs a slash command as the chat box would, matching SLASH_<KEY><n> aliases.
function WoW.slash(line)
    local cmd, rest = line:match("^(%S+)%s*(.*)$")
    for key, fn in pairs(SlashCmdList) do
        for i = 1, 10 do
            local alias = rawget(_G, "SLASH_" .. key .. i)
            if not alias then break end
            if alias == cmd then return fn(rest) end
        end
    end
    error("unknown slash command " .. cmd)
end

-- This client's state, reset with the core's by WoW.reset() (loadAddon calls it).
table.insert(WoW.onReset, function()
    WoW.now, WoW.epoch = 0, 1790000000
    WoW.fileIDs = {}
    WoW.missingTemplates = {}
    -- The level cap (#34): both functions answer it on Forever (Vanilla content: 60);
    -- a test can take one away (WoW.capFns.expansion = false) or change the value.
    WoW.levelCap, WoW.capFns = 60, { expansion = true, player = true }
    WoW.sounds = {}
    WoW.metadata = { Version = "@project-version@" }
    WoW.build = { "1.60.1", "71037", "Nov 18 2026", 16001 }
    -- The realm is hidden since the 2026-11-20 server hotfix: GetRealmName() is "" (porting guide).
    WoW.playerName, WoW.playerSurname, WoW.realm = "Fizzle", "Sprocketwhistle", ""
    WoW.guild = nil
    WoW.rosterRequests, WoW.eventLogQueries = 0, 0
    SlashCmdList = {}
    UISpecialFrames = {}
    WoW.loadedAddOns = {}
    -- EventRegistry: the callbacks registered, by event (CallbackRegistryMixin
    -- passes the owner first).
    WoW.callbacks = {}
    EventRegistry = {
        RegisterCallback = function(self, event, fn, owner)
            WoW.callbacks[event] = WoW.callbacks[event] or {}
            table.insert(WoW.callbacks[event], { fn = fn, owner = owner })
        end,
        TriggerEvent = function(self, event, ...)
            for _, c in ipairs(WoW.callbacks[event] or {}) do c.fn(c.owner, ...) end
        end,
    }
    UIParent._width, UIParent._height = 1366, 768
    GameTooltip = WoW.newWidget("GameTooltip", UIParent, "GameTooltip")
    -- Retail's Settings framework: Options > AddOns. Recorded in WoW.settings.
    WoW.settings = { canvas = {}, addons = {}, subs = {} }
    WoW.ldb, WoW.ldbi = nil, nil                -- made on first use (LibStub, below)
    WoW.las, WoW.lasSent, WoW.lasPeers, WoW.lasSnapshots, WoW.noAccountSync = nil, {}, {}, nil, nil
    WoW.lasNotReady, WoW.lasStoredOff = {}, nil
    WoW.prefixes, WoW.addonSent, WoW.addonResult, WoW.ctlHeld = {}, {}, nil, {}
    ChatThrottleLib = WoW.newCTL and WoW.newCTL() or nil
    -- Blizzard's Settings window (HIGH strata), hidden until opened.
    SettingsPanel = WoW.newWidget("Frame", UIParent, "SettingsPanel")
    SettingsPanel._strata = "HIGH"
    SettingsPanel._shown, SettingsPanel._vis = false, false
end)

--------------------------------------------------------------------------------
-- Libraries
--------------------------------------------------------------------------------

-- Fake LibDataBroker-1.1 and LibDBIcon-1.0 (the vendored Libs\ are not loaded
-- in tests; Gnomesweeper's way). The fakes record what they are given:
-- WoW.ldb.objects, WoW.ldbi.registered / .buttons, and Show/Hide on the button.
-- LibStub itself is the REAL one the embedded LibGlass-1.0 brings; WoW.fakeLibs
-- then answers these two names with the fakes, every other from the real one.
local function fakeLib(major)
    if major == "LibDataBroker-1.1" then WoW.ldb = WoW.ldb or WoW.newLDB(); return WoW.ldb end
    if major == "LibDBIcon-1.0" then WoW.ldbi = WoW.ldbi or WoW.newLDBI(); return WoW.ldbi end
    if major == "LibAccountSync-1.0" and not WoW.noAccountSync then WoW.las = WoW.las or WoW.newLAS(); return WoW.las end
end
function WoW.fakeLibs(stub)
    setmetatable(stub, { __call = function(self, major, silent)
        return fakeLib(major) or self:GetLibrary(major, silent)
    end })
end
function WoW.newLDB()
    local lib = { objects = {} }
    function lib:NewDataObject(name, obj) self.objects[name] = obj; return obj end
    return lib
end
function WoW.newLDBI()
    local lib = { registered = {}, buttons = {}, registrations = 0 }
    function lib:Register(name, obj, db)
        self.registrations = self.registrations + 1
        local b = WoW.newWidget("Button", UIParent, "LibDBIcon10_" .. name)
        b._scripts.OnClick = function(self, mouse) obj.OnClick(self, mouse) end
        b.dataObject, b.db = obj, db
        if db.hide then b._shown, b._vis = false, false end
        self.registered[name], self.buttons[name] = db, b
    end
    -- As the real one (LibDBIcon-1.0 MINOR 56): Show/Hide only show or hide the
    -- button (Show re-anchors it on the ring); neither touches the saved table.
    function lib:Show(name) self.buttons[name]:Show(); self.buttons[name]._repositioned = true end
    function lib:Hide(name) self.buttons[name]:Hide() end
    function lib:GetMinimapButton(name) return self.buttons[name] end
    return lib
end

-- A scripted LibAccountSync-1.0 (#37), as AltStable's tests use: New records
-- the instance; SendTo records sends in WoW.lasSent; WoW.lasPeers is Peers();
-- WoW.lasDeliver(payload, sender) hands a message to the registered handler.
function WoW.newLAS()
    local lib = { instances = {} }
    function lib:New(o)
        -- enabled: the library's own stored switch (WoW.lasStoredOff: an earlier "off").
        local inst = { opts = o, messages = (o.messages == true and not WoW.lasSnapshots) or nil,
                       enabled = not WoW.lasStoredOff }
        inst.OnMessage = function(fn) inst.handler = fn end
        inst.Peers = function() return WoW.lasPeers or {} end
        -- As the real SendTo (LibAccountSync.lua I.SendTo): nil, "disabled" when off;
        -- 0 ("not-ready") while the peer's handshake isn't done; else 1.
        inst.SendTo = function(guid, payload, cb)
            if not inst.enabled then return nil, "disabled" end
            if WoW.lasNotReady[guid] then return 0 end
            WoW.lasSent[#WoW.lasSent + 1] = { guid = guid, payload = payload }
            return 1
        end
        inst.SetEnabled = function(on) inst.enabled = on end
        inst.IsEnabled = function() return inst.enabled end
        self.instances[#self.instances + 1] = inst
        return inst
    end
    return lib
end
function WoW.lasDeliver(payload, sender)
    local inst = WoW.las and WoW.las.instances[1]
    if inst and inst.handler then inst.handler(payload, sender, 1) end
end

--------------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------------

Settings = {
    RegisterCanvasLayoutCategory = function(frame, name)
        local cat = { frame = frame, name = name, GetID = function() return "cat:" .. name end }
        WoW.settings.canvas[#WoW.settings.canvas + 1] = cat
        return cat
    end,
    RegisterAddOnCategory = function(cat) WoW.settings.addons[#WoW.settings.addons + 1] = cat end,
    OpenToCategory = function(id) WoW.settings.opened = id; SettingsPanel:Show() end,
    RegisterCanvasLayoutSubcategory = function(parent, frame, name)
        local cat = { parent = parent, frame = frame, name = name }
        WoW.settings.subs[#WoW.settings.subs + 1] = cat
        return cat
    end,
}

-- The calendar clock: WoW.epoch, moved by WoW.advance (above).
function time(t) if t then return os.time(t) end return WoW.epoch end
function GetMaxLevelForPlayerExpansion()
    if not WoW.capFns.expansion then error("not on this client") end
    WoW.capCalls = (WoW.capCalls or 0) + 1
    return WoW.levelCap
end
function GetMaxPlayerLevel()
    if not WoW.capFns.player then error("not on this client") end
    return WoW.levelCap
end
-- PlaySound(kit, channel): recorded; answers willPlay as the client does.
function PlaySound(kit, channel) WoW.sounds[#WoW.sounds + 1] = { kit = kit, channel = channel }; return true end
-- Whether the client has a template (the test can say it's missing).
function DoesTemplateExist(name) return not WoW.missingTemplates[name] end
function date(fmt, t) return os.date(fmt, t) end
-- The player, on 70009+: the surname comes back in the second return.
function UnitName(unit) if unit == "player" then return WoW.playerName, WoW.playerSurname end return nil end
function GetRealmName() return WoW.realm end
function GetBuildInfo() return unpack(WoW.build) end
-- The client's file table: WoW.fileIDs[path] = id; anything else answers nil.
function GetFileIDFromPath(path) return WoW.fileIDs[path] end
C_AddOns = {
    GetAddOnMetadata = function(name, key) return WoW.metadata[key] end,
    IsAddOnLoaded = function(name) return WoW.loadedAddOns[name] == true end,
}

-- The retail list widgets Forever ships (Blizzard_SharedXML/Shared/Scroll):
-- the view keeps its row initializer, so a test can draw a row with it.
function CreateScrollBoxListLinearView()
    local view = {}
    function view:SetElementExtent(h) self.extent = h end
    function view:SetElementInitializer(frameType, fn) self.rowType, self.initializer = frameType, fn end
    return view
end
ScrollUtil = { InitScrollBoxListWithScrollBar = function(box, bar, view) box._view, box._bar = view, bar end }
function CreateDataProvider(list)
    local dp = { list = list or {} }
    function dp:GetSize() return #self.list end
    return dp
end

--------------------------------------------------------------------------------
-- The guild
--
-- WoW.guild = { name, realm, ranks = { "Guild Master", ... } (rank index 0 first),
--   members = { { name, rank (0-based index), level, class, zone, note, onote,
--                 online, guid, lastOnline = { y, m, d, h } }, ... },
--   events = { { type, p1, p2, rank, y, m, d, h }, ... }, canViewOfficerNote,
--   isOfficer, motd, clubId }.
--
-- MEASURED (1.60.1.70338, docs/FOREVER-PROBE.md): GetGuildRosterInfo returns 17
-- values in Retail's order, the GUID last, the name with its surname and no
-- realm, the rank index 0-based (0 = Guild Master), the officer note "" for a
-- character that can't view it. GetGuildRosterLastOnline is four nils for an
-- online member, else years, months, days, hours. GetNumGuildMembers returns
-- two values. GetGuildEventInfo returns 8 values (type, player1, player2, rank,
-- years, months, days, hours), oldest first. player1/player2 are nil until the
-- burst of GUILD_EVENT_LOG_UPDATE has settled, then named: WoW.guild.eventNames
-- (nil: still settling) models both.
--------------------------------------------------------------------------------

function IsInGuild() return WoW.guild ~= nil end
-- The 4th return is the GUILD's realm, which can differ from the player's (porting guide).
function GetGuildInfo(unit)
    local gd = WoW.guild
    if unit ~= "player" or not gd or gd.loading then return nil end
    return gd.name, gd.ranks[(gd.myRank or 0) + 1], gd.myRank or 0, gd.realm
end
function GetNumGuildMembers()
    local gd = WoW.guild
    if not gd or gd.loading then return 0, 0 end
    local online = 0
    for _, m in ipairs(gd.members) do if m.online then online = online + 1 end end
    return #gd.members, online
end
function GetGuildRosterShowOffline() return not (WoW.guild and WoW.guild.hideOffline) end
function GetGuildRosterInfo(i)
    local m = WoW.guild and not WoW.guild.loading and WoW.guild.members[i]
    if not m then return nil end
    local onote = WoW.guild.canViewOfficerNote and m.onote or ""
    return m.name, WoW.guild.ranks[m.rank + 1], m.rank, m.level, m.class, m.zone or "",
        m.note or "", onote, m.online and true or false, 0, m.class, -1, 0, false, false, 3, m.guid
end
function GetGuildRosterLastOnline(i)
    local m = WoW.guild and WoW.guild.members[i]
    if not m then return nil end
    if m.online or not m.lastOnline then return nil, nil, nil, nil end
    return m.lastOnline[1], m.lastOnline[2], m.lastOnline[3], m.lastOnline[4]
end
function GuildControlGetNumRanks() return WoW.guild and #WoW.guild.ranks or 0 end
function GuildControlGetRankName(i) return WoW.guild and WoW.guild.ranks[i] end
function QueryGuildEventLog() WoW.eventLogQueries = WoW.eventLogQueries + 1 end
function GetNumGuildEvents() return WoW.guild and WoW.guild.events and #WoW.guild.events or 0 end
function GetGuildEventInfo(i)
    local e = WoW.guild and WoW.guild.events and WoW.guild.events[i]
    if not e then return nil end
    local names = WoW.guild.eventNames
    return e[1], names and e[2] or nil, names and e[3] or nil, e[4], e[5], e[6], e[7], e[8]
end
C_GuildInfo = {
    GuildRoster = function() WoW.rosterRequests = WoW.rosterRequests + 1 end,
    CanViewOfficerNote = function() return WoW.guild ~= nil and WoW.guild.canViewOfficerNote == true end,
    IsGuildOfficer = function() return WoW.guild ~= nil and WoW.guild.isOfficer == true end,
    -- Protected in some state on Forever (#16): counted so a test can prove the
    -- scan never calls it.
    GetMOTD = function()
        WoW.motdReads = (WoW.motdReads or 0) + 1
        return WoW.guild and WoW.guild.motd or ""
    end,
}
-- WoW.guild.club = { { ClubMemberInfo fields }, ... } (memberId = its index).
C_Club = {
    GetGuildClubId = function() return WoW.guild and WoW.guild.clubId end,
    GetClubMembers = function(clubId)
        local ids = {}
        for i in ipairs(WoW.guild and WoW.guild.club or {}) do ids[i] = i end
        return ids
    end,
    GetMemberInfo = function(clubId, memberId) return WoW.guild and WoW.guild.club and WoW.guild.club[memberId] end,
}
-- Localized system strings: enUS, as read from the client (70338, the probe).
ERR_GUILD_JOIN_S = "%s has joined the guild."
ERR_GUILD_LEAVE_S = "%s has left the guild."
ERR_GUILD_REMOVE_SS = "%s has been kicked out of the guild by %s."
ERR_GUILD_PROMOTE_SSS = "%s has promoted %s to %s."
ERR_GUILD_DEMOTE_SSS = "%s has demoted %s to %s."
ERR_GUILD_LEADER_CHANGED_SS = "%s has made %s the new Guild Master."

function CreateColor(r, g, b, a) return { r = r, g = g, b = b, a = a } end
Enum = { UITextureSliceMode = { Stretched = 0, Tiled = 1 },
         ClubMemberPresence = { Unknown = 0, Online = 1, OnlineMobile = 2, Offline = 3, Away = 4, Busy = 5 } }
function table.wipe(t) for k in pairs(t) do t[k] = nil end return t end
wipe = table.wipe

-- Addon messages (#38), as Gnomesweeper's stubs model them: a GUILD message is
-- recorded in WoW.addonSent and, as the server does, echoed to its sender as
-- CHAT_MSG_ADDON. Measured (Gnomesweeper, 70205): the sender is "First Surname",
-- no realm. WoW.addonResult: what a send answers (0: success).
C_ChatInfo = {
    RegisterAddonMessagePrefix = function(prefix)
        WoW.prefixes[prefix] = true
        return 0
    end,
    SendAddonMessage = function(prefix, message, chatType, target)
        assert(#message <= 255, "an addon message over 255 bytes")
        local result = WoW.addonResult or 0
        if result ~= 0 then return result end
        table.insert(WoW.addonSent, { prefix = prefix, message = message, chatType = chatType, target = target })
        if chatType == "GUILD" and WoW.guild then
            local me = WoW.playerName .. " " .. WoW.playerSurname
            WoW.fire("CHAT_MSG_ADDON", prefix, message, "GUILD", me, me, 0, 0, "", 0)
        end
        return 0
    end,
}
-- A scripted ChatThrottleLib (the real one comes with LibAccountSync, not
-- loaded here): it holds what it's given, like the real one under load, until
-- WoW.ctlDeliver(n) sends the oldest n (all: nil), each then reported to its
-- callback as the real v32 does: (arg, didSend, result). It raises on a
-- message over 255 bytes, as v32 does.
function WoW.newCTL()
    return {
        SendAddonMessage = function(self, prio, prefix, text, chattype, target, queueName, callback, arg)
            assert(#text <= 255, "ChatThrottleLib: message too long")
            table.insert(WoW.ctlHeld, { prio = prio, prefix = prefix, text = text, chattype = chattype,
                                        target = target, queueName = queueName, callback = callback, arg = arg })
        end,
    }
end
function WoW.ctlDeliver(n)
    local sent = 0
    while #WoW.ctlHeld > 0 and (not n or sent < n) do
        local m = table.remove(WoW.ctlHeld, 1)
        local result = C_ChatInfo.SendAddonMessage(m.prefix, m.text, m.chattype, m.target)
        sent = sent + 1
        if m.callback then m.callback(m.arg, result == 0, result) end
    end
    return sent
end

WoW.reset()

-- Strict globals: any read of a global not defined above is an error, except
-- the addon's own, which are legitimately nil before their first assignment.
-- LibStub: read by its own loader before it exists (the harness clears it for
-- each load, so the embedded LibGlass-1.0 starts fresh).
Kit.strict({ GuildSpy = true, GuildSpyDB = true, LibStub = true })
