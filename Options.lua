-- Options.lua: the settings (#4), on a page in the game's Options > AddOns >
-- GuildSpy, with an About page under it. Gnomesweeper's recipe
-- (..\Gnomesweeper\Options.lua): one list of what can be set, one place that
-- checks and saves a change (Options.Set), radio groups rather than dropdowns,
-- and pages hidden at creation and built on their first show. The page re-reads
-- the values every time it shows and after every change.
--
-- The settings live in GuildSpyDB.settings, account-wide; nil means the default.
-- Scanner reads them at each scan, so a change applies from the next one.

local ADDON = ...
GuildSpy = GuildSpy or {}
local Options = {}
GuildSpy.Options = Options

local function st() return GuildSpyDB.settings end

GuildSpy.TAGLINE = "Who joined, left, got promoted, levelled or came back: live, and while you were away."

Options.LEVEL_DEFAULT, Options.RETURN_DEFAULT = 10, 14

Options.ITEMS = {
    { key = "digest", kind = "toggle", label = "Login summary",
      note = "At login, what changed since anyone on your account last looked.",
      get = function() return st().digest ~= false end },
    { key = "levelMin", kind = "choice", label = "Level-ups",
      choices = { { 1, "Every level" }, { 10, "From level 10" }, { 20, "From level 20" },
                  { 40, "From level 40" }, { 60, "Only every tenth level" } },
      note = "Every tenth level (10, 20, 30...) is always reported.",
      get = function() return st().levelMin or Options.LEVEL_DEFAULT end },
    { key = "returnDays", kind = "choice", label = "Back after a long absence",
      choices = { { 7, "Away 7 days or more" }, { 14, "Away 14 days or more" }, { 30, "Away 30 days or more" },
                  { 60, "Away 60 days or more" } },
      note = "Only when GuildSpy saw the member away that long before they came back.",
      get = function() return st().returnDays or Options.RETURN_DEFAULT end },
    { key = "capSound", kind = "toggle", label = "Sound at the level cap",
      note = "A fanfare when a guildmate reaches the level cap: once live, once for a login summary. Ticking it plays it.",
      get = function() return st().capSound ~= false end,
      set = function(v)
          st().capSound = v
          if v then GuildSpy.Scanner.CapSound() end
      end },
    { key = "minimapButton", kind = "toggle", label = "Minimap button",
      note = "Left-click opens or closes the log, right-click opens these settings. Drag it around the minimap.",
      get = function() return GuildSpy.Minimap.Shown() end,
      set = function(v) GuildSpy.Minimap.SetShown(v) end },
}

-- Chat lines as changes happen, by type. The login summary and the log window
-- always have everything.
Options.CHAT = {
    { key = "chat:JOIN", label = "Joins and rejoins", kinds = { "JOIN", "REJOIN" } },
    { key = "chat:LEAVE", label = "Departures and kicks", kinds = { "LEAVE" } },
    { key = "chat:PROMOTE", label = "Promotions and demotions", kinds = { "PROMOTE", "DEMOTE", "RANK" } },
    { key = "chat:RANKS", label = "Changes to the guild's ranks", kinds = { "RANKS" } },
    { key = "chat:NAME", label = "Name changes", kinds = { "NAME" } },
    { key = "chat:RETURN", label = "Members back after a long absence", kinds = { "RETURN" } },
    { key = "chat:NOTE", label = "Note edits", kinds = { "NOTE" } },
    { key = "chat:ONOTE", label = "Officer note edits (only if you can read them)", kinds = { "ONOTE" } },
    { key = "chat:LEVEL", label = "Level-ups", kinds = { "LEVEL" } },
    { key = "chat:MOTD", label = "Message of the day", kinds = { "MOTD" } },
}
for _, c in ipairs(Options.CHAT) do
    c.kind = "toggle"
    c.get = function() return st().chat[c.kinds[1]] ~= false end
    -- On is no saved value at all, as before there was a page.
    c.set = function(v)
        for _, k in ipairs(c.kinds) do
            if v then st().chat[k] = nil else st().chat[k] = false end
        end
    end
end

-- Options > AddOns > GuildSpy > Sharing (owner, SYNC.md §10). Phase 2 (#37):
-- my other accounts; phase 3 adds guildmates.
Options.SHARING = {
    { key = "syncAccounts", kind = "toggle", label = "Sync with my other accounts",
      note = "While another of your accounts is online in the same guild, the two share their logs over Battle.net.",
      get = function() return GuildSpy.AccountSync.Enabled() end,
      set = function(v) GuildSpy.AccountSync.SetEnabled(v) end },
}

local BY_KEY = {}
for _, item in ipairs(Options.SHARING) do BY_KEY[item.key] = item end
for _, item in ipairs(Options.ITEMS) do BY_KEY[item.key] = item end
for _, item in ipairs(Options.CHAT) do BY_KEY[item.key] = item end

------------------------------------------------------------
-- The one place a setting changes
------------------------------------------------------------

function Options.Get(key)
    local item = BY_KEY[key]
    if item and item.get then return item.get() end
    return nil
end

local function valid(item, v)
    if item.kind == "toggle" then return type(v) == "boolean" end
    for _, c in ipairs(item.choices or {}) do if c[1] == v then return true end end
    return false
end

local views = {}     -- refresh functions of the built views

function Options.Refresh()
    for _, fn in ipairs(views) do fn() end
    if Options.RefreshSharing then Options.RefreshSharing() end
end

-- Checks and saves one setting. False (and nothing changed) when the value
-- isn't one it can take.
function Options.Set(key, v)
    local item = BY_KEY[key]
    if not (item and valid(item, v)) then return false end
    if item.set then item.set(v) else st()[key] = v end
    Options.Refresh()
    return true
end

-- A saved value no page could have set (a damaged file, a later version) goes
-- back to the default, so the scan never compares a level with text.
function Options.Validate(settings)
    for _, item in ipairs(Options.ITEMS) do
        -- An item with `set` keeps its value elsewhere (the minimap button: LibDBIcon's table).
        local v = settings[item.key]
        if not item.set and v ~= nil and not valid(item, v)
                and not (item.kind == "choice" and type(v) == "number" and v > 0) then
            settings[item.key] = nil
        end
    end
    if type(settings.chat) ~= "table" then settings.chat = {} end
    for k, v in pairs(settings.chat) do
        if v ~= false then settings.chat[k] = nil end
    end
end

------------------------------------------------------------
-- Options > AddOns > GuildSpy (Blizzard's look, Blizzard's templates)
------------------------------------------------------------

-- Hidden from the start: a frame is created shown, so the first time Settings
-- displayed it no OnShow would fire and the page would stay blank (Gnomesweeper,
-- 70205).
local page = CreateFrame("Frame")
page.name = "GuildSpy"
page:Hide()
local category

local CHECK_ART = {
    normal = "Interface\\Buttons\\UI-CheckBox-Up", pushed = "Interface\\Buttons\\UI-CheckBox-Down",
    highlight = "Interface\\Buttons\\UI-CheckBox-Highlight", checked = "Interface\\Buttons\\UI-CheckBox-Check",
}
local RADIO_ART = "Interface\\Buttons\\UI-RadioButton"   -- 4 cells: normal, checked, highlight, pushed

local function label(parent, text, template, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    if width then fs:SetWidth(width) end
    fs:SetText(text)
    return fs
end
local canvas               -- the page's scroll child: every control lives here
local function pageLabel(text, template) return label(canvas, text, template) end

-- A check or radio button from the client's template, or our own from its art
-- when the template is missing (a missing template returns a bare frame).
local function checkButton(radio)
    local cb, templated = GuildSpy.API.SafeFrame("CheckButton", canvas,
        radio and "UIRadioButtonTemplate" or "UICheckButtonTemplate", "text")
    if not templated then
        if radio then
            cb:SetSize(16, 16)
            cb:SetNormalTexture(RADIO_ART)
            cb:GetNormalTexture():SetTexCoord(0, 0.25, 0, 1)
            cb:SetCheckedTexture(RADIO_ART)
            cb:GetCheckedTexture():SetTexCoord(0.25, 0.5, 0, 1)
            cb:SetHighlightTexture(RADIO_ART)
            cb:GetHighlightTexture():SetTexCoord(0.5, 0.75, 0, 1)
        else
            cb:SetNormalTexture(CHECK_ART.normal)
            cb:SetPushedTexture(CHECK_ART.pushed)
            cb:SetHighlightTexture(CHECK_ART.highlight)
            cb:SetCheckedTexture(CHECK_ART.checked)
        end
    end
    if not radio then cb:SetSize(24, 24) end
    return cb
end

local function buildPage()
    -- Scrolls when the page is taller than the Settings canvas; without the
    -- template a plain ScrollFrame still clips and scrolls by wheel.
    local scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -26, 4)
    canvas = CreateFrame("Frame", nil, scroll)
    canvas:SetSize(600, 600)
    scroll:SetScrollChild(canvas)
    if scroll.ScrollBar then
        scroll:HookScript("OnScrollRangeChanged", function(self, _, yrange)
            self.ScrollBar:SetShown((yrange or self:GetVerticalScrollRange()) > 0)
        end)
    else
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            local v = math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 40))
            self:SetVerticalScroll(v)
        end)
    end
    scroll:SetScript("OnSizeChanged", function(_, w)
        if type(w) == "number" and w > 0 then canvas:SetWidth(w) end
    end)
    page.scroll, page.canvas = scroll, canvas

    local title = pageLabel("|cff7fd4ffGuild|rSpy", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", canvas, "TOPLEFT", 16, -16)
    local sub = pageLabel(GuildSpy.TAGLINE, "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 2, -6)
    sub:SetWidth(620)

    local y = -72
    local refreshers = {}
    page.controls = {}
    local function toggle(item, x)
        local c = {}
        c.check = checkButton(false)
        c.check:SetPoint("TOPLEFT", canvas, "TOPLEFT", x, y)
        c.check:SetScript("OnClick", function(self) Options.Set(item.key, self:GetChecked() and true or false) end)
        c.label = pageLabel(item.label)
        c.label:SetPoint("LEFT", c.check, "RIGHT", 4, 0)
        refreshers[#refreshers + 1] = function() c.check:SetChecked(Options.Get(item.key) and true or false) end
        y = y - 26
        return c
    end
    local function note(text)
        local fs = pageLabel(text, "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 48, y + 4)
        fs:SetWidth(520)
        y = y - 26
        return fs
    end

    for _, item in ipairs(Options.ITEMS) do
        local c
        if item.kind == "toggle" then
            c = toggle(item, 16)
        else
            c = { radios = {} }
            c.label = pageLabel(item.label)
            c.label:SetPoint("TOPLEFT", canvas, "TOPLEFT", 20, y)
            y = y - 22
            for i, choice in ipairs(item.choices) do
                local rb = checkButton(true)
                rb:SetPoint("TOPLEFT", canvas, "TOPLEFT", 28, y)
                rb.value = choice[1]
                rb:SetScript("OnClick", function() Options.Set(item.key, choice[1]) end)
                local fs = pageLabel(choice[2])
                fs:SetPoint("LEFT", rb, "RIGHT", 4, 0)
                c.radios[i] = rb
                y = y - 22
            end
            refreshers[#refreshers + 1] = function()
                local current = Options.Get(item.key)
                for _, rb in ipairs(c.radios) do rb:SetChecked(rb.value == current) end
            end
        end
        c.note = note(item.note)
        page.controls[item.key] = c
    end

    y = y - 6
    local head = pageLabel("Chat lines", "GameFontNormalLarge")
    head:SetPoint("TOPLEFT", canvas, "TOPLEFT", 16, y)
    y = y - 22
    local intro = pageLabel("A line in chat as each change happens. The login summary and the log window always have everything.",
        "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", canvas, "TOPLEFT", 20, y)
    intro:SetWidth(560)
    y = y - 22
    for _, item in ipairs(Options.CHAT) do page.controls[item.key] = toggle(item, 16) end

    canvas:SetHeight(-y + 40)                  -- what's on it: the scroll range follows
    views[#views + 1] = function()
        if not page:IsShown() then return end
        for _, fn in ipairs(refreshers) do fn() end
    end
end

page:SetScript("OnShow", function(self)
    if not self.built then
        self.built = true
        buildPage()
    end
    Options.Refresh()
end)

------------------------------------------------------------
-- Options > AddOns > GuildSpy > About
------------------------------------------------------------

local about = CreateFrame("Frame")
about.name = "About"
about:Hide()                -- see `page`: or its first show is blank

Options.LINKS = {
    { "CurseForge", "https://www.curseforge.com/wow/addons/guildspy" },
    { "GitHub", "https://github.com/Spotnick2/GuildSpy" },
    -- One person tests it in one guild: players' reports are how the rest is found.
    { "Report a bug", "https://github.com/Spotnick2/GuildSpy/issues/new/choose" },
}

-- A link the player can copy: addons can't open a browser or touch the
-- clipboard, so it is a read-only edit box that selects itself on a click, for
-- Ctrl+C (Gnomesweeper's). Typing puts the link back.
local function linkBox(url)
    local box = CreateFrame("EditBox", nil, about)
    box:SetSize(400, 22)
    box:SetAutoFocus(false)
    box:SetFontObject("ChatFontNormal")
    box:SetTextInsets(6, 6, 0, 0)
    box.bg = box:CreateTexture(nil, "BACKGROUND")
    box.bg:SetAllPoints(box)
    box.bg:SetColorTexture(0, 0, 0, 0.5)
    box.url = url
    box:SetText(url)
    box:SetCursorPosition(0)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)
    box:SetScript("OnMouseUp", function(self) self:HighlightText() end)
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(self.url)
            self:HighlightText()
        end
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return box
end

local function buildAbout()
    -- Each line hangs under the one before it, `gap` below: a line that wraps
    -- pushes the rest down (fixed steps overlapped a wrapped tagline).
    local prev, prevIndent
    local function add(fs, gap, indent)
        indent = indent or 0
        if prev then
            fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", indent - prevIndent, -gap)
        else
            fs:SetPoint("TOPLEFT", about, "TOPLEFT", 16 + indent, -16)
        end
        prev, prevIndent = fs, indent
        return fs
    end
    about.title = add(label(about, "|cff7fd4ffGuild|rSpy", "GameFontNormalHuge"), 0)
    about.tagline = add(label(about, GuildSpy.TAGLINE, "GameFontHighlightLarge", 620), 6, 2)
    about.version = add(label(about, "Version " .. GuildSpy.API.AddOnVersion(ADDON)
        .. "  \194\183  for World of Warcraft: Forever  \194\183  by Spotnick", "GameFontHighlightSmall"), 6, 2)

    add(label(about, "What it does", "GameFontNormalLarge"), 18)
    for _, line in ipairs({
        "GuildSpy watches the guild roster and reports what changed: who joined, left or was kicked, promotions and demotions, note edits, level-ups, name changes, and members back after a long absence.",
        "It never changes anything in your guild.",
        "Officer notes only show on a character that can read them.",
        "The log is shared by every character on your account.",
    }) do add(label(about, line, nil, 620), 6, 4) end

    add(label(about, "Links", "GameFontNormalLarge"), 18)
    about.links = {}
    for _, link in ipairs(Options.LINKS) do
        local name = add(label(about, link[1], nil, 110), 10, 4)
        local box = linkBox(link[2])
        box:SetPoint("LEFT", name, "LEFT", 114, 0)
        about.links[#about.links + 1] = box
    end
    add(label(about, "Click a link, then Ctrl+C to copy it.", "GameFontHighlightSmall"), 10, 4)

    add(label(about, "Commands", "GameFontNormalLarge"), 18)
    about.commands = {}
    for _, h in ipairs(GuildSpy.HELP or {}) do
        if not h[2]:find("(for measuring)", 1, true) then
            about.commands[#about.commands + 1] = add(label(about, h[1] .. "  -  " .. h[2], "GameFontHighlightSmall", 620), 3, 4)
        end
    end
end

about:SetScript("OnShow", function(self)
    if not self.built then
        self.built = true
        buildAbout()
    end
end)

------------------------------------------------------------
-- Options > AddOns > GuildSpy > Sharing (#37)
------------------------------------------------------------

local sharing = CreateFrame("Frame")
sharing.name = "Sharing"
sharing:Hide()              -- see `page`: or its first show is blank

local function ago(t)
    if not t then return nil end
    return GuildSpy.Log.Relative and GuildSpy.Log.Relative(t, time()) or (GuildSpy.Log.Ago(time() - t) .. " ago")
end

-- One line per account the library sees: synced when, or why not.
function Options.SharingLines()
    local AS = GuildSpy.AccountSync
    local peers, running = AS.Status()
    local _, myKey = GuildSpy.Scanner.Current()
    local lines = {}
    if not AS.Enabled() then return { "Off." } end
    if not running then return { "Not available: Battle.net sync didn't start on this client." } end
    for _, p in ipairs(peers) do
        local state
        if p.syncedAt then state = "synced " .. ago(p.syncedAt)
        elseif p.guild and myKey and p.guild ~= myKey then state = "online, in another guild (not synced)"
        elseif not p.guild then state = "online, not in a guild yet (not synced)"
        else state = "online, syncing" end
        lines[#lines + 1] = p.name .. ": " .. state
    end
    if #lines == 0 then lines[1] = "None of your other accounts seen this session. Log in on one, in the same guild." end
    return lines
end

local function sharingLabel(text, template, width)
    local fs = sharing:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    if width then fs:SetWidth(width) end
    fs:SetText(text)
    return fs
end

local function buildSharing()
    local title = sharingLabel("Sharing", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", sharing, "TOPLEFT", 16, -16)
    local sub = sharingLabel("What GuildSpy shares, and with whom. Only ever within your current guild.",
        "GameFontHighlightSmall", 620)
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 2, -6)
    sharing.controls = {}
    local y = -72
    for _, item in ipairs(Options.SHARING) do
        local cb, templated = GuildSpy.API.SafeFrame("CheckButton", sharing, "UICheckButtonTemplate", "text")
        if not templated then
            cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
            cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        end
        cb:SetSize(24, 24)
        cb:SetPoint("TOPLEFT", sharing, "TOPLEFT", 16, y)
        cb:SetScript("OnClick", function(self) Options.Set(item.key, self:GetChecked() and true or false) end)
        local fs = sharingLabel(item.label)
        fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        local note = sharingLabel(item.note, "GameFontHighlightSmall", 560)
        note:SetPoint("TOPLEFT", sharing, "TOPLEFT", 48, y - 22)
        sharing.controls[item.key] = { check = cb, label = fs, note = note }
        y = y - 56
    end
    local head = sharingLabel("Your other accounts", "GameFontNormalLarge")
    head:SetPoint("TOPLEFT", sharing, "TOPLEFT", 16, y)
    sharing.status = sharingLabel("", "GameFontHighlightSmall", 600)
    sharing.status:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 4, -8)
end

function Options.RefreshSharing()
    if not sharing.built or not sharing:IsShown() then return end
    for _, item in ipairs(Options.SHARING) do
        sharing.controls[item.key].check:SetChecked(Options.Get(item.key) and true or false)
    end
    sharing.status:SetText(table.concat(Options.SharingLines(), "\n"))
end

sharing:SetScript("OnShow", function(self)
    if not self.built then
        self.built = true
        buildSharing()
    end
    Options.RefreshSharing()
end)

local function register()
    local Settings = rawget(_G, "Settings")
    if category or not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
    category = Settings.RegisterCanvasLayoutCategory(page, page.name)
    Settings.RegisterAddOnCategory(category)
    if Settings.RegisterCanvasLayoutSubcategory then
        pcall(Settings.RegisterCanvasLayoutSubcategory, category, sharing, sharing.name)
        pcall(Settings.RegisterCanvasLayoutSubcategory, category, about, about.name)
    end
    -- The log window is in the DIALOG strata, above Settings (HIGH): it steps aside.
    local sp = rawget(_G, "SettingsPanel")
    if sp and sp.HookScript then
        sp:HookScript("OnShow", function() GuildSpy.UI.CloseWindow() end)
    end
end

-- Opens Options > AddOns > GuildSpy; false when the Settings framework can't.
function Options.OpenPage()
    local Settings = rawget(_G, "Settings")
    if not (category and Settings and Settings.OpenToCategory) then return false end
    return pcall(Settings.OpenToCategory, category:GetID()) and true or false
end

-- /gspy options (and the minimap button): open the page, or say where it is.
function Options.Open()
    if Options.OpenPage() then return true end
    GuildSpy.Print("the settings are in the game's Options > AddOns > GuildSpy.")
    return false
end

local reg = CreateFrame("Frame")
reg:RegisterEvent("PLAYER_LOGIN")
reg:SetScript("OnEvent", register)

Options._test = {
    page = page,
    about = about,
    sharing = sharing,
    category = function() return category end,
}
