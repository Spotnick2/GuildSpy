-- Wire.lua (#37): sync messages as text. Loaded with every global forbidden (pure).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")
local Wire = loadPure(newPureEnv(), "Wire.lua").Wire

local FIELDS = { "uid", "rev", "kind", "name", "to", "from", "approx", "lastStep", "at", "ns" }
local ALLOWED = {}
for _, f in ipairs(FIELDS) do ALLOWED[f] = true end

-- An entry survives a round trip exactly: types, and text with the escaped characters.
local e = { uid = "ab12:7", rev = 3, kind = "NOTE", name = "Ann Lee", from = "50% off\tnow", to = "a|b\nc\r%25",
            approx = false, lastStep = true, at = 1790000000.5, ns = "g:Bo Kay" }
local line = Wire.Entry(e, FIELDS)
check(not line:find("\n", 1, true), "an entry is one line")
local back = Wire.ReadEntry(line, ALLOWED)
for _, k in ipairs(FIELDS) do eq(back[k], e[k], "round trip: " .. k) end
eq(type(back.rev), "number", "...numbers stay numbers")
eq(back.approx, false, "...false stays false (not absent)")

-- Only allowed keys come back; anything malformed refuses the whole entry.
local extra = Wire.ReadEntry(line .. "\tseq=n5\there=b1", ALLOWED)
check(extra and extra.seq == nil and extra.here == nil, "keys outside the list are dropped")
eq(Wire.ReadEntry("uid=xabc", ALLOWED), nil, "an unknown type refuses it")
eq(Wire.ReadEntry("rev=nabc", ALLOWED), nil, "a bad number refuses it")
eq(Wire.ReadEntry("approx=b2", ALLOWED), nil, "a bad boolean refuses it")
eq(Wire.ReadEntry("no equals sign", ALLOWED), nil, "a field without key=value refuses it")

-- A message: kind, header fields (escaped), entry lines.
local msg = Wire.Message("PAGE", { "7", "Parse Partout-Forever", 0, 12, 1 }, { line, line })
local kind, f, lines = Wire.Read(msg)
eq(kind, "PAGE", "the kind")
eq(f[2], "Parse Partout-Forever", "a header field")
eq(f[4], "12", "header fields come back as strings")
eq(#lines, 2, "two entry lines")
eq(Wire.ReadEntry(lines[2], ALLOWED).to, e.to, "an entry line reads back")
local k2, f2 = Wire.Read(Wire.Message("CAP", { "" }))
check(k2 == "CAP" and f2[1] == "", "an empty header field (no guild) survives")
local k3, f3 = Wire.Read(Wire.Message("CAP", { "Odd\tGuild\n-Realm" }))
eq(f3[1], "Odd\tGuild\n-Realm", "a header field with tabs or newlines survives")

-- Not ours: nothing.
eq(Wire.Read("H1|1|Karuzo"), nil, "another format")
eq(Wire.Read("GSA\t2\tCAP\tx"), nil, "another version")
eq(Wire.Read(nil), nil, "not a string")

done("test_wire")
