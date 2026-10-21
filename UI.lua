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
-- The panels, over the host. Not + 1: that's Glass UI's glass when its guild
-- skin is on (#63), and frames at one level have no guaranteed draw order.
UI.GUILD_PANEL_LEVEL = UI.GUILD_LEVEL + 2
-- Fully opaque: at 0.97 bright chat text and member names still showed through.
UI.GUILD_BG = { 0.04, 0.045, 0.055, 1 }
UI.STRATA_ABOVE = { BACKGROUND = "LOW", LOW = "MEDIUM", MEDIUM = "HIGH", HIGH = "DIALOG",
                    DIALOG = "FULLSCREEN", FULLSCREEN = "FULLSCREEN_DIALOG" }
-- Blizzard's side tabs, in order (Blizzard_Communities/CommunitiesFrame.xml).
UI.BLIZZARD_TABS = { "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab", "GuildPreferredPlaySettingsTab" }

local panel, win, tab, guildHost
local prof, ptab               -- the Professions tab's panel and tab (#9)
local category, query, scope, rank = nil, "", "all", nil
local newSince = 0             -- entries past this seq are marked new while the panel is open
local visit                    -- the guild state whose rows the open panel shows
local tipOwner                 -- the row or summary whose tooltip is up
local glassed = false          -- Glass UI's guild skin is applied to guildHost (#63)

local function canView() return API.CanViewOfficerNote() == true end
local function current() return GuildSpy.Scanner.Current() end
-- Guildmates' reports set to "Never" (#38): out of the counts and every tab but Reports.
local function hideReports() return GuildSpy.GuildSync ~= nil and GuildSpy.GuildSync.ReportsMode() == "never" end

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
        local now = time()
        GameTooltip:SetText(date("%Y-%m-%d %H:%M", entry.at))
        GameTooltip:AddLine(Log.Line(Log.View(self.group, entry), now), 1, 1, 1, true)
        GameTooltip:AddLine(Log.Provenance(entry), 0.6, 0.6, 0.6, true)
        local src = Log.Source(entry)
        if src then GameTooltip:AddLine(Log.Esc(src), 0.6, 0.8, 1, true) end
        -- The change's other records (#59), each as its observer has it.
        for _, m in ipairs(self.group and self.group.members or {}) do
            if m ~= entry then
                local who = (Log.Source(m) or "Seen here"):gsub("^%u", string.lower)
                GameTooltip:AddLine("Also " .. Log.Esc(who)
                    -- Plain gives "||" back as "|": escaped again for the tooltip (#61 review).
                    .. ": " .. Log.Esc(Log.Plain(Log.Text(m, now))) .. " (" .. Log.When(m, now) .. ")", 0.6, 0.8, 1, true)
            end
        end
        local gs = current()
        for _, n in ipairs(gs and Log.MemberNotes(gs, entry, canView()) or {}) do
            GameTooltip:AddLine(n.label .. ": |cff" .. n.color .. Log.Esc(n.text) .. "|r", 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() tipOwner = nil; GameTooltip:Hide() end)
end

-- New: every record of its change is past the boundary (#59), so a late
-- report of a change already seen doesn't light it up again.
local function isNew(e)
    local g = panel.groups and panel.groups[e]
    return (g and g.seq or e.seq) > newSince
end

-- One list element: a section heading ({ header }) or an entry ({ entry, odd }).
local function initRow(row, el)
    if not row.text then buildRow(row) end
    local e = el.entry
    row.entry = e
    row.group = e and panel.groups and panel.groups[e]
    row.header:SetShown(el.header ~= nil)
    row.header:SetText(el.header or "")
    for _, part in ipairs({ row.stripe, row.mark, row.icon, row.when, row.text }) do part:SetShown(e ~= nil) end
    if not e then return end
    row.stripe:SetShown(el.odd == true)
    row.mark:SetShown(isNew(e))
    classIcon(row.icon, e.class)
    row.when:SetText(Log.When(e, time()))
    row.text:SetText(Log.Row(Log.View(row.group, e), time(), panel.classOf))
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
        for _, c in ipairs(visit and Log.NewCounts(visit, newSince, canView(), hideReports()) or {}) do
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
    for _, e in ipairs(rows) do if isNew(e) then newCount = newCount + 1 end end
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
        if isNew(e) then new[#new + 1] = e else old[#old + 1] = e end
    end
    -- One scan dates what it noticed to the same second; their windows still
    -- order them (#59): a departure the next scan confirmed ended before a
    -- join it saw, as a recreated character's old self leaves the name free.
    local function later(a, b)
        if (a.at or 0) ~= (b.at or 0) then return (a.at or 0) > (b.at or 0) end
        local ha, hb = tonumber(a.hi) or a.at or 0, tonumber(b.hi) or b.at or 0
        if ha ~= hb then return ha > hb end
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
    local limit = #Log.NewCounts(gs, newSince, canView(), hideReports())
    s:SetText(Log.NewSummary(gs, newSince, canView(), nil, hideReports()))
    while width > 0 and limit > 1 and (s[measure](s) or 0) > width do
        limit = limit - 1
        s:SetText(Log.NewSummary(gs, newSince, canView(), limit, hideReports()))
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
    if UI.RefreshProfessions then UI.RefreshProfessions() end
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
    local rows, groups = {}, {}
    if gs then
        rows, groups = Log.Filter(gs, { category = category, query = query, canViewOfficer = canView(),
                                        since = Log.ScopeSince(scope, now), rank = rank,
                                        hideReports = hideReports() }, now)
    end
    panel.groups = groups
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

-- A panel's marble, hidden while it sits on Glass UI's glass in the guild
-- window (#63). The standalone window keeps it.
local function marble(p)
    if p then p.bg:SetShown(not (glassed and p:GetParent() == guildHost)) end
end

local function setHost(host, level)
    if not panel then build() end
    panel:SetParent(host)
    panel:ClearAllPoints()
    panel:SetAllPoints(host)
    panel:SetFrameStrata(host:GetFrameStrata())
    panel:SetFrameLevel(level)
    marble(panel)
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
    if guildHost and guildHost:IsVisible() then
        if prof and prof:IsShown() then UI.ShowInGuild() end      -- the Professions tab: back to the log
        return
    end
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
-- The guild window's Professions tab (#9)
------------------------------------------------------------
-- Retail's guild profession view, rebuilt (Professions.lua): a header per
-- profession (Blizzard's CollapsibleHeader art, as CommunitiesMemberList.xml),
-- its members under it. In the guild window only, under the GuildSpy tab.

UI.PROF_ICON = "Interface\\Icons\\Trade_BlackSmithing"
UI.PROF_ART = {
    header = "Interface\\Buttons\\CollapsibleHeader",
    left = { 0.17578125, 0.47265625, 0.29687500, 0.54687500 },
    right = { 0.17578125, 0.47265625, 0.01562500, 0.26562500 },
    middle = { 0.48046875, 0.98046875, 0.01562500, 0.26562500 },
    plus = "Interface\\Buttons\\UI-PlusButton-Up",
    minus = "Interface\\Buttons\\UI-MinusButton-Up",
}
-- Columns, as retail's roster (Lvl, Class, Name, Zone, Rank, Note; no Skill).
UI.PROF_COLS = { level = 8, class = 40, name = 62, zone = 214, rank = 344, note = 454 }

local offline, pquery, collapsed = true, "", {}

function UI.ProfessionsEnabled()
    local s = GuildSpyDB and GuildSpyDB.settings
    return not (s and s.professionsTab == false)
end

local function memberTooltip(self)
    local m = self.member
    if not m then return end
    tipOwner = self
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(m.name)
    local line = {}
    if m.level then line[#line + 1] = "Level " .. m.level end
    if m.rankName then line[#line + 1] = m.rankName end
    if #line > 0 then GameTooltip:AddLine(table.concat(line, ", "), 1, 1, 1) end
    GameTooltip:AddLine(table.concat(m.professions or {}, ", "), 1, 0.82, 0)
    if m.online then
        if m.zone and m.zone ~= "" then GameTooltip:AddLine(m.zone, 0.8, 0.8, 0.8) end
    elseif m.lastSeenAt then
        GameTooltip:AddLine("Last online " .. Log.Relative(m.lastSeenAt, time()), 0.6, 0.6, 0.6)
    end
    if m.note and m.note ~= "" then
        GameTooltip:AddLine("Note: " .. Log.Esc(m.note), 0.8, 0.8, 0.8, true)
    end
    GameTooltip:Show()
end

local function buildProfRow(row)
    local art = UI.PROF_ART
    -- The header: Blizzard's collapsible-header bar.
    row.hLeft = row:CreateTexture(nil, "BORDER")
    row.hLeft:SetTexture(art.header)
    row.hLeft:SetTexCoord(unpack(art.left))
    row.hLeft:SetSize(76, 16)
    row.hLeft:SetPoint("LEFT", row, "LEFT", 3, 0)
    row.hRight = row:CreateTexture(nil, "BORDER")
    row.hRight:SetTexture(art.header)
    row.hRight:SetTexCoord(unpack(art.right))
    row.hRight:SetSize(76, 16)
    row.hRight:SetPoint("RIGHT", row, "RIGHT", -3, 0)
    row.hMiddle = row:CreateTexture(nil, "BACKGROUND")
    row.hMiddle:SetTexture(art.header)
    row.hMiddle:SetTexCoord(unpack(art.middle))
    row.hMiddle:SetHeight(16)
    row.hMiddle:SetPoint("LEFT", row.hLeft, "RIGHT", -20, 0)
    row.hMiddle:SetPoint("RIGHT", row.hRight, "LEFT", 20, 0)
    row.toggle = row:CreateTexture(nil, "ARTWORK")
    row.toggle:SetSize(14, 14)
    row.toggle:SetPoint("LEFT", row.hLeft, "LEFT", 8, 0)
    row.pIcon = row:CreateTexture(nil, "ARTWORK")
    row.pIcon:SetSize(14, 14)
    row.pIcon:SetPoint("LEFT", row.hLeft, "LEFT", 26, 0)
    row.pIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.pName = font(row, "GameFontNormalSmall", "LEFT")
    row.pName:SetPoint("LEFT", row.hLeft, "LEFT", 46, 1)
    row.pCount = font(row, "GameFontNormalSmall", "RIGHT")
    row.pCount:SetPoint("RIGHT", row.hRight, "RIGHT", -10, 1)
    -- A member.
    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints(row)
    row.stripe:SetTexture(UI.ART.stripe)
    row.stripe:SetTexCoord(unpack(UI.ART.stripeCoords))
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    hl:SetTexture(UI.ART.highlight)
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.5)
    local c = UI.PROF_COLS
    row.level = font(row, "GameFontHighlightSmall", "CENTER")
    row.level:SetPoint("LEFT", row, "LEFT", c.level, 0)
    row.level:SetWidth(28)
    row.cIcon = row:CreateTexture(nil, "ARTWORK")
    row.cIcon:SetTexture(UI.ART.classes)
    row.cIcon:SetSize(16, 16)
    row.cIcon:SetPoint("LEFT", row, "LEFT", c.class, 0)
    local function col(key, nextKey, object)
        local fs = font(row, object or "GameFontHighlightSmall", "LEFT")
        fs:SetPoint("LEFT", row, "LEFT", c[key], 0)
        if nextKey then fs:SetWidth(c[nextKey] - c[key] - 6) else fs:SetPoint("RIGHT", row, "RIGHT", -8, 0) end
        fs:SetWordWrap(false)
        return fs
    end
    row.name = col("name", "zone", "GameFontHighlight")
    row.zone = col("zone", "rank")
    row.rank = col("rank", "note")
    row.note = col("note")
    row:SetScript("OnClick", function(self)
        if self.group and not self.member then
            collapsed[self.group.id] = not self.collapsed
            UI.RefreshProfessions()
        end
    end)
    row:SetScript("OnEnter", memberTooltip)
    row:SetScript("OnLeave", function() tipOwner = nil; GameTooltip:Hide() end)
end

local function initProfRow(row, el)
    if not row.pName then buildProfRow(row) end
    local isHeader = el.member == nil
    row.group, row.member, row.collapsed = el.group, el.member, el.collapsed
    for _, part in ipairs({ row.hLeft, row.hRight, row.hMiddle, row.toggle, row.pIcon, row.pName, row.pCount }) do
        part:SetShown(isHeader)
    end
    for _, part in ipairs({ row.stripe, row.level, row.cIcon, row.name, row.zone, row.rank, row.note }) do
        part:SetShown(not isHeader)
    end
    if isHeader then
        local g = el.group
        row.toggle:SetTexture(el.collapsed and UI.PROF_ART.plus or UI.PROF_ART.minus)
        row.pIcon:SetTexture(g.icon)
        row.pName:SetText(g.name)
        row.pCount:SetText(g.online .. " of " .. g.total .. " online")
        return
    end
    local m = el.member
    row.stripe:SetShown(el.odd == true)
    row.level:SetText(m.level and tostring(m.level) or "")
    classIcon(row.cIcon, m.class)
    local colors = rawget(_G, "RAID_CLASS_COLORS")
    local cc = m.class and type(colors) == "table" and colors[m.class]
    local name = Log.Esc(m.name)
    if not m.online then
        row.name:SetText("|cff808080" .. name .. "|r")
    elseif cc and cc.colorStr then
        row.name:SetText("|c" .. cc.colorStr .. name .. "|r")
    else
        row.name:SetText(name)
    end
    if m.online then
        row.zone:SetText(m.zone and Log.Esc(m.zone) or "")
    else
        row.zone:SetText(m.lastSeenAt and ("|cff808080" .. Log.Relative(m.lastSeenAt, time()) .. "|r") or "")
    end
    row.rank:SetText(m.rankName and Log.Esc(m.rankName) or "")
    row.note:SetText(m.note and Log.Esc(m.note) or "")
end

local function buildProfessions()
    prof = CreateFrame("Frame", nil, UIParent)
    prof:Hide()
    prof.bg = prof:CreateTexture(nil, "BACKGROUND")
    prof.bg:SetAllPoints(prof)
    prof.bg:SetTexture(UI.ART.background, "REPEAT", "REPEAT")
    prof.bg:SetHorizTile(true)
    prof.bg:SetVertTile(true)

    local cb = GuildSpy.API.SafeFrame("CheckButton", prof, "UICheckButtonTemplate", "text")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", prof, "TOPLEFT", 10, -6)
    cb:SetChecked(offline)
    cb:SetScript("OnClick", function(self)
        offline = self:GetChecked() and true or false
        UI.RefreshProfessions()
    end)
    prof.offline = cb
    local cbl = font(prof, "GameFontNormalSmall", "LEFT")
    cbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cbl:SetText("Show offline members")

    local search = CreateFrame("EditBox", nil, prof, "SearchBoxTemplate")
    search:SetSize(180, 20)
    search:SetPoint("TOPRIGHT", prof, "TOPRIGHT", -12, -8)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(self)
        pquery = self:GetText() or ""
        UI.RefreshProfessions()
    end)
    prof.search = search

    -- Column titles, as retail's roster. The class icon's column is narrower
    -- than "Class", which ran into "Name" in game: it has no title.
    local c = UI.PROF_COLS
    for _, h in ipairs({ { "Lvl", c.level + 4 }, { "Name", c.name }, { "Zone", c.zone },
                         { "Rank", c.rank }, { "Note", c.note } }) do
        local fs = font(prof, "GameFontHighlightSmall", "LEFT")
        fs:SetPoint("TOPLEFT", prof, "TOPLEFT", h[2] + 4, -36)
        fs:SetText(h[1])
    end

    local box = CreateFrame("Frame", nil, prof, "WowScrollBoxList")
    box:SetPoint("TOPLEFT", prof, "TOPLEFT", 4, -52)
    box:SetPoint("BOTTOMRIGHT", prof, "BOTTOMRIGHT", -20, UI.FOOTER_H)
    local bar = CreateFrame("EventFrame", nil, prof, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(UI.ROW_HEIGHT)
    view:SetElementInitializer("Button", initProfRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    prof.box = box

    prof.footer = font(prof, "GameFontDisableSmall", "RIGHT")
    prof.footer:SetPoint("BOTTOMRIGHT", prof, "BOTTOMRIGHT", -12, 6)
    prof.empty = font(prof, "GameFontDisable", "CENTER")
    prof.empty:SetPoint("CENTER", box, "CENTER", 0, 0)
end

-- Re-reads C_Club and the roster: cheap enough on every roster scan while shown.
function UI.RefreshProfessions()
    if not prof or not prof:IsVisible() then return end
    if tipOwner then tipOwner = nil; GameTooltip:Hide() end
    local gs = current()
    local groups = GuildSpy.Professions.Build(API.ClubMembers(), gs)
    -- Each member's professions, for the tooltip.
    for _, g in ipairs(groups) do
        for _, m in ipairs(g.members) do m.professions = {} end
    end
    for _, g in ipairs(groups) do
        for _, m in ipairs(g.members) do table.insert(m.professions, g.name) end
    end
    prof.groups = groups
    prof.elements = GuildSpy.Professions.Elements(groups, { offline = offline, query = pquery, collapsed = collapsed })
    local constants = rawget(_G, "ScrollBoxConstants")
    prof.box:SetDataProvider(CreateDataProvider(prof.elements), constants and constants.RetainScrollPosition)
    local people = {}
    for _, g in ipairs(groups) do for _, m in ipairs(g.members) do people[m.guid or m.name] = true end end
    local n = 0
    for _ in pairs(people) do n = n + 1 end
    prof.footer:SetText(n > 0 and (n .. (n == 1 and " member" or " members") .. " with a profession") or "")
    local why
    if not gs then why = "No guild seen yet."
    elseif #groups == 0 then why = "No professions known yet."
    elseif #prof.elements == 0 then why = pquery:match("%S") and "Nobody matches your search." or "Nobody online with a profession." end
    prof.empty:SetText(why or "")
    prof.empty:SetShown(why ~= nil)
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
    if ptab then ptab:SetChecked(false) end
end

function UI.ShowInGuild()
    local cf = rawget(_G, "CommunitiesFrame")
    if not cf or not guildHost then return end
    if win and win:IsShown() then win:Hide() end
    if prof then prof:Hide() end
    if ptab then ptab:SetChecked(false) end
    local was = guildHost:IsShown()
    guildHost:Show()
    setHost(guildHost, UI.GUILD_PANEL_LEVEL)
    tab:SetChecked(true)
    blizzardTabs(cf, false)
    if was then UI.Refresh() else opened() end
end

-- The Professions tab (#9): the same host, the professions panel instead of the log.
function UI.ShowProfessions()
    local cf = rawget(_G, "CommunitiesFrame")
    if not cf or not guildHost or not UI.ProfessionsEnabled() then return end
    if win and win:IsShown() then win:Hide() end
    -- Leaving the log here counts as closing it: what it showed is seen.
    if panel and panel:IsShown() and panel:GetParent() == guildHost then
        closed()
        panel:Hide()
    end
    if not prof then buildProfessions() end
    guildHost:Show()
    prof:SetParent(guildHost)
    prof:ClearAllPoints()
    prof:SetAllPoints(guildHost)
    prof:SetFrameStrata(guildHost:GetFrameStrata())
    prof:SetFrameLevel(UI.GUILD_PANEL_LEVEL)
    marble(prof)
    prof:Show()
    tab:SetChecked(false)
    ptab:SetChecked(true)
    blizzardTabs(cf, false)
    UI.RefreshProfessions()
end

-- After Blizzard lays its tabs out: ours goes under the last guild tab shown,
-- and only while the guild's tabs are (the guild selected, not minimized).
function UI.PlaceTab()
    local cf = rawget(_G, "CommunitiesFrame")
    if not cf or not tab then return end
    local info, play = cf.GuildInfoTab, cf.GuildPreferredPlaySettingsTab
    if not (info and info:IsShown()) then
        tab:Hide()
        if ptab then ptab:Hide() end
        UI.HideInGuild()
        return
    end
    local last = (play and play:IsShown()) and play or info
    tab:ClearAllPoints()
    tab:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -20)
    tab:Show()
    -- The Professions tab, under ours, while the setting is on (#9).
    if ptab then
        if UI.ProfessionsEnabled() then
            ptab:ClearAllPoints()
            ptab:SetPoint("TOPLEFT", tab, "BOTTOMLEFT", 0, -20)
            ptab:Show()
        else
            ptab:Hide()
            if prof and prof:IsShown() then UI.HideInGuild() end
        end
    end
    -- Blizzard just re-checked one of its tabs. If this is a Blizzard tab
    -- being clicked, SetDisplayMode's hook hides us right after and that
    -- check must stay; if we're still shown a frame later, it's ours.
    if guildHost:IsShown() then
        C_Timer.After(0, function()
            if guildHost:IsShown() then blizzardTabs(cf, false) end
        end)
    end
end

------------------------------------------------------------
-- Glass UI's guild skin (#63)
------------------------------------------------------------
-- Optional. With Glass UI installed and its guild skin on, our side tabs and
-- guildHost take its look through its tenant API (GlassUI docs/SUITE.md,
-- "Tenants"): it styles the tabs, and puts its glass on the host at the host's
-- level + 1. We paint the host's base in the window floor's colour and hide the
-- panels' marble; the rows keep their stripes, as the roster's do. Glass UI
-- never writes our frames, and we read nothing of it but these calls. Without
-- it (or with a version that doesn't speak API 1), nothing changes.

-- Glass UI on, or off again (it calls this under pcall).
local function onSkin(on, look)
    glassed = on == true
    local c = glassed and type(look) == "table" and look.backing
    if type(c) ~= "table" or type(c[1]) ~= "number" or type(c[2]) ~= "number" or type(c[3]) ~= "number" then
        c = UI.GUILD_BG
    end
    guildHost.bg:SetColorTexture(c[1], c[2], c[3], 1)      -- opaque always: see GUILD_BG
    marble(panel)
    marble(prof)
end

-- One of Glass UI's tenant calls, if this Glass UI has it. Raw reads only, so
-- nothing of Glass UI's runs here.
local function suite(name)
    local G = rawget(_G, "GlassUI")
    local S = type(G) == "table" and rawget(G, "Suite")
    if type(S) ~= "table" or rawget(S, "API") ~= 1 then return nil end
    local fn = rawget(S, name)
    return type(fn) == "function" and fn or nil
end

local function handOver()
    local skinTab, skinPanel = suite("SkinTab"), suite("SkinPanel")
    if skinTab then
        pcall(skinTab, ADDON, tab)
        pcall(skinTab, ADDON, ptab)
    end
    if skinPanel then pcall(skinPanel, ADDON, guildHost, onSkin) end
end

------------------------------------------------------------
-- Attaching to the guild window
------------------------------------------------------------

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

    ptab = CreateFrame("CheckButton", nil, cf, "RightSideTabTemplate")
    ptab:SetSize(32, 32)
    ptab:SetFrameLevel(510)
    if ptab.Icon then ptab.Icon:SetTexture(UI.PROF_ICON) end
    ptab.tooltip = "Guild professions"
    ptab.tooltip2 = nil
    ptab:HookScript("OnClick", function() UI.ShowProfessions() end)
    ptab:Hide()
    UI.ptab = ptab

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
    handOver()                                     -- after the host's level: Glass UI's glass goes at + 1

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
                      professions = function() return prof end,
                      scope = function() return scope end, rank = function() return rank end }
