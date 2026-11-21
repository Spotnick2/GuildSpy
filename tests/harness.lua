-- harness.lua: the addon loader. dofile it after wow_stubs.lua. The
-- assertions (check, eq, done) are WowTestKit's, global.

-- A pure test loads no stub (newPureEnv below); it still takes the kit's
-- assertions, so its done() is the same as every other file's.
if not rawget(_G, "Kit") then dofile("tests/kit.lua") end

TOC = "GuildSpy.toc"

-- Every file line of the TOC, in load order, as written (backslashes).
function tocLines() return Kit.tocLines(TOC) end

-- Lua files listed in the TOC, in load order, as paths from the repo root.
-- `all` includes Libs\ (the vendored libraries), which the tests never
-- load. The embedded LibGlass-1.0 is the TOC's .xml line, never in this list: libGlassScripts() has its files.
function tocFiles(all)
    local files = {}
    for _, file in ipairs(Kit.tocFiles(TOC)) do
        if all or not file:match("^Libs/") then files[#files + 1] = file end
    end
    return files
end

-- The embedded LibGlass-1.0 comes from a checkout, not from Libs\ (gitignored,
-- filled by the packager): $LIBGLASS, else ../LibGlass. No checkout fails the
-- run loudly; a silently skipped library would test nothing (after
-- GlassUnitFrames' harness).
LIBGLASS_XML = "Libs\\LibGlass-1.0\\LibGlass-1.0.xml"
LIBACCOUNTSYNC_XML = "Libs\\LibAccountSync-1.0\\LibAccountSync-1.0.xml"
function libGlassRoot()
    local root = (os.getenv("LIBGLASS") or "../LibGlass"):gsub("\\", "/"):gsub("/$", "")
    local f = io.open(root .. "/LibGlass-1.0.xml", "rb")
    if not f then
        error("LibGlass checkout not found at " .. root .. " (no LibGlass-1.0.xml): clone "
              .. "github.com/Spotnick2/LibGlass there or set LIBGLASS", 0)
    end
    f:close()
    return root
end

-- The Lua files the library's XML loads, as paths, in order: what the client
-- runs for the TOC's XML line. A listed file that is missing fails here.
function libGlassScripts()
    local root = libGlassRoot()
    local f = assert(io.open(root .. "/LibGlass-1.0.xml", "rb"))
    local xml = f:read("*a"):gsub("<!%-%-.-%-%->", "")   -- listed in a comment is not loaded
    f:close()
    local files = {}
    for file in xml:gmatch('<Script%s+file="([^"]+)"') do
        local path = root .. "/" .. file:gsub("\\", "/")
        local src = io.open(path, "rb")
        if not src then error("LibGlass checkout at " .. root .. " is missing " .. file, 0) end
        src:close()
        files[#files + 1] = path
    end
    if #files == 0 then error("LibGlass-1.0.xml at " .. root .. " lists no Script files", 0) end
    return files
end

-- Load the addon the way the client does: every TOC file with (name, ns), the
-- library's XML expanded in place (a fresh LibStub and LibGlass each time, so
-- no instance outlives its session), the vendored Libs\ left out, then
-- ADDON_LOADED. A fresh session each call; opts.db seeds GuildSpyDB, and
-- opts.setup() runs after the reset, before any file (a test's client state).
function loadAddon(opts)
    opts = opts or {}
    GuildSpy, GuildSpyDB = nil, opts.db
    WoW.reset()
    if opts.setup then opts.setup() end
    local ns = {}
    for _, line in ipairs(tocLines()) do
        local files
        if line == LIBGLASS_XML then
            LibStub = nil
            files = libGlassScripts()
        elseif line == LIBACCOUNTSYNC_XML then
            files = {}          -- a scripted fake answers LibStub("LibAccountSync-1.0") (wow_stubs)
        elseif line:match("^Libs\\") then
            files = {}
        elseif line:match("%.lua$") then
            files = { (line:gsub("\\", "/")) }
        else
            error("the harness can't load TOC line " .. line, 0)
        end
        for _, file in ipairs(files) do
            local chunk = assert(loadfile(file))
            chunk("GuildSpy", ns)
        end
        if line == LIBGLASS_XML then WoW.fakeLibs(LibStub) end
    end
    WoW.fire("ADDON_LOADED", "GuildSpy")
end

-- ForeverProbe, the probe host (Tools/GuildSpyProbe's dependency), loaded into
-- this stub environment: $FOREVERPROBE, else ../ForeverProbe, its TOC's files
-- with ("ForeverProbe", {}), then its ADDON_LOADED. GlassChat's loader. It is
-- private and local, so CI sets FOREVERPROBE_OPTIONAL=1 and a probe test exits
-- as SKIPPED there; locally a missing checkout is an error, never a silent skip.
function loadForeverProbe()
    local root = (os.getenv("FOREVERPROBE") or "../ForeverProbe"):gsub("\\", "/"):gsub("/$", "")
    local toc = io.open(root .. "/ForeverProbe.toc", "rb")
    if not toc then
        if os.getenv("FOREVERPROBE_OPTIONAL") == "1" then
            io.write("SKIPPED: ForeverProbe isn't here (private, local only); the probe tests run locally\n")
            os.exit(0)
        end
        error("ForeverProbe checkout not found at " .. root .. ": clone it there or set FOREVERPROBE", 0)
    end
    local files = {}
    for line in toc:read("*a"):gmatch("[^\r\n]+") do
        if line:match("%.lua$") and not line:match("^#") then files[#files + 1] = root .. "/" .. line end
    end
    toc:close()
    for _, file in ipairs(files) do assert(loadfile(file))("ForeverProbe", {}) end
    WoW.fire("ADDON_LOADED", "ForeverProbe")
    return ForeverProbe
end

-- GuildSpyProbe (Tools/GuildSpyProbe) the way the client loads it: a fresh
-- session and a fresh ForeverProbe, then every .lua line of the probe's TOC
-- with ("GuildSpyProbe", ns), then its ADDON_LOADED. opts.db seeds
-- GuildSpyProbeDB; opts.setup() runs after the reset (a test's client state).
-- GuildSpy itself isn't loaded: the probe reads the client, not the addon.
-- Returns the probe's namespace.
PROBE_TOC = "Tools/GuildSpyProbe/GuildSpyProbe.toc"
function loadProbe(opts)
    opts = opts or {}
    ForeverProbe, ForeverProbeDB, GuildSpyProbeDB = nil, nil, opts.db
    WoW.reset()
    if opts.setup then opts.setup() end
    loadForeverProbe()
    local ns = {}
    for _, file in ipairs(Kit.tocFiles(PROBE_TOC)) do
        assert(loadfile("Tools/GuildSpyProbe/" .. file))("GuildSpyProbe", ns)
    end
    WoW.fire("ADDON_LOADED", "GuildSpyProbe")
    return ns
end

-- Pure modules are loaded with every global but a few
-- Lua builtins forbidden, reads AND writes (except the addon's own table):
-- "pure" is then enforced, not claimed. A stray client call, or a missing
-- `local`, fails the suite.
local PURE_ALLOWED = { "math", "string", "table", "type", "setmetatable", "error", "tostring",
                       "tonumber", "next", "ipairs", "pairs", "assert", "select" }
function newPureEnv()
    local env = {}
    for _, k in ipairs(PURE_ALLOWED) do env[k] = _G[k] end
    return setmetatable(env, {
        __index = function(_, k)
            if k == "GuildSpy" then return nil end   -- the file's own `X = X or {}`
            error("a pure file read the global '" .. tostring(k) .. "'", 2)
        end,
        __newindex = function(t, k, v)
            if k ~= "GuildSpy" then error("a pure file wrote the global '" .. tostring(k) .. "'", 2) end
            rawset(t, k, v)
        end,
    })
end

function loadPure(env, file)
    local chunk = assert(loadfile(file))
    setfenv(chunk, env)
    chunk("GuildSpy", {})
    return env.GuildSpy
end
