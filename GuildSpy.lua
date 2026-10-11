-- GuildSpy.lua: the entry point. Loads last (see the TOC).
--
-- Phase 0 (docs/PLAN.md): the saved table, the slash commands and the build
-- check. The roster tracking (Roster, Scanner, Log) comes in phase 1, on the
-- shapes /gspy probe measures.

local ADDON = ...
GuildSpy = GuildSpy or {}
local API = GuildSpy.API

local PREFIX = "|cff7fd4ffGuildSpy:|r "
local function say(msg) print(PREFIX .. msg) end
GuildSpy.Print = say

GuildSpy.HELP = {
    { "/gspy help", "this list" },
    { "/gspy version", "the addon's version and the client build" },
    { "/gspy probe", "dump the guild API's shapes (for measuring)" },
    { "/gspy probe watch", "record every system message (for measuring)" },
}

-- GuildSpyDB: account-wide. Phase 1 adds `guilds` (docs/PLAN.md "Storage").
-- A table that isn't one is replaced: a damaged file must not stop the load.
local function initDB()
    if type(GuildSpyDB) ~= "table" then GuildSpyDB = {} end
    GuildSpyDB.version = GuildSpyDB.version or 1
end

local function slash(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "probe" then
        if rest:lower() == "watch" then GuildSpy.Probe.ToggleWatch() else GuildSpy.Probe.Run() end
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
