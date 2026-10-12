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
end

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    WoW.chat[#WoW.chat + 1] = table.concat(parts, " ")
end

function GetTime() return WoW.now end
function time(t) if t then return os.time(t) end return WoW.epoch end
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
