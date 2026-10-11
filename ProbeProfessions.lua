-- ProbeProfessions.lua: does Forever's server answer the guild profession API?
-- For measuring only (an addon opportunity, not GuildSpy's scope: docs/FOREVER-PROBE.md).
--
-- Forever ships Retail's guild-recipe UI unchanged (wow-ui-source, forever vs
-- live branch: Blizzard_Communities\CommunitiesMemberList.lua and
-- Blizzard_Professions are identical there). Its one gate is
-- C_TradeSkillUI.IsGuildTradeSkillsEnabled(), which hides the Professions
-- roster column. Behind it:
--   * C_Club member info: profession1/2 Name, ID, Rank per member;
--   * QueryGuildRecipes -> GUILD_TRADESKILL_UPDATE -> GetGuildTradeSkillInfo:
--     the guild's crafters per profession;
--   * C_GuildInfo.QueryGuildMembersForRecipe -> GUILD_RECIPE_KNOWN_BY_MEMBERS ->
--     GetGuildRecipeInfoPostQuery / GetGuildRecipeMember: who knows a recipe;
--   * C_GuildInfo.QueryGuildMemberRecipes(guid, skillLine): a member's whole
--     recipe book, opened in the Professions frame (`/gspy probe recipes`,
--     opt-in because it opens a window).
-- The legacy globals are in the dump by name only; every call is pcall'd.

local ADDON = ...
GuildSpy = GuildSpy or {}
local API = GuildSpy.API
local Probe = GuildSpy.Probe
local g, packText, packData, scalarsOf = Probe.g, Probe.packText, Probe.packData, Probe.scalarsOf

local function say(msg) print("|cff7fd4ffGuildSpy probe:|r " .. msg) end
local function out() return GuildSpyDB and GuildSpyDB.probe end

-- One starter recipe per crafting profession (skill line -> recipe spell id),
-- for the "who knows this recipe" query. Gathering professions have none.
Probe.STARTER_RECIPES = {
    [171] = 2330,   -- Alchemy: Minor Healing Potion
    [164] = 2660,   -- Blacksmithing: Rough Sharpening Stone
    [333] = 7418,   -- Enchanting: Enchant Bracer - Minor Health
    [202] = 3918,   -- Engineering: Rough Blasting Powder
    [165] = 2152,   -- Leatherworking: Light Armor Kit
    [197] = 2963,   -- Tailoring: Bolt of Linen Cloth
    [186] = 2657,   -- Mining: Smelt Copper
    [185] = 2538,   -- Cooking: Charred Wolf Meat
    [129] = 3275,   -- First Aid: Linen Bandage
}
local SETTLE = 3        -- seconds of quiet before a burst-y answer is read
local RECIPE_WAIT = 4   -- seconds to wait for each "who knows this" answer

local function clubMembers()
    local club = g("C_Club") or {}
    local cid = API.Pack(club.GetGuildClubId)
    if not (cid.ok and cid[1]) then return nil, {} end
    local mem = API.Pack(club.GetClubMembers, cid[1])
    local ids = (mem.ok and type(mem[1]) == "table") and mem[1] or {}
    local infos = {}
    for i, id in ipairs(ids) do
        local info = API.Pack(club.GetMemberInfo, cid[1], id)
        if info.ok and type(info[1]) == "table" then infos[#infos + 1] = info[1] end
    end
    return cid[1], infos
end

-- Every member's professions: counts per profession, and whether any skill
-- rank is above 1 (the 3 sampled on the first run were all 1).
function Probe.ProfessionSurvey(infos)
    local s = { members = 0, withAny = 0, rankAbove1 = 0, rankMax = 0, byProfession = {}, list = {} }
    for _, m in ipairs(infos) do
        s.members = s.members + 1
        local any = false
        for slot = 1, 2 do
            local id, name, rank = m["profession" .. slot .. "ID"], m["profession" .. slot .. "Name"],
                m["profession" .. slot .. "Rank"]
            if id then
                any = true
                local key = tostring(name or id)
                local b = s.byProfession[key] or { id = id, count = 0, rankMax = 0 }
                b.count = b.count + 1
                if type(rank) == "number" then
                    if rank > b.rankMax then b.rankMax = rank end
                    if rank > s.rankMax then s.rankMax = rank end
                    if rank > 1 then s.rankAbove1 = s.rankAbove1 + 1 end
                end
                s.byProfession[key] = b
            end
        end
        if any then s.withAny = s.withAny + 1 end
        s.list[#s.list + 1] = { m.name, m.level, m.profession1Name, m.profession1Rank,
                                m.profession2Name, m.profession2Rank }
    end
    return s
end

local recipeQueue = {}

local function nextRecipeQuery()
    local o = out()
    local item = table.remove(recipeQueue, 1)
    if not o or not item then return end
    local cgi = g("C_GuildInfo") or {}
    local r = API.Pack(cgi.QueryGuildMembersForRecipe, item.skillLine, item.recipe)
    local entry = { skillLine = item.skillLine, recipe = item.recipe, query = packData(r) }
    o.professions.recipeQueries[#o.professions.recipeQueries + 1] = entry
    Probe.pendingRecipe = entry
    C_Timer.After(RECIPE_WAIT, function()
        if Probe.pendingRecipe == entry then
            entry.answer = "(no GUILD_RECIPE_KNOWN_BY_MEMBERS within " .. RECIPE_WAIT .. " s)"
            Probe.pendingRecipe = nil
            nextRecipeQuery()
        end
    end)
end

local function recipeAnswered()
    local entry = Probe.pendingRecipe
    if not entry then return end
    Probe.pendingRecipe = nil
    local post = API.Pack(g("GetGuildRecipeInfoPostQuery"))
    entry.post = packData(post)
    local n = (post.ok and type(post[3]) == "number") and post[3] or 0
    entry.members = {}
    for i = 1, math.min(10, n) do entry.members[i] = packData(API.Pack(g("GetGuildRecipeMember"), i)) end
    say(string.format("recipe %d (skill line %d): %s", entry.recipe, entry.skillLine, packText(post)))
    nextRecipeQuery()
end

local function dumpGuildTradeSkills()
    local o = out()
    if not o or not o.professions then return end
    local n = API.Pack(g("GetNumGuildTradeSkill"))
    local count = (n.ok and type(n[1]) == "number") and n[1] or 0
    local t = { num = packData(n), entries = {} }
    for i = 1, math.min(40, count) do t.entries[i] = packData(API.Pack(g("GetGuildTradeSkillInfo"), i)) end
    o.professions.guildTradeSkill = t
    say("guild trade skill list: " .. count .. " rows; first: "
        .. (count > 0 and packText(API.Pack(g("GetGuildTradeSkillInfo"), 1)) or "none"))
end

-- Called from Probe.Run.
function Probe.Professions(o)
    local ts = g("C_TradeSkillUI") or {}
    local p = { enabled = packData(API.Pack(ts.IsGuildTradeSkillsEnabled)), canView = {}, recipeQueries = {} }
    o.professions = p
    local _, infos = clubMembers()
    local s = Probe.ProfessionSurvey(infos)
    p.survey = s
    local names = {}
    for name, b in pairs(s.byProfession) do
        names[#names + 1] = name .. " " .. b.count .. (b.rankMax > 1 and (" (max " .. b.rankMax .. ")") or "")
        p.canView[name] = packData(API.Pack(g("CanViewGuildRecipes"), b.id))
    end
    table.sort(names)
    say("guild trade skills enabled: " .. packText(API.Pack(ts.IsGuildTradeSkillsEnabled)))
    say(string.format("professions: %d of %d members have one; %d skill ranks above 1 (max %d)",
        s.withAny, s.members, s.rankAbove1, s.rankMax))
    if #names > 0 then say("  " .. table.concat(names, ", ")) end

    -- The crafters list (Communities calls this when the guild roster shows).
    Probe.wantTradeSkill = true
    p.queryGuildRecipes = packData(API.Pack(g("QueryGuildRecipes")))

    -- "Who knows this recipe", one profession at a time (the answer is global state).
    recipeQueue = {}
    local seen = {}
    for _, b in pairs(s.byProfession) do
        local recipe = Probe.STARTER_RECIPES[b.id]
        if recipe and not seen[b.id] then
            seen[b.id] = true
            recipeQueue[#recipeQueue + 1] = { skillLine = b.id, recipe = recipe }
        end
    end
    table.sort(recipeQueue, function(a, b) return a.skillLine < b.skillLine end)
    nextRecipeQuery()
end

-- `/gspy probe recipes`: a guildmate's recipe book, as Communities opens it
-- (click a member under a profession header). Opens the Professions frame.
function Probe.MemberRecipes()
    local o = out()
    if not o then say("run /gspy probe first"); return end
    local me = API.PlayerFullName()
    local _, infos = clubMembers()
    local pick
    for _, m in ipairs(infos) do
        if m.guid and not m.isSelf and m.name ~= me and Probe.STARTER_RECIPES[m.profession1ID or -1] then
            if not pick or (m.presence == 1 and pick.presence ~= 1) then pick = m end
        end
    end
    if not pick then say("no guildmate with a crafting profession found"); return end
    local cgi = g("C_GuildInfo") or {}
    local r = API.Pack(cgi.QueryGuildMemberRecipes, pick.guid, pick.profession1ID)
    o.memberRecipes = { member = pick.name, guid = pick.guid, skillLine = pick.profession1ID,
                        profession = pick.profession1Name, rank = pick.profession1Rank,
                        query = packData(r), events = {} }
    Probe.wantMemberRecipes = true
    say("asked for " .. tostring(pick.name) .. "'s " .. tostring(pick.profession1Name)
        .. " recipes; reading them in " .. SETTLE .. " s")
    C_Timer.After(SETTLE + 1, function() Probe.DumpMemberRecipes() end)
end

function Probe.DumpMemberRecipes()
    local o = out()
    local mr = o and o.memberRecipes
    if not mr or not Probe.wantMemberRecipes then return end
    Probe.wantMemberRecipes = nil
    local ts = g("C_TradeSkillUI") or {}
    mr.isGuildMember = packData(API.Pack(ts.IsTradeSkillGuildMember))
    mr.isReady = packData(API.Pack(ts.IsTradeSkillReady))
    local base = API.Pack(ts.GetBaseProfessionInfo)
    mr.baseProfession = (base.ok and type(base[1]) == "table") and scalarsOf(base[1]) or packData(base)
    local all = API.Pack(ts.GetAllRecipeIDs)
    local ids = (all.ok and type(all[1]) == "table") and all[1] or {}
    mr.recipeIDs, mr.learned, mr.learnedNames = #ids, 0, {}
    for _, id in ipairs(ids) do
        local info = API.Pack(ts.GetRecipeInfo, id)
        local ri = info.ok and type(info[1]) == "table" and info[1]
        if ri and ri.learned then
            mr.learned = mr.learned + 1
            if #mr.learnedNames < 15 then mr.learnedNames[#mr.learnedNames + 1] = ri.name end
        end
    end
    say(string.format("%s's recipes: guild-member view %s, %d recipe ids, %d learned (%s)",
        tostring(mr.member), packText(API.Pack(ts.IsTradeSkillGuildMember)), mr.recipeIDs, mr.learned,
        table.concat(mr.learnedNames, ", ")))
end

local frame = CreateFrame("Frame")
Probe.professionFrame = frame
for _, e in ipairs({ "GUILD_TRADESKILL_UPDATE", "GUILD_RECIPE_KNOWN_BY_MEMBERS", "TRADE_SKILL_SHOW",
                     "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED" }) do
    if not API.RegisterEvent(frame, e) then Probe.refused[#Probe.refused + 1] = e end
end
frame:SetScript("OnEvent", function(_, event)
    if event == "GUILD_TRADESKILL_UPDATE" then
        if not Probe.wantTradeSkill then return end
        Probe.tradeSkillGen = (Probe.tradeSkillGen or 0) + 1
        local gen = Probe.tradeSkillGen
        C_Timer.After(SETTLE, function()
            if gen ~= Probe.tradeSkillGen or not Probe.wantTradeSkill then return end
            Probe.wantTradeSkill = nil
            dumpGuildTradeSkills()
        end)
    elseif event == "GUILD_RECIPE_KNOWN_BY_MEMBERS" then
        recipeAnswered()
    else
        local mr = out() and out().memberRecipes
        if mr and Probe.wantMemberRecipes then mr.events[#mr.events + 1] = event end
    end
end)
