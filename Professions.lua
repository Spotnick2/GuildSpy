-- Professions.lua: who in the guild has which profession (#9). Pure: no
-- client call. Retail's guild profession view, rebuilt from the same data
-- (Blizzard_Communities/CommunitiesMemberList.lua, UpdateProfessionDisplay):
-- each member's profession1ID/Name and profession2ID/Name in C_Club's member
-- info, which Forever serves (docs/FOREVER-PROBE.md 13-17) while it keeps the
-- view itself switched off. No skill levels (C_Club says 1 for all) and no
-- recipes: the server has neither.

GuildSpy = GuildSpy or {}
local Professions = {}
GuildSpy.Professions = Professions

-- Icons by skill line. C_TradeSkillUI.GetTradeSkillTexture, which retail
-- uses, isn't in Forever's API dump; these are the classic icons, which the
-- client ships.
Professions.ICONS = {
    [171] = "Interface\\Icons\\Trade_Alchemy",
    [164] = "Interface\\Icons\\Trade_BlackSmithing",
    [333] = "Interface\\Icons\\Trade_Engraving",
    [202] = "Interface\\Icons\\Trade_Engineering",
    [182] = "Interface\\Icons\\Spell_Nature_NatureTouchGrow",
    [165] = "Interface\\Icons\\Trade_LeatherWorking",
    [186] = "Interface\\Icons\\Trade_Mining",
    [393] = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
    [197] = "Interface\\Icons\\Trade_Tailoring",
    [356] = "Interface\\Icons\\Trade_Fishing",
    [185] = "Interface\\Icons\\INV_Misc_Food_15",
    [129] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
}
Professions.UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- The groups: { { id, name, icon, members = { ... }, online, total } }, by
-- name; in each, online members first, then by name. A member is the roster
-- snapshot's record when GuildSpy has one (by GUID), else what C_Club says.
-- `infos`: C_Club member infos; `gs`: the guild's saved state.
function Professions.Build(infos, gs)
    local roster = gs and type(gs.members) == "table" and gs.members or {}
    local ranks = gs and type(gs.ranks) == "table" and gs.ranks or {}
    local byId, list = {}, {}
    for _, info in ipairs(infos or {}) do
        if type(info) == "table" then
            local m = type(info.guid) == "string" and roster[info.guid]
            -- Someone the roster shows as gone (pending the departure's
            -- confirmation) isn't listed: the roster is the authority.
            if not (m and m.missingSince) then
                local who = {
                    guid = info.guid,
                    name = (m and m.name) or info.name,
                    level = (m and m.level) or info.level,
                    class = m and m.class or nil,
                    rank = m and m.rank,
                    rankName = m and type(m.rank) == "number" and ranks[m.rank + 1] or nil,
                    note = (m and m.note) or info.memberNote,
                    online = (m and m.online) == true,
                    lastSeenAt = m and m.lastSeenAt,
                    zone = info.zone,
                }
                if type(who.name) == "string" and who.name ~= "" then
                    local seen = {}
                    for slot = 1, 2 do
                        local id, name = info["profession" .. slot .. "ID"], info["profession" .. slot .. "Name"]
                        if type(id) == "number" and not seen[id] then
                            seen[id] = true
                            local g = byId[id]
                            if not g then
                                g = { id = id, name = type(name) == "string" and name ~= "" and name or ("#" .. id),
                                      icon = Professions.ICONS[id] or Professions.UNKNOWN_ICON,
                                      members = {}, online = 0, total = 0 }
                                byId[id] = g
                                list[#list + 1] = g
                            end
                            g.members[#g.members + 1] = who
                            g.total = g.total + 1
                            if who.online then g.online = g.online + 1 end
                        end
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    for _, g in ipairs(list) do
        table.sort(g.members, function(a, b)
            if a.online ~= b.online then return a.online end
            return a.name < b.name
        end)
    end
    return list
end

-- The list's elements: a header per profession ({ group, collapsed }), then
-- its members ({ member, group, odd }) when expanded. opts: offline (show
-- offline members), query (by name, plain, case-insensitive: matching
-- members show under their profession, expanded), collapsed ({ [id] = bool },
-- nil: collapsed, as retail starts).
function Professions.Elements(groups, opts)
    opts = opts or {}
    local q = opts.query and opts.query:lower():match("^%s*(.-)%s*$")
    if q == "" then q = nil end
    local collapsed = opts.collapsed or {}
    local els = {}
    for _, g in ipairs(groups or {}) do
        local shown = {}
        for _, m in ipairs(g.members) do
            if (opts.offline or m.online) and (not q or m.name:lower():find(q, 1, true)) then
                shown[#shown + 1] = m
            end
        end
        if not q or #shown > 0 then
            local closed = not q and collapsed[g.id] ~= false
            els[#els + 1] = { group = g, collapsed = closed, shown = #shown }
            if not closed then
                for i, m in ipairs(shown) do els[#els + 1] = { member = m, group = g, odd = i % 2 == 1 } end
            end
        end
    end
    return els
end
