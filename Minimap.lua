-- Minimap.lua: the minimap button, the addon compartment and the key binding
-- (#5). Left-click opens or closes the log window, right-click opens the
-- settings. Gnomesweeper's recipe (..\Gnomesweeper\Minimap.lua): a
-- LibDataBroker launcher shown by LibDBIcon (Libs\), which gives dragging
-- around the ring, round and square minimaps, and button collectors.
--
-- Its position and whether it is shown are LibDBIcon's own table,
-- GuildSpyDB.minimap ({ hide, minimapPos, ... }). Showing or hiding it is a
-- setting (Options.lua: "minimapButton"), so it goes through Options.Set.
--
-- The addon compartment: the TOC's AddonCompartmentFunc names a global that
-- clicks the same way (Blizzard_Minimap/Mainline/AddonCompartment.lua calls it
-- with the addon's name and the mouse button). The key binding is Bindings.xml.

local ADDON = ...
GuildSpy = GuildSpy or {}
local Minimap_ = {}          -- not "Minimap": that is the client's minimap frame
GuildSpy.Minimap = Minimap_

local NAME = "GuildSpy"
Minimap_.ICON = "Interface\\Icons\\INV_Misc_Spyglass_03"      -- the TOC's IconTexture
local registered = false

-- LibDBIcon's table. Made (or repaired) once, at ADDON_LOADED (GuildSpy.lua),
-- and never replaced after: LibDBIcon keeps a reference to it.
local function db() return GuildSpyDB.minimap end

function Minimap_.Shown() return not db().hide end

-- Whether there is a button at all (no libraries, or a name already taken: none).
function Minimap_.Available() return registered end

-- Show or hide it, and save that. LibDBIcon's own Show/Hide never touch the
-- saved table, so the choice is written here.
function Minimap_.SetShown(v)
    db().hide = not v
    Minimap_.Apply()
end

-- One click, from the minimap button or the compartment (both call it with
-- something first, the button or the addon's name, then the mouse button).
function Minimap_.Click(_, button)
    if button == "RightButton" then
        GuildSpy.Options.Open()
    else
        GuildSpy.UI.Toggle()
    end
end

-- The guild, who is online at the last scan, what's new since the log window
-- was last looked at, and what the clicks do.
local HINT = { 0.75, 0.78, 0.85 }
local function tooltip(tip, drag)
    tip:AddLine("|cff7fd4ffGuild|rSpy")
    local gs = GuildSpy.Scanner.Current()
    local _, guild = GuildSpy.API.GuildKey()
    if gs and guild then
        local total, online = 0, 0
        for _, m in pairs(type(gs.members) == "table" and gs.members or {}) do
            total = total + 1
            if type(m) == "table" and m.online then online = online + 1 end
        end
        tip:AddLine(guild, 1, 1, 1)
        tip:AddLine(online .. " of " .. total .. " members online", 0.8, 0.8, 0.8)
        tip:AddLine(GuildSpy.Log.NewSummary(gs, gs.viewedSeq or 0, GuildSpy.API.CanViewOfficerNote() == true), 1, 1, 1)
    else
        tip:AddLine("No guild seen yet.", 0.6, 0.6, 0.6)
    end
    tip:AddLine("Left-click: open or close the log", HINT[1], HINT[2], HINT[3])
    tip:AddLine("Right-click: settings", HINT[1], HINT[2], HINT[3])
    if drag then tip:AddLine("Drag: move around the minimap", HINT[1], HINT[2], HINT[3]) end
end

-- The TOC's AddonCompartmentFunc*: globals, as the compartment looks them up by name.
GuildSpy_OnAddonCompartmentClick = Minimap_.Click
function GuildSpy_OnAddonCompartmentEnter(_, row)
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    tooltip(GameTooltip, false)
    GameTooltip:Show()
end
function GuildSpy_OnAddonCompartmentLeave() GameTooltip:Hide() end

-- The key binding's line in Key Bindings > GuildSpy (Bindings.xml): a global,
-- as the client looks it up by name.
BINDING_NAME_GUILDSPY_TOGGLE = "Open or close the activity log"

local launcher = {
    type = "launcher",
    label = "GuildSpy",
    icon = Minimap_.ICON,
    OnClick = Minimap_.Click,
    OnTooltipShow = function(tip) tooltip(tip, true) end,
}

-- Show or hide it to match the setting (called by Options.Set).
function Minimap_.Apply()
    if not registered then return end
    local icon = LibStub("LibDBIcon-1.0")
    if db().hide then icon:Hide(NAME) else icon:Show(NAME) end
end

local function register()
    if registered then return end
    local ok, ldb = pcall(LibStub, "LibDataBroker-1.1")
    local ok2, icon = pcall(LibStub, "LibDBIcon-1.0")
    if not (ok and ok2 and ldb and icon) then return end    -- no libraries: no button, nothing else breaks
    -- NewDataObject answers nil when another addon already took the name;
    -- Register would then error at login. Either way: no button.
    local obj = ldb:NewDataObject(NAME, launcher)
    if not obj then return end
    registered = pcall(icon.Register, icon, NAME, obj, db())
end

local reg = CreateFrame("Frame")
reg:RegisterEvent("PLAYER_LOGIN")
reg:SetScript("OnEvent", register)

Minimap_._test = { launcher = launcher, registered = function() return registered end }
