-- GuildSpy.lua: the entry point. Loads last (see the TOC).
--
-- The saved table, the slash commands and the build check. The tracking is
-- Scanner.lua's (on Roster, Patterns, EventLog and Log).

local ADDON = ...
GuildSpy = GuildSpy or {}
local API = GuildSpy.API

local PREFIX = "|cff7fd4ffGuildSpy:|r "
local function say(msg) print(PREFIX .. msg) end
GuildSpy.Print = say

GuildSpy.HELP = {
    { "/gspy help", "this list" },
    { "/gspy log", "open the log window (also a tab in the guild window)" },
    { "/gspy log <n>", "print the last n changes in chat" },
    { "/gspy options", "the settings (also in Options > AddOns > GuildSpy)" },
    { "/gspy status", "what GuildSpy knows about your guild" },
    { "/gspy scan", "look at the roster now" },
    { "/gspy rebaseline", "start over from the current roster (the log is kept)" },
    { "/gspy version", "the addon's version and the client build" },
    { "/gspy probe", "dump the guild API's shapes (for measuring)" },
    { "/gspy probe watch", "record every system message (for measuring)" },
    { "/gspy probe log", "dump the guild event log again (for measuring)" },
    { "/gspy probe recipes", "open a guildmate's recipe book through the guild API (for measuring)" },
}

-- GuildSpyDB: account-wide (docs/PLAN.md "Storage"). A part that isn't the
-- right type is replaced: a damaged file must not stop the load. Each guild's
-- own table is checked when it is first used (Scanner).
local function initDB()
    if type(GuildSpyDB) ~= "table" then GuildSpyDB = {} end
    local db = GuildSpyDB
    db.version = db.version or 1
    if type(db.settings) ~= "table" then db.settings = {} end
    GuildSpy.Options.Validate(db.settings)
    if type(db.guilds) ~= "table" then db.guilds = {} end
    if type(db.nextSeq) ~= "number" then db.nextSeq = 1 end
end

local function slash(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "probe" then
        rest = rest:lower()
        if rest == "watch" then GuildSpy.Probe.ToggleWatch()
        elseif rest == "log" then
            if GuildSpyDB.probe then GuildSpy.Probe.DumpEventLog() else say("run /gspy probe first") end
        elseif rest == "recipes" then GuildSpy.Probe.MemberRecipes()
        else GuildSpy.Probe.Run() end
    elseif cmd == "log" then
        if tonumber(rest) then GuildSpy.Scanner.PrintLog(tonumber(rest)) else GuildSpy.UI.Open() end
    elseif cmd == "options" or cmd == "settings" or cmd == "config" then
        GuildSpy.Options.Open()
    elseif cmd == "status" then
        GuildSpy.Scanner.Status()
    elseif cmd == "scan" then
        GuildSpy.Scanner.Request()
        say("asked the server for the roster.")
    elseif cmd == "rebaseline" then
        GuildSpy.Scanner.Rebaseline()
    elseif cmd == "version" then
        say(API.AddOnVersion(ADDON) .. " on client " .. tostring(API.ClientBuild())
            .. " (measured on " .. GuildSpy.MEASURED_ON_BUILD .. ")")
    else
        say("commands:")
        for _, h in ipairs(GuildSpy.HELP) do print("  " .. h[1] .. " - " .. h[2]) end
    end
end

SLASH_GUILDSPY1 = "/guildspy"
SLASH_GUILDSPY2 = "/gspy"
SlashCmdList.GUILDSPY = slash

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" and name == ADDON then
        initDB()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        -- A build other than the one the notes describe: the guild shapes may have moved.
        local build = API.ClientBuild()
        if build and build ~= GuildSpy.MEASURED_ON_BUILD then
            say("client " .. build .. " is not the build GuildSpy was measured on ("
                .. GuildSpy.MEASURED_ON_BUILD .. ").")
        end
    end
end)

GuildSpy._test = GuildSpy._test or {}
GuildSpy._test.slash = slash
