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
check(mr.inconclusive ~= nil, "no recipe API here: inconclusive, not an error")

-- The client as measured on 70338: C_TradeSkillUI is there, the switch is off.
local closes, expanded, collapsed = 0, {}, {}
local function forever()
    rawset(_G, "C_TradeSkillUI", {
        IsGuildTradeSkillsEnabled = function() return false end,
        IsTradeSkillGuildMember = function() return true end,
        IsTradeSkillReady = function() return true end,
        GetBaseProfessionInfo = function() return { professionID = 171, skillLevel = 75, professionName = "Alchemy" } end,
        GetAllRecipeIDs = function() return { 2330, 2331 } end,
        GetRecipeInfo = function(id) return { name = "Recipe " .. id, learned = id == 2330 } end,
        CloseTradeSkill = function() closes = closes + 1 end,
    })
    rawset(_G, "CanViewGuildRecipes", function() return false end)
end
local function unforever()
    for _, k in ipairs({ "C_TradeSkillUI", "CanViewGuildRecipes", "GetGuildRecipeInfoPostQuery",
                         "GetNumGuildTradeSkill", "GetGuildTradeSkillInfo", "ExpandGuildTradeSkillHeader",
                         "CollapseGuildTradeSkillHeader" }) do rawset(_G, k, nil) end
end

loadAddon({ setup = function() WoW.guild = guild() end })
forever()
WoW.slash("/gspy probe")
p = GuildSpyDB.probe.professions
eq(p.enabled[1], false, "the switch read as off")
eq(p.canView.Tailoring[1], false, "CanViewGuildRecipes read per profession")

-- A late answer to a timed-out query is kept apart, never credited to the next one.
WoW.advance(5)                                       -- Alchemy (171) times out; Tailoring (197) pending
rawset(_G, "GetGuildRecipeInfoPostQuery", function() return 171, 2330, 3 end)
WoW.fire("GUILD_RECIPE_KNOWN_BY_MEMBERS")
eq(p.recipeQueries[2].post, nil, "Alchemy's late answer isn't Tailoring's")
eq(p.strayAnswers[1][1], 171, "...it is kept as a stray answer")
rawset(_G, "GetGuildRecipeInfoPostQuery", function() return 197, 2963, 0 end)
WoW.fire("GUILD_RECIPE_KNOWN_BY_MEMBERS")
eq(p.recipeQueries[2].post[1], 197, "Tailoring's own answer is Tailoring's")

-- The crafter list: collapsed headers are expanded to read member rows, then collapsed again.
local open = {}
rawset(_G, "GetNumGuildTradeSkill", function() return open[171] and 3 or 2 end)
rawset(_G, "GetGuildTradeSkillInfo", function(i)
    if i == 1 then return 171, not open[171], 1, "Alchemy", 1, 1, 2 end
    if open[171] and i == 2 then return 171, nil, nil, nil, nil, nil, nil, "Akka Avery", "Akka Avery", "PRIEST", true, "", 75 end
    return 197, true, 1, "Tailoring", 0, 0, 2
end)
rawset(_G, "ExpandGuildTradeSkillHeader", function(id) open[id] = true; expanded[#expanded + 1] = id end)
rawset(_G, "CollapseGuildTradeSkillHeader", function(id) open[id] = nil; collapsed[#collapsed + 1] = id end)
WoW.fire("GUILD_TRADESKILL_UPDATE")
WoW.advance(4)
local gts = p.guildTradeSkill
eq(gts.headers, 2, "two headers")
eq(#expanded, 2, "both collapsed headers expanded")
eq(gts.memberRows, 1, "the member row read")
eq(gts.numbersSeen[13].max, 75, "...with the number it carries (a skill, if the server sends one)")
eq(#collapsed, 2, "...and collapsed again afterwards")

-- A guildmate's book: the crafting profession may be the second one; the book is read, then closed.
WoW.guild.club[3].profession1ID, WoW.guild.club[3].profession1Name = 182, "Herbalism"
WoW.guild.club[3].profession2ID, WoW.guild.club[3].profession2Name = 171, "Alchemy"
C_TradeSkillUI.IsTradeSkillLinked = function() return true, "Akka Avery" end
WoW.slash("/gspy probe recipes")
local mr = GuildSpyDB.probe.memberRecipes
eq(mr.member, "Akka Avery", "an online crafter whose craft is in slot 2")
eq(mr.skillLine, 171, "...asked for that craft")
check(WoW.chat[#WoW.chat]:find("Alchemy recipes", 1, true), "...named by that slot's profession")
WoW.fire("TRADE_SKILL_SHOW")
WoW.advance(5)
eq(mr.inconclusive, nil, "the book that opened is provably the one asked for")
eq(mr.recipeIDs, 2, "the recipe ids read")
eq(mr.learned, 1, "...and which are learned")
eq(mr.learnedNames[1], "Recipe 2330", "...by name")
eq(closes, 1, "the book this probe opened is closed")

-- Nothing opened after the request (another book was already open): inconclusive, left alone.
WoW.slash("/gspy probe recipes")
mr = GuildSpyDB.probe.memberRecipes
WoW.advance(5)
check(mr.inconclusive and mr.inconclusive:find("no trade skill view opened", 1, true), "no new view: inconclusive")
eq(mr.recipeIDs, nil, "...nothing read as this member's")
eq(closes, 1, "...and the open view is left alone")

-- Another guildmate's book opened meanwhile: inconclusive, left alone.
C_TradeSkillUI.IsTradeSkillLinked = function() return true, "Someone Else" end
WoW.slash("/gspy probe recipes")
mr = GuildSpyDB.probe.memberRecipes
WoW.fire("TRADE_SKILL_SHOW")
WoW.advance(5)
check(mr.inconclusive and mr.inconclusive:find("Someone Else", 1, true), "someone else's book: inconclusive")
eq(closes, 1, "...and not closed")

-- A same-profession book that doesn't name its member: inconclusive, left alone.
C_TradeSkillUI.IsTradeSkillLinked = function() return false, nil end
WoW.slash("/gspy probe recipes")
mr = GuildSpyDB.probe.memberRecipes
WoW.fire("TRADE_SKILL_SHOW")
WoW.advance(5)
check(mr.inconclusive and mr.inconclusive:find("doesn't name its member", 1, true), "an unnamed view: inconclusive")
eq(mr.recipeIDs, nil, "...nothing read as the asked member's")
eq(closes, 1, "...and not closed")

-- A second request within the wait: the first timer does nothing.
C_TradeSkillUI.IsTradeSkillLinked = function() return true, "Akka Avery" end
WoW.slash("/gspy probe recipes")
WoW.advance(2)
WoW.slash("/gspy probe recipes")
local second = GuildSpyDB.probe.memberRecipes
WoW.fire("TRADE_SKILL_SHOW")
WoW.advance(2.5)                                       -- the first timer fires now
eq(second.done, nil, "the first request's timer didn't consume the second")
WoW.advance(3)
eq(second.done, true, "the second's own timer did")
eq(closes, 2, "...and closed only its own book")
unforever()

-- /gspy probe log with no probe yet: says so, runs nothing.
loadAddon({ setup = function() WoW.guild = guild() end })
WoW.slash("/gspy probe log")
eq(GuildSpyDB.probe, nil, "no probe run")
check(WoW.chat[#WoW.chat]:find("run /gspy probe first", 1, true), "...and it says what to do")

done("test_probe_professions")
