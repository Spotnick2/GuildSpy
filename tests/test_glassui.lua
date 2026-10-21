-- Glass UI's guild skin (#63): GuildSpy hands its side tabs and guildHost to
-- Glass UI's tenant API (GlassUI docs/SUITE.md, "Tenants") when it's there,
-- and changes nothing when it isn't. The fake below is the API's contract:
-- Suite.API 1, SkinTab(owner, tab), SkinPanel(owner, host, onSkin), each
-- returning a bool; onSkin(on, look) with look = { backing = { r, g, b } }.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

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
    local mt = getmetatable(cf)
    setmetatable(cf, { __index = mt.__index, __newindex = function(_, k)
        error("the addon wrote CommunitiesFrame." .. tostring(k), 2)
    end })
    return cf
end

local G = { name = "Parse Partout", realm = "Forever", myRank = 1, ranks = { "Guild Master", "Officer", "Member" },
            members = { { name = "Ann Lee", rank = 2, level = 30, class = "MAGE", online = true,
                          guid = "Player-1-00000001", note = "" } },
            events = {}, eventNames = true, motd = "", canViewOfficerNote = false, clubId = 7, club = {} }

-- A Glass UI that records the calls; `suite` overrides its fields.
local function fakeGlassUI(suite)
    local calls = { tabs = {}, panels = {} }
    local S = { API = 1 }
    function S.SkinTab(owner, tab) calls.tabs[#calls.tabs + 1] = { owner = owner, tab = tab }; return true end
    function S.SkinPanel(owner, host, onSkin)
        calls.panels[#calls.panels + 1] = { owner = owner, host = host, onSkin = onSkin, level = host:GetFrameLevel() }
        onSkin(false, { backing = { 0.2, 0.2, 0.2 } })          -- at registration, before it's applied
        return true
    end
    for k, v in pairs(suite or {}) do S[k] = v end
    return { Suite = S }, calls
end

-- Loads GuildSpy with this GlassUI global (nil: not installed) and opens the
-- guild window's tabs.
local function start(glassUI)
    rawset(_G, "GlassUI", glassUI)
    loadAddon({ setup = function() WoW.guild = G end })
    WoW.fire("PLAYER_LOGIN")
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    WoW.advance(25)
    local cf = communitiesFrame()
    WoW.fire("ADDON_LOADED", "Blizzard_Communities")
    cf:UpdateCommunitiesTabs()
    return GuildSpy.UI, GuildSpy._test.UI
end

local function color(tex) local c = tex._color; return c and table.concat(c, ",") end
local STOCK = table.concat({ 0.04, 0.045, 0.055, 1 }, ",")

do  -- Without Glass UI: as before, with the panels at the host's level + 2.
    local UI, T = start(nil)
    eq(color(UI.guildHost.bg), STOCK, "no Glass UI: the host's own opaque base")
    UI.tab._scripts.OnClick(UI.tab)
    local panel = T.panel()
    eq(panel:GetFrameLevel(), UI.guildHost:GetFrameLevel() + 2, "the log panel at the host's level + 2 (Glass UI's glass is + 1)")
    check(panel.bg:IsShown(), "...with its marble")
    UI.ptab._scripts.OnClick(UI.ptab)
    local prof = T.professions()
    eq(prof:GetFrameLevel(), UI.guildHost:GetFrameLevel() + 2, "the professions panel too")
    check(prof.bg:IsShown(), "...with its marble")
end

do  -- With Glass UI: both tabs and the host handed over, once.
    local glassUI, calls = fakeGlassUI()
    local UI, T = start(glassUI)
    eq(#calls.tabs, 2, "both side tabs handed over")
    check(calls.tabs[1].owner == "GuildSpy" and calls.tabs[1].tab == UI.tab, "...the GuildSpy tab, as GuildSpy")
    check(calls.tabs[2].owner == "GuildSpy" and calls.tabs[2].tab == UI.ptab, "...the Professions tab")
    check(calls.tabs[1].tab:GetParent() == rawget(_G, "CommunitiesFrame"), "...parented to the guild window, as SkinTab requires")
    eq(#calls.panels, 1, "the host handed over")
    check(calls.panels[1].owner == "GuildSpy" and calls.panels[1].host == UI.guildHost, "...guildHost, as GuildSpy")
    eq(calls.panels[1].level, UI.GUILD_LEVEL, "...after its level is set (Glass UI puts its glass at that + 1)")
    eq(color(UI.guildHost.bg), STOCK, "onSkin(false) at registration: the stock base")
    UI.HideInGuild()
    local cf = rawget(_G, "CommunitiesFrame")
    cf:UpdateCommunitiesTabs()
    eq(#calls.tabs + #calls.panels, 3, "laying the tabs out again hands nothing over again")

    -- The skin applied.
    local onSkin = calls.panels[1].onSkin
    onSkin(true, { backing = { 0.1, 0.2, 0.3 } })
    eq(color(UI.guildHost.bg), "0.1,0.2,0.3,1", "applied: the base in the window floor's colour, opaque")
    UI.tab._scripts.OnClick(UI.tab)
    local panel = T.panel()
    check(not panel.bg:IsShown(), "...the log panel's marble hidden in the guild window")
    UI.ptab._scripts.OnClick(UI.ptab)
    local prof = T.professions()
    check(not prof.bg:IsShown(), "...and the professions panel's")
    UI.HideInGuild()
    WoW.slash("/gspy log")
    check(T.window():IsShown() and panel:GetParent() ~= UI.guildHost, "(the log in the standalone window)")
    check(panel.bg:IsShown(), "the standalone window keeps the marble")
    T.window():Hide()

    -- Turned off while the log is open in the guild window.
    UI.tab._scripts.OnClick(UI.tab)
    check(not panel.bg:IsShown(), "(the marble hidden again in the guild window)")
    onSkin(false, { backing = { 0.1, 0.2, 0.3 } })
    eq(color(UI.guildHost.bg), STOCK, "off: the stock base")
    check(panel.bg:IsShown() and prof.bg:IsShown(), "...and both marbles back")

    -- A look without a usable colour.
    onSkin(true, { backing = { 0.1, "x", 0.3 } })
    eq(color(UI.guildHost.bg), STOCK, "a backing without three numbers: the stock base")
    onSkin(true, nil)
    eq(color(UI.guildHost.bg), STOCK, "...no look at all: the same")
    check(not panel.bg:IsShown(), "...the skin still applied")
end

do  -- Another API version: nothing handed over.
    local glassUI, calls = fakeGlassUI({ API = 2 })
    local UI = start(glassUI)
    eq(#calls.tabs + #calls.panels, 0, "API 2: nothing handed over")
    eq(color(UI.guildHost.bg), STOCK, "...the stock base")
    glassUI, calls = fakeGlassUI({ API = "1" })
    start(glassUI)
    eq(#calls.tabs + #calls.panels, 0, "API \"1\" (not the number): nothing handed over")
end

do  -- A Glass UI with one call and not the other: each checked on its own.
    local glassUI, calls = fakeGlassUI({ SkinPanel = false })
    start(glassUI)
    check(#calls.tabs == 2 and #calls.panels == 0, "no SkinPanel: the tabs still handed over")
    glassUI, calls = fakeGlassUI({ SkinTab = "no" })
    start(glassUI)
    check(#calls.tabs == 0 and #calls.panels == 1, "no SkinTab: the host still handed over")
end

do  -- A Glass UI that throws: GuildSpy's guild window still works.
    local glassUI = fakeGlassUI({ SkinTab = function() error("boom") end,
                                  SkinPanel = function() error("boom") end })
    local UI, T = start(glassUI)
    check(UI.tab:IsShown() and UI.ptab:IsShown(), "a throwing SkinTab/SkinPanel: the tabs still shown")
    UI.tab._scripts.OnClick(UI.tab)
    check(UI.guildHost:IsShown() and T.panel():IsShown() and T.panel().bg:IsShown(), "...the log opens, as stock")
    rawset(_G, "GlassUI", { Suite = setmetatable({}, { __index = function() error("read") end }) })
    loadAddon({ setup = function() WoW.guild = G end })
    WoW.fire("PLAYER_LOGIN")
    communitiesFrame()
    WoW.fire("ADDON_LOADED", "Blizzard_Communities")
    check(GuildSpy.UI.tab ~= nil, "a Suite whose reads throw: only raw reads, attached as stock")
end

rawset(_G, "GlassUI", nil)
done("test_glassui")
