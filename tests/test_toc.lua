-- The manifest, the slash commands, the build check, and the embedded glass material.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local toc = io.open("GuildSpy.toc"):read("*a")
check(toc:find("## Interface: 16001", 1, true), "interface 16001 (1.60.1; 11601 is the transposed-digit bug)")
check(toc:find("## Version: @project-version@", 1, true), "packager version token kept")
check(toc:find("## SavedVariables: GuildSpyDB", 1, true), "saved variables declared")

-- The packager substitutes keywords in EVERY file it ships, Lua included (Priestly #83,
-- Gnomesweeper #75): no shipped Lua file may hold one whole, not even in a comment.
do
    local shipped = tocFiles(true)
    for _, f in ipairs(libGlassScripts()) do shipped[#shipped + 1] = f end
    for _, file in ipairs(shipped) do
        local fh = io.open(file, "rb")
        local src = fh and fh:read("*a") or ""
        if fh then fh:close() end
        local keyword = src:match("(@[%w%-]+@)")
        check(keyword == nil, file .. " holds no packager keyword the release would rewrite: " .. tostring(keyword))
    end
    check(#shipped >= 5, "(every shipped Lua file was read: " .. #shipped .. ")")
end

local files, seen = tocFiles(), {}
for _, f in ipairs(files) do
    check(io.open(f, "r") ~= nil, "TOC file exists: " .. f)
    check(not seen[f], "TOC lists each file once: " .. f)
    seen[f] = true
end
-- Glass.lua calls LibStub("LibGlass-1.0") at file scope: the library loads first.
eq(tocLines()[1], LIBGLASS_XML, "LibGlass-1.0 loads first")
eq(files[1], "Compat.lua", "Compat loads first (after the libraries)")
eq(files[#files], "GuildSpy.lua", "the entry point loads last")

-- Boot: the saved table is made, a damaged one replaced, an existing one kept.
loadAddon()
eq(type(GuildSpyDB), "table", "GuildSpyDB made")
eq(GuildSpyDB.version, 1, "GuildSpyDB versioned")
loadAddon({ db = "garbage" })
eq(type(GuildSpyDB), "table", "a damaged GuildSpyDB is replaced")
loadAddon({ db = { version = 1, keep = true } })
eq(GuildSpyDB.keep, true, "an existing GuildSpyDB is kept")
check(GuildSpy.Glass ~= nil, "the glass instance exists")
for _, cmd in ipairs({ "/guildspy", "/gspy" }) do
    local before = #WoW.chat
    WoW.slash(cmd .. " help")
    check(#WoW.chat > before, cmd .. " help answers")
end

-- The build check: quiet on the measured build, one line on another.
loadAddon()
WoW.fire("PLAYER_LOGIN")
eq(#WoW.chat, 0, "no build warning on the measured build")
loadAddon({ setup = function() WoW.build = { "1.60.1", "70999", "", 16001 } end })
WoW.fire("PLAYER_LOGIN")
check(WoW.chat[1] and WoW.chat[1]:find("70999", 1, true), "a different build is named at login")

-- The event list the stub validates against is checked in; it must be the dump's.
do
    local DUMP = os.getenv("GUILDSPY_API_DUMP") or "C:/Projects/WoW/References/Forever/api/forever-api-1.60.1.70450.md"
    local f = io.open(DUMP, "r")
    if f then
        local inEvents, dumpEvents, n = false, {}, 0
        for line in f:lines() do
            if line:match("^## ") then
                inEvents = line:match("^## Documented events") ~= nil
            elseif inEvents then
                local name = line:match("^([A-Z][A-Z0-9_]+)%s+%(")
                if name then dumpEvents[name] = true; n = n + 1 end
            end
        end
        f:close()
        local missing, extra = {}, {}
        for e in pairs(dumpEvents) do if not WoW.KNOWN_EVENTS[e] then missing[#missing + 1] = e end end
        for e in pairs(WoW.KNOWN_EVENTS) do if not dumpEvents[e] then extra[#extra + 1] = e end end
        eq(#missing, 0, "every dump event is in the fixture: " .. table.concat(missing, ","))
        eq(#extra, 0, "no fixture event is missing from the dump: " .. table.concat(extra, ","))
        check(n > 1000, "the dump's event list was read (" .. n .. ")")
    else
        io.write("  (events fixture check skipped: no API dump at " .. DUMP .. ")\n")
    end
end

-- Glass.MEDIA points into the embedded copy, where the packager puts it.
eq(GuildSpy.Glass.MEDIA, "Interface\\AddOns\\GuildSpy\\Libs\\LibGlass-1.0\\Media\\", "MEDIA is the embedded copy's")

-- No control characters in a text file (but tab, CR, LF): an edit script's "\f"
-- once wrote a form feed into a sibling's CLAUDE.md, twice.
do
    local p = io.popen("git ls-files")
    local listed = p and p:read("*a") or ""
    if p then p:close() end
    for path in listed:gmatch("[^\r\n]+") do
        if path:match("%.lua$") or path:match("%.md$") or path:match("%.toc$") or path:match("%.xml$")
            or path:match("%.yml$") or path:match("%.ps1$") or path == ".pkgmeta" then
            local f = io.open(path, "rb")
            if f then
                local text = f:read("*a")
                f:close()
                local bad = text:find("[%z\1-\8\11\12\14-\31\127]")
                check(not bad, path .. " has no control character (one at byte " .. tostring(bad) .. ")")
            end
        end
    end
end

done("test_toc")
