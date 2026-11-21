-- The manifest, the slash commands, the build check, and the embedded glass material.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

-- WowTestKit's: interface 16001, the version token, every listed .lua file
-- exists, every line is listed once. The XML lines are the .pkgmeta externals
-- (gitignored): libGlassScripts() fails on a LibGlass checkout without its XML.
Kit.checkToc(TOC)

local toc = io.open(TOC):read("*a")
check(toc:find("## SavedVariables: GuildSpyDB", 1, true), "saved variables declared")
-- Glass UI first when it's installed, so its tenant API is there when the guild window attaches (#63).
check(toc:find("## OptionalDeps: GlassUI\r?\n"), "Glass UI an optional dependency")
-- The `wago` job uploads to the project the packaged TOC names (#52).
check(toc:find("## X%-Curse%-Project%-ID: 1741939\r?\n"), "the CurseForge project ID")
check(toc:find("## X%-Wago%-ID: ANz7YQ64\r?\n"), "the Wago project ID")

-- The icon (#97): the logo's eye, one texture for the AddOns list, the
-- compartment, the minimap button and the guild window's side tab.
do
    local icon = toc:match("## IconTexture: ([^\r\n]+)")
    eq(icon, "Interface\\AddOns\\GuildSpy\\Media\\Logo", "the TOC's icon is our logo")
    loadAddon()
    eq(GuildSpy.Minimap.ICON, icon, "...the minimap button uses it")
    eq(GuildSpy.UI.ICON, icon, "...and the guild window's side tab")
    local fh = io.open("Media/Logo.tga", "rb")
    local head = fh and fh:read(18)
    local body = fh and fh:read("*a")
    if fh then fh:close() end
    check(head ~= nil, "Media/Logo.tga exists")
    if head then
        local b = { head:byte(1, 18) }
        eq(b[3], 2, "...an uncompressed true-colour TGA")
        eq(b[13] + b[14] * 256, 256, "...256 wide")
        eq(b[15] + b[16] * 256, 256, "...256 high (a power of two)")
        eq(b[17], 32, "...32 bits a pixel")
        eq(#body >= 256 * 256 * 4, true, "...and every pixel is there")
    end
end

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

local files = tocFiles()
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

-- The guild API probe moved out of the addon, to Tools/GuildSpyProbe (#67):
-- what it saved in GuildSpyDB is dropped, and /gspy has no probe command.
loadAddon({ db = { version = 1, keep = true, probe = { build = "x" }, probeLog = { { e = "PLAYER_LOGIN" } },
                   probeWatch = true } })
eq(GuildSpyDB.probe, nil, "the old probe dump is dropped")
eq(GuildSpyDB.probeLog, nil, "...the old login timeline")
eq(GuildSpyDB.probeWatch, nil, "...and the old watch switch")
eq(GuildSpyDB.keep, true, "...and nothing else")
eq(GuildSpy.Probe, nil, "the addon has no probe of its own")
for _, h in ipairs(GuildSpy.HELP) do check(not h[1]:find("probe", 1, true), "no probe in the help: " .. h[1]) end
WoW.fire("PLAYER_LOGIN")
WoW.fire("GUILD_ROSTER_UPDATE", true)
eq(GuildSpyDB.probeLog, nil, "no login timeline is kept any more")

-- The build check: quiet on the measured build, one line on another.
loadAddon()
WoW.fire("PLAYER_LOGIN")
eq(#WoW.chat, 0, "no build warning on the measured build")
loadAddon({ setup = function() WoW.build = { "1.60.1", "70999", "", 16001 } end })
WoW.fire("PLAYER_LOGIN")
check(WoW.chat[1] and WoW.chat[1]:find("70999", 1, true), "a different build is named at login")

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
