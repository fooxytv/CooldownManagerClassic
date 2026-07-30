#!/usr/bin/env python3
"""Load and exercise the addon against a stubbed WoW client.

luacheck parses; this runs. It catches the failures a parse cannot see -- load
order mistakes, indexing a nil child widget, an API branch that was never taken
-- which otherwise only appear after a /reload in game.

The stub is deliberately small: enough of the widget and C_* API for the load
sequence, a layout pass and an update tick. Every file listed in the .toc is
loaded in .toc order, so a new file is covered the moment it is packaged.

Run with the Cooldown Manager atlases present and absent, since Classic Era may
ship neither and the fallback paths are otherwise never taken.

    python ci/tests/smoke_test.py

Requires: pip install lupa
"""

import sys
from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:
    print("smoke_test: lupa is not installed (pip install lupa) - skipping.")
    sys.exit(0)

ROOT = Path(__file__).resolve().parents[2]
STUB = Path(__file__).with_name("wow_stub.lua")

failures = []


def check(name, actual, expected):
    if actual != expected:
        failures.append(f"{name}: expected {expected!r}, got {actual!r}")
        print(f"  FAIL {name}: expected {expected!r}, got {actual!r}")
    else:
        print(f"  ok   {name} = {actual!r}")


def addon_files():
    """Every Lua file in the .toc, in load order. Libraries are third-party."""
    toc = (ROOT / "CooldownManagerClassic.toc").read_text(encoding="utf-8")
    return [
        line.strip().replace("\\", "/")
        for line in toc.splitlines()
        if line.strip().lower().endswith(".lua")
        and not line.strip().lower().startswith("libs")
    ]


def load_addon(with_art=True):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(STUB.read_text(encoding="utf-8"))
    if not with_art:
        lua.execute("__setAtlasesPresent(false)")

    lua.execute("__ns = {}")
    ns = lua.globals().__ns
    for rel in addon_files():
        source = (ROOT / rel).read_text(encoding="utf-8")
        chunk = lua.eval("function(s, n) return assert(load(s, n)) end")(source, "@" + rel)
        chunk("CooldownManagerClassic", ns)
    return lua


SCRIPT = """
local ns = __ns
local R = {}
ns.DB:Initialize()
ns.Core.initialized = true

-- Icons: a tracked buff renders and counts down.
local buffs = ns.DB:GetGroup("buffs")
buffs.spells = { { spellID = 187880, name = "Maelstrom Weapon", rankIndependent = true } }
local group = ns.Group.Create("buffs")
group:Layout()
group:Update()
R.iconKind = group.widgetKind
R.iconCount = #group.icons
R.iconTimer = group.icons[1].timeText:GetText()

-- Bars: the same group as bars, then back again, exercising both pools.
buffs.appearance.display = "Bars"
group:Layout(); group:Update()
R.barKind = group.widgetKind
R.barName = group.icons[1].nameText:GetText()
buffs.appearance.display = "Icons"
group:Layout()
R.backToIcons = group.widgetKind

-- Cooldown bars: the effect drives the bar, then the recharge.
local cdbars = ns.DB:GetGroup("cooldownbars")
cdbars.spells = { { spellID = 187880, name = "Maelstrom Weapon", rankIndependent = true } }
local cdgroup = ns.Group.Create("cooldownbars")
cdgroup:Layout(); cdgroup:Update()
R.cooldownBarKind = cdgroup.widgetKind
R.cooldownBarPhase = ns.Cooldowns:GetBarState(187880).phase

-- Resource bars. Disabled is the default, and a disabled bar must still become
-- visible and draggable when unlocked -- otherwise the only setting that can
-- enable it sits behind a frame nobody can click.
--
-- All three are created, not just health: each key reads a different API, and
-- the combo path in particular is the one that recursed into a stack overflow.
--
-- The "combo" bar is now the adaptive class-resource bar, so it only shows combo
-- pips for a combo-point class -- run these as a Rogue.
_G.UnitClass = function() return "Rogue", "ROGUE", 4 end
for _, key in ipairs(ns.Constants.BAR_ORDER) do
    ns.ResourceBar.Create(key)
    ns.DB:GetBar(key).enabled = false
    ns.bars[key]:Layout()
end

local health, combo = ns.bars.health, ns.bars.combo
R.barHiddenWhenDisabled = health.frame:IsShown()

ns.EditMode:SetManualUnlock(true)
R.barShownWhenUnlocked = health.frame:IsShown()
R.barDraggable = health.unlocked and true or false
R.barRendersWhenUnlocked = health.text:GetText()
R.comboShownWhenUnlocked = combo.frame:IsShown()
R.comboPips = #combo.pips

-- Combo pip colour tracks how close the finisher is. Filled pips all take the
-- same colour; unfilled ones stay grey whatever the count.
local function ComboFillAt(points)
    _G.GetComboPoints = function() return points end
    combo:Update()
    local filled = combo.pips[math.max(points, 1)].__color
    return ("%.2f/%.2f/%.2f"):format(filled[1], filled[2], filled[3])
end

R.comboAt3 = ComboFillAt(3)
R.comboAt4 = ComboFillAt(4)
R.comboAt5 = ComboFillAt(5)
R.comboUnfilledAt5 = combo.pips[5].__color[1]
ComboFillAt(2)
R.comboUnfilledAt2 = ("%.2f"):format(combo.pips[5].__color[1])
_G.GetComboPoints = function() return 0 end

-- The adaptive class-resource bar: as a Rogue the source is combo points.
R.classResourceSource = combo.source

-- As a Warlock the same bar shows soul shards as a counted bar with the running
-- total. Shards have no cap, so this is a filled bar, not pips.
_G.UnitClass = function() return "Warlock", "WARLOCK", 9 end
_G.GetItemCount = function() return 7 end
ns.DB:GetBar("combo").enabled = true
local shardBar = ns.ResourceBar.Create("combo")
shardBar:Layout(); shardBar:Update()
R.shardSource = shardBar.source
R.shardText = shardBar.text:GetText()

-- The class-resource bar is form-aware for a Druid: combo points exist only in
-- cat form, where the power is Energy. Bear (Rage) and caster (Mana) have none,
-- so the source resolves to nil and the bar hides -- the power bar covers those.
-- Re-laying out on each UnitPowerType change stands in for the UNIT_DISPLAYPOWER
-- shapeshift re-Layout that Core drives in game.
_G.UnitClass = function() return "Druid", "DRUID", 11 end
ns.DB:GetBar("combo").enabled = true
ns.DB:GetBar("combo").appearance.resourceSource = ""
local druid = ns.ResourceBar.Create("combo")

_G.UnitPowerType = function() return 3, "ENERGY" end
druid:Layout()
R.druidCatSource = druid.source
R.druidCatShown = druid.frame:IsShown()

_G.UnitPowerType = function() return 1, "RAGE" end
druid:Layout()
R.druidBearSource = tostring(druid.source)
R.druidBearShown = druid.frame:IsShown()

_G.UnitPowerType = function() return 0, "MANA" end
druid:Layout()
R.druidCasterSource = tostring(druid.source)

-- The Resource Source override pins the bar regardless of class and form. "none"
-- hides it even in cat form; a specific key forces that source outright.
_G.UnitPowerType = function() return 3, "ENERGY" end
ns.DB:GetBar("combo").appearance.resourceSource = "none"
druid:Layout()
R.druidForcedNone = tostring(druid.source)

ns.DB:GetBar("combo").appearance.resourceSource = "soulshards"
druid:Layout()
R.druidForcedSource = druid.source
ns.DB:GetBar("combo").appearance.resourceSource = ""

_G.UnitPowerType = function() return 0, "MANA" end

-- The bar panel surfaces the Resource Source dropdown for the class-resource bar
-- only. Opening it for "combo" shows the row; for "power" it is hidden.
ns.BarPanel:Show("combo")
R.resourceSourceShownForCombo = _G.CDMCBarPanel.resourceSource:IsShown()
ns.BarPanel:Show("power")
R.resourceSourceHiddenForPower = _G.CDMCBarPanel.resourceSource:IsShown()
ns.BarPanel:Hide()

-- Target DoT tracking: a debuff the player applied to the target drives the
-- active phase of a cooldown bar for a spell with no real cooldown (Moonfire).
-- Only the player's own debuff counts, and a new/empty target reads clean.
_G.__hasTarget = true
_G.__targetAura = { spellId = 8921, name = "Moonfire", sourceUnit = "player",
                    duration = 12, expirationTime = GetTime() + 9, timeMod = 1 }
ns.Auras:ClearCache()
local moonfire = ns.Cooldowns:GetBarState(8921)
R.dotPhase = moonfire.phase
R.dotRemaining = math.floor(moonfire.remaining + 0.5)

-- A debuff cast by someone else on the same target is ignored.
_G.__targetAura = { spellId = 8921, name = "Moonfire", sourceUnit = "party1",
                    duration = 12, expirationTime = GetTime() + 9, timeMod = 1 }
ns.Auras:MarkTargetDirty()
R.dotIgnoresOthers = ns.Cooldowns:GetBarState(8921).phase

-- No target: the DoT source is empty and the bar falls back to ready.
_G.__targetAura = nil
_G.__hasTarget = false
ns.Auras:MarkTargetDirty()
R.dotNoTarget = ns.Cooldowns:GetBarState(8921).phase

-- Back to the stub default so nothing downstream sees the test's class.
_G.UnitClass = function() return "Shaman", "SHAMAN", 7 end
_G.GetItemCount = function() return 0 end

ns.EditMode:SetManualUnlock(false)
R.barHiddenAgain = health.frame:IsShown()

ns.DB:GetBar("health").enabled = true
health:Layout()
R.barShownWhenEnabled = health.frame:IsShown()

-- Revert has to restore bar positions too, now that bars can be dragged.
ns.DB:SetBarPosition("health", "CENTER", "CENTER", 11, 22)
ns.EditMode:Enter()
ns.DB:SetBarPosition("health", "CENTER", "CENTER", 999, 999)
ns.EditMode:RevertChanges()
R.barPositionReverted = ns.DB:GetBar("health").position.x
ns.EditMode:Exit()

-- Profile round trip: everything out, everything back.
buffs.appearance.barWidth = 317
local exported = ns.Serialization:Export()
R.exportPrefix = exported:sub(1, 6)
local imported = ns.Serialization:Import(exported)
R.importedBarWidth = imported.groups.buffs.appearance.barWidth
R.importedSpellName = imported.groups.buffs.spells[1].name

-- The dialogs build and open.
ns.SpellPicker:Show("cooldowns")
R.pickerShown = _G.CDMCSettingsFrame:IsShown()
ns.ProfileShare:ShowExport()
R.shareShown = _G.CDMCProfileShare:IsShown()
ns.EditModePanel:Show("essential")
R.panelShown = _G.CDMCEditModePanel:IsShown()

-- The reactive-highlights checkbox toggles the profile flag (it is not a group
-- appearance option, so it uses the custom get/set path).
local hlCheck = _G.CDMCEditModePanel.showHighlights
hlCheck:SetChecked(true)
hlCheck:GetScript("OnClick")(hlCheck)
R.highlightCheckboxOn = ns.DB:AreHighlightsEnabled()
hlCheck:SetChecked(false)
hlCheck:GetScript("OnClick")(hlCheck)
R.highlightCheckboxOff = ns.DB:AreHighlightsEnabled()

-- Every tab must render. A panel tab builds its own widgets instead of spell
-- sections, so a mistake there throws rather than looking merely empty.
ns.SpellPicker:Show("profiles")
R.profilesTabShown = _G.CDMCSettingsFrame:IsShown()
ns.SpellPicker:Show("cooldowns")

-- LibSharedMedia wrapper: the library is absent under the stub, so an empty or
-- unknown key falls back to the built-in path.
R.mediaFontFallback = ns.Media.Fetch("font", "", "FALLBACK.ttf")
R.mediaBarFallback = ns.Media.Fetch("statusbar", "Unregistered", "FALLBACK.tga")

-- A bar with a chosen texture still lays out (falls back, no error).
ns.DB:GetBar("power").appearance.barTexture = "Some LSM Bar"
ns.bars.power:Layout()
R.mediaBarLaidOut = (ns.bars.power.frame:GetWidth() or 0) > 0

-- An icon group with a chosen font still configures (falls back, no error).
buffs.appearance.fontFace = "Some LSM Font"
group:Layout()
R.mediaFontLaidOut = group.icons[1] ~= nil

-- Keybind text: a tracked cooldown spell on an action bar shows its abbreviated
-- hotkey; off by default, and only for cooldown (non-aura) groups.
ns.Keybinds:Rebuild()
R.keybindMapped = ns.Keybinds:Get(686)

local kbGroup = ns.Group.Create("essential")
local kbIcon = ns.Icon:Acquire(kbGroup.frame, "essential")
ns.Icon:Configure(kbIcon, { name = "Shadow Bolt" }, 686, { showKeybind = true, iconSize = 40 }, "essential")
R.keybindShown = kbIcon.keybindText:IsShown()
R.keybindText = kbIcon.keybindText:GetText()

ns.Icon:Configure(kbIcon, { name = "Shadow Bolt" }, 686, { showKeybind = false, iconSize = 40 }, "essential")
R.keybindOff = kbIcon.keybindText:IsShown()

-- Reactive highlighting: a proc lights up the matching tracked icon, and clears
-- when it falls off. Warlock's Shadow Trance -> Shadow Bolt, chosen because that
-- rule is not SoD-gated and so runs under the stub.
_G.UnitClass = function() return "Warlock", "WARLOCK", 9 end
_G.__aura = { spellId = 17941, name = "Shadow Trance", icon = "x",
              applications = 1, duration = 0, expirationTime = 0, timeMod = 1 }
ns.Auras:ClearCache()
ns.DB:SetHighlightsEnabled(true)
ns.Highlights:OnProfileChanged()

local eGroup = ns.Group.Create("essential")
local sbIcon = ns.Icon:Acquire(eGroup.frame, "essential")
sbIcon.entry = { name = "Shadow Bolt" }
sbIcon.spellID = 686
eGroup.icons = { sbIcon }

ns.Highlights:Apply()
R.glowOn = sbIcon.glowRequested and true or false

-- Proc consumed: the aura is gone, so the glow clears on the next pass.
_G.__aura = { spellId = 0, name = "None", applications = 0, duration = 0, expirationTime = 0 }
ns.Auras:ClearCache()
ns.Highlights:Apply()
R.glowOff = sbIcon.glowRequested and true or false

-- With highlighting off, a live proc must not glow.
_G.__aura = { spellId = 17941, name = "Shadow Trance", applications = 1, duration = 0, expirationTime = 0 }
ns.Auras:ClearCache()
ns.DB:SetHighlightsEnabled(false)
ns.Highlights:Apply()
R.glowDisabled = sbIcon.glowRequested and true or false

-- Resource-bar settings panel: it opens, and its Enabled checkbox flips the flag.
ns.BarPanel:Show("power")
R.barPanelShown = _G.CDMCBarPanel:IsShown()
local barEnable = _G.CDMCBarPanel.enabled
barEnable:SetChecked(true)
barEnable:GetScript("OnClick")(barEnable)
R.barPanelEnables = ns.DB:GetBar("power").enabled

-- Richer visibility: hide-when-full and with-target track the resource/target.
local pbar = ns.bars.power
pbar.unlocked = false
ns.DB:GetBar("power").enabled = true
ns.DB:GetBar("power").appearance.visibility = "HideWhenFull"
_G.UnitPower = function() return 100 end
_G.UnitPowerMax = function() return 100 end
pbar:Layout()
R.barHiddenWhenFull = pbar.frame:IsShown()
_G.UnitPower = function() return 40 end
pbar:Layout()
R.barShownWhenNotFull = pbar.frame:IsShown()

ns.DB:GetBar("power").appearance.visibility = "WithTarget"
_G.__hasTarget = false
pbar:Layout()
R.barHiddenNoTarget = pbar.frame:IsShown()
_G.__hasTarget = true
pbar:Layout()
R.barShownWithTarget = pbar.frame:IsShown()

R.artMask = ns.Icon.art.mask and true or false
return R
"""

# Profile binding is its own scenario: it needs a fresh DB per simulated
# character, and it turns on the ADDON_LOADED race that caused the real bug.
PROFILE_SCRIPT = """
local ns = __ns
local R = {}

local realUnitClass, realUnitName = _G.UnitClass, _G.UnitName

local function LoginAs(name, class, classReadyAtAddonLoaded)
    _G.UnitName = function(unit) if unit == "player" then return name end return realUnitName(unit) end
    _G.UnitClass = function() return nil end
    ns.DB:Initialize()                       -- ADDON_LOADED
    if classReadyAtAddonLoaded then
        -- Not actually used for binding any more; proves it does not matter.
        _G.UnitClass = function() return class, class:upper(), 1 end
        ns.DB:Initialize()
    end
    _G.UnitClass = function() return class, class:upper(), 1 end
    ns.DB:SelectProfileForCharacter()        -- PLAYER_LOGIN
    return ns.DB:GetCurrentProfileName()
end

-- The regression guard: ADDON_LOADED must not bind a character to anything.
-- The class is not known that early, and binding from a nil class is what put
-- several characters on one shared profile.
_G.UnitName = function(unit) if unit == "player" then return "Bindtest" end return realUnitName(unit) end
_G.UnitClass = function() return nil end
ns.DB.root = nil
ns.DB:Initialize()
ns.DB.root.profileKeys = {}
ns.DB:Initialize()
R.noBindAtAddonLoaded = (ns.DB.root.profileKeys["Bindtest - " .. GetRealmName()] == nil)

-- A rogue and a shaman, with the class unavailable at ADDON_LOADED both times.
-- This is exactly the race that put two characters on one profile.
R.rogueProfile = LoginAs("Varkha", "Rogue", false)
R.shamanProfile = LoginAs("Shadee", "Shaman", false)
R.profilesDiffer = (R.rogueProfile ~= R.shamanProfile)

-- Editing one must not reach the other.
ns.DB.root.profiles[R.rogueProfile].groups.essential.spells = { { spellID = 1752 } }
R.shamanUntouched = #ns.DB.root.profiles[R.shamanProfile].groups.essential.spells

-- Repair: two characters already stuck on a shared Default, as found in a live
-- SavedVariables file. Each should be moved to its own class profile.
local realm = GetRealmName()
ns.DB.root.profileKeys = {
    ["Varkha - " .. realm] = "Default",
    ["Shadee - " .. realm] = "Default",
}
ns.DB.repairedFromShared = nil
R.repairedShaman = LoginAs("Shadee", "Shaman", false)
R.repairFlagged = tostring(ns.DB.repairedFromShared)
R.defaultKept = ns.DB.root.profiles["Default"] ~= nil

-- The headline flow behind the Profiles tab: a second shaman copies the first
-- shaman's layout, then diverges from it without editing the source.
ns.DB.root.profiles["Shaman"].groups.essential.spells = { { spellID = 403 } }
ns.DB:CreateProfile("Shaman Alt", "Shaman")
R.copyInheritsLayout = #ns.DB.root.profiles["Shaman Alt"].groups.essential.spells

ns.DB:SetProfile("Shaman Alt")
ns.DB:GetGroup("essential").spells = { { spellID = 403 }, { spellID = 421 } }
R.copyDiverged = #ns.DB.root.profiles["Shaman Alt"].groups.essential.spells
R.copySourceUntouched = #ns.DB.root.profiles["Shaman"].groups.essential.spells

R.duplicateNameRejected = select(1, ns.DB:CreateProfile("Shaman Alt")) == false
R.deleteInUseRejected = select(1, ns.DB:DeleteProfile("Shaman Alt")) == false

-- A lone character deliberately on Default is left where it is.
ns.DB.root.profileKeys = { ["Solo - " .. realm] = "Default" }
ns.DB.repairedFromShared = nil
R.soloProfile = LoginAs("Solo", "Warrior", false)
R.soloNotRepaired = ns.DB.repairedFromShared == nil

_G.UnitClass, _G.UnitName = realUnitClass, realUnitName
return R
"""


def run(with_art):
    label = "atlases present" if with_art else "atlases absent"
    print(f"\nsmoke_test [{label}]")
    try:
        lua = load_addon(with_art)
        results = dict(lua.execute(SCRIPT))
    except Exception as exc:  # noqa: BLE001 - any Lua error is a test failure
        failures.append(f"[{label}] {exc}")
        print(f"  FAIL {exc}")
        return

    check("icon widget", results["iconKind"], "icons")
    check("icon count", results["iconCount"], 1)
    check("icon timer", results["iconTimer"], "12")
    check("bar widget", results["barKind"], "bars")
    check("bar name", results["barName"], "Maelstrom Weapon")
    check("back to icons", results["backToIcons"], "icons")
    check("cooldown bar widget", results["cooldownBarKind"], "bars")
    check("cooldown bar phase", results["cooldownBarPhase"], "active")
    check("bar hidden when disabled", results["barHiddenWhenDisabled"], False)
    check("bar shown when unlocked", results["barShownWhenUnlocked"], True)
    check("bar draggable when unlocked", results["barDraggable"], True)
    check("bar renders when unlocked", results["barRendersWhenUnlocked"], "100 / 100")
    check("combo bar shown when unlocked", results["comboShownWhenUnlocked"], True)
    check("combo bar pips", results["comboPips"], 5)
    check("combo fill at 3 (yellow)", results["comboAt3"], "1.00/0.85/0.10")
    check("combo fill at 4 (orange)", results["comboAt4"], "1.00/0.50/0.10")
    check("combo fill at 5 (red)", results["comboAt5"], "0.95/0.15/0.15")
    check("combo unfilled stays grey", results["comboUnfilledAt2"], "0.25")
    check("class resource source (rogue)", results["classResourceSource"], "combo")
    check("class resource source (warlock)", results["shardSource"], "soulshards")
    check("class resource shard total", results["shardText"], "7")
    check("druid cat resolves combo", results["druidCatSource"], "combo")
    check("druid cat bar shown", results["druidCatShown"], True)
    check("druid bear resolves none", results["druidBearSource"], "nil")
    check("druid bear bar hidden", results["druidBearShown"], False)
    check("druid caster resolves none", results["druidCasterSource"], "nil")
    check("resource override none hides", results["druidForcedNone"], "nil")
    check("resource override forces source", results["druidForcedSource"], "soulshards")
    check("resource source dropdown shown for combo", results["resourceSourceShownForCombo"], True)
    check("resource source dropdown hidden for power", results["resourceSourceHiddenForPower"], False)
    check("target dot drives cooldown bar active", results["dotPhase"], "active")
    check("target dot bar shows remaining", results["dotRemaining"], 9)
    check("target dot ignores others' casts", results["dotIgnoresOthers"], "ready")
    check("target dot falls back to ready with no target", results["dotNoTarget"], "ready")
    check("highlight on proc", results["glowOn"], True)
    check("highlight clears", results["glowOff"], False)
    check("highlight off when disabled", results["glowDisabled"], False)
    check("bar hidden again when locked", results["barHiddenAgain"], False)
    check("bar shown when enabled", results["barShownWhenEnabled"], True)
    check("bar position reverted", results["barPositionReverted"], 11)
    check("export format", results["exportPrefix"], "CDMC2:")
    check("round-trip bar width", results["importedBarWidth"], 317)
    check("round-trip spell name", results["importedSpellName"], "Maelstrom Weapon")
    check("picker opens", results["pickerShown"], True)
    check("share window opens", results["shareShown"], True)
    check("edit panel opens", results["panelShown"], True)
    check("highlight checkbox enables", results["highlightCheckboxOn"], True)
    check("highlight checkbox disables", results["highlightCheckboxOff"], False)
    check("profiles tab renders", results["profilesTabShown"], True)
    check("media font fallback", results["mediaFontFallback"], "FALLBACK.ttf")
    check("media bar fallback", results["mediaBarFallback"], "FALLBACK.tga")
    check("media bar still lays out", results["mediaBarLaidOut"], True)
    check("media font still configures", results["mediaFontLaidOut"], True)
    check("keybind mapped from bar", results["keybindMapped"], "s2")
    check("keybind shown when enabled", results["keybindShown"], True)
    check("keybind text abbreviated", results["keybindText"], "s2")
    check("keybind off by default", results["keybindOff"], False)
    check("bar panel opens", results["barPanelShown"], True)
    check("bar panel enable checkbox", results["barPanelEnables"], True)
    check("bar hidden when full", results["barHiddenWhenFull"], False)
    check("bar shown when not full", results["barShownWhenNotFull"], True)
    check("bar hidden with no target", results["barHiddenNoTarget"], False)
    check("bar shown with target", results["barShownWithTarget"], True)
    check("atlas probe", results["artMask"], with_art)


def run_profiles():
    print("\nsmoke_test [per-character profiles]")
    try:
        lua = load_addon(True)
        results = dict(lua.execute(PROFILE_SCRIPT))
    except Exception as exc:  # noqa: BLE001 - any Lua error is a test failure
        failures.append(f"[profiles] {exc}")
        print(f"  FAIL {exc}")
        return

    check("ADDON_LOADED does not bind", results["noBindAtAddonLoaded"], True)
    check("rogue gets its own profile", results["rogueProfile"], "Rogue")
    check("shaman gets its own profile", results["shamanProfile"], "Shaman")
    check("profiles are separate", results["profilesDiffer"], True)
    check("editing one leaves the other", results["shamanUntouched"], 0)
    check("shared Default is repaired", results["repairedShaman"], "Shaman")
    check("repair is reported", results["repairFlagged"], "Default")
    check("repair keeps the old profile", results["defaultKept"], True)
    check("copy inherits the source layout", results["copyInheritsLayout"], 1)
    check("copy diverges from source", results["copyDiverged"], 2)
    check("copy leaves the source alone", results["copySourceUntouched"], 1)
    check("duplicate name rejected", results["duplicateNameRejected"], True)
    check("deleting the in-use profile rejected", results["deleteInUseRejected"], True)
    check("lone Default user untouched", results["soloProfile"], "Default")
    check("lone Default not flagged", results["soloNotRepaired"], True)


run(with_art=True)
run(with_art=False)
run_profiles()

print()
if failures:
    print(f"smoke_test: {len(failures)} failure(s)")
    sys.exit(1)
print("smoke_test: all checks passed")
