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
    function cf:UpdateCommunitiesTabs()
        for _, key in ipairs({ "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab" }) do
            self[key]:SetShown(self.guildSelected or key == "ChatTab" or key == "RosterTab")
            self[key]:SetChecked(false)
        end
        self.RosterTab:SetChecked(true)
    end
    function cf:SetDisplayMode(mode) self:UpdateCommunitiesTabs() end
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

-- A Blizzard tab clicked: our panel goes away.
cf:SetDisplayMode("ROSTER")
check(not UI.guildHost:IsShown(), "a Blizzard tab hides the panel")
check(not tab:GetChecked(), "...and unchecks ours")

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
