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
-- A tooltip that records its lines; a double line is its two texts joined by a tab.
local function newTip()
    local tip = { lines = {} }
    function tip:AddLine(text) self.lines[#self.lines + 1] = text end
    function tip:AddDoubleLine(l, r) self.lines[#self.lines + 1] = l .. "\t" .. r end
    return tip
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
    local tip = newTip()
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
    local tip = newTip()
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
    -- A guildmate's report: counted, unless reports are set to Never (#43 review).
    GuildSpy.Log.Receive(GuildSpyDB, gs, { uid = "bo1:1", rev = 1, kind = "JOIN", guid = "Player-1-0000000A", name = "Di Fox",
        at = now - 60, lo = now - 120, hi = now - 60, obs = now - 60, origin = "Bo Kay" }, "guild", "Bo Kay", now)
    tip.lines = {}
    WoW.ldb.objects.GuildSpy.OnTooltipShow(tip)
    eq(GuildSpy.Log.Plain(tip.lines[4]), "New: 1 joined", "a guildmate's report is new")
    GuildSpyDB.settings.reports = "never"
    tip.lines = {}
    WoW.ldb.objects.GuildSpy.OnTooltipShow(tip)
    eq(GuildSpy.Log.Plain(tip.lines[4]), "No new activity", "...not with reports set to Never, as in the window")
    GuildSpyDB.settings.reports = nil
    -- An online member gone from the roster, not yet confirmed as left (#27 review).
    table.remove(WoW.guild.members, 2)                       -- Ann Lee, online
    WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
    check(gs.members["Player-1-00000002"] and gs.members["Player-1-00000002"].missingSince,
        "(Ann is kept, pending the departure's confirmation)")
    tip.lines = {}
    WoW.ldb.objects.GuildSpy.OnTooltipShow(tip)
    eq(tip.lines[3], "1 of 2 members online", "a member pending departure isn't counted")
end

do  -- the most recent changes in the tooltip (#95)
    inGuild()
    local Log, O = GuildSpy.Log, GuildSpy.Options
    local gs = GuildSpyDB.guilds["Parse Partout-Forever"]
    local now = time()
    local function show()
        local tip = newTip()
        WoW.ldb.objects.GuildSpy.OnTooltipShow(tip)
        for i, l in ipairs(tip.lines) do tip.lines[i] = Log.Plain(l) end
        return tip.lines
    end
    Log.Add(GuildSpyDB, gs, { kind = "JOIN", name = "Cy New", guid = "Player-1-00000009" }, now - 7200)
    Log.Add(GuildSpyDB, gs, { kind = "ONOTE", name = "Ann Lee", guid = "Player-1-00000002", from = "", to = "tank" }, now - 60)
    eq(O.Get("tooltipRecent"), 5, "the last 5 by default")
    local lines = show()
    eq(lines[5], " ", "a gap after the summary")
    eq(lines[6], "Cy New joined the guild\t2h ago", "a change as the window's row, its time on the right")
    eq(lines[7], " ", "...one change only: no officer note for a non-officer")
    eq(lines[8], "Left-click: open or close the log", "...then a gap and the hints")
    WoW.guild.canViewOfficerNote = true
    lines = show()
    eq(lines[6], "Ann Lee officer note: \"tank\"\t1m ago", "an officer sees the officer note, newest first")
    eq(lines[7], "Cy New joined the guild\t2h ago", "...then the older change")
    WoW.guild.canViewOfficerNote = false

    -- More than fit: the newest five, newest first.
    for i = 1, 6 do
        Log.Add(GuildSpyDB, gs, { kind = "LEVEL", name = "Bo Kay", guid = "Player-1-00000003", from = 30 + i, to = 31 + i }, now - 600 + i)
    end
    lines = show()
    eq(lines[6], "Bo Kay reached level 37\t9m ago", "the newest first")
    eq(lines[10], "Bo Kay reached level 33\t9m ago", "...five of them")
    eq(lines[11], " ", "...and no more")
    O.Set("tooltipRecent", 3)
    lines = show()
    eq(lines[8], "Bo Kay reached level 35\t9m ago", "the last 3: three")
    eq(lines[9], " ", "...and no more")
    O.Set("tooltipRecent", 0)
    lines = show()
    eq(lines[5], "Left-click: open or close the log", "None: no list, no gaps")
    eq(O.Set("tooltipRecent", 4), false, "a number that isn't a choice is refused")
    for i = 1, 5 do
        Log.Add(GuildSpyDB, gs, { kind = "NOTE", name = "Bo Kay", guid = "Player-1-00000003", from = "n" .. (i - 1), to = "n" .. i }, now - 300 + i)
    end
    GuildSpyDB.settings.tooltipRecent = 50                -- a later version's larger number (12 changes now)
    lines = show()
    local rows = 0
    for _, l in ipairs(lines) do if l:find("\t", 1, true) then rows = rows + 1 end end
    eq(rows, 10, "a larger saved number is held to 10")
    eq(lines[15], "Bo Kay reached level 33\t9m ago", "...the newest ten")
    GuildSpyDB.settings.tooltipRecent = nil

    -- A long value is cut, on a character boundary; the window keeps it whole.
    local motd = ("\226\130\172"):rep(20)                 -- 20 euro signs, 3 bytes each
    Log.Add(GuildSpyDB, gs, { kind = "MOTD", to = motd }, now)
    lines = show()
    local shown = lines[6]:match('^New MOTD: "(.-)"\t')
    eq(shown, ("\226\130\172"):rep(13) .. "...", "a long MOTD: cut to 40 bytes, not halfway through a character")
    eq(Log.Short({ to = ("\195\169"):rep(30) }, 40).to, ("\195\169"):rep(20) .. "...", "...a cut between two characters keeps them all")
    eq(gs.log[#gs.log].to, motd, "...the log keeps it whole")
    eq(Log.Short({ kind = "NOTE", to = "short" }, 40).to, "short", "a short value is left alone")
    local pipes = Log.Short({ kind = "NOTE", to = ("|"):rep(50) }, 40)
    eq(Log.Plain(Log.Row(pipes, now)), "? note: \"" .. ("|"):rep(40) .. "...\"", "a cut value is escaped after the cut")

    -- Guildmates' reports: listed, marked, unless they're set to Never.
    Log.Receive(GuildSpyDB, gs, { uid = "bo1:1", rev = 1, kind = "JOIN", guid = "Player-1-0000000A", name = "Di Fox",
        at = now - 30, lo = now - 90, hi = now - 30, obs = now - 30, origin = "Bo Kay" }, "guild", "Bo Kay", now)
    local function listed(text)
        for _, l in ipairs(show()) do if l:find(text, 1, true) then return true end end
        return false
    end
    check(listed("Di Fox joined the guild  (reported)"), "a guildmate's report is listed, marked")
    GuildSpyDB.settings.reports = "never"
    check(not listed("Di Fox"), "...not with reports set to Never")
    GuildSpyDB.settings.reports = nil

    -- The compartment's tooltip (GameTooltip) has the list too.
    GuildSpy_OnAddonCompartmentEnter(nil, CreateFrame("Frame"))
    local found = false
    for _, l in ipairs(GameTooltip._lines or {}) do
        if Log.Plain(l):find("^New MOTD: ") then found = true end
    end
    check(found, "the addon compartment's tooltip lists them")

    -- The settings page has the choice.
    local page = O._test.page
    page:Show()
    local radios = page.controls.tooltipRecent.radios
    eq(#radios, 4, "the settings page: None, 3, 5, 10")
    local sel
    for _, rb in ipairs(radios) do if rb:GetChecked() then sel = rb.value end end
    eq(sel, 5, "...5 selected by default")
    radios[1]._scripts.OnClick(radios[1])
    eq(GuildSpyDB.settings.tooltipRecent, 0, "...None: saved")
    local bad = { tooltipRecent = "x", chat = {} }
    O.Validate(bad)
    eq(bad.tooltipRecent, nil, "a saved value no page could set goes back to the default")
end

do  -- by when it happened, not by place in the log (#96 Codex review)
    inGuild()
    local Log = GuildSpy.Log
    local gs = GuildSpyDB.guilds["Parse Partout-Forever"]
    local now = time()
    local function rows()
        local tip = newTip()
        WoW.ldb.objects.GuildSpy.OnTooltipShow(tip)
        local out = {}
        for _, l in ipairs(tip.lines) do
            local text = Log.Plain(l):match("^(.-)\t")
            if text then out[#out + 1] = text end
        end
        return out
    end
    -- Five changes from today, then sync catching up appends five from yesterday.
    for i = 1, 5 do
        Log.Add(GuildSpyDB, gs, { kind = "LEVEL", name = "Bo Kay", guid = "Player-1-00000003", from = 30 + i, to = 31 + i }, now - 600 + i)
    end
    for i = 1, 5 do
        Log.Receive(GuildSpyDB, gs, { uid = "bo2:" .. i, rev = 1, kind = "JOIN", guid = "Player-1-000000B" .. i, name = "Old Join" .. i,
            at = now - 86400 + i, lo = now - 86460 + i, hi = now - 86400 + i, obs = now - 86400 + i, origin = "Ann Lee" },
            "guild", "Ann Lee", now)
    end
    check(gs.log[#gs.log].name == "Old Join5", "(yesterday's joins are last in the log)")
    local r = rows()
    eq(#r, 5, "five rows")
    eq(r[1], "Bo Kay reached level 36", "the newest by time first, though older history was appended after it")
    eq(r[5], "Bo Kay reached level 32", "...today's five, none of yesterday's")
    -- An entry the event log dates back (Log.Enrich moving `at`) sorts by that time.
    gs.log[5].at = now - 2 * 86400
    r = rows()
    eq(r[1], "Bo Kay reached level 35", "an entry moved back in time drops from the top")
    eq(r[5], "Old Join5 joined the guild  (reported)", "...and the newest older change takes its place")
    -- Same second: the window's tie-breakers (hi, then seq) decide, as in the window.
    local a = { at = 100, hi = 100, seq = 1 }
    local b = { at = 100, hi = 90, seq = 2 }
    check(Log.Later(a, b) and not Log.Later(b, a), "the same second: the later window end is newer")
    check(Log.Later({ at = 100, seq = 3 }, { at = 100, seq = 2 }), "...then the later seq")
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
