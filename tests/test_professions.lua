-- The guild Professions tab (#9): who has which profession, from C_Club's
-- member info (measured: names and ids for every member, skill always 1),
-- grouped as retail's guild profession view; then the tab in the guild window.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

CLASS_ICON_TCOORDS = { WARRIOR = { 0, 0.25, 0, 0.25 }, MAGE = { 0.25, 0.49609375, 0, 0.25 } }
RAID_CLASS_COLORS = { WARRIOR = { colorStr = "ffc69b6d" }, MAGE = { colorStr = "ff3fc7eb" } }

loadAddon()
local P = GuildSpy.Professions

-- C_Club member info, as measured (docs/FOREVER-PROBE.md section 9).
local function info(guid, name, p1, p2, extra)
    local i = { guid = guid, name = name, level = 30, zone = "Stormwind", memberNote = "", presence = 1 }
    if p1 then i.profession1ID, i.profession1Name, i.profession1Rank = p1[1], p1[2], 1 end
    if p2 then i.profession2ID, i.profession2Name, i.profession2Rank = p2[1], p2[2], 1 end
    for k, v in pairs(extra or {}) do i[k] = v end
    return i
end
local ALCH, HERB, MINE, TAIL = { 171, "Alchemy" }, { 182, "Herbalism" }, { 186, "Mining" }, { 197, "Tailoring" }

do  -- Grouping: as retail's UpdateProfessionDisplay, with the roster's record of each member.
    local gs = { ranks = { "Guild Master", "Officer", "Member" }, members = {
        ["Player-1-00000001"] = { name = "Ann Lee", rank = 1, level = 42, class = "MAGE", online = true, note = "alts: Bo" },
        ["Player-1-00000002"] = { name = "Abe Cy", rank = 2, level = 12, class = "WARRIOR", online = false, lastSeenAt = 100 },
        ["Player-1-00000003"] = { name = "Gone Away", rank = 2, online = false, missingSince = 5 },
    } }
    local infos = {
        info("Player-1-00000001", "Ann Lee", ALCH, HERB),
        info("Player-1-00000002", "Abe Cy", HERB, MINE, { gsOnline = true }),
        info("Player-1-00000003", "Gone Away", TAIL),
        info("Player-1-00000004", "Di Fox", { 2933, "Test Profession [DNT]" }, nil, { level = 7, gsOnline = true }),
        info("Player-1-00000005", "No Trade"),
        info("Player-1-00000006", "Twice", MINE, MINE),
    }
    local groups = P.Build(infos, gs)
    local names = {}
    for _, g in ipairs(groups) do names[#names + 1] = g.name .. ":" .. g.total end
    eq(table.concat(names, ","), "Alchemy:1,Herbalism:2,Mining:2,Test Profession [DNT]:1",
        "one group per profession, by name, with its count (a member pending departure isn't listed)")
    local herb = groups[2]
    eq(herb.members[1].name, "Ann Lee", "online members first, though Abe sorts before Ann")
    eq(herb.online, 1, "...and counted online")
    local ann = herb.members[1]
    check(ann.level == 42 and ann.class == "MAGE" and ann.rankName == "Officer" and ann.note == "alts: Bo",
        "a member's level, class, rank and note come from GuildSpy's roster")
    eq(groups[1].members[1], ann, "...one record, under both of Ann's professions")
    local di = groups[4].members[1]
    check(di.level == 7 and di.class == nil and di.rankName == nil, "someone the roster doesn't know: what C_Club says")
    check(di.online and groups[4].online == 1, "...online by C_Club's presence")
    check(not herb.members[2].online, "a roster member: the roster's online, not C_Club's presence")
    eq(groups[4].icon, P.UNKNOWN_ICON, "...an unknown profession: a question mark")
    eq(groups[1].icon, P.ICONS[171], "a known one: its icon")
    eq(groups[3].total, 2, "the same profession in both slots counts once")

    -- The list: headers collapsed, as retail starts.
    local els = P.Elements(groups, { offline = true })
    eq(#els, 4, "four headers, collapsed")
    check(els[1].group and els[1].collapsed, "...a header knows its group")
    els = P.Elements(groups, { offline = true, collapsed = { [182] = false } })
    eq(#els, 6, "Herbalism opened: its two members under it")
    check(els[3].member == ann and els[4].member.name == "Abe Cy", "...in order")
    els = P.Elements(groups, { offline = false, collapsed = { [182] = false } })
    eq(#els, 5, "offline members hidden: Cy goes")
    els = P.Elements(groups, { offline = true, query = "cy" })
    eq(#els, 4, "a search: the professions with a match, opened, with only the matches")
    check(els[1].group.name == "Herbalism" and els[2].member.name == "Abe Cy" and els[3].group.name == "Mining",
        "...Cy under Herbalism and Mining")
end

------------------------------------------------------------
-- The tab in the guild window
------------------------------------------------------------
local function communitiesFrame()
    local cf = CreateFrame("Frame", "CommunitiesFrame", UIParent)
    cf.CommunitiesList = CreateFrame("Frame", nil, cf)
    for _, key in ipairs({ "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab", "GuildPreferredPlaySettingsTab" }) do
        cf[key] = CreateFrame("CheckButton", nil, cf)
        cf[key]:Hide()
    end
    cf.displayMode = "ROSTER"
    local modeTab = { CHAT = "ChatTab", ROSTER = "RosterTab", GUILD_BENEFITS = "GuildBenefitsTab", GUILD_INFO = "GuildInfoTab" }
    function cf:UpdateCommunitiesTabs()
        for _, key in ipairs({ "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab" }) do
            self[key]:Show()
            self[key]:SetChecked(false)
        end
        self[modeTab[self.displayMode]]:SetChecked(true)
    end
    function cf:SetDisplayMode(mode)
        if self.displayMode == mode then return end
        rawset(self, "displayMode", mode)
        self:UpdateCommunitiesTabs()
    end
    function cf:clickTab(key, mode) self[key]:SetChecked(true); self:SetDisplayMode(mode) end
    local mt = getmetatable(cf)
    setmetatable(cf, { __index = mt.__index, __newindex = function(_, k)
        error("the addon wrote CommunitiesFrame." .. tostring(k), 2)
    end })
    return cf
end

do
    local function m(name, rank, guid, extra)
        local r = { name = name, rank = rank, level = 30, class = "MAGE", online = true, guid = guid, note = "" }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end
    local G = { name = "Parse Partout", realm = "Forever", myRank = 1, ranks = { "Guild Master", "Officer", "Member" },
                members = { m("Fizzle Sprocketwhistle", 1, "Player-1-00000001"),
                            m("Ann Lee", 2, "Player-1-00000002", { class = "WARRIOR" }),
                            m("Bo Kay", 2, "Player-1-00000003", { online = false }) },
                events = {}, eventNames = true, motd = "", canViewOfficerNote = false, clubId = 7,
                club = { info("Player-1-00000001", "Fizzle Sprocketwhistle", TAIL),
                         info("Player-1-00000002", "Ann Lee", ALCH, HERB),
                         info("Player-1-00000003", "Bo Kay", HERB),
                         -- Not in the roster yet (joined since the last complete scan).
                         info("Player-1-00000009", "Cy New", HERB, nil, { presence = 4 }),
                         info("Player-1-00000010", "Di Gone", HERB, nil, { presence = 3 }),
                         info("Player-1-00000011", "Ed Now", TAIL, nil, { presence = 1 }) } }
    loadAddon({ setup = function() WoW.guild = G end })
    WoW.fire("PLAYER_LOGIN")
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    WoW.advance(25)
    local UI, T = GuildSpy.UI, GuildSpy._test.UI
    local cf = communitiesFrame()
    WoW.fire("ADDON_LOADED", "Blizzard_Communities")
    local tab, ptab = UI.tab, UI.ptab
    check(ptab and ptab:GetParent() == cf and not ptab:IsShown(), "the Professions tab is made with the guild window, hidden")
    cf:UpdateCommunitiesTabs()
    check(ptab:IsShown() and ptab._points[1][2] == tab, "shown under the GuildSpy tab")

    -- Opening it.
    ptab._scripts.OnClick(ptab)
    local prof = T.professions()
    check(UI.guildHost:IsShown() and prof:IsShown() and prof:GetParent() == UI.guildHost, "the professions panel, in the guild window")
    check(ptab:GetChecked() and not tab:GetChecked() and not cf.RosterTab:GetChecked(), "...its tab checked, the others not")
    local els = prof.elements
    eq(#els, 3, "three professions, collapsed")
    local view = prof.box._view
    local row = CreateFrame("Button", nil, prof)
    view.initializer(row, els[2])
    eq(row.pName:GetText(), "Herbalism", "a header: the profession")
    eq(row.pCount:GetText(), "2 of 4 online", "...how many are online (Cy New: Away, from C_Club)")
    check(row.member == nil and row.hLeft:IsShown() and not row.name:IsShown(), "...drawn as a header")
    local tail = CreateFrame("Button", nil, prof)
    view.initializer(tail, els[3])
    eq(tail.pCount:GetText(), "2 of 2 online", "Tailoring: Fizzle, and Ed Now, Online by C_Club")
    row._scripts.OnClick(row)
    els = prof.elements
    eq(#els, 7, "clicked: Herbalism opens, with Ann, Cy, Bo and Di")
    eq(els[4].member.name, "Cy New", "...a member the roster doesn't know yet, online by presence, with the online")
    local r2 = CreateFrame("Button", nil, prof)
    view.initializer(r2, els[3])
    check(r2.name:GetText():find("Ann Lee", 1, true) and r2.name:GetText():find("ffc69b6d", 1, true),
        "a member: the name in the class colour")
    eq(r2.level:GetText(), "30", "...the level")
    eq(r2.rank:GetText(), "Member", "...the rank")
    eq(r2.zone:GetText(), "Stormwind", "...where they are")
    r2._scripts.OnEnter(r2)
    check(table.concat(GameTooltip._lines or {}, "\n"):find("Alchemy, Herbalism", 1, true),
        "the tooltip lists both of Ann's professions")
    local r3 = CreateFrame("Button", nil, prof)
    view.initializer(r3, els[5])
    check(r3.name:GetText():find("|cff808080", 1, true), "an offline member: greyed")
    check(prof.offline:GetChecked(), "show offline members: on by default, as retail")
    prof.offline:SetChecked(false)                         -- a click toggles it, then OnClick
    prof.offline._scripts.OnClick(prof.offline)
    eq(#prof.elements, 5, "offline members hidden: Bo and Di go, Cy stays")
    prof.offline:SetChecked(true)
    prof.offline._scripts.OnClick(prof.offline)

    -- Back to the log, and /gspy log from the Professions tab.
    tab._scripts.OnClick(tab)
    check(not prof:IsShown() and T.panel():IsShown() and tab:GetChecked() and not ptab:GetChecked(),
        "the GuildSpy tab: the log again, the Professions tab unchecked")
    ptab._scripts.OnClick(ptab)
    WoW.slash("/gspy log")
    check(T.panel():IsShown() and not prof:IsShown(), "/gspy log from the Professions tab: the log, in the guild window")

    -- A Blizzard tab: both go.
    ptab._scripts.OnClick(ptab)
    cf:clickTab("ChatTab", "CHAT")
    check(not UI.guildHost:IsShown() and not ptab:GetChecked(), "a Blizzard tab hides it")

    -- The setting.
    local O = GuildSpy.Options
    check(O.Get("professionsTab"), "the setting is on by default")
    ptab._scripts.OnClick(ptab)
    O.Set("professionsTab", false)
    eq(GuildSpyDB.settings.professionsTab, false, "off: saved")
    check(not ptab:IsShown() and not UI.guildHost:IsShown(), "...the tab goes, and the panel with it")
    ptab._scripts.OnClick(ptab)
    check(not UI.guildHost:IsShown(), "...a click on the hidden tab does nothing")
    O.Set("professionsTab", true)
    eq(GuildSpyDB.settings.professionsTab, nil, "on again: nothing saved")
    check(ptab:IsShown(), "...the tab is back")
end

done("test_professions")
