-- Patterns: system messages -> { kind, actor, target, rank }. Pure.
dofile("tests/harness.lua")
local Patterns = loadPure(newPureEnv(), "Patterns.lua").Patterns

-- The client's strings, as measured on 70338 (docs/FOREVER-PROBE.md #10).
local G = {
    ERR_GUILD_JOIN_S = "%s has joined the guild.",
    ERR_GUILD_LEAVE_S = "%s has left the guild.",
    ERR_GUILD_REMOVE_SS = "%s has been kicked out of the guild by %s.",
    ERR_GUILD_PROMOTE_SSS = "%s has promoted %s to %s.",
    ERR_GUILD_DEMOTE_SSS = "%s has demoted %s to %s.",
    ERR_GUILD_LEADER_CHANGED_SS = "%s has made %s the new Guild Master.",
}
local parse = Patterns.Build(G)

local r = parse("Zekari Tush has joined the guild.")           -- seen live on 70338
eq(r.kind, "JOIN", "join")
eq(r.target, "Zekari Tush", "...the surname kept")
r = parse("Hank Skorpio has left the guild.")
eq(r.kind, "LEAVE", "leave")
eq(r.target, "Hank Skorpio", "...who")
r = parse("Bo Kay has been kicked out of the guild by Enzo Matrix.")
eq(r.kind, "KICK", "kick")
eq(r.target, "Bo Kay", "...who was kicked")
eq(r.actor, "Enzo Matrix", "...by whom")
r = parse("Enzo Matrix has promoted Ann Lee to Mega Turbo GM.")
eq(r.kind, "PROMOTE", "promotion")
eq(r.actor, "Enzo Matrix", "...the officer")
eq(r.target, "Ann Lee", "...the member")
eq(r.rank, "Mega Turbo GM", "...a rank name with spaces")
r = parse("Enzo Matrix has demoted Ann Lee to Initiate.")
eq(r.kind, "DEMOTE", "demotion")
r = parse("Enzo Matrix has made Ann Lee the new Guild Master.")
eq(r.kind, "LEADER", "leader change")
eq(r.target, "Ann Lee", "...the new leader")

-- Not guild messages.
eq(parse("|Hplayer:Hank Skorpio|h[Hank Skorpio]|h has come online."), nil, "online lines aren't guild changes")
eq(parse("Koma Kino is already in a guild."), nil, "an invite failure isn't a join")
eq(parse("You are now Away: AFK"), nil, "other system text")
eq(parse("Zekari Tush has joined the guild. Extra"), nil, "anchored at the end")
eq(parse(nil), nil, "nil is no message")

-- A player link in a message reads as its name.
r = parse("|Hplayer:Zekari Tush|h[Zekari Tush]|h has joined the guild.")
eq(r and r.target, "Zekari Tush", "a linked name")

-- Magic characters in a format are literal, and positional placeholders are mapped.
local pat = Patterns.Compile("%s (100%%) a.b+c %s")
eq(pat, "^(.-) %(100%%%) a%.b%+c (.+)$", "escaped and anchored")
local fr = Patterns.Build({ ERR_GUILD_REMOVE_SS = "%2$s a renvoyé %1$s de la guilde." })
r = fr("Enzo Matrix a renvoyé Bo Kay de la guilde.")
eq(r.target, "Bo Kay", "positional: the first argument is the target wherever it sits")
eq(r.actor, "Enzo Matrix", "...and the second the actor")

eq(Patterns.Build({}), nil, "no strings: no parser")

done("test_patterns")
