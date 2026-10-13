-- wow_stubs.lua: a model of the Forever client, driven through WoW.
--
-- AN ALLOWLIST, like the siblings' (..\GlassRaidFrames\tests\wow_stubs.lua):
--   * Globals are STRICT: reading one that isn't defined here is an error.
--     Before stubbing a global, confirm it is in
--     C:\Projects\WoW\References\forever-api-1.60.1.70338.md and copy its signature;
--     defining something Forever lacks lets a broken call pass.
--   * RegisterEvent throws on an event the client doesn't have (the list is
--     tests/events-1.60.1.70338.txt, generated from the dump by
--     Tools/make_events_fixture.py; test_toc checks they agree).
--   * Widgets answer ANY method as a recorded no-op, so a call to a method
--     Forever lacks would pass silently: tests/test_methods.lua checks every
--     "Type:Method" in WoW.methodsCalled against the dump's widget methods.
--
-- Fields that tests drive: WoW.now (GetTime), WoW.screen (UIParent's size),
-- frame._left / frame._top (what GetLeft / GetTop answer), frame._mouseOver,
-- and the guild: WoW.guild (see "The guild" below).

local EVENTS_FIXTURE = "tests/events-1.60.1.70338.txt"

WoW = { frames = {}, chat = {}, methodsCalled = {}, now = 0, screen = { w = 1366, h = 768 } }

WoW.KNOWN_EVENTS = {}
do
    local f = assert(io.open(EVENTS_FIXTURE, "r"), EVENTS_FIXTURE .. " missing (python Tools/make_events_fixture.py)")
    for line in f:lines() do
        local name = line:match("^([A-Z][A-Z0-9_]+)%s*$")
        if name then WoW.KNOWN_EVENTS[name] = true end
    end
    f:close()
end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

local Methods = {}   -- the methods that do something; every other one is a recorded no-op

local widgetMT = {
    __index = function(w, k)
        if type(k) ~= "string" or not k:match("^%u") then return nil end   -- fields read as nil
        return function(self, ...)
            WoW.methodsCalled[self._type .. ":" .. k] = true
            local impl = Methods[k]
            if impl then return impl(self, ...) end
            return nil
        end
    end,
}

local function newWidget(wtype, parent, name)
    local w = setmetatable({
        _type = wtype, _parent = parent, _name = name, _shown = true, _points = {},
        _scripts = {}, _events = {}, _width = 0, _height = 0, _scale = 1,
        _level = parent and parent._level and (parent._level + 1) or 1,
        _strata = "MEDIUM", _text = "",
    }, widgetMT)
    if WoW.widgets then WoW.widgets[#WoW.widgets + 1] = w end   -- every widget made (the locale guard walks them)
    if parent then
        parent._children = parent._children or {}
        table.insert(parent._children, w)
    end
    return w
end

function CreateFrame(ftype, name, parent, template)
    assert(ftype == "Frame" or ftype == "Button" or ftype == "StatusBar" or ftype == "CheckButton" or ftype == "EditBox" or ftype == "ScrollFrame"
        or ftype == "EventFrame" or ftype == "DropdownButton",
        "CreateFrame: unexpected frame type " .. tostring(ftype))
    local w = newWidget(ftype, parent or UIParent, name)
    w._template = template
    -- What the client's templates make (the field each is proved by, as API.SafeFrame checks),
    -- unless the test says the template is missing (it then returns a bare frame, as the client does).
    if template and not WoW.missingTemplates[template] then
        if template == "UICheckButtonTemplate" or template == "UIRadioButtonTemplate" then
            w.text = newWidget("FontString", w)
        elseif template == "UIPanelButtonTemplate" then
            w.Text = newWidget("FontString", w)
        elseif template == "UIPanelScrollFrameTemplate" then
            w.ScrollBar = newWidget("Slider", w)
        elseif template == "RightSideTabTemplate" then
            w.Icon = newWidget("Texture", w)          -- RightSideTab.xml's parentKey="Icon"
        end
    end
    table.insert(WoW.frames, w)
    if name then rawset(_G, name, w) end
    return w
end

function Methods.CreateTexture(w, name) return newWidget("Texture", w, name) end
-- Animations: a group records its animations and whether it plays; an
-- animation records its type, so test_methods can check each call against the
-- dump's SimpleAnim<Type>API.
function Methods.CreateAnimationGroup(w)
    local ag = newWidget("AnimationGroup", w)
    ag._anims, ag._playing = {}, false
    return ag
end
function Methods.CreateAnimation(ag, atype)
    local a = newWidget(atype or "Animation", ag)
    a._animType = atype
    table.insert(ag._anims, a)
    return a
end
function Methods.Play(ag) ag._playing = true; ag._plays = (ag._plays or 0) + 1 end
function Methods.Stop(ag) ag._playing = false end
function Methods.IsPlaying(ag) return ag._playing == true end
function Methods.SetLooping(ag, l) ag._looping = l end
function Methods.SetDegrees(a, d) a._degrees = d end
function Methods.SetStartDelay(a, d) a._delay = d end
function Methods.SetEndDelay(a, d) a._endDelay = d end
function Methods.SetDuration(a, d) a._duration = d end
function Methods.CreateMaskTexture(w, name) return newWidget("MaskTexture", w, name) end
function Methods.CreateFontString(w, name) return newWidget("FontString", w, name) end

function Methods.SetJustifyH(w, j) w._justifyH = j end

function Methods.Show(w)
    local was = w._shown
    w._shown = true
    if not was and w._scripts.OnShow then w._scripts.OnShow(w) end    -- only on a hidden > shown change
end
function Methods.Hide(w)
    local was = w._shown
    w._shown = false
    if was and w._scripts.OnHide then w._scripts.OnHide(w) end        -- only on a shown > hidden change
end
function Methods.SetShown(w, v) if v then Methods.Show(w) else Methods.Hide(w) end end
function Methods.IsShown(w) return w._shown end
function Methods.IsVisible(w)
    local p = w
    while p do
        if not p._shown then return false end
        p = p._parent
    end
    return true
end

function Methods.SetPoint(w, ...) table.insert(w._points, { ... }) end
function Methods.SetAllPoints(w, rel) w._points = { { "ALL", rel } } end
function Methods.ClearAllPoints(w) w._points = {} end
function Methods.GetNumPoints(w) return #w._points end
function Methods.GetPoint(w, i)
    local p = w._points[i or 1]
    if not p then return nil end
    return p[1], p[2], p[3], p[4], p[5]
end

function Methods.SetSize(w, x, y) w._width, w._height = x, y end
function Methods.SetWidth(w, x) w._width = x end
function Methods.SetHeight(w, y) w._height = y end
function Methods.GetWidth(w) return w._width end
function Methods.GetHeight(w) return w._height end

-- The scale chain, so a test can catch the "compared in the wrong space" class
-- of mistake (porting guide: GetCenter is in the frame's OWN space).
function Methods.SetScale(w, s) w._scale = s end
function Methods.GetScale(w) return w._scale end
function Methods.GetEffectiveScale(w)
    local s, p = 1, w
    while p do s = s * (p._scale or 1); p = p._parent end
    return s
end

function Methods.SetFrameLevel(w, l) w._level = l end
function Methods.GetFrameLevel(w) return w._level end
function Methods.SetFrameStrata(w, s) w._strata = s end
function Methods.GetFrameStrata(w) return w._strata end
function Methods.SetParent(w, p) w._parent = p end
function Methods.GetParent(w) return w._parent end
function Methods.GetName(w) return w._name end

function Methods.SetScript(w, name, fn) w._scripts[name] = fn end
function Methods.GetScript(w, name) return w._scripts[name] end
function Methods.HookScript(w, name, fn)
    local old = w._scripts[name]
    w._scripts[name] = function(...) if old then old(...) end; fn(...) end
end
function Methods.RegisterEvent(w, e)
    if not WoW.KNOWN_EVENTS[e] then error("Attempt to register unknown event \"" .. tostring(e) .. "\"", 2) end
    w._events[e] = true
    return true
end
function Methods.UnregisterEvent(w, e) w._events[e] = nil end

function Methods.SetText(w, t)
    w._text = t
    if w._type == "GameTooltip" then w._lines = {} end     -- a new tooltip starts with its title
end
function Methods.AddLine(w, text) w._lines = w._lines or {}; w._lines[#w._lines + 1] = text end
-- A tooltip's owner; taking one clears what it said, as in the client.
function Methods.SetOwner(w, owner) w._owner = owner; w._lines = {} end
function Methods.GetText(w) return w._text end
function Methods.SetTexture(w, t) w._texture = t end
function Methods.SetChecked(w, v) w._checked = v and true or false end
-- A WowScrollBoxList's data: the list it was given (ScrollBoxListMixin:SetDataProvider).
function Methods.SetDataProvider(w, dp) w._dataProvider = dp end
-- Its scroll position in pixels (ScrollBoxBaseMixin), clamped to the content.
function Methods.GetDerivedScrollOffset(w) return w._offset or 0 end
function Methods.ScrollToOffset(w, o)
    local n = w._dataProvider and w._dataProvider:GetSize() or 0
    local extent = w._extent or 20
    w._offset = math.max(0, math.min(o, n * extent))
end
-- A WowStyle1DropdownTemplate's menu: the generator, run by a test with a fake root.
function Methods.SetupMenu(w, fn) w._menu = fn end
-- A FontString's text width: 7 px a visible character (colour codes take none).
function Methods.GetUnboundedStringWidth(w)
    local plain = (w._text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return #plain * 7
end
function Methods.SetEnabled(w, v) w._enabled = v and true or false end
function Methods.IsEnabled(w) return w._enabled ~= false end
-- An edit box's selection: HighlightText() selects all, (0, 0) none.
function Methods.HighlightText(w, a, b) w._selected = not (a == 0 and b == 0) end
function Methods.GetChecked(w) return w._checked or false end
-- A button's state textures: Set* makes one, Get* returns it (so its tex coords can be set).
for _, part in ipairs({ "Normal", "Pushed", "Highlight", "Checked" }) do
    Methods["Set" .. part .. "Texture"] = function(w, t)
        local tex = newWidget("Texture", w)
        tex._texture = t
        w["_" .. part] = tex
    end
    Methods["Get" .. part .. "Texture"] = function(w) return w["_" .. part] end
end
function Methods.SetColorTexture(w, ...) w._texture = nil; w._color = { ... } end
function Methods.SetAlpha(w, a) w._alpha = a end
function Methods.SetTextureSliceMargins(w, ...) w._slice = { ... } end
function Methods.SetTexCoord(w, ...) w._texCoord = { ... } end
function Methods.SetBlendMode(w, m) w._blend = m end
function Methods.SetDesaturated(w, v) w._desaturated = v end
function Methods.GetAlpha(w) return w._alpha or 1 end
function Methods.SetVertexColor(w, ...) w._vertex = { ... } end
function Methods.SetTextColor(w, ...) w._textColor = { ... } end
function Methods.SetMovable(w, v) w._movable = v end
function Methods.SetClampedToScreen(w, v) w._clamped = v end
function Methods.EnableMouse(w, v) w._mouse = v end
function Methods.IsMovable(w) return w._movable == true end
function Methods.StartMoving(w) w._moving = true end
function Methods.StopMovingOrSizing(w) w._moving = false end
function Methods.GetLeft(w) return w._left end
function Methods.GetTop(w) return w._top end
function Methods.IsMouseOver(w) return w._mouseOver == true end


--------------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------------

function WoW.fire(event, ...)
    for _, f in ipairs(WoW.frames) do
        local fn = f._events[event] and f._scripts.OnEvent
        if fn then fn(f, event, ...) end
    end
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

function WoW.reset()
    WoW.frames, WoW.chat, WoW.widgets = {}, {}, {}
    WoW.now, WoW.epoch, WoW.timers = 0, 1790000000, {}
    WoW.fileIDs = {}
    WoW.missingTemplates = {}
    -- The level cap (#34): both functions answer it on Forever (Vanilla content: 60);
    -- a test can take one away (WoW.capFns.expansion = false) or change the value.
    WoW.levelCap, WoW.capFns = 60, { expansion = true, player = true }
    WoW.sounds = {}
    WoW.metadata = { Version = "@project-version@" }
    WoW.build = { "1.60.1", "70338", "Oct 10 2026", 16001 }
    WoW.playerName, WoW.playerSurname, WoW.realm = "Fizzle", "Sprocketwhistle", "Forever"
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
    UIParent = newWidget("Frame", nil, "UIParent")
    UIParent._width, UIParent._height = 1366, 768
    GameTooltip = newWidget("GameTooltip", UIParent, "GameTooltip")
    -- Retail's Settings framework: Options > AddOns. Recorded in WoW.settings.
    WoW.settings = { canvas = {}, addons = {}, subs = {} }
    WoW.ldb, WoW.ldbi = nil, nil                -- made on first use (LibStub, above)
    WoW.las, WoW.lasSent, WoW.lasPeers, WoW.lasSnapshots, WoW.noAccountSync = nil, {}, {}, nil, nil
    WoW.lasNotReady, WoW.lasStoredOff = {}, nil
    WoW.prefixes, WoW.addonSent, WoW.addonResult, WoW.ctlHeld = {}, {}, nil, {}
    ChatThrottleLib = WoW.newCTL and WoW.newCTL() or nil
    -- Blizzard's Settings window (HIGH strata), hidden until opened.
    SettingsPanel = newWidget("Frame", UIParent, "SettingsPanel")
    SettingsPanel._strata = "HIGH"
    SettingsPanel._shown = false
end

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
        local b = newWidget("Button", UIParent, "LibDBIcon10_" .. name)
        b._scripts.OnClick = function(self, mouse) obj.OnClick(self, mouse) end
        b.dataObject, b.db = obj, db
        if db.hide then b._shown = false end
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

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    WoW.chat[#WoW.chat + 1] = table.concat(parts, " ")
end

function GetTime() return WoW.now end
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
function GetLocale() return "enUS" end
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
-- hooksecurefunc([table,] name, fn): runs fn after the original, which it
-- replaces in the table (rawset: the client's own write, never the addon's).
function hooksecurefunc(t, name, fn)
    if type(t) == "string" then t, name, fn = _G, t, name end
    local orig = rawget(t, name) or t[name]
    rawset(t, name, function(...) local r = { orig(...) }; fn(...); return unpack(r) end)
end

-- Timers run when WoW.advance moves the clock past them, in order. The
-- calendar clock (time()) moves with it.
C_Timer = {
    After = function(seconds, fn)
        WoW.timers[#WoW.timers + 1] = { at = WoW.now + seconds, fn = fn, seq = #WoW.timers }
    end,
}
-- In the 1.60.1.70338 dump; repeats until cancelled.
function C_Timer.NewTicker(seconds, fn)
    local t = { cancelled = false }
    local function step()
        if t.cancelled then return end
        fn()
        C_Timer.After(seconds, step)
    end
    C_Timer.After(seconds, step)
    function t:Cancel() self.cancelled = true end
    return t
end
function WoW.advance(seconds)
    local target = WoW.now + seconds
    while true do
        local best, bi
        for i, t in ipairs(WoW.timers) do
            if t.at <= target and (not best or t.at < best.at or (t.at == best.at and t.seq < best.seq)) then best, bi = t, i end
        end
        if not best then break end
        table.remove(WoW.timers, bi)
        WoW.epoch = WoW.epoch + (math.max(WoW.now, best.at) - WoW.now)
        WoW.now = math.max(WoW.now, best.at)
        best.fn()
    end
    WoW.epoch = WoW.epoch + (target - WoW.now)
    WoW.now = target
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
Enum = { UITextureSliceMode = { Stretched = 0, Tiled = 1 } }
function issecretvalue(v) return false end
function table.wipe(t) for k in pairs(t) do t[k] = nil end return t end
wipe = table.wipe
-- Client string alias (in the dump's _G walk); LibStub's version check uses it.
strmatch = string.match

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
local allowNil = { GuildSpy = true, GuildSpyDB = true, LibStub = true }
setmetatable(_G, { __index = function(_, k)
    if allowNil[k] then return nil end
    error("read of undefined global '" .. tostring(k) .. "' (not stubbed: is it in the API dump?)", 2)
end })
