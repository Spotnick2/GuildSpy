-- Patterns.lua: guild system messages -> { kind, actor, target, rank }. PURE:
-- no WoW API; the shell passes the client's localized format strings in.
--
-- Built from the client's own ERR_GUILD_* strings, not hardcoded English
-- (measured enUS on 70338: docs/FOREVER-PROBE.md #10). Names have surnames
-- ("Kaleid Sumner"), so every name is captured with a dot pattern, never %S+.
-- Positional placeholders ("%2$s", other locales) are mapped to their slots.

local ADDON = ...
GuildSpy = GuildSpy or {}
local Patterns = {}
GuildSpy.Patterns = Patterns

-- Global string -> kind and what each placeholder holds, in argument order.
Patterns.SOURCES = {
    { global = "ERR_GUILD_JOIN_S",            kind = "JOIN",    args = { "target" } },
    { global = "ERR_GUILD_LEAVE_S",           kind = "LEAVE",   args = { "target" } },
    { global = "ERR_GUILD_REMOVE_SS",         kind = "KICK",    args = { "target", "actor" } },
    { global = "ERR_GUILD_PROMOTE_SSS",       kind = "PROMOTE", args = { "actor", "target", "rank" } },
    { global = "ERR_GUILD_DEMOTE_SSS",        kind = "DEMOTE",  args = { "actor", "target", "rank" } },
    { global = "ERR_GUILD_LEADER_CHANGED_SS", kind = "LEADER",  args = { "actor", "target" } },
}

-- A format string -> an anchored Lua pattern, and the argument slot each
-- capture fills. The last capture is greedy, the others are not: in
-- "%s has promoted %s to %s." the rank may hold spaces, the names can't
-- hold " has promoted ".
function Patterns.Compile(fmt)
    local pattern, order, nextArg = { "^" }, {}, 1
    local i, n = 1, #fmt
    local pieces = {}
    while i <= n do
        local pos, argPos, len
        local a, b, num = fmt:find("^%%(%d)%$s", i)
        if a then pos, argPos, len = a, tonumber(num), b - a + 1 end
        if not pos and fmt:sub(i, i + 1) == "%s" then pos, argPos, len = i, nextArg, 2; nextArg = nextArg + 1 end
        if pos then
            pieces[#pieces + 1] = { capture = argPos }
            i = i + len
        else
            local c = fmt:sub(i, i)
            if c == "%" and fmt:sub(i + 1, i + 1) == "%" then c = "%"; i = i + 1 end
            local last = pieces[#pieces]
            if last and last.text then last.text = last.text .. c else pieces[#pieces + 1] = { text = c } end
            i = i + 1
        end
    end
    local captures = 0
    for _, p in ipairs(pieces) do if p.capture then captures = captures + 1 end end
    local seen = 0
    for _, p in ipairs(pieces) do
        if p.capture then
            seen = seen + 1
            pattern[#pattern + 1] = (seen == captures) and "(.+)" or "(.-)"
            order[#order + 1] = p.capture
        else
            pattern[#pattern + 1] = (p.text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
        end
    end
    pattern[#pattern + 1] = "$"
    return table.concat(pattern), order
end

-- globals: name -> format string (the shell passes _G's ERR_GUILD_* values).
-- Returns a parser, or nil when none of the strings exist.
function Patterns.Build(globals)
    local parsers = {}
    for _, src in ipairs(Patterns.SOURCES) do
        local fmt = globals[src.global]
        if type(fmt) == "string" and fmt:find("%", 1, true) then
            local pattern, order = Patterns.Compile(fmt)
            parsers[#parsers + 1] = { kind = src.kind, args = src.args, pattern = pattern, order = order }
        end
    end
    if #parsers == 0 then return nil end
    return function(msg)
        if type(msg) ~= "string" then return nil end
        -- A player link ("|Hplayer:X|h[X]|h") reads as its name.
        msg = msg:gsub("|Hplayer:[^|]*|h%[(.-)%]|h", "%1")
        for _, p in ipairs(parsers) do
            local caps = { msg:match(p.pattern) }
            if caps[1] then
                local out = { kind = p.kind }
                for c, slot in ipairs(p.order) do
                    local field = p.args[slot]
                    if field then out[field] = caps[c] end
                end
                return out
            end
        end
        return nil
    end
end
