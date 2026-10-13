-- Minimap.lua (#5): the minimap button, the addon compartment and the key
-- binding. LibDBIcon and LibDataBroker are the stub's recording fakes (the
-- real Libs\ are not loaded in tests).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function chatHas(text)
    for _, line in ipairs(WoW.chat) do if line:find(text, 1, true) then return true end end
    return false
end
local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
end
local function member(name, rank, guid, online)
    return { name = name, rank = rank, level = 30, class = "MAGE", online = online, guid = guid, note = "" }
end
local function newGuild()
    return { name = "Parse Partout", realm = "Forever", myRank = 3,
             ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" },
             members = { member("Fizzle Sprocketwhistle", 3, "Player-1-00000001", true),
                         member("Ann Lee", 3, "Player-1-00000002", true),
                         member("Bo Kay", 4, "Player-1-00000003", false) },
             events = {}, eventNames = true, motd = "hello", canViewOfficerNote = false }
end
local function inGuild(db)
    local G = newGuild()
    loadAddon({ db = db, setup = function() WoW.guild = G end })
    WoW.fire("PLAYER_LOGIN")
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
    WoW.advance(25)
    return G
end
local function win() return GuildSpy._test.UI.window() end
local function isOpen() return win() ~= nil and win():IsShown() end

do
    loadAddon()
    local M = GuildSpy.Minimap
    eq(type(GuildSpyDB.minimap), "table", "its saved table exists from the start (LibDBIcon's own shape)")
    eq(M._test.registered(), false, "nothing is registered before login")
    WoW.fire("PLAYER_LOGIN")
    eq(M._test.registered(), true, "at login the button is registered")
    eq(WoW.ldbi.registered.GuildSpy, GuildSpyDB.minimap, "...with LibDBIcon, keeping its place in GuildSpyDB.minimap")
    local obj = WoW.ldb.objects.GuildSpy
    eq(obj.type, "launcher", "...as a LibDataBroker launcher")
    eq(obj.icon, "Interface\\Icons\\INV_Misc_Spyglass_03", "...with the spyglass")
    WoW.fire("PLAYER_LOGIN")
    eq(WoW.ldbi.registrations, 1, "a second login event registers nothing twice")

    local button = WoW.ldbi:GetMinimapButton("GuildSpy")
    check(button:IsShown(), "it is shown by default")
    check(not isOpen(), "(the log is closed)")
    button._scripts.OnClick(button, "LeftButton")
    check(isOpen(), "left-click opens the log")
    button._scripts.OnClick(button, "LeftButton")
    check(not isOpen(), "...and closes it")
    button._scripts.OnClick(button, "RightButton")
    eq(WoW.settings.opened, "cat:GuildSpy", "right-click opens the settings")

    -- Out of a guild: the tooltip says so, and what the clicks do.
    local tip = { lines = {} }
    function tip:AddLine(text) self.lines[#self.lines + 1] = text end
    obj.OnTooltipShow(tip)
    eq(tip.lines[1], "|cff7fd4ffGuild|rSpy", "the tooltip names it")
    eq(tip.lines[2], "No guild seen yet.", "...no guild yet")
    eq(tip.lines[3], "Left-click: open or close the log", "...what a left-click does")
    eq(tip.lines[4], "Right-click: settings", "...and a right-click")
    eq(tip.lines[5], "Drag: move around the minimap", "...and dragging")

    -- A setting, through Options.Set.
    local O = GuildSpy.Options
    eq(O.Get("minimapButton"), true, "the setting reads shown")
    eq(O.Set("minimapButton", false), true, "it can be hidden")
    check(not button:IsShown(), "...the button goes")
    eq(GuildSpyDB.minimap.hide, true, "...saved in LibDBIcon's table")
    eq(O.Get("minimapButton"), false, "...and the setting reads hidden")
    eq(O.Set("minimapButton", "no"), false, "a value that isn't true or false is refused")
    O.Set("minimapButton", true)
    check(button:IsShown(), "shown again")

    -- The settings page has it.
    local page = O._test.page
    page:Show()
    local cb = page.controls.minimapButton.check
    eq(cb:GetChecked(), true, "the settings page has a check box for it")
    cb:SetChecked(false); cb._scripts.OnClick(cb)
    check(not button:IsShown(), "...unticking hides the button")
    cb:SetChecked(true); cb._scripts.OnClick(cb)

    -- /gspy minimap
    WoW.chat = {}
    WoW.slash("/gspy minimap")
    check(not button:IsShown(), "/gspy minimap hides it")
    check(chatHas("hidden: /gspy minimap brings it back"), "...and says how to bring it back")
    WoW.slash("/gspy minimap")
    check(button:IsShown(), "...and again shows it")
    check(chatHas("minimap button shown."), "...saying so")
end

do  -- in a guild: the tooltip has the guild, who's online, and what's new
    inGuild()
    local gs = GuildSpyDB.guilds["Parse Partout-Forever"]
    local now = time()
    GuildSpy.Log.Add(GuildSpyDB, gs, { kind = "JOIN", name = "Cy New", guid = "Player-1-00000009" }, now)
    GuildSpy.Log.Add(GuildSpyDB, gs, { kind = "ONOTE", name = "Ann Lee", guid = "Player-1-00000002", from = "", to = "tank" }, now)
    local tip = { lines = {} }
    function tip:AddLine(text) self.lines[#self.lines + 1] = text end
    WoW.ldb.objects.GuildSpy.OnTooltipShow(tip)
    eq(tip.lines[2], "Parse Partout", "the guild's name")
    eq(tip.lines[3], "2 of 3 members online", "...who's online at the last scan")
    local new = GuildSpy.Log.Plain(tip.lines[4])
    eq(new, "New: 1 joined", "...what's new since the log was last looked at, no officer note for a non-officer")
    WoW.guild.canViewOfficerNote = true
    tip.lines = {}
    WoW.ldb.objects.GuildSpy.OnTooltipShow(tip)
    check(GuildSpy.Log.Plain(tip.lines[4]):find("1 note edit", 1, true), "...an officer's counts the officer note")
    -- Looked at in the window: nothing new.
    GuildSpy.UI.Open()
    win():Hide()
    tip.lines = {}
    WoW.ldb.objects.GuildSpy.OnTooltipShow(tip)
    eq(GuildSpy.Log.Plain(tip.lines[4]), "No new activity", "after the window: nothing new")
    -- An online member gone from the roster, not yet confirmed as left (#27 review).
    table.remove(WoW.guild.members, 2)                       -- Ann Lee, online
    WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
    check(gs.members["Player-1-00000002"] and gs.members["Player-1-00000002"].missingSince,
        "(Ann is kept, pending the departure's confirmation)")
    tip.lines = {}
    WoW.ldb.objects.GuildSpy.OnTooltipShow(tip)
    eq(tip.lines[3], "1 of 2 members online", "a member pending departure isn't counted")
end

do  -- hidden in the saved file: it stays hidden
    loadAddon({ db = { minimap = { hide = true, minimapPos = 123 } } })
    WoW.fire("PLAYER_LOGIN")
    check(not WoW.ldbi:GetMinimapButton("GuildSpy"):IsShown(), "a button saved hidden starts hidden")
    eq(GuildSpyDB.minimap.minimapPos, 123, "...and its saved place is kept")
    eq(GuildSpy.Options.Get("minimapButton"), false, "...and the setting says so")
end

do  -- a damaged saved table is replaced
    loadAddon({ db = { minimap = "junk" } })
    eq(type(GuildSpyDB.minimap), "table", "a minimap entry that isn't a table is replaced")
end

do  -- the name already taken by another addon: no button, no error at login
    loadAddon()
    WoW.ldb = WoW.newLDB()
    WoW.ldb.objects.GuildSpy = {}
    function WoW.ldb:NewDataObject(name, obj)       -- as the real one: nil for a taken name
        if self.objects[name] then return nil end
        self.objects[name] = obj; return obj
    end
    WoW.fire("PLAYER_LOGIN")
    eq(GuildSpy.Minimap.Available(), false, "a taken name: no button")
    eq(WoW.ldbi.registrations, 0, "...nothing registered")
    WoW.chat = {}
    WoW.slash("/gspy minimap")
    check(chatHas("there is no minimap button"), "/gspy minimap says there is none, not 'shown'")
end

do  -- Register itself erroring (LibDBIcon errors on a name it already has)
    loadAddon()
    WoW.ldbi = WoW.newLDBI()
    function WoW.ldbi:Register() error("Object 'GuildSpy' is already registered.") end
    WoW.fire("PLAYER_LOGIN")
    eq(GuildSpy.Minimap.Available(), false, "a Register that errors: no button, no error at login")
end

do  -- hiding is saved by us: LibDBIcon's Show/Hide never write the table
    loadAddon()
    WoW.fire("PLAYER_LOGIN")
    local button = WoW.ldbi:GetMinimapButton("GuildSpy")
    GuildSpy.Options.Set("minimapButton", false)
    eq(GuildSpyDB.minimap.hide, true, "hidden: saved, so it stays hidden after a restart")
    button._repositioned = nil
    GuildSpy.Options.Set("minimapButton", true)
    eq(GuildSpyDB.minimap.hide, false, "shown: saved")
    check(button._repositioned, "(showing it re-anchors it on the ring, as LibDBIcon does)")
end

do  -- no libraries: no button, nothing else breaks
    loadAddon()
    local real = LibStub
    LibStub = function() error("no such library") end
    WoW.fire("PLAYER_LOGIN")
    LibStub = real
    eq(GuildSpy.Minimap._test.registered(), false, "without the libraries there is no button")
    GuildSpy.Minimap.Apply()
    check(true, "...and showing or hiding it is a no-op, not an error")
    WoW.slash("/gspy log")
    check(isOpen(), "...and the log still opens")
end

do  -- the compartment: the TOC names globals that click like the minimap button
    loadAddon()
    WoW.fire("PLAYER_LOGIN")
    local toc = readFile("GuildSpy.toc")
    local fname = toc:match("## AddonCompartmentFunc:%s*([%w_]+)")
    eq(fname, "GuildSpy_OnAddonCompartmentClick", "the TOC names the compartment's function")
    local fn = rawget(_G, fname)
    eq(type(fn), "function", "...and it exists, as a global (the compartment looks it up by name)")
    fn("GuildSpy", "LeftButton")                     -- the compartment's call: (addonName, buttonName)
    check(isOpen(), "a left-click in the compartment opens the log")
    fn("GuildSpy", "LeftButton")
    check(not isOpen(), "...and closes it")
    WoW.settings.opened = nil
    fn("GuildSpy", "RightButton")
    eq(WoW.settings.opened, "cat:GuildSpy", "a right-click opens the settings")

    for _, field in ipairs({ "OnEnter", "OnLeave" }) do
        local g = toc:match("## AddonCompartmentFunc" .. field .. ":%s*([%w_]+)")
        eq(type(g and rawget(_G, g)), "function", "the TOC's AddonCompartmentFunc" .. field .. " names a global function")
    end
    local row = CreateFrame("Button")
    GuildSpy_OnAddonCompartmentEnter("GuildSpy", row)
    eq(GameTooltip._owner, row, "hovering its row: a tooltip on it")
    eq(GameTooltip._lines[1], "|cff7fd4ffGuild|rSpy", "...naming it")
    local last = GameTooltip._lines[#GameTooltip._lines]
    eq(last, "Right-click: settings", "...saying what right-click does, and no 'drag' line (that's the minimap button's)")
    GuildSpy_OnAddonCompartmentLeave("GuildSpy", row)
    check(not GameTooltip:IsShown(), "leaving it hides the tooltip")
end

do  -- the key binding: Bindings.xml's code, and its names in Key Bindings
    loadAddon()
    WoW.fire("PLAYER_LOGIN")
    local xml = readFile("Bindings.xml")
    local bindings = {}
    for attrs, body in xml:gmatch("<Binding%s+(.-)>%s*(.-)%s*</Binding>") do
        bindings[#bindings + 1] = { name = attrs:match('name%s*=%s*"([^"]+)"'),
                                    category = attrs:match('category%s*=%s*"([^"]+)"'),
                                    header = attrs:match("header%s*="), body = body }
    end
    eq(#bindings, 1, "Bindings.xml has one binding")
    for _, b in ipairs(bindings) do
        -- Measured on Gnomesweeper: without a category it lands in "Other", and a
        -- header shows as a raw HEADER_ row.
        eq(b.category, "GuildSpy", b.name .. ": in a GuildSpy section of its own")
        check(not b.header, b.name .. ": no header (a raw row, measured)")
        check(type(rawget(_G, "BINDING_NAME_" .. b.name)) == "string", b.name .. ": its line in Key Bindings")
        check(loadstring(b.body) ~= nil, b.name .. ": its code compiles")
    end
    eq(bindings[1].name, "GUILDSPY_TOGGLE", "the toggle")
    eq(rawget(_G, "BINDING_NAME_GUILDSPY_TOGGLE"), "Open or close the activity log", "...its line")
    local run = assert(loadstring(bindings[1].body))
    check(not isOpen(), "(the log closed, not even built)")
    run()
    check(isOpen(), "the key opens the log (building it the first time)")
    run()
    check(not isOpen(), "...and closes it")
end

do  -- deploy and the package carry Bindings.xml (the client finds it by name, not in the TOC)
    local deploy = readFile("Tools/deploy.ps1")
    check(deploy:find('".xml"', 1, true) ~= nil, "deploy copies the root's .xml files")
    local ci = readFile(".github/workflows/package-check.yml")
    check(ci:find("GuildSpy/Bindings.xml", 1, true) ~= nil, "the package check expects Bindings.xml")
    local pkg = readFile(".pkgmeta")
    local block = pkg:match("\nignore:%s*\n(.-)\n%S") or pkg:match("\nignore:%s*\n(.*)$") or ""
    local entries = 0
    for entry in block:gmatch("%-%s*\"?([^\"\r\n]+)\"?") do
        entries = entries + 1
        local pattern = "^" .. entry:gsub("[%.%-%+%(%)%[%]%^%$%%]", "%%%0"):gsub("%*", ".*") .. "$"
        check(not ("Bindings.xml"):match(pattern), "the package's ignore entry '" .. entry .. "' doesn't drop Bindings.xml")
    end
    check(entries > 5, "(the ignore list was read: " .. entries .. " entries)")
end

done("test_minimap")
