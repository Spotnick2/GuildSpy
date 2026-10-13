-- #34: reaching the level cap stands out (GRM's "Level Cap! Hurray!"), with an
-- optional fanfare: once live, once for a login summary.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function member(name, rank, guid, level)
    return { name = name, rank = rank, level = level or 30, class = "MAGE", online = true, guid = guid, note = "" }
end
local function newGuild()
    return { name = "Parse Partout", realm = "Forever", myRank = 3,
             ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" },
             -- Cy first: in roster order its level-up is logged before the cap ones,
             -- so only the cap's priority can put those first in the summary.
             members = { member("Cy Dee", 3, "Player-1-00000004", 40),
                         member("Fizzle Sprocketwhistle", 3, "Player-1-00000001"),
                         member("Ann Lee", 3, "Player-1-00000002", 59),
                         member("Bo Kay", 3, "Player-1-00000003", 58) },
             events = {}, eventNames = true, motd = "hello", canViewOfficerNote = false }
end
local function chatHas(text)
    for _, line in ipairs(WoW.chat) do
        if GuildSpy.Log.Plain(line):find(text, 1, true) then return line end
    end
end
local function login(db, guild)
    loadAddon({ db = db, setup = function() WoW.guild = guild end })
    WoW.fire("PLAYER_LOGIN")
    WoW.fire("GUILD_ROSTER_UPDATE", false)
    for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
    WoW.advance(25)
end
local function rosterUpdate() WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3) end
local function find(name)
    for _, m in ipairs(WoW.guild.members) do if m.name == name then return m end end
end

-- The cap, from the client: asked once per session (it moves only with a client update).
loadAddon()
local API = GuildSpy.API
WoW.capCalls = 0
eq(API.LevelCap(), 60, "the cap: the expansion's max level")
for _ = 1, 5 do API.LevelCap() end
eq(WoW.capCalls, 1, "...asked once, then kept for the session")
loadAddon({ setup = function() WoW.capFns.expansion = false end })
eq(GuildSpy.API.LevelCap(), 60, "...else the player's")
loadAddon({ setup = function() WoW.capFns.expansion, WoW.capFns.player = false, false end })
eq(GuildSpy.API.LevelCap(), nil, "...neither: no cap")
loadAddon({ setup = function() WoW.levelCap = 0 end })
eq(GuildSpy.API.LevelCap(), nil, "a cap that isn't a positive number is no cap")
loadAddon()
local Log = GuildSpy.Log

-- The words: in chat and in the window, only at the cap.
local cap = { kind = "LEVEL", name = "Ann Lee", from = 59, to = 60 }
local below = { kind = "LEVEL", name = "Ann Lee", from = 58, to = 59 }
check(Log.IsCap(cap) and not Log.IsCap(below), "a level-up to 60 is the cap; to 59 isn't")
check(not Log.IsCap({ kind = "JOIN", name = "X", to = 60 }), "only a level-up")
eq(Log.Plain(Log.Line(cap, 0)), "Ann Lee reached level 60, the level cap!", "chat: the cap's words")
check(Log.Line(cap, 0):find("|cffffd100level 60, the level cap!|r", 1, true), "...in gold")
eq(Log.Plain(Log.Line(below, 0)), "Ann Lee reached level 59", "below the cap: as before")
eq(Log.Plain(Log.Row(cap, 0)), "Ann Lee reached level 60, the level cap!", "the window: the same words")
check(Log.Row(cap, 0):find("|cffffd100level 60, the level cap!|r", 1, true), "...in gold")
eq(Log.Plain(Log.Row({ kind = "LEVEL", name = "Bo Kay", from = 55, to = 60 }, 0)),
    "Bo Kay leveled from 55 to level 60, the level cap!", "several levels at once to the cap")
loadAddon({ setup = function() WoW.capFns.expansion, WoW.capFns.player = false, false end })
eq(GuildSpy.Log.Plain(GuildSpy.Log.Line(cap, 0)), "Ann Lee reached level 60", "no cap from the client: the usual words")

-- The summary: a cap level-up before the other level-ups, and one fanfare however many.
local G = newGuild()
login(nil, G)
local gs = GuildSpyDB.guilds["Parse Partout-Forever"]
local db = GuildSpyDB
-- While away: Cy levels, then Ann and Bo hit the cap.
find("Cy Dee").level = 41
find("Ann Lee").level = 60
find("Bo Kay").level = 60
WoW.sounds = {}
login(db, G)
check(chatHas("Ann Lee reached level 60, the level cap!") and chatHas("reached level 41"), "(the summary has both)")
-- The order, on fixed entries: Cy's level-up is older, yet the cap comes first.
local lines = Log.Digest({ shownSeq = 0, log = {
    { seq = 1, at = 1, kind = "LEVEL", name = "Cy Dee", from = 40, to = 41 },
    { seq = 2, at = 2, kind = "LEVEL", name = "Ann Lee", from = 59, to = 60 } } }, false, 10)
check(Log.Plain(lines[2]):find("Ann Lee reached level 60", 1, true), "the summary lists a cap level-up first")
check(Log.Plain(lines[3]):find("Cy Dee reached level 41", 1, true), "...then the other level-ups")
eq(#WoW.sounds, 1, "one fanfare for a summary with two")
eq(WoW.sounds[1].kit, GuildSpy.Scanner.CAP_SOUND, "...the level-up fanfare")
eq(WoW.sounds[1].channel, "SFX", "...on the Sound Effects channel")

-- Live: one fanfare per cap level-up, none below.
G = newGuild()
login(nil, G)
WoW.sounds, WoW.chat = {}, {}
find("Cy Dee").level = 41
rosterUpdate()
check(chatHas("reached level 41"), "(a live level-up below the cap)")
eq(#WoW.sounds, 0, "...plays nothing")
find("Ann Lee").level = 60
rosterUpdate()
check(chatHas("reached level 60, the level cap!"), "a live level-up to the cap says so")
eq(#WoW.sounds, 1, "...with one fanfare")

-- The setting: off plays nothing; ticking it plays it once (to hear it).
local O = GuildSpy.Options
eq(O.Get("capSound"), true, "the fanfare is on by default")
O.Set("capSound", false)
eq(GuildSpyDB.settings.capSound, false, "off: saved")
WoW.sounds = {}
find("Bo Kay").level = 60
rosterUpdate()
check(chatHas("Bo Kay reached level 60"), "(Bo hits the cap)")
eq(#WoW.sounds, 0, "the fanfare off: silent")
O.Set("capSound", true)
eq(#WoW.sounds, 1, "ticking it on plays it, to hear it")
eq(O.Set("capSound", "loud"), false, "only true or false")

-- A summary with the setting off, or with the summary off: silent.
G = newGuild()
login(nil, G)
db = GuildSpyDB
db.settings.capSound = false
find("Ann Lee").level = 60
WoW.sounds = {}
login(db, G)
check(chatHas("the level cap"), "(the summary has it)")
eq(#WoW.sounds, 0, "the fanfare off: no sound with the summary")
db.settings.capSound, db.settings.digest = nil, false
find("Bo Kay").level = 60
WoW.sounds = {}
login(db, G)
eq(#WoW.sounds, 0, "the summary off: no sound either")

done("test_levelcap")
