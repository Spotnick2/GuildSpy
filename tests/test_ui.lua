-- The log window (#3): the filter, the standalone window, the "new" marker,
-- the digest's link, and the guild window's tab, which must never write a
-- field of Blizzard's frame.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

-- Class art and colours, as the client has them (Blizzard_SharedXML/SharedConstants.lua).
-- Here only: the other tests match chat lines without class colours.
CLASS_ICON_TCOORDS = { WARRIOR = { 0, 0.25, 0, 0.25 }, MAGE = { 0.25, 0.49609375, 0, 0.25 } }
RAID_CLASS_COLORS = { WARRIOR = { colorStr = "ffc69b6d" }, MAGE = { colorStr = "ff3fc7eb" } }

local function member(name, rank, guid)
    return { name = name, rank = rank, level = 30, class = "MAGE", online = true, guid = guid, note = "" }
end
local function newGuild()
    return { name = "Parse Partout", realm = "Forever", myRank = 3,
             ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" },
             members = { member("Fizzle Sprocketwhistle", 3, "Player-1-00000001"),
                         member("Ann Lee", 3, "Player-1-00000002") },
             events = {}, eventNames = true, motd = "hello", canViewOfficerNote = false }
end

-- Blizzard's guild window as far as the tab uses it: the side tabs, the list,
-- and the two methods it hooks. Any write of a field by the addon fails.
local function communitiesFrame()
    local cf = CreateFrame("Frame", "CommunitiesFrame", UIParent)
    cf.CommunitiesList = CreateFrame("Frame", nil, cf)
    for _, key in ipairs({ "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab", "GuildPreferredPlaySettingsTab" }) do
        cf[key] = CreateFrame("CheckButton", nil, cf)
        cf[key]:Hide()
    end
    cf.guildSelected = true
    cf.displayMode = "ROSTER"
    local modeTab = { CHAT = "ChatTab", ROSTER = "RosterTab", GUILD_BENEFITS = "GuildBenefitsTab", GUILD_INFO = "GuildInfoTab" }
    -- As CommunitiesFrameMixin:UpdateCommunitiesTabs: show the guild's tabs,
    -- then check the one for the current mode only.
    function cf:UpdateCommunitiesTabs()
        for _, key in ipairs({ "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab" }) do
            self[key]:SetShown(self.guildSelected or key == "ChatTab" or key == "RosterTab")
            self[key]:SetChecked(false)
        end
        self[modeTab[self.displayMode]]:SetChecked(true)
    end
    -- As SetDisplayMode: returns early on the same mode, else updates the tabs.
    function cf:SetDisplayMode(mode)
        if self.displayMode == mode then return end
        rawset(self, "displayMode", mode)
        self:UpdateCommunitiesTabs()
    end
    -- What a tab click does: RightSideTabMixin checks it, then SetDisplayMode.
    function cf:clickTab(key, mode) self[key]:SetChecked(true); self:SetDisplayMode(mode) end
    local mt = getmetatable(cf)
    setmetatable(cf, { __index = mt.__index, __newindex = function(_, k)
        error("the addon wrote CommunitiesFrame." .. tostring(k), 2)
    end })
    return cf
end

local G = newGuild()
loadAddon({ setup = function() WoW.guild = G end })
WoW.fire("PLAYER_LOGIN")
WoW.fire("GUILD_ROSTER_UPDATE", false)
for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(25)
local gs = GuildSpyDB.guilds["Parse Partout-Forever"]
check(gs and gs.observedAt, "baselined")

local Log, UI, T = GuildSpy.Log, GuildSpy.UI, GuildSpy._test.UI
local now = time()
local function add(ev) return Log.Add(GuildSpyDB, gs, ev, now) end
add({ kind = "JOIN", name = "Bo Kay", guid = "Player-1-00000003" })
add({ kind = "PROMOTE", name = "Bo Kay", guid = "Player-1-00000003", actor = "Enzo Matrix", from = "Initiate", to = "Member" })
add({ kind = "ONOTE", name = "Ann Lee", guid = "Player-1-00000002", from = "", to = "main tank" })
add({ kind = "LEVEL", name = "Ann Lee", guid = "Player-1-00000002", class = "MAGE", from = 29, to = 30 })

-- The filter: newest first, by category, by text, officer notes only for those who may read them.
local rows = Log.Filter(gs, {}, now)
eq(#rows, 3, "all but the officer note for a non-officer")
eq(rows[1].kind, "LEVEL", "newest first")
eq(#Log.Filter(gs, { canViewOfficer = true }, now), 4, "an officer sees the officer note")
eq(#Log.Filter(gs, { category = "ranks" }, now), 1, "the Ranks pill")
eq(#Log.Filter(gs, { category = "notes" }, now), 0, "...Notes for a non-officer: none")
eq(#Log.Filter(gs, { query = "  enzo " }, now), 1, "search finds the officer, any case, trimmed")
eq(#Log.Filter(gs, { query = "bo kay" }, now), 2, "...and a member's every entry")
eq(#Log.Filter(gs, { query = "main tank" }, now), 0, "...never an officer note it can't show")
eq(#Log.Filter(gs, { query = "|c" }, now), 0, "colour codes aren't searched")

-- /gspy log opens the window on the current guild's log.
WoW.chat = {}
WoW.slash("/gspy log")
local win = T.window()
check(win and win:IsShown(), "/gspy log opens the window")
local panel = T.panel()
eq(#panel.rows, 3, "...listing what this character may see")
eq(panel.box._dataProvider:GetSize(), 4, "...handed to the scroll box under a \"New\" heading")
check(not panel.empty:IsShown(), "...no empty text")
local found = false
for _, name in ipairs(UISpecialFrames) do if name == "GuildSpyLogWindow" then found = true end end
check(found, "Escape closes it")
eq(#WoW.chat, 0, "...and nothing printed")

-- Rows: the initializer draws an entry, with the "new" marker past the last look.
local view = panel.box._view
local function draw(row, e) view.initializer(row, { entry = e }) end
local row = CreateFrame("Button", nil, panel)
draw(row, panel.rows[1])
eq(Log.Plain(row.text:GetText()), "Ann Lee reached level 30", "a row shows the entry")
check(row.text:GetText():find("|cff3fc7ebAnn Lee|r", 1, true), "...the name in its class colour")
check(row.icon:IsShown() and row.icon._texCoord[1] == 0.25, "...and its class icon")
check(row.mark:IsShown(), "...marked new: never looked at")
row._scripts.OnEnter(row)
check(GameTooltip._text and GameTooltip._lines[1]:find("reached level 30", 1, true), "its tooltip has the whole line")

-- Closing makes it seen; the next opening marks nothing old as new.
win:Hide()
eq(gs.viewedSeq, rows[1].seq, "closing records the last entry seen")
local onote = gs.log[3]
check(onote.kind == "ONOTE" and gs.viewedSeq > onote.seq, "(the officer note is below it)")
add({ kind = "LEAVE", name = "Bo Kay", guid = "Player-1-00000003", how = "quit" })
WoW.slash("/gspy log")
eq(#panel.rows, 4, "a new entry shows")
draw(row, panel.rows[1])
check(row.mark:IsShown(), "...marked new")
draw(row, panel.rows[2])
check(not row.mark:IsShown(), "an entry seen before isn't")

-- A pill narrows the list; the search box too.
panel.pills[2]._scripts.OnClick(panel.pills[2])          -- Members
eq(#panel.rows, 2, "the Members pill: the join and the leave")
panel.search._text = "zzz"
panel.search._scripts.OnTextChanged(panel.search)
check(panel.empty:IsShown() and panel.empty:GetText() == "No activity matches your search.", "no match says so")
panel.search._text = ""
panel.search._scripts.OnTextChanged(panel.search)
panel.pills[1]._scripts.OnClick(panel.pills[1])          -- All

-- New entries redraw an open window.
G.members[2].level = 31
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
eq(#panel.rows, 5, "a level-up while open shows at once")

-- Officer-note permission lost while the window is open (#18 review).
WoW.guild.canViewOfficerNote = true
win:Hide(); WoW.slash("/gspy log")
local hasOnote = function()
    for _, e in ipairs(panel.rows) do if e.kind == "ONOTE" then return e end end
end
local on = hasOnote()
check(on, "an officer sees the officer note in the window")
local onRow = CreateFrame("Button", nil, panel)
draw(onRow, on)
onRow._scripts.OnEnter(onRow)
check(GameTooltip:IsShown(), "...and its tooltip")
-- Each way the permission can go, without a roster update (follow-up review),
-- and by a scan with no change.
local revokers = {
    { "a rank update", function() WoW.fire("GUILD_RANKS_UPDATE") end },
    { "the player's rank update", function() WoW.fire("GUILD_RANKS_UPDATE_ACTIVE_PLAYER") end },
    { "a scan with no change", function() WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3) end },
}
for _, r in ipairs(revokers) do
    WoW.guild.canViewOfficerNote = true
    UI.Refresh()
    draw(onRow, hasOnote())
    onRow._scripts.OnEnter(onRow)
    WoW.guild.canViewOfficerNote = false
    r[2]()
    check(not hasOnote(), "permission lost, " .. r[1] .. ": the officer note goes from the list")
    check(not GameTooltip:IsShown(), "...and the tooltip showing it goes")
end
onRow._scripts.OnEnter(onRow)
check(not GameTooltip:IsShown(), "a stale row's tooltip never shows it")

-- The summary's tooltip counts a new officer note; it goes with the permission too (#22 review).
local function tipHas(word)
    for _, l in ipairs(GameTooltip._lines or {}) do if l:find(word, 1, true) then return true end end
end
add({ kind = "ONOTE", name = "Ann Lee", guid = "Player-1-00000002", from = "main tank", to = "off tank" })
for _, r in ipairs(revokers) do
    WoW.guild.canViewOfficerNote = true
    UI.Refresh()
    panel.summaryHit._scripts.OnEnter(panel.summaryHit)
    check(GameTooltip:IsShown() and tipHas("note edit"), "an officer's summary tooltip counts the new officer note")
    WoW.guild.canViewOfficerNote = false
    r[2]()
    check(not GameTooltip:IsShown(), "permission lost, " .. r[1] .. ": the summary tooltip goes")
end
panel.summaryHit._scripts.OnEnter(panel.summaryHit)
check(not tipHas("note edit"), "hovered again, it no longer counts the officer note")

-- #25: a row's tooltip has the member's notes as they are now.
do
    local R = { members = { ["g-a"] = { name = "Ann", note = "main tank", onote = "raid lead" },
                            ["g-b"] = { name = "Bo", note = "", onote = "" },
                            ["g-c"] = { name = "Cy", note = "alt of Ann" } },
                formers = { ["g-d"] = { name = "Dee" } } }
    local function labels(e, can)
        local out = {}
        for _, n in ipairs(Log.MemberNotes(R, e, can)) do out[#out + 1] = n.label .. "=" .. n.text end
        return table.concat(out, ";")
    end
    eq(labels({ guid = "g-a" }, true), "Note=main tank;Officer note=raid lead", "an officer: both notes")
    eq(labels({ guid = "g-a" }, false), "Note=main tank", "not an officer: the public note only")
    eq(labels({ guid = "g-b" }, true), "", "empty notes are left out")
    eq(labels({ guid = "g-c" }, true), "Note=alt of Ann", "an officer note never read: nothing, not '(none)'")
    eq(labels({ guid = "g-d" }, true), "", "a former member: no notes (none are kept)")
    eq(labels({ kind = "MOTD", to = "hi" }, true), "", "a guild-wide entry: none")
    eq(labels({ guid = "g-a" }, nil), "Note=main tank", "permission unknown counts as no")
end
-- In the window: Ann's notes from the roster, through a scan.
G.members[2].note, G.members[2].onote = "main tank", "raid lead"
WoW.guild.canViewOfficerNote = true
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(3)
local annRow
for _, e in ipairs(panel.rows) do
    if e.guid == "Player-1-00000002" and e.kind == "LEVEL" then annRow = e; break end
end
check(annRow, "(Ann's level-up is in the list)")
local nr = CreateFrame("Button", nil, panel)
draw(nr, annRow)
nr._scripts.OnEnter(nr)
check(tipHas("Note: |cffff99ffmain tank|r"), "an officer's row tooltip: the public note")
check(tipHas("Officer note: |cffff18edraid lead|r"), "...and the officer note")
WoW.guild.canViewOfficerNote = false
WoW.fire("GUILD_RANKS_UPDATE_ACTIVE_PLAYER")
check(not GameTooltip:IsShown(), "permission lost: the open tooltip goes")
draw(nr, annRow)
nr._scripts.OnEnter(nr)
check(tipHas("main tank") and not tipHas("raid lead"), "hovered again: the public note, no officer note")

-- Leaving the guild with the window open: no old rows, no old boundary.
local keep = WoW.guild
WoW.guild = nil
WoW.fire("PLAYER_GUILD_UPDATE")
eq(#panel.rows, 0, "out of the guild: the old guild's rows go")
check(panel.empty:GetText() == "No guild seen yet.", "...and it says so")
WoW.guild = keep
WoW.fire("PLAYER_GUILD_UPDATE")
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(25)
check(#panel.rows > 0, "back in: its rows return")
win:Hide()

-- /gspy log <n> still prints.
WoW.chat = {}
WoW.slash("/gspy log 2")
eq(#WoW.chat, 2, "/gspy log 2 prints two lines")

-- The digest's [open log] link.
win:Hide()
check(Log.Digest({ log = { { seq = 1, kind = "JOIN", name = "X", at = now } } }, false, now)[1]:find("|Haddon:guildspy:log|h", 1, true),
    "the digest's summary carries the link")
EventRegistry:TriggerEvent("SetItemRef", "item:1234", "[thing]", "LeftButton")
check(not win:IsShown(), "another link does nothing")
EventRegistry:TriggerEvent("SetItemRef", "addon:guildspy:log", "[open log]", "LeftButton")
check(win:IsShown(), "the link opens the window")
win:Hide()

------------------------------------------------------------
-- #19: the summary, times, scopes, row text, sections, Mark all as read
------------------------------------------------------------

-- The summary counts entries past the boundary, levels as "level changes".
local sg = { log = {} }
local sdb = { nextSeq = 1 }
for _, ev in ipairs({
    { kind = "JOIN", name = "A" }, { kind = "REJOIN", name = "B" }, { kind = "LEAVE", name = "C" },
    { kind = "PROMOTE", name = "D", to = "Member" }, { kind = "DEMOTE", name = "E", to = "Initiate" },
    { kind = "LEVEL", name = "F", from = 10, to = 13 }, { kind = "LEVEL", name = "G", from = 20, to = 21 },
    { kind = "ONOTE", name = "H", to = "alt" }, { kind = "NOTE", name = "I", to = "hi" },
}) do Log.Add(sdb, sg, ev, now) end
eq(Log.Plain(Log.NewSummary(sg, 0, false)),
    "New: 2 joined  \194\183  1 left  \194\183  2 rank changes  \194\183  1 note edit  \194\183  2 level changes",
    "summary: entries per group; a three-level entry counts once; no officer note for a non-officer")
check(Log.Plain(Log.NewSummary(sg, 0, true)):find("2 note edits", 1, true), "...an officer counts it")
eq(Log.Plain(Log.NewSummary(sg, 5, false)), "New: 1 note edit  \194\183  2 level changes", "...only past the boundary")
eq(Log.Plain(Log.NewSummary(sg, 9, true)), "No new activity", "...nothing past it")
eq(sg.log[1].after, nil, "(no interval given: no 'after')")
eq(Log.Add(sdb, sg, { kind = "JOIN", name = "J", lo = now - 99 }, now).after, now - 99, "an entry keeps the previous scan's time")

-- Times: relative, "about" when a guess, provenance in words.
local base = os.time({ year = 2026, month = 10, day = 12, hour = 10, min = 0, sec = 0 })
local function at(h, extra)
    local e = { at = base - h * 3600 }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end
eq(Log.When(at(0), base), "just now", "under a minute: just now")
eq(Log.When({ at = base - 300 }, base), "5m ago", "minutes")
eq(Log.When(at(3), base), "3h ago", "hours")
eq(Log.When(at(3, { approx = true }), base), "about 3h ago", "the event log's hour: about")
eq(Log.When(at(3, { approx = false, after = base - 99999 }), base), "3h ago", "seen live: exact, whatever the gap")
eq(Log.When(at(3, { after = base - 4 * 3600 }), base), "about 3h ago", "a scan long after the last one: about")
eq(Log.When(at(30, { approx = true }), base), "Yesterday", "a day-level time needs no 'about'")
eq(Log.When(at(3, { after = base - 3 * 3600 - 60 }), base), "3h ago", "a scan a minute after the last one: exact enough")
eq(Log.When(at(25), base), "Yesterday", "yesterday (over 24h, after yesterday's midnight)")
eq(Log.When({ at = os.time({ year = 2026, month = 10, day = 3, hour = 12 }) }, base), "Oct 3", "older: a date")
check(Log.Provenance(at(3, { approx = false })):find("live", 1, true), "provenance: live")
check(Log.Provenance(at(3, { approx = true })):find("event log", 1, true), "provenance: the event log")
check(Log.Provenance(at(3, { after = base - 9 * 3600 })):find("between", 1, true), "provenance: a scan's interval")
check(Log.Provenance(at(3)):find("scan noticed", 1, true), "provenance: a scan")

-- Time scopes: local midnight for Today.
local midnight = os.time({ year = 2026, month = 10, day = 12, hour = 0, min = 0, sec = 0 })
eq(Log.ScopeSince("today", base), midnight, "Today starts at local midnight")
eq(Log.ScopeSince("week", base), base - 7 * 86400, "Last 7 days")
-- Clock changes (#22 review): midnight is the calendar's, on the change day and the day after.
-- The US and EU 2026 dates; they bite where the machine's zone has daylight saving.
for _, d in ipairs({ { 3, 8 }, { 3, 9 }, { 11, 1 }, { 11, 2 }, { 3, 29 }, { 3, 30 }, { 10, 25 }, { 10, 26 } }) do
    local noon = os.time({ year = 2026, month = d[1], day = d[2], hour = 12 })
    local m = os.date("*t", Log.ScopeSince("today", noon))
    check(m.hour == 0 and m.min == 0 and m.day == d[2], "Today starts at 00:00 on " .. d[1] .. "-" .. d[2])
    local y = os.date("*t", Log.Midnight(noon, 1))
    check(y.hour == 0 and y.day == os.date("*t", noon - 86400).day, "...and yesterday at its own 00:00")
    local justIn = os.time({ year = 2026, month = d[1], day = d[2] - 1, hour = 0, min = 30 })
    local justOut = os.time({ year = 2026, month = d[1], day = d[2] - 2, hour = 23, min = 30 })
    eq(Log.When({ at = justIn }, noon + 12 * 3600 - 60), "Yesterday", "...00:30 the day before is Yesterday")
    check(Log.When({ at = justOut }, noon + 12 * 3600 - 60) ~= "Yesterday", "...23:30 two days before isn't")
end
eq(Log.ScopeSince("all", base), nil, "All history: no bound")
local tg = { log = { { seq = 1, kind = "JOIN", name = "Late", at = midnight - 1 },
                     { seq = 2, kind = "JOIN", name = "Early", at = midnight, approx = true } } }
local today = Log.Filter(tg, { since = Log.ScopeSince("today", base) }, base)
eq(#today, 1, "Today: one second before midnight is out")
eq(today[1].name, "Early", "...midnight itself (an approximate time too) is in")

-- Row text: the actor, "last step by" when the evidence covers only the last step.
local classOf = function(name) return name == "Enzo Matrix" and "WARRIOR" or nil end
local promo = { kind = "PROMOTE", name = "Bo Kay", to = "Raider", from = "Initiate", actor = "Enzo Matrix" }
eq(Log.Plain(Log.Row(promo, now, classOf)), "Bo Kay promoted to Raider by Enzo Matrix", "row: promoted to, by")
check(Log.Row(promo, now, classOf):find("|cffc69b6dEnzo Matrix|r", 1, true), "...the actor in their class colour")
promo.lastStep = true
eq(Log.Plain(Log.Row(promo, now, classOf)), "Bo Kay promoted to Raider (last step by Enzo Matrix)",
    "...never a plain 'by' when only the last step is known")
eq(Log.Plain(Log.Row({ kind = "LEVEL", name = "Saint Anger", from = 16, to = 19 }, now)),
    "Saint Anger leveled from 16 to 19", "row: several levels")
check(Log.Row({ kind = "JOIN", name = "No Class" }, now):find("|cffffffffNo Class|r", 1, true),
    "row: no class, a plain white name")
eq(Log.Plain(Log.Row({ kind = "LEAVE", name = "Bo Kay", how = "kick", actor = "Enzo Matrix", level = 20 }, now)),
    "Bo Kay was kicked by Enzo Matrix (level 20)", "row: a kick and who did it")

-- The panel: sections, stripes, summary, footer, Mark all as read.
gs.viewedSeq = nil
for i = 1, 30 do add({ kind = "LEVEL", name = "Ann Lee", guid = "Player-1-00000002", from = 30 + i, to = 31 + i }) end
local top = gs.log[#gs.log].seq
gs.viewedSeq = top - 3
WoW.slash("/gspy log")
local els = panel.elements
eq(els[1].header, "New", "something new: a New heading first")
eq(els[5].header, "Earlier", "...an Earlier heading after the three new entries")
check(els[2].odd and not els[3].odd and els[4].odd, "...alternate rows striped")
check(Log.Plain(panel.summary:GetText()) == "New: 3 level changes", "the summary counts the new entries")
check(panel.markRead:IsEnabled(), "Mark all as read: enabled with something new")
eq(panel.footer:GetText(), "Updated " .. Log.Relative(gs.observedAt, time()), "the footer: the last complete scan")
draw(row, els[2].entry)
row._scripts.OnEnter(row)
eq(GameTooltip._lines[2], Log.Provenance(els[2].entry), "the tooltip says what the time means")
row._scripts.OnLeave(row)
view.initializer(row, els[1])
check(row.header:IsShown() and not row.text:IsShown() and not row.mark:IsShown(), "a heading row shows only its heading")

-- Scrolled down, then marked read: the rows on screen stay put.
panel.pills[5]._scripts.OnClick(panel.pills[5])          -- Levels
panel.search._text = "ann"
panel.search._scripts.OnTextChanged(panel.search)
els = panel.elements
panel.box._offset = 10 * UI.ROW_HEIGHT + 5
local first = els[11].entry
local shownSeq, listed = gs.shownSeq, #panel.rows
check(listed > 30 and listed < #gs.log, "(Levels and 'ann': a narrowed list)")
UI.MarkAllRead()
eq(gs.viewedSeq, top, "Mark all as read: viewedSeq to the newest entry")
eq(gs.shownSeq, shownSeq, "...the digest's boundary untouched")
eq(#panel.rows, listed, "...the filters and the search kept")
for _, el in ipairs(panel.elements) do check(not el.header, "...no headings left") end
local idx
for i, el in ipairs(panel.elements) do if el.entry == first then idx = i end end
eq((idx - 1) * UI.ROW_HEIGHT - panel.box._offset, -5, "...the first row on screen stays where it was")
eq(Log.Plain(panel.summary:GetText()), "No new activity", "...the summary clears")
check(not panel.markRead:IsEnabled(), "...and the button is disabled")
draw(row, panel.rows[1])
check(not row.mark:IsShown(), "...no dots")
panel.search._text = ""
panel.search._scripts.OnTextChanged(panel.search)
panel.pills[1]._scripts.OnClick(panel.pills[1])

-- A catch-up with many kinds new (#22 review): the line fits, and still counts everything.
local before = gs.viewedSeq
for _, ev in ipairs({
    { kind = "JOIN", name = "Kay One" }, { kind = "LEAVE", name = "Kay Two", how = "quit" },
    { kind = "PROMOTE", name = "Kay Three", to = "Member" }, { kind = "NAME", name = "Kay Four", from = "Kay Old" },
    { kind = "RETURN", name = "Kay Five", days = 20 }, { kind = "NOTE", name = "Kay Six", to = "x" },
    { kind = "MOTD", to = "raid tonight" },
}) do add(ev) end
win:Hide(); gs.viewedSeq = before; WoW.slash("/gspy log")
panel.summary._width = 300
UI.Refresh()
local line = Log.Plain(panel.summary:GetText())
check(#line * 7 <= 300, "a long summary is cut to fit: " .. line)
local more = tonumber(line:match("%+(%d+) more$"))
check(more, "...ending in +N more")
local total, shown = 0, 0
for _, c in ipairs(Log.NewCounts(gs, before, false)) do total = total + c.n end
for n in line:gsub("%+%d+ more$", ""):gmatch("(%d+) %a") do shown = shown + tonumber(n) end
eq(shown + more, total, "...and the shown counts plus N are every new entry")
panel.summaryHit._scripts.OnEnter(panel.summaryHit)
eq(#GameTooltip._lines, 1 + #Log.NewCounts(gs, before, false), "its tooltip: every tab, then every group")
check(GameTooltip._lines[1]:find("every tab", 1, true), "...saying it counts every tab")
panel.summaryHit._scripts.OnLeave(panel.summaryHit)
panel.summary._width = 0
UI.MarkAllRead()

-- Ordering: by when it happened inside a section, whatever the seq.
local recent = add({ kind = "JOIN", name = "Night Owl", at = now - 60 })
local older = add({ kind = "JOIN", name = "Early Bird", at = now - 7200 })   -- recorded later, happened earlier
UI.MarkAllRead()
local posRecent, posOlder
for i, e in ipairs(panel.rows) do
    if e == recent then posRecent = i elseif e == older then posOlder = i end
end
check(older.seq > recent.seq and posRecent < posOlder, "a later seq with an older time sorts below a newer time")

-- Empty lists say why, in the terms of what's selected.
local emptyGs = { log = { { seq = 1, kind = "JOIN", name = "Solo", at = now - 90 * 86400 } } }
local keepCurrent = GuildSpy.Scanner.Current
GuildSpy.Scanner.Current = function() return emptyGs end
UI.Refresh()
panel.pills[4]._scripts.OnClick(panel.pills[4])          -- Notes
eq(panel.empty:GetText(), "No note changes recorded yet.", "Notes, empty: says so")
panel.pills[6]._scripts.OnClick(panel.pills[6])          -- MOTD
eq(panel.empty:GetText(), "No message-of-the-day changes recorded yet.", "MOTD, empty: says so")
UI.SetScope("week")
eq(panel.empty:GetText(), "No message-of-the-day changes in this time range.", "...in a time range")
panel.pills[1]._scripts.OnClick(panel.pills[1])
eq(panel.empty:GetText(), "No activity in this time range.", "All, in a time range: says so")
UI.SetScope("all")
GuildSpy.Scanner.Current = keepCurrent
UI.Refresh()

-- The time-scope dropdown: its radios, and Today.
local radios = {}
panel.scope._menu(panel.scope, { CreateRadio = function(_, label, isSel, setSel)
    radios[#radios + 1] = { label = label, isSel = isSel, setSel = setSel }
end })
eq(#radios, 4, "the dropdown lists four scopes")
check(radios[1].label == "All history" and radios[1].isSel(), "...All history selected")
local all = #panel.rows
add({ kind = "JOIN", name = "Old Timer", guid = "Player-1-00000009", at = now - 40 * 86400 })
UI.Refresh()
eq(#panel.rows, all + 1, "(an entry 40 days old shows in All history)")
radios[4].setSel()                                          -- Last 30 days
check(radios[4].isSel() and not radios[1].isSel(), "Last 30 days selected")
eq(#panel.rows, all, "...the old entry is out")
radios[1].setSel()
win:Hide()

-- #23: filter by rank, the member's rank now.
do
    local R = { ranks = { "Guild Master", "Raid A", "Raid B", "Member" },
                members = { ["g-a"] = { name = "Ann", rank = 1 }, ["g-b"] = { name = "Bo", rank = 2 } },
                formers = { ["g-c"] = { name = "Cy", rankName = "Raid A" } } }
    local function e(t) return t end
    local level = e({ kind = "LEVEL", guid = "g-a", from = 29, to = 30 })
    check(Log.InRank(level, R, "Raid A"), "a member's entry under the rank they hold now")
    check(not Log.InRank(level, R, "Raid B"), "...not under another")
    local cyNote = e({ kind = "NOTE", guid = "g-c", to = "x" })
    check(Log.InRank(cyNote, R, "Raid A"), "a former member's entry under the rank they left with")
    local leave = e({ kind = "LEAVE", guid = "g-d", from = "Raid B" })
    check(Log.InRank(leave, R, "Raid B"), "a departure under the rank it left from, even once the former is pruned")
    local moved = e({ kind = "PROMOTE", guid = "g-b", from = "Raid A", to = "Raid B" })
    check(Log.InRank(moved, R, "Raid A") and Log.InRank(moved, R, "Raid B"),
        "a move between teams under both: leaving one, joining the other")
    check(not Log.InRank(moved, R, "Member"), "...and not under an unrelated rank")
    check(not Log.InRank(e({ kind = "MOTD", to = "hi" }), R, "Raid A"), "the MOTD under no rank")
    check(not Log.InRank(e({ kind = "RANKS", to = "Raid A" }), R, "Raid A"), "a rank-structure change under no rank")
    local renamed = e({ kind = "PROMOTE", guid = "g-x", from = "Raiders", to = "Old Name" })
    check(not Log.InRank(renamed, R, "Raid A"), "an old rank name doesn't match a renamed rank (by design)")
    check(not Log.InRank(e({ kind = "LEVEL", guid = "g-z" }), R, "Raid A"), "an unknown member under no rank")
    check(not Log.InRank(level, { members = R.members }, "Raid A"), "no rank list: no match, no error")
    local all = Log.Filter({ ranks = R.ranks, members = R.members, formers = R.formers,
                             log = { { seq = 1, at = now, kind = "JOIN", guid = "g-a", name = "Ann" },
                                     { seq = 2, at = now, kind = "LEVEL", guid = "g-b", name = "Bo", from = 9, to = 10 },
                                     { seq = 3, at = now, kind = "MOTD", to = "hi" },
                                     { seq = 4, at = now, kind = "LEVEL", guid = "g-a", name = "Ann", from = 10, to = 11 } } },
                           { rank = "Raid A", category = "levels" }, now)
    eq(#all, 1, "the rank combines with a tab")
    eq(all[1].seq, 4, "...Ann's level-up only")
end

-- The rank dropdown: All ranks, then the guild's ranks; it narrows the list.
win:Show()
local rradios = {}
panel.rank._menu(panel.rank, { CreateRadio = function(_, label, isSel, setSel)
    rradios[#rradios + 1] = { label = label, isSel = isSel, setSel = setSel }
end })
eq(#rradios, 1 + #gs.ranks, "the rank dropdown lists All ranks and every rank")
check(rradios[1].label == "All ranks" and rradios[1].isSel(), "...All ranks selected")
eq(rradios[2].label, gs.ranks[1], "...then the ranks in order")
local everything = #panel.rows
rradios[5].setSel()                                          -- Member: Ann's and Fizzle's rank
check(rradios[5].isSel() and T.rank() == "Member", "a rank selected")
check(#panel.rows > 0 and #panel.rows < everything, "...the list narrows to it")
for _, r in ipairs(panel.rows) do check(r.kind ~= "MOTD", "...without guild-wide entries") end
rradios[3].setSel()                                          -- Officer: nobody
check(panel.empty:IsShown() and panel.empty:GetText() == "No activity for Officer recorded yet.", "an empty rank says so")
panel.pills[5]._scripts.OnClick(panel.pills[5])              -- Levels
eq(panel.empty:GetText(), "No level changes for Officer recorded yet.", "...with the tab's words")
panel.pills[1]._scripts.OnClick(panel.pills[1])
local keepRanks = gs.ranks
gs.ranks = { "Guild Master", "Lieutenant", "Veteran", "Member", "Recruit" }
UI.Refresh()
eq(T.rank(), nil, "a rank the guild no longer has lets go")
eq(#panel.rows, everything, "...and the list shows every rank again")
gs.ranks = keepRanks
UI.Refresh()
win:Hide()

-- The guild window: Blizzard_Communities loads on demand.
local cf = communitiesFrame()
WoW.fire("ADDON_LOADED", "Blizzard_Communities")
local tab = UI.tab
check(tab and tab:GetParent() == cf, "the tab is attached when the guild window loads")
-- Every field of Blizzard's frame as it is now (after the hooks, which are the
-- client's own writes): the addon must change none (the guard above only sees new ones).
local before = {}
for k, v in pairs(cf) do if k:sub(1, 1) ~= "_" and k ~= "displayMode" then before[k] = v end end
check(not tab:IsShown(), "...hidden until Blizzard lays its tabs out")
cf:UpdateCommunitiesTabs()
check(tab:IsShown(), "shown under the guild's tabs")
local p = tab._points[1]
check(p and p[2] == cf.GuildInfoTab, "...anchored below the Info tab")
cf.GuildPreferredPlaySettingsTab:Show()
cf:UpdateCommunitiesTabs()
check(tab._points[1][2] == cf.GuildPreferredPlaySettingsTab, "...or below the play settings tab when it shows")
cf.GuildPreferredPlaySettingsTab:Hide()

-- Clicking it: the panel over the content, Blizzard's tabs unchecked, the window closed.
WoW.slash("/gspy log")
check(win:IsShown(), "(the standalone window is open)")
tab._scripts.OnClick(tab)
check(UI.guildHost:IsShown(), "the tab shows the panel in the guild window")
check(panel:GetParent() == UI.guildHost, "...the same panel, moved there")
check(not win:IsShown(), "...the standalone window closed")
check(tab:GetChecked() and not cf.RosterTab:GetChecked(), "...ours checked, Blizzard's not")
eq(#panel.rows, #Log.Filter(gs, {}, time()), "...listing the log")
WoW.slash("/gspy log")
check(not win:IsShown(), "/gspy log leaves it in the guild window")

WoW.advance(0)
check(UI.guildHost:GetFrameStrata() == "HIGH", "the panel sits a strata above the guild window (MEDIUM)")
eq(UI.guildHost.bg._color[4], 1, "the panel's background is fully opaque (nothing under it shows through)")

-- The current Blizzard tab clicked again (SetDisplayMode returns early): our panel goes away.
cf:clickTab("RosterTab", "ROSTER")
WoW.advance(0)
check(not UI.guildHost:IsShown(), "a Blizzard tab hides the panel")
check(not tab:GetChecked(), "...and unchecks ours")
check(cf.RosterTab:GetChecked(), "...and Roster stays checked")

-- Another Blizzard tab (#18 review): it ends up checked, ours not.
tab._scripts.OnClick(tab)
WoW.advance(0)
cf:clickTab("GuildInfoTab", "GUILD_INFO")
WoW.advance(0)
check(not UI.guildHost:IsShown(), "Info clicked from our panel: the panel goes")
check(cf.GuildInfoTab:GetChecked(), "...and Info is checked")
check(not cf.RosterTab:GetChecked() and not tab:GetChecked(), "...alone")

-- Blizzard re-laying its tabs while ours stays up: ours stays the checked one.
tab._scripts.OnClick(tab)
cf:UpdateCommunitiesTabs()
WoW.advance(0)
check(UI.guildHost:IsShown() and tab:GetChecked() and not cf.GuildInfoTab:GetChecked(),
    "a re-layout with our panel up: ours checked, Blizzard's not")
cf:clickTab("RosterTab", "ROSTER")

-- Another club selected (no guild tabs): no tab, no panel.
tab._scripts.OnClick(tab)
cf.guildSelected = false
cf:UpdateCommunitiesTabs()
check(not tab:IsShown() and not UI.guildHost:IsShown(), "a community selected: the tab and panel go")
cf.guildSelected = true
cf:UpdateCommunitiesTabs()

-- The guild window closing takes the panel with it.
tab._scripts.OnClick(tab)
cf:Hide()
check(not UI.guildHost:IsShown(), "closing the guild window hides the panel")
local changed
for k, v in pairs(before) do if rawget(cf, k) ~= v then changed = k end end
eq(changed, nil, "no field of Blizzard's frame was rewritten")

local firstDB = GuildSpyDB
-- Already loaded at login: attached then.
loadAddon({ setup = function() WoW.guild = newGuild(); WoW.loadedAddOns.Blizzard_Communities = true end })
local cf2 = communitiesFrame()
WoW.fire("PLAYER_LOGIN")
check(GuildSpy.UI.tab and GuildSpy.UI.tab:GetParent() == cf2, "loaded before us: attached at login")

-- A damaged "viewed" mark in the saved file: dropped, the window still opens.
local saved = firstDB
saved.guilds["Parse Partout-Forever"].viewedSeq = "lots"
loadAddon({ db = saved, setup = function() WoW.guild = newGuild() end })
WoW.fire("PLAYER_LOGIN")
WoW.fire("GUILD_ROSTER_UPDATE", false)
for _ = 1, 3 do WoW.fire("GUILD_EVENT_LOG_UPDATE") end
WoW.advance(25)
WoW.slash("/gspy log")
GuildSpy._test.UI.window():Hide()
check(type(saved.guilds["Parse Partout-Forever"].viewedSeq) == "number", "a text viewedSeq is replaced, not compared")

-- A client without the dropdown or the top-tab template: plain buttons that still work.
loadAddon({ db = saved, setup = function()
    WoW.guild = newGuild()
    WoW.missingTemplates.WowStyle1DropdownTemplate = true
    WoW.missingTemplates.PanelTopTabButtonTemplate = true
end })
WoW.fire("PLAYER_LOGIN")
WoW.fire("GUILD_ROSTER_UPDATE", false); WoW.advance(25)
WoW.slash("/gspy log")
local fp, FT = GuildSpy._test.UI.panel(), GuildSpy._test.UI
eq(fp.scope._template, "UIPanelButtonTemplate", "no dropdown template: a button")
eq(fp.pills[1]._template, "UIPanelButtonTemplate", "no top-tab template: buttons")
fp.scope._scripts.OnClick(fp.scope)
eq(FT.scope(), "today", "...clicking it moves to the next scope")
eq(fp.scope:GetText(), "Today", "...and names it")
for _ = 1, 3 do fp.scope._scripts.OnClick(fp.scope) end
eq(FT.scope(), "all", "...and wraps around")
eq(fp.rank:GetText(), "All ranks", "the rank button starts on All ranks")
fp.rank._scripts.OnClick(fp.rank)
eq(FT.rank(), "Guild Master", "...clicking it moves to the first rank")
eq(fp.rank:GetText(), "Guild Master", "...and names it")
for _ = 1, 5 do fp.rank._scripts.OnClick(fp.rank) end
eq(FT.rank(), nil, "...and wraps around to All ranks")
eq(fp.rank:GetText(), "All ranks", "...named")
FT.window():Hide()

done("test_ui")
