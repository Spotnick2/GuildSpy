-- Every widget method the addon calls must exist on this client, for that
-- widget type (WowTestKit's Kit.checkMethods, against the build tests/kit.pin
-- names), and every client function the stub models must be on it too.
--
-- The core answers a method the build lacks on a type only where it's called,
-- and a Methods implementation answers on every type, so a call to a method
-- Forever lacks on that widget would otherwise pass silently. This checks
-- each recorded "Type:Method" as that exact pair. Keep the exercise reaching
-- every window and handler the addon builds.
-- It does NOT prove argument contracts, event behaviour or protection rules:
-- that is the in-game pass (docs/FOREVER-PROBE.md).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

-- Class art and colours, as the client has them (Blizzard_SharedXML/SharedConstants.lua).
CLASS_ICON_TCOORDS = { WARRIOR = { 0, 0.25, 0, 0.25 }, MAGE = { 0.25, 0.49609375, 0, 0.25 } }
RAID_CLASS_COLORS = { WARRIOR = { colorStr = "ffc69b6d" }, MAGE = { colorStr = "ff3fc7eb" } }

-- The stub models Forever: each client function it defines is in the build's
-- list (its tables, Enum, ScrollUtil, the ERR_ strings, are not in it).
local functions = Kit.data("functions")
for _, name in ipairs({ "IsInGuild", "GetGuildInfo", "GetNumGuildMembers", "GetGuildRosterShowOffline",
                        "GetGuildRosterInfo", "GetGuildRosterLastOnline", "GuildControlGetNumRanks",
                        "GuildControlGetRankName", "QueryGuildEventLog", "GetNumGuildEvents", "GetGuildEventInfo",
                        "GetBuildInfo", "UnitName", "GetRealmName", "PlaySound", "DoesTemplateExist",
                        "GetFileIDFromPath", "GetMaxLevelForPlayerExpansion", "GetMaxPlayerLevel", "time", "date",
                        "wipe", "CreateColor", "CreateScrollBoxListLinearView", "CreateDataProvider" }) do
    check(functions[name] and type(rawget(_G, name)) == "function", "the stub's " .. name .. " is on Forever " .. Kit.BUILD)
end
for _, ns in ipairs({ "C_GuildInfo", "C_Club", "C_ChatInfo", "C_AddOns", "C_Timer" }) do
    for k in pairs(rawget(_G, ns)) do
        check(functions[ns .. "." .. k], "the stub's " .. ns .. "." .. k .. " is on Forever " .. Kit.BUILD)
    end
end

-- C_Club member info, as measured (docs/FOREVER-PROBE.md section 9).
local function info(guid, name, p1, extra)
    local i = { guid = guid, name = name, level = 30, zone = "Stormwind", memberNote = "", presence = 1 }
    if p1 then i.profession1ID, i.profession1Name, i.profession1Rank = p1[1], p1[2], 1 end
    for k, v in pairs(extra or {}) do i[k] = v end
    return i
end
local function member(name, rank, guid, extra)
    local r = { name = name, rank = rank, level = 30, class = "MAGE", online = true, guid = guid, note = "" }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end
local G = { name = "Parse Partout", realm = "Forever", myRank = 1,
            ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" },
            members = { member("Fizzle Sprocketwhistle", 1, "Player-1-00000001"),
                        member("Ann Lee", 3, "Player-1-00000002", { onote = "main tank", class = "WARRIOR" }),
                        member("Bo Kay", 4, "Player-1-00000003", { online = false, lastOnline = { 0, 0, 2, 3 } }),
                        member("Enzo Matrix", 0, "Player-1-00000004") },
            events = {}, eventNames = true, motd = "hello", canViewOfficerNote = true, isOfficer = true, clubId = 7,
            club = { info("Player-1-00000001", "Fizzle Sprocketwhistle", { 197, "Tailoring" }),
                     info("Player-1-00000002", "Ann Lee", { 182, "Herbalism" }),
                     info("Player-1-00000003", "Bo Kay", { 182, "Herbalism" }, { presence = 3 }) } }

-- Blizzard's guild window as far as the side tabs use it (test_ui has the full one).
local function communitiesFrame()
    local cf = CreateFrame("Frame", "CommunitiesFrame", UIParent)
    cf.CommunitiesList = CreateFrame("Frame", nil, cf)
    for _, key in ipairs({ "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab", "GuildPreferredPlaySettingsTab" }) do
        cf[key] = CreateFrame("CheckButton", nil, cf)
        cf[key]:Hide()
    end
    cf.guildSelected, cf.displayMode = true, "ROSTER"
    local modeTab = { CHAT = "ChatTab", ROSTER = "RosterTab", GUILD_BENEFITS = "GuildBenefitsTab", GUILD_INFO = "GuildInfoTab" }
    function cf:UpdateCommunitiesTabs()
        for _, key in ipairs({ "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab" }) do
            self[key]:SetShown(true)
            self[key]:SetChecked(false)
        end
        self[modeTab[self.displayMode]]:SetChecked(true)
    end
    function cf:SetDisplayMode(mode)
        if self.displayMode == mode then return end
        self.displayMode = mode
        self:UpdateCommunitiesTabs()
    end
    return cf
end

-- A session: login and the baseline, then changes the log keeps.
loadAddon({ setup = function() WoW.guild = G end })
WoW.fire("PLAYER_LOGIN")
WoW.fire("GUILD_MOTD", G.motd)
WoW.fire("GUILD_ROSTER_UPDATE", false)
for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(25)
WoW.fire("CHAT_MSG_SYSTEM", "Enzo Matrix has promoted Bo Kay to Member.")
G.members[3].rank = 3
G.members[2].level, G.members[2].note = 31, "alts: Bo"
G.members[2].onote = "off tank"
WoW.fire("GUILD_ROSTER_UPDATE", false)
WoW.advance(5)
WoW.fireAllRegistered()
WoW.advance(100)

-- Every command.
for _, cmd in ipairs({ "", "help", "version", "status", "scan", "log 5", "minimap", "minimap", "probe", "probe watch",
                       "probe watch", "probe log", "probe recipes", "rebaseline", "nonsense" }) do
    WoW.slash("/gspy " .. cmd)
    WoW.advance(1)
end
WoW.advance(30)

-- The log window and every row it lists.
local UI, T = GuildSpy.UI, GuildSpy._test.UI
WoW.slash("/gspy log")
local panel = T.panel()
check(panel and #panel.rows > 0, "the exercise logged something to list (" .. (panel and #panel.rows or 0) .. ")")
local function drawAll(box, parent)
    local view, dp = box._view, box._dataProvider
    if not (view and dp) then return 0 end
    for _, el in ipairs(dp.list) do view.initializer(CreateFrame("Button", nil, parent), el) end
    return #dp.list
end
check(drawAll(panel.box, panel) > 0, "the log's rows were drawn")
panel.box:ScrollToOffset(40)

-- The guild window: the side tabs, the panel there, the professions panel.
local cf = communitiesFrame()
WoW.fire("ADDON_LOADED", "Blizzard_Communities")
cf:UpdateCommunitiesTabs()
check(UI.tab and UI.ptab, "the guild window's tabs were made")
UI.ptab._scripts.OnClick(UI.ptab)
local prof = T.professions()
check(prof and drawAll(prof.box, prof) > 0, "the professions rows were drawn")
UI.tab._scripts.OnClick(UI.tab)

-- The options page.
WoW.slash("/gspy options")
GuildSpy.Options._test.page:Show()

-- The minimap button and the compartment.
local obj = WoW.ldb and WoW.ldb.objects.GuildSpy
check(obj ~= nil, "the data object was made")
if obj then
    if obj.OnTooltipShow then obj.OnTooltipShow(GameTooltip) end
    local b = WoW.ldbi and WoW.ldbi.buttons.GuildSpy
    if b and obj.OnEnter then obj.OnEnter(b) end
    if b and obj.OnLeave then obj.OnLeave(b) end
end
GuildSpy_OnAddonCompartmentEnter(nil, UIParent)
GuildSpy_OnAddonCompartmentLeave(nil, UIParent)

-- Every script on every widget made, as the client would run it: hovers,
-- clicks, typing, focus, drags, shows and hides.
local SCRIPTS = { "OnEnter", "OnLeave", "OnMouseDown", "OnMouseUp", "OnClick", "OnTextChanged",
                  "OnEditFocusGained", "OnEditFocusLost", "OnEnterPressed", "OnEscapePressed",
                  "OnDragStart", "OnDragStop", "OnShow", "OnHide", "OnMouseWheel" }
local widgets, ran, errors = {}, 0, {}
for i, w in ipairs(WoW.widgets) do widgets[i] = w end
for _, w in ipairs(widgets) do
    for _, s in ipairs(SCRIPTS) do
        local fn = w._scripts and w._scripts[s]
        if fn then
            ran = ran + 1
            local ok, err = pcall(fn, w, s == "OnMouseWheel" and 1 or "LeftButton", false)
            if not ok then errors[#errors + 1] = s .. ": " .. tostring(err) end
        end
    end
end
check(ran >= 60, "the walk ran the widgets' scripts (" .. ran .. ")")
eq(#errors, 0, "no script failed in the walk" .. (errors[1] and (": " .. errors[1]) or ""))
WoW.advance(5)

-- Loading alone records 4, the session 110: the floor keeps the exercise from
-- quietly shrinking back to the load.
local recorded = Kit.checkMethods({ allow = {
    ["Frame:SetDataProvider"] = "ScrollBoxListMixin:SetDataProvider, a WowScrollBoxList's (Blizzard_SharedXML/Shared/Scroll/ScrollBox.lua:703, ScrollTemplates.xml:4)",
    ["Frame:GetDerivedScrollOffset"] = "ScrollBoxBaseMixin:GetDerivedScrollOffset (Blizzard_SharedXML/Shared/Scroll/ScrollBox.lua:395)",
    ["Frame:ScrollToOffset"] = "ScrollBoxBaseMixin:ScrollToOffset (Blizzard_SharedXML/Shared/Scroll/ScrollBox.lua:421)",
    ["Button:SetupMenu"] = "DropdownButtonMixin:SetupMenu, a WowStyle1DropdownTemplate's (Blizzard_Menu/DropdownButton.lua:237)",
} })
check(recorded >= 100, "the exercise reached every window (" .. recorded .. " recorded)")
done("test_methods")
