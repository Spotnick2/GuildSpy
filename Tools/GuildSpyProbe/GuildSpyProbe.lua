-- GuildSpyProbe: a ForeverProbe module (/fp gs). Measures what Guild Roster
-- Manager sends on the guild channel on Forever, before deciding #8 (a GRM
-- listener). GRMClassify.lua does the counting; this file wires it to the client.
--
-- Saved across sessions in GuildSpyProbeDB.grm: counts per prefix, channel and
-- tag, per day; up to 3 samples per tag (typed text reduced to field shapes);
-- sender and member-name shapes against the roster; the GRM users heard.
--
-- /fp steps gs grm : state, one GRMUSER "REQ?" on your click, the answers, /reload.
-- Then leave it loaded and play normally: it keeps listening.

local ADDON, NS = ...
local MAX_LOG = 3000
local C = NS.GRMClassify

local Probe = ForeverProbe:Module("GuildSpyProbe", { api = 1, cmd = "gs" })
local function say(msg) Probe:Say(msg) end

local DB          -- GuildSpyProbeDB.grm, bound at ADDON_LOADED

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

-- "First Surname", as CHAT_MSG_ADDON names senders (GuildSpy's Compat.lua:68).
local function me()
    local name, second = UnitName("player")
    if type(name) ~= "string" or name == "" or secret(name) then return nil end
    if name:find(" ") then return name end
    if type(second) == "string" and second ~= "" and not secret(second) then return name .. " " .. second end
    return name
end

-- Roster names as a set, read again after each GUILD_ROSTER_UPDATE.
local roster, rosterDirty, rosterSize = {}, true, 0
local function readRoster()
    if not rosterDirty then return roster end
    rosterDirty = false
    roster, rosterSize = {}, 0
    local ok, n = pcall(GetNumGuildMembers)
    if not ok or type(n) ~= "number" or secret(n) then return roster end
    for i = 1, n do
        local okI, name = pcall(GetGuildRosterInfo, i)
        if okI and type(name) == "string" and not secret(name) and name ~= "" then
            roster[name] = true
            rosterSize = rosterSize + 1
        end
    end
    return roster
end

local function restrictions()
    local ok, v = Probe:Try("C_Secrets.HasSecretRestrictions",
        C_Secrets and C_Secrets.HasSecretRestrictions)
    return ok and v
end

local function grmLoaded()
    local ok, v = Probe:Try("C_AddOns.IsAddOnLoaded",
        C_AddOns and C_AddOns.IsAddOnLoaded, "Guild_Roster_Manager")
    return ok and v
end

-- The state worth a line at login and in the procedure.
local function state()
    local _, build = GetBuildInfo()
    local inGuild = IsInGuild and IsInGuild() or false
    readRoster()
    local s = {
        build = build, at = time(), inGuild = inGuild,
        restrictions = restrictions(), grmLoaded = grmLoaded(), roster = rosterSize,
    }
    DB.state = s
    say(("state: build %s, in guild %s, roster %d names, HasSecretRestrictions %s, GRM loaded here %s")
        :format(Probe.Show(build, true), tostring(inGuild), rosterSize,
            Probe.Show(s.restrictions), Probe.Show(s.grmLoaded)))
    return s
end

local function register()
    for _, p in ipairs(C.PREFIXES) do
        local ok, res = Probe:Try("RegisterAddonMessagePrefix " .. p,
            C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix, p)
        if ok then say("prefix " .. p .. " registered: " .. Probe.Show(res)) end
    end
end

local REG_SINCE = { at = nil, n = 0 }    -- REG/INIT answers since the last ask

local function onMessage(prefix, text, channel, sender)
    if not DB then return end
    if secret(prefix) then return end
    if type(prefix) ~= "string" or not C.IsPrefix(prefix) then return end
    if secret(text) or secret(channel) or secret(sender) then
        DB.secret = DB.secret + 1
        return
    end
    local r = C.Record(DB, { prefix = prefix, text = text, channel = channel, sender = sender },
        { now = time(), day = date("%Y-%m-%d"), roster = readRoster(), me = me() })
    if not r or r.self then return end
    if prefix == "GRMUSER" and (r.tag == "REG" or r.tag == "INIT") then
        if REG_SINCE.at then REG_SINCE.n = REG_SINCE.n + 1 end
        local u = DB.users[sender]
        say(("GRM user heard: version %s, sync %s, %s"):format(
            Probe.Show(u and u.version, true), Probe.Show(u and u.syncEnabled, true),
            C.NameShape(sender) .. "/" .. C.RosterMatch(sender, readRoster())))
    end
    if r.sample then
        say(("sample %s %s on %s: %s"):format(prefix, r.tag, Probe.Show(channel, true), r.sample))
    end
end

-- One GRMUSER "REQ?" on the guild channel: every GRM user answers with its
-- REG line (GRM_Core.lua:3209-3211 in R1.99521). Only on the owner's click.
local function ask()
    if not (IsInGuild and IsInGuild()) then say("ask: not in a guild"); return false end
    REG_SINCE.at, REG_SINCE.n = GetTime(), 0
    local ok, res = Probe:Try("SendAddonMessage GRMUSER REQ?",
        C_ChatInfo and C_ChatInfo.SendAddonMessage, "GRMUSER", "REQ?", "GUILD")
    say("ask: GRMUSER REQ? sent on GUILD: " .. Probe.Show(ok and res))
    DB.asks = (DB.asks or 0) + 1
    return ok, res
end

local function summary()
    for _, line in ipairs(C.Summary(DB)) do say(line) end
    local shapes = {}
    for k, n in pairs(DB.senders) do shapes[#shapes + 1] = k .. "=" .. n end
    for k, n in pairs(DB.senderMatch) do shapes[#shapes + 1] = "roster:" .. k .. "=" .. n end
    table.sort(shapes)
    if #shapes > 0 then say("  senders: " .. table.concat(shapes, " ")) end
    for tag, t in pairs(DB.nameFields) do
        local parts = {}
        for k, n in pairs(t) do parts[#parts + 1] = k .. "=" .. n end
        table.sort(parts)
        say("  member names in " .. tag .. ": " .. table.concat(parts, " "))
    end
    return DB.total
end

Probe:Command("grm", function() summary() end, "GRM messages heard so far, per prefix, channel and tag")
Probe:Command("users", function()
    local n = 0
    for name, u in pairs(DB.users) do
        n = n + 1
        say(("  %s: version %s, patch day %s, sync %s, all ranks %s, heard %d times")
            :format(name, Probe.Show(u.version, true), Probe.Show(u.patchDay, true),
                Probe.Show(u.syncEnabled, true), Probe.Show(u.exportAllRanks, true), u.count or 0))
    end
    say(n .. " GRM users heard")
end, "the GRM users heard, with their version and sync settings")
Probe:Command("samples", function()
    for key, list in pairs(DB.samples) do
        for _, s in ipairs(list) do say(("  %s on %s (%s): %s"):format(key, s.channel, s.sender, s.text)) end
    end
end, "the samples kept, per prefix and tag")
Probe:Command("state", function() state() end, "build, secret restrictions, GRM loaded here, roster size")
Probe:Command("ask", function() ask() end, "send one GRMUSER REQ? on the guild channel: GRM users answer")
Probe:Command("clear", function()
    for k in pairs(DB) do DB[k] = nil end
    C.Init(DB)
    Probe:ClearLog()
    say("GRM data and log cleared")
end, "forget everything recorded")

Probe:Steps("grm", {
    title = "Who in the guild runs GRM (#8)",
    { text = "Reading the state: build, secret restrictions, whether GRM runs here.", auto = true,
      run = function()
          local s = state()
          return s.inGuild, s.restrictions, s.grmLoaded, s.roster
      end,
      check = function() return DB.state and DB.state.inGuild, "in a guild" end },
    { text = "Ask the guild's GRM users to announce themselves. This sends one hidden addon message "
          .. "(GRMUSER REQ?) on the guild channel; GRM answers it with its version line.",
      button = "Ask", run = function() return ask() end },
    { text = "Listening for 15 seconds for their answers.", timeout = 45,
      wait = function()
          if not REG_SINCE.at then return true, "not asked" end
          local left = 15 - (GetTime() - REG_SINCE.at)
          if left <= 0 then return true, REG_SINCE.n end
          return false, ("%d answers, %ds left"):format(REG_SINCE.n, math.ceil(left))
      end },
    { text = "Type /reload (or press Reload now) to write the results to disk.", reload = true },
    { text = "So far.", auto = true, run = function() return summary() end },
    { text = "Done. Leave the probe loaded and play normally for about a week; it keeps "
          .. "listening. /reload before the results are read." },
})

local boot = CreateFrame("Frame")
Probe:RegisterEvents(boot, { "ADDON_LOADED", "PLAYER_LOGIN", "CHAT_MSG_ADDON", "GUILD_ROSTER_UPDATE" })
boot:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        onMessage(...)
    elseif event == "GUILD_ROSTER_UPDATE" then
        rosterDirty = true
    elseif event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        Probe:Ready()
        if type(GuildSpyProbeDB) ~= "table" then GuildSpyProbeDB = {} end
        if type(GuildSpyProbeDB.log) ~= "table" then GuildSpyProbeDB.log = {} end
        if type(GuildSpyProbeDB.grm) ~= "table" then GuildSpyProbeDB.grm = {} end
        Probe:UseLog(GuildSpyProbeDB.log, MAX_LOG)
        DB = C.Init(GuildSpyProbeDB.grm)
        GuildSpyProbeDB.loads = (GuildSpyProbeDB.loads or 0) + 1
        register()
        say(("loaded (%d loads), %d GRM messages so far. /fp gs for the commands, /fp steps gs grm to start")
            :format(GuildSpyProbeDB.loads, DB.total))
    elseif event == "PLAYER_LOGIN" then
        -- The roster and the guild need a moment after login.
        C_Timer.After(10, function()
            Probe:Try("C_GuildInfo.GuildRoster", C_GuildInfo and C_GuildInfo.GuildRoster)
            C_Timer.After(5, state)
        end)
    end
end)

NS._test = { Probe = Probe, onMessage = onMessage, ask = ask }
