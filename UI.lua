-- UI.lua: the log window (#3, #19). One panel, styled like the guild roster
-- (a "new" summary, search, time scope, Mark all as read, category tabs, the
-- list under New / Earlier headings, the last scan's time), shown in one of
-- two hosts:
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
UI.ROW_HEIGHT = 20
-- The panel's rows of controls, from its top (#19).
UI.SEARCH_Y, UI.TABS_Y, UI.LIST_Y, UI.FOOTER_H = 30, 54, 86, 22
-- The guild roster's own art (Blizzard_Communities/CommunitiesMemberList.xml),
-- so the panel looks like the tab next to it.
UI.ART = {
    background = "Interface\\FrameGeneral\\UI-Background-Marble",
    stripe = "Interface\\GuildFrame\\GuildFrame",
    stripeCoords = { 0.36230469, 0.38183594, 0.95898438, 0.99804688 },
    highlight = "Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar",
    classes = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes",
    newDot = "communities-icon-notification",
}
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
local category, query, scope, rank = nil, "", "all", nil
local newSince = 0             -- entries past this seq are marked new while the panel is open
local visit                    -- the guild state whose rows the open panel shows
local tipOwner                 -- the row or summary whose tooltip is up

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

-- A Blizzard template, or the fallback when this client doesn't have it.
local function template(name, fallback)
    local exists = rawget(_G, "DoesTemplateExist")
    if exists and not exists(name) then return fallback end
    return name
end

local function font(parent, object, justify)
    local fs = parent:CreateFontString(nil, "ARTWORK", object)
    if justify then fs:SetJustifyH(justify) end
    return fs
end

------------------------------------------------------------
-- The panel
------------------------------------------------------------

local function classIcon(tex, class)
    local coords = rawget(_G, "CLASS_ICON_TCOORDS")
    local c = class and type(coords) == "table" and coords[class]
    if c then tex:SetTexCoord(unpack(c)) end
    tex:SetShown(c ~= nil)
end

local function buildRow(row)
    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints(row)
    row.stripe:SetTexture(UI.ART.stripe)
    row.stripe:SetTexCoord(unpack(UI.ART.stripeCoords))
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    hl:SetTexture(UI.ART.highlight)
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.5)                -- a hover, softer than a selection
    row.mark = row:CreateTexture(nil, "ARTWORK")
    row.mark:SetAtlas(UI.ART.newDot)
    row.mark:SetSize(10, 10)
    row.mark:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetTexture(UI.ART.classes)
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", row, "LEFT", 26, 0)
    row.when = font(row, "GameFontDisableSmall", "RIGHT")
    row.when:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.when:SetWidth(96)
    row.text = font(row, "GameFontHighlight", "LEFT")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.text:SetPoint("RIGHT", row.when, "LEFT", -6, 0)
    row.text:SetWordWrap(false)
    row.header = font(row, "GameFontNormal", "LEFT")
    row.header:SetPoint("LEFT", row, "LEFT", 8, 0)
    -- The whole sentence, the exact time and what it means: the row is short.
    -- Then the member's notes as they are now (#25).
    row:SetScript("OnEnter", function(self)
        local entry = self.entry
        if not entry or not Log.Visible(entry, canView()) then return end
        tipOwner = self
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(date("%Y-%m-%d %H:%M", entry.at))
        GameTooltip:AddLine(Log.Line(entry, time()), 1, 1, 1, true)
        GameTooltip:AddLine(Log.Provenance(entry), 0.6, 0.6, 0.6, true)
        local src = Log.Source(entry)
        if src then GameTooltip:AddLine(Log.Esc(src), 0.6, 0.8, 1, true) end
        local gs = current()
        for _, n in ipairs(gs and Log.MemberNotes(gs, entry, canView()) or {}) do
            GameTooltip:AddLine(n.label .. ": |cff" .. n.color .. Log.Esc(n.text) .. "|r", 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() tipOwner = nil; GameTooltip:Hide() end)
end

-- One list element: a section heading ({ header }) or an entry ({ entry, odd }).
local function initRow(row, el)
    if not row.text then buildRow(row) end
    local e = el.entry
    row.entry = e
    row.header:SetShown(el.header ~= nil)
    row.header:SetText(el.header or "")
    for _, part in ipairs({ row.stripe, row.mark, row.icon, row.when, row.text }) do part:SetShown(e ~= nil) end
    if not e then return end
    row.stripe:SetShown(el.odd == true)
    row.mark:SetShown(e.seq > newSince)
    classIcon(row.icon, e.class)
    row.when:SetText(Log.When(e, time()))
    row.text:SetText(Log.Row(e, time(), panel.classOf))
end

local function selectPill()
    for _, b in ipairs(panel.pills) do
        local on = b.key == category
        local select, deselect = rawget(_G, "PanelTemplates_SelectTab"), rawget(_G, "PanelTemplates_DeselectTab")
        if b.isTab and select and deselect then
            if on then select(b) else deselect(b) end
        elseif on then
            b:LockHighlight()
        else
            b:UnlockHighlight()
        end
    end
end

local function makePill(key, label, prev)
    local tpl = template("PanelTopTabButtonTemplate", "UIPanelButtonTemplate")
    local b = CreateFrame("Button", nil, panel, tpl)
    b.isTab = tpl == "PanelTopTabButtonTemplate"
    b:SetText(label)
    local resize = rawget(_G, "PanelTemplates_TabResize")
    if b.isTab and resize then resize(b, 0, nil, 56) else b:SetSize(76, 22) end
    if prev then
        b:SetPoint("LEFT", prev, "RIGHT", b.isTab and -4 or 2, 0)
    else
        b:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -UI.TABS_Y)
    end
    b.key = key
    b:SetScript("OnClick", function()
        category = key
        selectPill()
        UI.Refresh()
    end)
    panel.pills[#panel.pills + 1] = b
    return b
end

-- The time-scope dropdown; a button cycling the scopes where the client has
-- no dropdown template.
local function makeScope()
    local tpl = template("WowStyle1DropdownTemplate", "UIPanelButtonTemplate")
    local dd = CreateFrame(tpl == "UIPanelButtonTemplate" and "Button" or "DropdownButton", nil, panel, tpl)
    dd:SetSize(130, 22)
    if tpl == "WowStyle1DropdownTemplate" then
        dd:SetupMenu(function(_, root)
            for _, s in ipairs(Log.SCOPES) do
                root:CreateRadio(s.label, function() return scope == s.key end, function() UI.SetScope(s.key) end)
            end
        end)
    else
        dd.cycles = true
        dd:SetText(Log.SCOPES[1].label)
        dd:SetScript("OnClick", function()
            for i, s in ipairs(Log.SCOPES) do
                if s.key == scope then UI.SetScope(Log.SCOPES[i % #Log.SCOPES + 1].key); return end
            end
        end)
    end
    return dd
end

-- The rank dropdown (#23): All ranks, then the guild's ranks as they are now.
local function rankChoices()
    local gs = current()
    local list = { { label = "All ranks" } }
    for _, r in ipairs(gs and type(gs.ranks) == "table" and gs.ranks or {}) do
        if type(r) == "string" then list[#list + 1] = { label = r, key = r } end
    end
    return list
end

local function hasRank(gs, name)
    for _, c in ipairs(gs and type(gs.ranks) == "table" and gs.ranks or {}) do
        if c == name then return true end
    end
end

local function makeRank()
    local tpl = template("WowStyle1DropdownTemplate", "UIPanelButtonTemplate")
    local dd = CreateFrame(tpl == "UIPanelButtonTemplate" and "Button" or "DropdownButton", nil, panel, tpl)
    dd:SetSize(130, 22)
    if tpl == "WowStyle1DropdownTemplate" then
        dd:SetupMenu(function(_, root)
            for _, c in ipairs(rankChoices()) do
                root:CreateRadio(c.label, function() return rank == c.key end, function() UI.SetRank(c.key) end)
            end
        end)
    else
        dd.cycles = true
        dd:SetText("All ranks")
        dd:SetScript("OnClick", function()
            local list = rankChoices()
            for i, c in ipairs(list) do
                if c.key == rank then UI.SetRank(list[i % #list + 1].key); return end
            end
            UI.SetRank(nil)
        end)
    end
    return dd
end

local function build()
    panel = CreateFrame("Frame", nil, UIParent)
    panel:Hide()
    panel.bg = panel:CreateTexture(nil, "BACKGROUND")
    panel.bg:SetAllPoints(panel)
    panel.bg:SetTexture(UI.ART.background, "REPEAT", "REPEAT")
    panel.bg:SetHorizTile(true)
    panel.bg:SetVertTile(true)

    panel.summary = font(panel, "GameFontHighlight", "LEFT")
    panel.summary:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -10)
    panel.summary:SetPoint("RIGHT", panel, "RIGHT", -12, 0)
    panel.summary:SetWordWrap(false)

    local read = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    read:SetSize(120, 22)
    read:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -UI.SEARCH_Y)
    read:SetText("Mark all as read")
    read:SetScript("OnClick", function() UI.MarkAllRead() end)
    panel.markRead = read

    local dd = makeScope()
    dd:SetPoint("RIGHT", read, "LEFT", -8, 0)
    panel.scope = dd

    local rd = makeRank()
    rd:SetPoint("RIGHT", dd, "LEFT", -8, 0)
    panel.rank = rd

    local search = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
    search:SetHeight(20)
    search:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -UI.SEARCH_Y - 1)
    search:SetPoint("RIGHT", rd, "LEFT", -10, 0)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(self)
        query = self:GetText() or ""
        UI.Refresh()
    end)
    panel.search = search

    panel.pills = {}
    local prev = makePill(nil, "All")
    for _, c in ipairs(Log.CATEGORIES) do prev = makePill(c.key, c.label, prev) end
    selectPill()

    local box = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
    box:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -UI.LIST_Y)
    box:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -20, UI.FOOTER_H)
    local bar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(UI.ROW_HEIGHT)
    view:SetElementInitializer("Button", initRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    panel.box = box

    -- The summary's tooltip: every group, and that it counts every tab.
    local hit = CreateFrame("Frame", nil, panel)
    hit:SetAllPoints(panel.summary)
    hit:EnableMouse(true)
    hit:SetScript("OnEnter", function(self)
        tipOwner = self
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText("New activity")
        GameTooltip:AddLine("Across every tab, whatever is selected, since you last marked it read.", 0.8, 0.8, 0.8, true)
        for _, c in ipairs(visit and Log.NewCounts(visit, newSince, canView()) or {}) do
            GameTooltip:AddLine("|cff" .. c.color .. c.n .. "|r " .. c.word, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    hit:SetScript("OnLeave", function() tipOwner = nil; GameTooltip:Hide() end)
    panel.summaryHit = hit

    panel.footer = font(panel, "GameFontDisableSmall", "RIGHT")
    panel.footer:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 6)

    panel.empty = font(panel, "GameFontDisable", "CENTER")
    panel.empty:SetPoint("CENTER", box, "CENTER", 0, 0)
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

-- The entry at or below the top of the list, and how far below the top it
-- sits: redrawn, the list scrolls so it stays put (a heading coming or going
-- above it doesn't move what's on screen).
local function anchor()
    local box, els = panel.box, panel.elements
    if not els or not box.GetDerivedScrollOffset then return end
    local offset = box:GetDerivedScrollOffset() or 0
    if offset <= 0 then return end
    for i = math.floor(offset / UI.ROW_HEIGHT) + 1, #els do
        if els[i].entry then return els[i].entry, (i - 1) * UI.ROW_HEIGHT - offset end
    end
end

local function restore(entry, below)
    if not entry then return end
    for i, el in ipairs(panel.elements) do
        if el.entry == entry then
            panel.box:ScrollToOffset(math.max(0, (i - 1) * UI.ROW_HEIGHT - below))
            return
        end
    end
end

-- The list's elements: the rows under "New" and "Earlier" headings when
-- something is new, alternate rows striped.
local function elements(rows)
    local els, newCount = {}, 0
    for _, e in ipairs(rows) do if e.seq > newSince then newCount = newCount + 1 end end
    local odd = false
    for i, e in ipairs(rows) do
        if newCount > 0 and i == 1 then els[#els + 1] = { header = "New" } end
        if newCount > 0 and i == newCount + 1 then els[#els + 1] = { header = "Earlier" } end
        odd = not odd
        els[#els + 1] = { entry = e, odd = odd }
    end
    return els
end

-- Newest first by when it happened, within New and within Earlier: an entry
-- enriched with an older time (the event log's hour) sorts by that time.
local function byTime(rows)
    local new, old = {}, {}
    for _, e in ipairs(rows) do
        if e.seq > newSince then new[#new + 1] = e else old[#old + 1] = e end
    end
    local function later(a, b)
        if (a.at or 0) ~= (b.at or 0) then return (a.at or 0) > (b.at or 0) end
        return a.seq > b.seq
    end
    table.sort(new, later)
    table.sort(old, later)
    for _, e in ipairs(old) do new[#new + 1] = e end
    return new
end

-- Why the list is empty, in the terms of what's selected.
local function emptyText(gs)
    if #(gs.log or {}) == 0 then return "Nothing recorded yet." end
    if query:match("%S") then return "No activity matches your search." end
    local ranged = scope ~= "all"
    local what
    for _, c in ipairs(Log.CATEGORIES) do
        if c.key == category then what = c.empty end
    end
    if not what and not rank and not ranged then return "Nothing recorded yet." end
    return "No " .. (what or "activity") .. (rank and (" for " .. rank) or "")
        .. (ranged and " in this time range." or " recorded yet.")
end

-- The summary: as many groups as fit, then "+N more" (#22 review).
local function fitSummary(gs)
    local s = panel.summary
    if not gs then s:SetText(""); return end
    local width = s:GetWidth() or 0
    local measure = s.GetUnboundedStringWidth and "GetUnboundedStringWidth" or "GetStringWidth"
    local limit = #Log.NewCounts(gs, newSince, canView())
    s:SetText(Log.NewSummary(gs, newSince, canView()))
    while width > 0 and limit > 1 and (s[measure](s) or 0) > width do
        limit = limit - 1
        s:SetText(Log.NewSummary(gs, newSince, canView(), limit))
    end
end

-- A name's class, from the roster we last saw (to colour an actor).
local function classLookup(gs)
    local byName = {}
    for _, m in pairs(gs and type(gs.members) == "table" and gs.members or {}) do
        if type(m) == "table" and m.name then byName[m.name] = m.class end
    end
    return function(name) return byName[name] end
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
    -- A tooltip up on a row or the summary is redrawn by hovering again; an
    -- officer note in it, or its count, must not outlive the right to read it.
    if tipOwner then tipOwner = nil; GameTooltip:Hide() end
    -- A rank the guild no longer has (another guild, renamed, removed) lets go.
    if rank and not hasRank(gs, rank) then UI.SetRank(nil); return end
    local now = time()
    local keep, below = anchor()
    local rows = gs and Log.Filter(gs, { category = category, query = query, canViewOfficer = canView(),
                                         since = Log.ScopeSince(scope, now), rank = rank }, now) or {}
    rows = byTime(rows)
    panel.rows = rows
    panel.elements = elements(rows)
    panel.classOf = classLookup(gs)
    local constants = rawget(_G, "ScrollBoxConstants")
    panel.box:SetDataProvider(CreateDataProvider(panel.elements), constants and constants.RetainScrollPosition)
    restore(keep, below)

    fitSummary(gs)
    panel.markRead:SetEnabled(gs ~= nil and topVisible(gs) > newSince)
    panel.footer:SetText(gs and gs.observedAt and ("Updated " .. Log.Relative(gs.observedAt, now)) or "")
    local why = gs and #rows == 0 and emptyText(gs) or nil
    if not gs then why = "No guild seen yet." end
    panel.empty:SetText(why or "")
    panel.empty:SetShown(why ~= nil)
    if win and win.title then
        local _, name = API.GuildKey()
        win.title:SetText("|cff7fd4ffGuild|rSpy" .. (name and ("  |cff999999" .. name .. "|r") or ""))
    end
end

-- "Mark all as read": the dots and the summary go; the filters, the search
-- and the rows on screen stay. The digest's own boundary (shownSeq) is untouched.
function UI.MarkAllRead()
    if not visit then return end
    markViewed(visit)
    newSince = visit.viewedSeq or 0
    UI.Refresh()
end

function UI.SetScope(key)
    scope = key
    if panel and panel.scope.cycles then
        for _, s in ipairs(Log.SCOPES) do if s.key == key then panel.scope:SetText(s.label) end end
    end
    UI.Refresh()
end

function UI.SetRank(name)
    rank = name
    if panel and panel.rank.cycles then panel.rank:SetText(name or "All ranks") end
    UI.Refresh()
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

function UI.CloseWindow()
    if win and win:IsShown() then win:Hide() end
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
GuildSpy._test.UI = { onLink = onLink, panel = function() return panel end, window = function() return win end,
                      scope = function() return scope end, rank = function() return rank end }
