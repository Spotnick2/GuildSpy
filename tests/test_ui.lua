-- The log window (#3): the filter, the standalone window, the "new" marker,
-- the digest's link, and the guild window's tab, which must never write a
-- field of Blizzard's frame.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function member(name, rank, guid)
    return { name = name, rank = rank, level = 30, class = "MAGE", online = true, guid = guid, note = "" }
end
local function newGuild()
    return { name = "Parse Partout", realm = "Forever", myRank = 3,
             ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" },
             members = { member("Fizzle Sprocketwhistle", 3, "Player-1-00000001"),
                         member("Ann Lee", 3, "Player-1-00000002") },
             events = {}, eventNames = true, motd = "hello", canViewOfficerNote = false }
end

-- Blizzard's guild window as far as the tab uses it: the side tabs, the list,
-- and the two methods it hooks. Any write of a field by the addon fails.
local function communitiesFrame()
    local cf = CreateFrame("Frame", "CommunitiesFrame", UIParent)
    cf.CommunitiesList = CreateFrame("Frame", nil, cf)
    for _, key in ipairs({ "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab", "GuildPreferredPlaySettingsTab" }) do
        cf[key] = CreateFrame("CheckButton", nil, cf)
        cf[key]:Hide()
    end
    cf.guildSelected = true
    cf.displayMode = "ROSTER"
    local modeTab = { CHAT = "ChatTab", ROSTER = "RosterTab", GUILD_BENEFITS = "GuildBenefitsTab", GUILD_INFO = "GuildInfoTab" }
    -- As CommunitiesFrameMixin:UpdateCommunitiesTabs: show the guild's tabs,
    -- then check the one for the current mode only.
    function cf:UpdateCommunitiesTabs()
        for _, key in ipairs({ "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab" }) do
            self[key]:SetShown(self.guildSelected or key == "ChatTab" or key == "RosterTab")
            self[key]:SetChecked(false)
        end
        self[modeTab[self.displayMode]]:SetChecked(true)
    end
    -- As SetDisplayMode: returns early on the same mode, else updates the tabs.
    function cf:SetDisplayMode(mode)
        if self.displayMode == mode then return end
        rawset(self, "displayMode", mode)
        self:UpdateCommunitiesTabs()
    end
    -- What a tab click does: RightSideTabMixin checks it, then SetDisplayMode.
    function cf:clickTab(key, mode) self[key]:SetChecked(true); self:SetDisplayMode(mode) end
    local mt = getmetatable(cf)
    setmetatable(cf, { __index = mt.__index, __newindex = function(_, k)
        error("the addon wrote CommunitiesFrame." .. tostring(k), 2)
    end })
    return cf
end

local G = newGuild()
loadAddon({ setup = function() WoW.guild = G end })
WoW.fire("PLAYER_LOGIN")
WoW.fire("GUILD_ROSTER_UPDATE", false)
for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(25)
local gs = GuildSpyDB.guilds["Parse Partout-Forever"]
check(gs and gs.observedAt, "baselined")

local Log, UI, T = GuildSpy.Log, GuildSpy.UI, GuildSpy._test.UI
local now = time()
local function add(ev) return Log.Add(GuildSpyDB, gs, ev, now) end
add({ kind = "JOIN", name = "Bo Kay", guid = "Player-1-00000003" })
add({ kind = "PROMOTE", name = "Bo Kay", guid = "Player-1-00000003", actor = "Enzo Matrix", from = "Initiate", to = "Member" })
add({ kind = "ONOTE", name = "Ann Lee", guid = "Player-1-00000002", from = "", to = "main tank" })
add({ kind = "LEVEL", name = "Ann Lee", guid = "Player-1-00000002", from = 29, to = 30 })

-- The filter: newest first, by category, by text, officer notes only for those who may read them.
local rows = Log.Filter(gs, {}, now)
eq(#rows, 3, "all but the officer note for a non-officer")
eq(rows[1].kind, "LEVEL", "newest first")
eq(#Log.Filter(gs, { canViewOfficer = true }, now), 4, "an officer sees the officer note")
eq(#Log.Filter(gs, { category = "ranks" }, now), 1, "the Ranks pill")
eq(#Log.Filter(gs, { category = "notes" }, now), 0, "...Notes for a non-officer: none")
eq(#Log.Filter(gs, { query = "  enzo " }, now), 1, "search finds the officer, any case, trimmed")
eq(#Log.Filter(gs, { query = "bo kay" }, now), 2, "...and a member's every entry")
eq(#Log.Filter(gs, { query = "main tank" }, now), 0, "...never an officer note it can't show")
eq(#Log.Filter(gs, { query = "|c" }, now), 0, "colour codes aren't searched")

-- /gspy log opens the window on the current guild's log.
WoW.chat = {}
WoW.slash("/gspy log")
local win = T.window()
check(win and win:IsShown(), "/gspy log opens the window")
local panel = T.panel()
eq(#panel.rows, 3, "...listing what this character may see")
eq(panel.box._dataProvider:GetSize(), 3, "...handed to the scroll box")
check(not panel.empty:IsShown(), "...no empty text")
local found = false
for _, name in ipairs(UISpecialFrames) do if name == "GuildSpyLogWindow" then found = true end end
check(found, "Escape closes it")
eq(#WoW.chat, 0, "...and nothing printed")

-- Rows: the initializer draws an entry, with the "new" marker past the last look.
local view = panel.box._view
local row = CreateFrame("Button", nil, panel)
view.initializer(row, panel.rows[1])
check(row.text:GetText():find("Ann Lee reached level 30", 1, true), "a row shows the entry's line")
check(row.mark:IsShown(), "...marked new: never looked at")
row._scripts.OnEnter(row)
check(GameTooltip._text and GameTooltip._lines[1]:find("reached level 30", 1, true), "its tooltip has the whole line")

-- Closing makes it seen; the next opening marks nothing old as new.
win:Hide()
eq(gs.viewedSeq, rows[1].seq, "closing records the last entry seen")
local onote = gs.log[3]
check(onote.kind == "ONOTE" and gs.viewedSeq > onote.seq, "(the officer note is below it)")
add({ kind = "LEAVE", name = "Bo Kay", guid = "Player-1-00000003", how = "quit" })
WoW.slash("/gspy log")
eq(#panel.rows, 4, "a new entry shows")
view.initializer(row, panel.rows[1])
check(row.mark:IsShown(), "...marked new")
view.initializer(row, panel.rows[2])
check(not row.mark:IsShown(), "an entry seen before isn't")

-- A pill narrows the list; the search box too.
panel.pills[2]._scripts.OnClick(panel.pills[2])          -- Members
eq(#panel.rows, 2, "the Members pill: the join and the leave")
panel.search._text = "zzz"
panel.search._scripts.OnTextChanged(panel.search)
check(panel.empty:IsShown() and panel.empty:GetText() == "Nothing matches.", "no match says so")
panel.search._text = ""
panel.search._scripts.OnTextChanged(panel.search)
panel.pills[1]._scripts.OnClick(panel.pills[1])          -- All

-- New entries redraw an open window.
G.members[2].level = 31
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
eq(#panel.rows, 5, "a level-up while open shows at once")

-- Officer-note permission lost while the window is open (#18 review).
WoW.guild.canViewOfficerNote = true
win:Hide(); WoW.slash("/gspy log")
local hasOnote = function()
    for _, e in ipairs(panel.rows) do if e.kind == "ONOTE" then return e end end
end
local on = hasOnote()
check(on, "an officer sees the officer note in the window")
local onRow = CreateFrame("Button", nil, panel)
view.initializer(onRow, on)
onRow._scripts.OnEnter(onRow)
check(GameTooltip:IsShown(), "...and its tooltip")
-- Each way the permission can go, without a roster update (follow-up review),
-- and by a scan with no change.
local revokers = {
    { "a rank update", function() WoW.fire("GUILD_RANKS_UPDATE") end },
    { "the player's rank update", function() WoW.fire("GUILD_RANKS_UPDATE_ACTIVE_PLAYER") end },
    { "a scan with no change", function() WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3) end },
}
for _, r in ipairs(revokers) do
    WoW.guild.canViewOfficerNote = true
    UI.Refresh()
    view.initializer(onRow, hasOnote())
    onRow._scripts.OnEnter(onRow)
    WoW.guild.canViewOfficerNote = false
    r[2]()
    check(not hasOnote(), "permission lost, " .. r[1] .. ": the officer note goes from the list")
    check(not GameTooltip:IsShown(), "...and the tooltip showing it goes")
end
onRow._scripts.OnEnter(onRow)
check(not GameTooltip:IsShown(), "a stale row's tooltip never shows it")

-- Leaving the guild with the window open: no old rows, no old boundary.
local keep = WoW.guild
WoW.guild = nil
WoW.fire("PLAYER_GUILD_UPDATE")
eq(#panel.rows, 0, "out of the guild: the old guild's rows go")
check(panel.empty:GetText() == "No guild seen yet.", "...and it says so")
WoW.guild = keep
WoW.fire("PLAYER_GUILD_UPDATE")
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(25)
check(#panel.rows > 0, "back in: its rows return")
win:Hide()

-- /gspy log <n> still prints.
WoW.chat = {}
WoW.slash("/gspy log 2")
eq(#WoW.chat, 2, "/gspy log 2 prints two lines")

-- The digest's [open log] link.
win:Hide()
check(Log.Digest({ log = { { seq = 1, kind = "JOIN", name = "X", at = now } } }, false, now)[1]:find("|Haddon:guildspy:log|h", 1, true),
    "the digest's summary carries the link")
EventRegistry:TriggerEvent("SetItemRef", "item:1234", "[thing]", "LeftButton")
check(not win:IsShown(), "another link does nothing")
EventRegistry:TriggerEvent("SetItemRef", "addon:guildspy:log", "[open log]", "LeftButton")
check(win:IsShown(), "the link opens the window")
win:Hide()

-- The guild window: Blizzard_Communities loads on demand.
local cf = communitiesFrame()
WoW.fire("ADDON_LOADED", "Blizzard_Communities")
local tab = UI.tab
check(tab and tab:GetParent() == cf, "the tab is attached when the guild window loads")
-- Every field of Blizzard's frame as it is now (after the hooks, which are the
-- client's own writes): the addon must change none (the guard above only sees new ones).
local before = {}
for k, v in pairs(cf) do if k:sub(1, 1) ~= "_" and k ~= "displayMode" then before[k] = v end end
check(not tab:IsShown(), "...hidden until Blizzard lays its tabs out")
cf:UpdateCommunitiesTabs()
check(tab:IsShown(), "shown under the guild's tabs")
local p = tab._points[1]
check(p and p[2] == cf.GuildInfoTab, "...anchored below the Info tab")
cf.GuildPreferredPlaySettingsTab:Show()
cf:UpdateCommunitiesTabs()
check(tab._points[1][2] == cf.GuildPreferredPlaySettingsTab, "...or below the play settings tab when it shows")
cf.GuildPreferredPlaySettingsTab:Hide()

-- Clicking it: the panel over the content, Blizzard's tabs unchecked, the window closed.
WoW.slash("/gspy log")
check(win:IsShown(), "(the standalone window is open)")
tab._scripts.OnClick(tab)
check(UI.guildHost:IsShown(), "the tab shows the panel in the guild window")
check(panel:GetParent() == UI.guildHost, "...the same panel, moved there")
check(not win:IsShown(), "...the standalone window closed")
check(tab:GetChecked() and not cf.RosterTab:GetChecked(), "...ours checked, Blizzard's not")
eq(#panel.rows, 5, "...listing the log")
WoW.slash("/gspy log")
check(not win:IsShown(), "/gspy log leaves it in the guild window")

WoW.advance(0)
check(UI.guildHost:GetFrameStrata() == "HIGH", "the panel sits a strata above the guild window (MEDIUM)")

-- The current Blizzard tab clicked again (SetDisplayMode returns early): our panel goes away.
cf:clickTab("RosterTab", "ROSTER")
WoW.advance(0)
check(not UI.guildHost:IsShown(), "a Blizzard tab hides the panel")
check(not tab:GetChecked(), "...and unchecks ours")
check(cf.RosterTab:GetChecked(), "...and Roster stays checked")

-- Another Blizzard tab (#18 review): it ends up checked, ours not.
tab._scripts.OnClick(tab)
WoW.advance(0)
cf:clickTab("GuildInfoTab", "GUILD_INFO")
WoW.advance(0)
check(not UI.guildHost:IsShown(), "Info clicked from our panel: the panel goes")
check(cf.GuildInfoTab:GetChecked(), "...and Info is checked")
check(not cf.RosterTab:GetChecked() and not tab:GetChecked(), "...alone")

-- Blizzard re-laying its tabs while ours stays up: ours stays the checked one.
tab._scripts.OnClick(tab)
cf:UpdateCommunitiesTabs()
WoW.advance(0)
check(UI.guildHost:IsShown() and tab:GetChecked() and not cf.GuildInfoTab:GetChecked(),
    "a re-layout with our panel up: ours checked, Blizzard's not")
cf:clickTab("RosterTab", "ROSTER")

-- Another club selected (no guild tabs): no tab, no panel.
tab._scripts.OnClick(tab)
cf.guildSelected = false
cf:UpdateCommunitiesTabs()
check(not tab:IsShown() and not UI.guildHost:IsShown(), "a community selected: the tab and panel go")
cf.guildSelected = true
cf:UpdateCommunitiesTabs()

-- The guild window closing takes the panel with it.
tab._scripts.OnClick(tab)
cf:Hide()
check(not UI.guildHost:IsShown(), "closing the guild window hides the panel")
local changed
for k, v in pairs(before) do if rawget(cf, k) ~= v then changed = k end end
eq(changed, nil, "no field of Blizzard's frame was rewritten")

local firstDB = GuildSpyDB
-- Already loaded at login: attached then.
loadAddon({ setup = function() WoW.guild = newGuild(); WoW.loadedAddOns.Blizzard_Communities = true end })
local cf2 = communitiesFrame()
WoW.fire("PLAYER_LOGIN")
check(GuildSpy.UI.tab and GuildSpy.UI.tab:GetParent() == cf2, "loaded before us: attached at login")

-- A damaged "viewed" mark in the saved file: dropped, the window still opens.
local saved = firstDB
saved.guilds["Parse Partout-Forever"].viewedSeq = "lots"
loadAddon({ db = saved, setup = function() WoW.guild = newGuild() end })
WoW.fire("PLAYER_LOGIN")
WoW.fire("GUILD_ROSTER_UPDATE", false)
for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(25)
WoW.slash("/gspy log")
GuildSpy._test.UI.window():Hide()
check(type(saved.guilds["Parse Partout-Forever"].viewedSeq) == "number", "a text viewedSeq is replaced, not compared")

done("test_ui")
