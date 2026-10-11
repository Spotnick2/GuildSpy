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

-- An answer belongs to the pending query only if it names that query's skill
-- line and recipe (the query may return an updated recipe id). A late answer
-- to a query that already timed out, or to the Communities UI's own query, is
-- kept apart and never credited to another query.
local function recipeAnswered()
    local o = out()
    local post = API.Pack(g("GetGuildRecipeInfoPostQuery"))
    local entry = Probe.pendingRecipe
    local mine = entry and post.ok and post[1] == entry.skillLine
        and (post[2] == entry.recipe or post[2] == entry.query[1])
    if not mine then
        if o and o.professions then
            local stray = o.professions.strayAnswers or {}
            o.professions.strayAnswers = stray
            stray[#stray + 1] = packData(post)
        end
        return
    end
    Probe.pendingRecipe = nil
    entry.post = packData(post)
    local n = (post.ok and type(post[3]) == "number") and post[3] or 0
    entry.members = {}
    for i = 1, math.min(10, n) do entry.members[i] = packData(API.Pack(g("GetGuildRecipeMember"), i)) end
    say(string.format("recipe %d (skill line %d): %s", entry.recipe, entry.skillLine, packText(post)))
    nextRecipeQuery()
end

-- The crafter list. Its headers come collapsed: expand each one to read the
-- member rows (Cata's layout puts each crafter's skill there), then collapse
-- them again, leaving the client's list as it was.
local function dumpGuildTradeSkills()
    local o = out()
    if not o or not o.professions then return end
    local function count()
        local n = API.Pack(g("GetNumGuildTradeSkill"))
        return (n.ok and type(n[1]) == "number") and n[1] or 0, n
    end
    local headers, n0 = count()
    local expanded = {}
    for i = 1, headers do
        local row = API.Pack(g("GetGuildTradeSkillInfo"), i)
        if row.ok and row[2] == true and type(row[1]) == "number" then expanded[#expanded + 1] = row[1] end
    end
    for _, id in ipairs(expanded) do API.Pack(g("ExpandGuildTradeSkillHeader"), id) end
    local total = count()
    local t = { num = packData(n0), headers = headers, rows = total, expanded = #expanded, entries = {},
                memberRows = 0, numbersSeen = {} }
    for i = 1, math.min(400, total) do
        local row = API.Pack(g("GetGuildTradeSkillInfo"), i)
        t.entries[i] = packData(row)
        if row.ok and row[4] == nil and type(row[8]) == "string" then
            t.memberRows = t.memberRows + 1
            -- Every number a member row carries, by position: a skill level would show here.
            for k = 9, row.n do
                if type(row[k]) == "number" then
                    local seen = t.numbersSeen[k] or { min = row[k], max = row[k] }
                    seen.min, seen.max = math.min(seen.min, row[k]), math.max(seen.max, row[k])
                    t.numbersSeen[k] = seen
                end
            end
        end
    end
    for _, id in ipairs(expanded) do API.Pack(g("CollapseGuildTradeSkillHeader"), id) end
    o.professions.guildTradeSkill = t
    local nums = {}
    for k, v in pairs(t.numbersSeen) do nums[#nums + 1] = k .. ":" .. v.min .. "-" .. v.max end
    table.sort(nums)
    say(string.format("guild crafter list: %d headers, %d rows once expanded, %d member rows; numbers by position: %s",
        headers, total, t.memberRows, #nums > 0 and table.concat(nums, " ") or "none"))
end

-- Called from Probe.Run.
function Probe.Professions(o)
    local ts = g("C_TradeSkillUI") or {}
    local enabled = API.Pack(ts.IsGuildTradeSkillsEnabled)
    local p = { enabled = packData(enabled), canView = {}, recipeQueries = {} }
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
    say("guild trade skills enabled: " .. packText(enabled))
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
    -- A crafting profession in either slot; an online member (online, mobile,
    -- away or busy: anything but offline or unknown) is preferred.
    local OFFLINE, UNKNOWN = 3, 0
    local function onlineish(m) return m.presence ~= nil and m.presence ~= OFFLINE and m.presence ~= UNKNOWN end
    local pick, slot
    for _, m in ipairs(infos) do
        if m.guid and not m.isSelf and m.name ~= me then
            for k = 1, 2 do
                if Probe.STARTER_RECIPES[m["profession" .. k .. "ID"] or -1]
                    and (not pick or (onlineish(m) and not onlineish(pick))) then
                    pick, slot = m, k
                end
            end
        end
    end
    if not pick then say("no guildmate with a crafting profession found"); return end
    local skillLine = pick["profession" .. slot .. "ID"]
    local cgi = g("C_GuildInfo") or {}
    local r = API.Pack(cgi.QueryGuildMemberRecipes, pick.guid, skillLine)
    -- Recorded for the measurement only (was a guildmate's book already open?);
    -- the identity check below decides what is read.
    local ts = g("C_TradeSkillUI") or {}
    local before = API.Pack(ts.IsTradeSkillGuildMember)
    Probe.recipeRequest = (Probe.recipeRequest or 0) + 1
    local request = Probe.recipeRequest
    o.memberRecipes = { member = pick.name, guid = pick.guid, skillLine = skillLine, presence = pick.presence,
                        profession = pick["profession" .. slot .. "Name"], rank = pick["profession" .. slot .. "Rank"],
                        query = packData(r), events = {}, request = request,
                        guildViewBefore = before.ok and before[1] == true or nil }
    say("asked for " .. tostring(pick.name) .. "'s " .. tostring(o.memberRecipes.profession)
        .. " recipes; reading them in " .. (SETTLE + 1) .. " s")
    -- Bound to this request: a second /gspy probe recipes makes this timer a no-op.
    C_Timer.After(SETTLE + 1, function() Probe.DumpMemberRecipes(request) end)
end

-- Whether the open trade skill view is provably the book `mr` asked for: a
-- view shown after the request, a guildmate's, ready, of the asked skill
-- line, and named as that member. Returns true, or false and why.
local function isRequestedBook(mr, ts)
    local shown = false
    for _, e in ipairs(mr.events) do
        if e == "TRADE_SKILL_SHOW" or e == "TRADE_SKILL_DATA_SOURCE_CHANGED" then shown = true end
    end
    if not shown then return false, "no trade skill view opened after the request" end
    local gm = API.Pack(ts.IsTradeSkillGuildMember)
    if not (gm.ok and gm[1] == true) then return false, "the open view isn't a guildmate's" end
    local ready = API.Pack(ts.IsTradeSkillReady)
    if not (ready.ok and ready[1] == true) then return false, "the view isn't ready" end
    local base = API.Pack(ts.GetBaseProfessionInfo)
    local id = base.ok and type(base[1]) == "table" and base[1].professionID
    if id ~= mr.skillLine then return false, "the open view is skill line " .. tostring(id) end
    -- The member must be positively identified: an unnamed view could be any
    -- guildmate's book of the same profession. (Whether this client names the
    -- player of a guild-member view is itself what a run will show.)
    local linked = API.Pack(ts.IsTradeSkillLinked)
    local name = linked.ok and linked[2]
    mr.linkedName = name
    if type(name) ~= "string" or name == "" then return false, "the open view doesn't name its member" end
    if name ~= mr.member then return false, "the open view is " .. name .. "'s" end
    return true
end

function Probe.DumpMemberRecipes(request)
    local o = out()
    local mr = o and o.memberRecipes
    if not mr or mr.request ~= request or mr.done then return end
    mr.done = true
    local ts = g("C_TradeSkillUI") or {}
    mr.isGuildMember = packData(API.Pack(ts.IsTradeSkillGuildMember))
    mr.isReady = packData(API.Pack(ts.IsTradeSkillReady))
    local base = API.Pack(ts.GetBaseProfessionInfo)
    mr.baseProfession = (base.ok and type(base[1]) == "table") and scalarsOf(base[1]) or packData(base)
    local ok, why = isRequestedBook(mr, ts)
    if not ok then
        -- Not provably ours: nothing is read as this member's, nothing is closed.
        mr.inconclusive = why
        say(string.format("%s's recipes: inconclusive (%s); the open view was left alone",
            tostring(mr.member), why))
        return
    end
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
    -- The book this request opened, and only that, is closed.
    API.Pack(ts.CloseTradeSkill)
    mr.closed = true
    say(string.format("%s's recipes: %d recipe ids, %d learned (%s)",
        tostring(mr.member), mr.recipeIDs, mr.learned, table.concat(mr.learnedNames, ", ")))
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
        if mr and not mr.done then mr.events[#mr.events + 1] = event end
    end
end)
