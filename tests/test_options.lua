-- The settings (#4): Options > AddOns > GuildSpy and its About page, the one
-- place a setting changes, the saved values' check, and that the scan and the
-- chat lines follow them.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function member(name, rank, guid, extra)
    local r = { name = name, rank = rank, level = 30, class = "MAGE", online = true, guid = guid, note = "" }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end
local function newGuild()
    return { name = "Parse Partout", realm = "Forever", myRank = 3,
             ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" },
             members = { member("Fizzle Sprocketwhistle", 3, "Player-1-00000001"),
                         member("Ann Lee", 3, "Player-1-00000002", { level = 3 }) },
             events = {}, eventNames = true, motd = "hello", canViewOfficerNote = false }
end
local function chatHas(text)
    for _, line in ipairs(WoW.chat) do if line:find(text, 1, true) then return line end end
end
local function login(db, guild)
    loadAddon({ db = db, setup = function() WoW.guild = guild end })
    WoW.fire("PLAYER_LOGIN")
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
    WoW.advance(25)
end
local function rosterUpdate() WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3) end

local G = newGuild()
login(nil, G)
local O, T = GuildSpy.Options, GuildSpy.Options._test
local S = GuildSpyDB.settings

-- Registered under Options > AddOns, with About under it.
eq(#WoW.settings.addons, 1, "one page in Options > AddOns")
eq(WoW.settings.addons[1].name, "GuildSpy", "...named GuildSpy")
eq(#WoW.settings.subs, 1, "one sub-page")
check(WoW.settings.subs[1].name == "About" and WoW.settings.subs[1].frame == T.about, "...About")

-- Hidden at creation, built on its first show (or the first show is blank).
local page = T.page
check(not page:IsShown() and not page.built, "the page is hidden and unbuilt until shown")
page:Show()
check(page.built and page.controls, "shown: built")

-- Defaults: nothing saved, the page shows the defaults.
check(page.controls.digest.check:GetChecked(), "the login summary is on by default")
local function selected(key)
    for _, rb in ipairs(page.controls[key].radios) do if rb:GetChecked() then return rb.value end end
end
eq(selected("levelMin"), 10, "level-ups from 10 by default")
eq(selected("returnDays"), 14, "back after 14 days by default")
for _, c in ipairs(O.CHAT) do
    check(page.controls[c.key].check:GetChecked(), "chat line on by default: " .. c.label)
end
eq(next(S.chat), nil, "...with nothing saved")

-- A radio saves its value; the page follows.
page.controls.levelMin.radios[1]._scripts.OnClick(page.controls.levelMin.radios[1])
eq(S.levelMin, 1, "Every level: saved")
eq(selected("levelMin"), 1, "...and selected")
-- ...and the scan uses it: a level-up from 3 to 4 is reported now.
for _, m in ipairs(G.members) do if m.name == "Ann Lee" then m.level = 4 end end
rosterUpdate()
check(chatHas("Ann Lee reached level 4"), "the next scan reports a level below 10")

-- A chat toggle covers each of its kinds; off is false, on is no saved value.
local joins = page.controls["chat:JOIN"].check
joins:SetChecked(false)
joins._scripts.OnClick(joins)
check(S.chat.JOIN == false and S.chat.REJOIN == false, "joins off: both join kinds off")
G.members[#G.members + 1] = member("Cy New", 4, "Player-1-00000009")
WoW.chat = {}
rosterUpdate()
check(not chatHas("Cy New"), "...no chat line for a join")
local gs = GuildSpyDB.guilds["Parse Partout-Forever"]
check(gs.log[#gs.log].kind == "JOIN" and gs.log[#gs.log].name == "Cy New", "...though the log has it")
joins:SetChecked(true)
joins._scripts.OnClick(joins)
check(S.chat.JOIN == nil and S.chat.REJOIN == nil, "joins on: nothing saved")

-- The login summary toggle.
local dg = page.controls.digest.check
dg:SetChecked(false)
dg._scripts.OnClick(dg)
eq(S.digest, false, "the login summary off: saved")
check(not dg:GetChecked(), "...and unchecked")

-- ...and the next login prints no summary.
WoW.chat = {}
login({ settings = { digest = false } }, newGuild())
check(not chatHas("now watching"), "the login summary off: none at login")
WoW.chat = {}
login(nil, newGuild())
check(chatHas("now watching"), "(on: there is one)")

-- Only values a page could set.
check(not O.Set("levelMin", 5), "a level not offered is refused")
check(not O.Set("digest", "yes"), "a toggle takes only true or false")
check(not O.Set("nope", true), "an unknown setting is refused")
eq(S.levelMin, 1, "...nothing changed")

-- A damaged saved table: whatever no page could have set goes back to the default.
local bad = { settings = { levelMin = "abc", returnDays = -3, digest = "x",
                           chat = { JOIN = true, LEAVE = false, NOTE = "off" } } }
login(bad, newGuild())
local bs = bad.settings
check(bs.levelMin == nil and bs.returnDays == nil and bs.digest == nil, "bad values go back to the defaults")
check(bs.chat.LEAVE == false and bs.chat.JOIN == nil and bs.chat.NOTE == nil, "...a chat setting keeps only false")
local bad2 = { settings = { chat = "x", levelMin = 15, returnDays = false } }
login(bad2, newGuild())
check(type(bad2.settings.chat) == "table", "a chat table that isn't one is replaced")
eq(bad2.settings.levelMin, 15, "a level from a later version (a number) is kept")
eq(bad2.settings.returnDays, nil, "a choice saved as false goes back to the default")

-- /gspy options opens the page; the log window steps aside from Settings.
WoW.slash("/gspy log")
local win = GuildSpy._test.UI.window()
check(win:IsShown(), "(the log window is open)")
WoW.slash("/gspy options")
eq(WoW.settings.opened, "cat:GuildSpy", "/gspy options opens Options > AddOns > GuildSpy")
check(not win:IsShown(), "...and the log window, above Settings, steps aside")

-- No Settings framework: it says where the settings would be.
local keep = Settings
Settings = nil
login(nil, newGuild())
WoW.chat = {}
WoW.slash("/gspy options")
check(chatHas("Options > AddOns > GuildSpy"), "no Settings framework: it says where")
Settings = keep

-- The About page: built on first show; the commands without the measuring ones.
login(nil, newGuild())
local about = GuildSpy.Options._test.about
check(not about.built, "About is unbuilt until shown")
about:Show()
check(about.built and #about.commands > 0, "shown: built")
local hasOptions = false
for _, fs in ipairs(about.commands) do
    check(not fs:GetText():find("measuring", 1, true), "no measuring command on About")
    if fs:GetText():find("/gspy options", 1, true) then hasOptions = true end
end
check(hasOptions, "...and /gspy options is there")
-- The links: copyable boxes; typing puts the link back.
eq(#about.links, 3, "three links: CurseForge, GitHub, Report a bug")
eq(about.links[1]:GetText(), "https://www.curseforge.com/wow/addons/guildspy", "...CurseForge's page")
eq(about.links[3]:GetText(), "https://github.com/Spotnick2/GuildSpy/issues/new/choose", "...and where to report a bug")
local lb = about.links[2]
lb:SetText("typed over")
lb._scripts.OnTextChanged(lb, true)
eq(lb:GetText(), "https://github.com/Spotnick2/GuildSpy", "typing in a link puts it back")
-- Each line under the one before: a wrapped line pushes the rest down (owner's screenshot).
local p = about.version._points[1]
check(p[1] == "TOPLEFT" and p[2] == about.tagline and p[3] == "BOTTOMLEFT", "the version hangs under the tagline, which may wrap")
p = about.commands[2]._points[1]
check(p[2] == about.commands[1] and p[3] == "BOTTOMLEFT", "...and each command under the one before")

-- Without the check and radio templates: our own buttons, from the art.
loadAddon({ setup = function()
    WoW.guild = newGuild()
    WoW.missingTemplates.UICheckButtonTemplate = true
    WoW.missingTemplates.UIRadioButtonTemplate = true
end })
WoW.fire("PLAYER_LOGIN")
local fp = GuildSpy.Options._test.page
fp:Show()
local rb = fp.controls.levelMin.radios[1]
eq(rb:GetNormalTexture()._texture, "Interface\\Buttons\\UI-RadioButton", "no radio template: drawn from the art")
eq(fp.controls.digest.check:GetCheckedTexture()._texture, "Interface\\Buttons\\UI-CheckBox-Check", "no check template: the same")
rb._scripts.OnClick(rb)
eq(GuildSpyDB.settings.levelMin, 1, "...and they still work")

done("test_options")
