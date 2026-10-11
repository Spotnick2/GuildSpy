-- The professions probe: survey every member, ask the guild-recipe API, and
-- never throw on a client where those calls are missing or silent.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function guild()
    return {
        name = "The Cogs", realm = "Forever", ranks = { "Guild Master", "Member" }, clubId = 7,
        members = { { name = "Fizzle Sprocketwhistle", rank = 0, level = 30, class = "MAGE", online = true,
                      guid = "Player-1-00000001" } },
        club = {
            { name = "Fizzle Sprocketwhistle", guid = "Player-1-00000001", isSelf = true, presence = 1,
              profession1ID = 197, profession1Name = "Tailoring", profession1Rank = 1 },
            { name = "Abby Lafey", guid = "Player-1-00000002", presence = 3, level = 30,
              profession1ID = 197, profession1Name = "Tailoring", profession1Rank = 1,
              profession2ID = 333, profession2Name = "Enchanting", profession2Rank = 1 },
            { name = "Akka Avery", guid = "Player-1-00000003", presence = 1, level = 20,
              profession1ID = 171, profession1Name = "Alchemy", profession1Rank = 75,
              profession2ID = 182, profession2Name = "Herbalism", profession2Rank = 1 },
            { name = "Nobody Home", guid = "Player-1-00000004", presence = 3, level = 5 },
        },
    }
end

-- The survey: counts per profession, and ranks above 1 noticed.
loadAddon({ setup = function() WoW.guild = guild() end })
WoW.slash("/gspy probe")
local p = GuildSpyDB.probe.professions
check(p ~= nil, "professions probed")
eq(p.survey.members, 4, "every club member surveyed")
eq(p.survey.withAny, 3, "members with a profession")
eq(p.survey.byProfession.Tailoring.count, 2, "Tailoring counted twice")
eq(p.survey.rankAbove1, 1, "one rank above 1")
eq(p.survey.rankMax, 75, "the highest rank")
eq(#p.survey.list, 4, "a row per member")
-- This client model has none of the legacy recipe globals: reported, not thrown.
eq(p.enabled.missing, true, "IsGuildTradeSkillsEnabled missing here, and said so")
eq(p.queryGuildRecipes.missing, true, "QueryGuildRecipes missing here, and said so")

-- "Who knows this recipe": one query per crafting profession in the guild, in turn,
-- each given up on after its wait when no answer comes.
eq(#p.recipeQueries, 1, "the first recipe query sent")
eq(p.recipeQueries[1].skillLine, 171, "lowest skill line first (Alchemy)")
WoW.advance(5)
eq(#p.recipeQueries, 2, "the next one after the wait")
check(p.recipeQueries[1].answer:find("no GUILD_RECIPE_KNOWN_BY_MEMBERS", 1, true), "a silent server is recorded")
WoW.advance(10)
eq(#p.recipeQueries, 3, "Alchemy, Tailoring, Enchanting: three crafting lines (Herbalism has no recipe)")

-- An answer moves the queue on at once and is read.
loadAddon({ setup = function() WoW.guild = guild() end })
rawset(_G, "GetGuildRecipeInfoPostQuery", function() return 171, 2330, 2 end)
rawset(_G, "GetGuildRecipeMember", function(i) return "Akka", "Akka Avery", "PRIEST", true end)
WoW.slash("/gspy probe")
WoW.fire("GUILD_RECIPE_KNOWN_BY_MEMBERS")
p = GuildSpyDB.probe.professions
eq(p.recipeQueries[1].post[3], 2, "the answer's member count read")
eq(p.recipeQueries[1].members[2][2], "Akka Avery", "the members who know it read")
eq(#p.recipeQueries, 2, "the next query sent without waiting")
rawset(_G, "GetGuildRecipeInfoPostQuery", nil)
rawset(_G, "GetGuildRecipeMember", nil)

-- The guild crafter list is read once its burst settles.
rawset(_G, "GetNumGuildTradeSkill", function() return 1 end)
rawset(_G, "GetGuildTradeSkillInfo", function(i) return 197, false, 0, "Tailoring" end)
WoW.fire("GUILD_TRADESKILL_UPDATE")
WoW.fire("GUILD_TRADESKILL_UPDATE")
WoW.advance(1)
eq(p.guildTradeSkill, nil, "not read mid-burst")
WoW.advance(3)
eq(p.guildTradeSkill.num[1], 1, "the crafter list read after the burst")
eq(p.guildTradeSkill.entries[1][4], "Tailoring", "...with its rows")
rawset(_G, "GetNumGuildTradeSkill", nil)
rawset(_G, "GetGuildTradeSkillInfo", nil)

-- A guildmate's recipe book: an online crafter who isn't you is picked.
loadAddon({ setup = function() WoW.guild = guild() end })
WoW.slash("/gspy probe recipes")
check(GuildSpyDB.probe == nil, "needs /gspy probe first")
WoW.slash("/gspy probe")
WoW.slash("/gspy probe recipes")
local mr = GuildSpyDB.probe.memberRecipes
eq(mr.member, "Akka Avery", "the online crafter, not yourself")
eq(mr.skillLine, 171, "...in their first profession")
WoW.fire("TRADE_SKILL_SHOW")
WoW.advance(5)
eq(mr.events[1], "TRADE_SKILL_SHOW", "the frame's events recorded")
eq(mr.recipeIDs, 0, "no recipe API here: zero, not an error")

done("test_probe_professions")
