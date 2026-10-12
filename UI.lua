-- UI.lua: the log window (#3). One panel (filters, a search box, the list),
-- shown in one of two hosts:
--   - the guild window (J): a GuildSpy side tab under Blizzard's, shown while
--     the guild is the selected club; the panel covers the content area;
--   - a standalone glass window: /gspy log, the digest's [open log] link and
--     (phase 2) the minimap button.
--
-- Taint rule: GuildSpy never opens, toggles or changes the display mode of
-- Blizzard's window and never writes its fields (opening it from addon code is
-- a known Forever trap, see ForeverUI's Skin.OpenHint). Only hooksecurefunc,
-- HookScript, widget calls on its tabs (SetChecked) and our own child frames.

local ADDON = ...
GuildSpy = GuildSpy or {}
local UI = {}
GuildSpy.UI = UI

local Log, Glass, API = GuildSpy.Log, GuildSpy.Glass, GuildSpy.API

UI.WIDTH, UI.HEIGHT = 640, 440
UI.ROW_HEIGHT = 18
UI.ICON = "Interface\\Icons\\INV_Misc_Spyglass_03"
UI.WINDOW_NAME = "GuildSpyLogWindow"
-- Above everything in the guild window's content area. A frame level alone
-- isn't enough (in game the member list and chat showed through), so the host
-- also takes the strata above the window's.
UI.GUILD_LEVEL = 1300
-- Fully opaque: at 0.97 bright chat text and member names still showed through.
UI.GUILD_BG = { 0.04, 0.045, 0.055, 1 }
UI.STRATA_ABOVE = { BACKGROUND = "LOW", LOW = "MEDIUM", MEDIUM = "HIGH", HIGH = "DIALOG",
                    DIALOG = "FULLSCREEN", FULLSCREEN = "FULLSCREEN_DIALOG" }
-- Blizzard's side tabs, in order (Blizzard_Communities/CommunitiesFrame.xml).
UI.BLIZZARD_TABS = { "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab", "GuildPreferredPlaySettingsTab" }

local panel, win, tab, guildHost
local category, query = nil, ""
local newSince = 0             -- entries past this seq are marked new while the panel is open
local visit                    -- the guild state whose rows the open panel shows
local tipRow                   -- the row whose tooltip is up

local function canView() return API.CanViewOfficerNote() == true end
local function current() return GuildSpy.Scanner.Current() end

-- The highest seq this character can see: what "viewed" moves to.
local function topVisible(gs)
    local top = 0
    for _, e in ipairs(gs and gs.log or {}) do
        if Log.Visible(e, canView()) and e.seq > top then top = e.seq end
    end
    return top
end

local function stamp(e)
    return date("%m-%d %H:%M", e.at) .. (e.approx and "~" or "")
end

------------------------------------------------------------
-- The panel
------------------------------------------------------------

local function initRow(row, e)
    if not row.text then
        row.mark = row:CreateTexture(nil, "ARTWORK")
        row.mark:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -3)
        row.mark:SetSize(3, UI.ROW_HEIGHT - 6)
        row.mark:SetColorTexture(0.5, 0.83, 1, 0.9)
        row.stamp = Glass.Font(row, 11, "LEFT")
        row.stamp:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.stamp:SetWidth(84)
        row.stamp:SetTextColor(0.6, 0.63, 0.7)
        row.text = Glass.Font(row, 12, "LEFT")
        row.text:SetPoint("LEFT", row.stamp, "RIGHT", 6, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.text:SetWordWrap(false)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(row)
        hl:SetColorTexture(1, 1, 1, 0.06)
        -- The whole line and the exact time: a long note is cut short in the row.
        row:SetScript("OnEnter", function(self)
            local entry = self.entry
            if not entry or not Log.Visible(entry, canView()) then return end
            tipRow = self
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(date("%Y-%m-%d %H:%M", entry.at) .. (entry.approx and " (approximate)" or ""))
            GameTooltip:AddLine(Log.Line(entry, time()), 1, 1, 1, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() tipRow = nil; GameTooltip:Hide() end)
    end
    row.entry = e
    row.mark:SetShown(e.seq > newSince)
    row.stamp:SetText(stamp(e))
    row.text:SetText(Log.Line(e, time()))
end

local function selectPill()
    for _, b in ipairs(panel.pills) do
        local on = b.key == category
        if on then Glass.SetSurfaceTint(b.glass, 0.25, 0.55, 0.85, 0.55) else Glass.SetSurfaceTint(b.glass) end
        b.label:SetTextColor(on and 1 or 0.78, on and 1 or 0.8, on and 1 or 0.86)
    end
end

local function makePill(key, label, width, prev)
    local b = CreateFrame("Button", nil, panel)
    b:SetSize(width, 20)
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4) end
    b.key = key
    local _, g = Glass.Pill(b, { size = "small" })
    b.glass = g
    b.label = Glass.Font(b, 11, "CENTER")
    b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.label:SetText(label)
    b:SetScript("OnClick", function()
        category = key
        selectPill()
        UI.Refresh()
    end)
    panel.pills[#panel.pills + 1] = b
    return b
end

local function build()
    panel = CreateFrame("Frame", nil, UIParent)
    panel:Hide()
    panel.pills = {}
    local prev = makePill(nil, "All", 40)
    for _, c in ipairs(Log.CATEGORIES) do prev = makePill(c.key, c.label, 62, prev) end
    selectPill()

    local search = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
    search:SetSize(150, 20)
    search:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -4)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(self)
        query = self:GetText() or ""
        UI.Refresh()
    end)
    panel.search = search

    local box = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
    box:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -30)
    box:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -14, 0)
    local bar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(UI.ROW_HEIGHT)
    view:SetElementInitializer("Button", initRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    panel.box = box

    panel.empty = Glass.Font(panel, 12, "CENTER")
    panel.empty:SetPoint("CENTER", box, "CENTER", 0, 0)
    panel.empty:SetTextColor(0.6, 0.63, 0.7)

end

-- A host opening marks what's new since the last look; a host closing makes
-- it seen (account-wide, per guild, like the digest's boundary).
local function markViewed(gs)
    if gs then gs.viewedSeq = math.max(gs.viewedSeq or 0, topVisible(gs)) end
end

-- The panel shows `gs` from now on: its own "new" boundary.
local function visitGuild(gs)
    visit = gs
    newSince = gs and gs.viewedSeq or 0
end

local function opened()
    visitGuild(current())
    UI.Refresh()
end

local function closed()
    markViewed(visit)
    visit = nil
end

-- Fills the list from the current guild's log. Cheap enough to run on every
-- new entry while the panel is shown.
function UI.Refresh()
    if not panel or not panel:IsVisible() then return end
    local gs = current()
    -- Another guild (or none) since the panel opened: the rows shown so far
    -- were the old guild's, seen; the new one starts from its own boundary.
    if gs ~= visit then
        markViewed(visit)
        visitGuild(gs)
    end
    -- A tooltip up on a row is redrawn from the new rows by hovering again; an
    -- officer note in it must not outlive the right to read it.
    if tipRow then tipRow = nil; GameTooltip:Hide() end
    local rows = gs and Log.Filter(gs, { category = category, query = query, canViewOfficer = canView() }, time()) or {}
    panel.rows = rows
    local constants = rawget(_G, "ScrollBoxConstants")
    panel.box:SetDataProvider(CreateDataProvider(rows), constants and constants.RetainScrollPosition)
    local why
    if not gs then why = "No guild seen yet."
    elseif #rows == 0 then why = (#(gs.log or {}) == 0) and "Nothing recorded yet." or "Nothing matches." end
    panel.empty:SetText(why or "")
    panel.empty:SetShown(why ~= nil)
    if win and win.title then
        local _, name = API.GuildKey()
        win.title:SetText("|cff7fd4ffGuild|rSpy" .. (name and ("  |cff999999" .. name .. "|r") or ""))
    end
end

local function setHost(host, level)
    if not panel then build() end
    panel:SetParent(host)
    panel:ClearAllPoints()
    panel:SetAllPoints(host)
    panel:SetFrameStrata(host:GetFrameStrata())
    panel:SetFrameLevel(level)
    panel:Show()
end

------------------------------------------------------------
-- The standalone window
------------------------------------------------------------

local function db() return GuildSpyDB end

local function savePosition()
    local left, top = win:GetLeft(), win:GetTop()
    if left and top then db().window = { x = left, y = top } end
end

local function buildWindow()
    win = CreateFrame("Frame", UI.WINDOW_NAME, UIParent)
    win:SetSize(UI.WIDTH, UI.HEIGHT)
    win:SetFrameStrata("DIALOG")
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) self:StartMoving() end)
    win:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePosition() end)
    local pos = db().window
    if type(pos) == "table" and type(pos.x) == "number" and type(pos.y) == "number" then
        win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    else
        win:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    table.insert(UISpecialFrames, UI.WINDOW_NAME)     -- Escape closes it
    win.glass = Glass.Apply(win, "large")
    local inset = Glass.Inset("large")
    win.title = Glass.Font(win, 14, "LEFT")
    win.title:SetPoint("TOPLEFT", win, "TOPLEFT", inset + 4, -inset - 2)
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -inset + 4, -inset + 4)
    close:SetScript("OnClick", function() win:Hide() end)
    win.content = CreateFrame("Frame", nil, win)
    win.content:SetPoint("TOPLEFT", win, "TOPLEFT", inset, -inset - 24)
    win.content:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -inset, inset)
    win:Hide()
    -- Only after that first Hide: a frame is made shown, and hiding it here
    -- would mark the whole log seen before anyone looked.
    win:SetScript("OnHide", closed)
end

-- /gspy log, the digest's link, the minimap button. While the panel is in the
-- guild window's tab, it stays there.
function UI.Open()
    if guildHost and guildHost:IsVisible() then return end
    if not win then buildWindow() end
    local was = win:IsShown()
    setHost(win.content, Glass.ContentLevel(win))
    win:Show()
    if was then UI.Refresh() else opened() end
end

function UI.Toggle()
    if win and win:IsShown() then win:Hide() else UI.Open() end
end

------------------------------------------------------------
-- The guild window's tab
------------------------------------------------------------

local function blizzardTabs(cf, checked)
    for _, key in ipairs(UI.BLIZZARD_TABS) do
        local t = cf[key]
        if t and t.SetChecked then t:SetChecked(checked) end
    end
end

function UI.HideInGuild()
    if guildHost then guildHost:Hide() end
    if tab then tab:SetChecked(false) end
end

function UI.ShowInGuild()
    local cf = rawget(_G, "CommunitiesFrame")
    if not cf or not guildHost then return end
    if win and win:IsShown() then win:Hide() end
    local was = guildHost:IsShown()
    guildHost:Show()
    setHost(guildHost, UI.GUILD_LEVEL + 1)
    tab:SetChecked(true)
    blizzardTabs(cf, false)
    if was then UI.Refresh() else opened() end
end

-- After Blizzard lays its tabs out: ours goes under the last guild tab shown,
-- and only while the guild's tabs are (the guild selected, not minimized).
function UI.PlaceTab()
    local cf = rawget(_G, "CommunitiesFrame")
    if not cf or not tab then return end
    local info, play = cf.GuildInfoTab, cf.GuildPreferredPlaySettingsTab
    if not (info and info:IsShown()) then
        tab:Hide()
        UI.HideInGuild()
        return
    end
    local last = (play and play:IsShown()) and play or info
    tab:ClearAllPoints()
    tab:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -20)
    tab:Show()
    -- Blizzard just re-checked one of its tabs. If this is a Blizzard tab
    -- being clicked, SetDisplayMode's hook hides us right after and that
    -- check must stay; if we're still shown a frame later, it's ours.
    if guildHost:IsShown() then
        C_Timer.After(0, function()
            if guildHost:IsShown() then blizzardTabs(cf, false) end
        end)
    end
end

function UI.AttachGuild()
    local cf = rawget(_G, "CommunitiesFrame")
    if not cf or tab then return end
    tab = CreateFrame("CheckButton", nil, cf, "RightSideTabTemplate")
    tab:SetSize(32, 32)
    tab:SetFrameLevel(510)
    if tab.Icon then tab.Icon:SetTexture(UI.ICON) end
    tab.tooltip = "GuildSpy"
    tab.tooltip2 = nil
    tab:HookScript("OnClick", function() UI.ShowInGuild() end)
    tab:Hide()
    UI.tab = tab

    guildHost = CreateFrame("Frame", nil, cf)
    local list = cf.CommunitiesList
    if list then
        guildHost:SetPoint("TOPLEFT", list, "TOPRIGHT", 4, 0)
    else
        guildHost:SetPoint("TOPLEFT", cf, "TOPLEFT", 172, -24)
    end
    guildHost:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", -6, 4)
    guildHost:SetFrameStrata(UI.STRATA_ABOVE[cf:GetFrameStrata()] or "HIGH")
    guildHost:SetFrameLevel(UI.GUILD_LEVEL)
    guildHost:EnableMouse(true)                    -- nothing under it takes the clicks
    guildHost.bg = guildHost:CreateTexture(nil, "BACKGROUND")
    guildHost.bg:SetAllPoints(guildHost)
    guildHost.bg:SetColorTexture(unpack(UI.GUILD_BG))
    guildHost:Hide()
    guildHost:SetScript("OnHide", closed)
    UI.guildHost = guildHost

    hooksecurefunc(cf, "UpdateCommunitiesTabs", UI.PlaceTab)
    -- A Blizzard tab clicked (even the one already current) or a mode change.
    hooksecurefunc(cf, "SetDisplayMode", UI.HideInGuild)
    cf:HookScript("OnHide", UI.HideInGuild)
    UI.PlaceTab()
end

------------------------------------------------------------
-- Wiring
------------------------------------------------------------

-- The digest's [open log] link (Log.OPEN_LINK): Blizzard routes addon links
-- to the "SetItemRef" callback (ItemRefHandlersShared.lua).
local function onLink(_, link)
    if type(link) == "string" and link:find("^addon:guildspy") then UI.Open() end
end

local registry = rawget(_G, "EventRegistry")
if registry then registry:RegisterCallback("SetItemRef", onLink, UI) end

-- A rank change can take away the right to read officer notes: redraw at
-- once, not at the next scan (#18 review). Refresh does nothing while hidden.
UI.PERMISSION_EVENTS = { GUILD_RANKS_UPDATE = true, GUILD_RANKS_UPDATE_ACTIVE_PLAYER = true,
                         PLAYER_GUILD_UPDATE = true }

local frame = CreateFrame("Frame")
API.RegisterEvent(frame, "ADDON_LOADED")
API.RegisterEvent(frame, "PLAYER_LOGIN")
for e in pairs(UI.PERMISSION_EVENTS) do API.RegisterEvent(frame, e) end
frame:SetScript("OnEvent", function(_, event, name)
    if UI.PERMISSION_EVENTS[event] then
        UI.Refresh()
    elseif event == "PLAYER_LOGIN" then
        -- Blizzard_Communities is load-on-demand: it may already be loaded.
        local ns = rawget(_G, "C_AddOns")
        if ns and ns.IsAddOnLoaded and ns.IsAddOnLoaded("Blizzard_Communities") then UI.AttachGuild() end
    elseif event == "ADDON_LOADED" and name == "Blizzard_Communities" then
        UI.AttachGuild()
    end
end)

GuildSpy._test = GuildSpy._test or {}
GuildSpy._test.UI = { onLink = onLink, panel = function() return panel end, window = function() return win end }
