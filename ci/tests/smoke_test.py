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

-- DoT tracking: a spell flagged trackDebuff is followed by the debuff the player
-- put on the target, in every section. Only the player's own debuff counts.
_G.__hasTarget = true
_G.__targetAura = { spellId = 8921, name = "Moonfire", sourceUnit = "player",
                    duration = 12, expirationTime = GetTime() + 9, timeMod = 1 }
ns.Auras:ClearCache()

-- Cooldown Bars path (flag-gated now).
local moonfire = ns.Cooldowns:GetBarState(8921, true)
R.dotPhase = moonfire.phase
R.dotRemaining = math.floor(moonfire.remaining + 0.5)

-- Without the flag the bar does NOT read the target debuff (stays ready).
R.dotUnflaggedPhase = ns.Cooldowns:GetBarState(8921).phase

-- Tracked Buffs path: GetTrackedState routes a flagged spell to the target DoT.
R.dotBuffActive = ns.Auras:GetTrackedState(8921, true).active and true or false
R.dotBuffUnflagged = ns.Auras:GetTrackedState(8921, false).active and true or false

-- Icon path: the DoT drives the icon countdown for a flagged spell.
R.dotIconRemaining = math.floor(ns.Cooldowns:GetIconState(8921, false, true).remaining + 0.5)

-- The same flag follows an ability whose aura lands on the *player* with no
-- cooldown behind it (Slice and Dice). Reading only the target debuff left these
-- blank in every section but the cooldown bars.
_G.__aura = { spellId = 5171, name = "Slice and Dice", icon = "x",
              applications = 0, duration = 21, expirationTime = GetTime() + 21, timeMod = 1 }
ns.Auras:ClearCache()
ns.Cooldowns:ClearCache()

R.selfBuffIcon = math.floor(ns.Cooldowns:GetIconState(5171, false, true).remaining + 0.5)
R.selfBuffTracked = math.floor(ns.Auras:GetTrackedState(5171, true).remaining + 0.5)
R.selfBuffBar = ns.Cooldowns:GetBarState(5171, true).phase
-- Unflagged, an icon still shows the cooldown alone -- nothing else changed.
R.selfBuffUnflaggedIcon = ns.Cooldowns:GetIconState(5171, false, false).remaining
-- And it is one of the abilities the picker flags for you.
R.selfBuffAutoFlagged = ns.Constants.IsAuraSpell(5171) and true or false

-- A flagged ability with neither aura up reads as inactive rather than erroring.
_G.__aura = { spellId = 0, name = "None", duration = 0, expirationTime = 0 }
ns.Auras:ClearCache()
R.selfBuffGone = ns.Auras:GetTrackedState(5171, true).active and true or false

_G.__aura = { spellId = 187880, name = "Maelstrom Weapon", applications = 5,
              duration = 30, expirationTime = GetTime() + 12, timeMod = 1 }
_G.__targetAura = { spellId = 8921, name = "Moonfire", sourceUnit = "player",
                    duration = 12, expirationTime = GetTime() + 9, timeMod = 1 }
ns.Auras:ClearCache()
ns.Cooldowns:ClearCache()

-- A debuff cast by someone else on the same target is ignored.
_G.__targetAura = { spellId = 8921, name = "Moonfire", sourceUnit = "party1",
                    duration = 12, expirationTime = GetTime() + 9, timeMod = 1 }
ns.Auras:MarkTargetDirty()
R.dotIgnoresOthers = ns.Cooldowns:GetBarState(8921, true).phase

-- No target: the DoT source is empty and the bar falls back to ready.
_G.__targetAura = nil
_G.__hasTarget = false
ns.Auras:MarkTargetDirty()
R.dotNoTarget = ns.Cooldowns:GetBarState(8921, true).phase

-- A spell with BOTH a cooldown and a DoT (Flame Shock): the DoT is the primary
-- countdown, while the cooldown still drives usability/desaturation. The stub
-- drives cooldowns through __cd (see C_Spell.GetSpellCooldown).
_G.__hasTarget = true
_G.__targetAura = { spellId = 8050, name = "Flame Shock", sourceUnit = "player",
                    duration = 18, expirationTime = GetTime() + 15, timeMod = 1 }
_G.__cd = { start = GetTime(), duration = 6 }   -- 6s cooldown running
ns.Auras:ClearCache()
ns.Cooldowns:ClearCache()
local fs = ns.Cooldowns:GetIconState(8050, false, true)
R.flameShockRemaining = math.floor(fs.remaining + 0.5)   -- the DoT (15), not the CD (6)
R.flameShockOnCdUsable = fs.available and true or false  -- false: still recharging

_G.__cd = nil                                    -- cooldown ready
ns.Cooldowns:ClearCache()
local fsReady = ns.Cooldowns:GetIconState(8050, false, true)
R.flameShockReadyRemaining = math.floor(fsReady.remaining + 0.5)  -- still the DoT (15)
R.flameShockReadyUsable = fsReady.available and true or false     -- true: recastable

_G.__targetAura = nil
_G.__hasTarget = false
ns.Cooldowns:ClearCache()
ns.Auras:ClearCache()

-- The DoT flag round-trips through export/import.
local savedEssentialDot = ns.DB:GetGroup("essential").spells
ns.DB:GetGroup("essential").spells = {
    { spellID = 8921, name = "Moonfire", rankIndependent = true, trackDebuff = true },
    { spellID = 5176, name = "Wrath", rankIndependent = true },
}
local dotImport = ns.Serialization:Import(ns.Serialization:Export())
local mfEntry, wrathEntry
for _, e in ipairs(dotImport.groups.essential.spells) do
    if e.spellID == 8921 then mfEntry = e elseif e.spellID == 5176 then wrathEntry = e end
end
R.dotFlagRoundTrip = (mfEntry and mfEntry.trackDebuff == true
    and wrathEntry and wrathEntry.trackDebuff == nil) and true or false
ns.DB:GetGroup("essential").spells = savedEssentialDot

-- Form-aware ability tags: a Druid's tracked set swaps with the form. One
-- ability tagged cat-only, one bear-only, one caster/moonkin, one untagged (all
-- forms). Form is driven through the signals the code reads -- power for cat and
-- bear, the Moonkin Form aura for moonkin, Mana with no form aura for caster.
_G.UnitClass = function() return "Druid", "DRUID", 11 end
local savedEssential = ns.DB:GetGroup("essential").spells
ns.DB:GetGroup("essential").spells = {
    { spellID = 5176, name = "Wrath", rankIndependent = false, forms = { caster = true, moonkin = true } },
    { spellID = 6807, name = "Maul",  rankIndependent = false, forms = { bear = true } },
    { spellID = 1082, name = "Claw",  rankIndependent = false, forms = { cat = true } },
    { spellID = 1126, name = "Mark of the Wild", rankIndependent = false },
}
local formGroup = ns.Group.Create("essential")

local function FormSpells(powerToken, moonkinUp)
    _G.UnitPowerType = function() return 0, powerToken end
    _G.__aura = moonkinUp
        and { spellId = 24858, name = "Moonkin Form", duration = 0, expirationTime = 0 }
        or { spellId = 0, name = "None", duration = 0, expirationTime = 0 }
    ns.Auras:ClearCache()
    formGroup:Layout()
    local ids = {}
    for _, icon in ipairs(formGroup.icons) do ids[#ids + 1] = icon.spellID end
    table.sort(ids)
    return table.concat(ids, ",")
end

R.formCat     = FormSpells("ENERGY", false)  -- Claw + untagged
R.formBear    = FormSpells("RAGE",   false)  -- Maul + untagged
R.formCaster  = FormSpells("MANA",   false)  -- Wrath + untagged
R.formMoonkin = FormSpells("MANA",   true)   -- Wrath + untagged

-- A non-Druid ignores the tags entirely: every entry shows.
_G.UnitClass = function() return "Rogue", "ROGUE", 4 end
_G.UnitPowerType = function() return 3, "ENERGY" end
ns.Auras:ClearCache()
formGroup:Layout()
local nonDruidIDs = {}
for _, icon in ipairs(formGroup.icons) do nonDruidIDs[#nonDruidIDs + 1] = icon.spellID end
table.sort(nonDruidIDs)
R.formNonDruid = table.concat(nonDruidIDs, ",")

-- Default form tags (#43): a Druid's cat/bear abilities arrive tagged, so
-- shapeshifting swaps them with no hand tagging. Driven through Core's event
-- handler rather than a hand-called Layout -- the wiring is the part that only
-- ran in the client until now.
_G.UnitClass = function() return "Druid", "DRUID", 11 end

local dispatch
for _, candidate in ipairs(_G.__frames) do
    if candidate:GetScript("OnEvent") then dispatch = candidate:GetScript("OnEvent") end
end
R.eventHandlerFound = dispatch ~= nil

-- Put back afterwards: the export/import check below runs on the tagged list
-- this section replaces.
local formTestSpells = ns.DB:GetGroup("essential").spells

R.defaultTagCat = ns.Constants.DefaultFormsFor(1082) and ns.Constants.DefaultFormsFor(1082).cat or false
R.defaultTagBear = ns.Constants.DefaultFormsFor(6807) and ns.Constants.DefaultFormsFor(6807).bear or false
-- Caster spells are deliberately left alone (SoD runes cast in more than one form).
R.defaultTagCaster = ns.Constants.DefaultFormsFor(5176) == nil
-- Each entry gets its own table, or tagging one ability would tag every other.
R.defaultTagCopies = ns.Constants.DefaultFormsFor(1082) ~= ns.Constants.DefaultFormsFor(1082)

ns.DB:GetGroup("essential").spells = {
    { spellID = 1082, name = "Claw", forms = ns.Constants.DefaultFormsFor(1082) },
    { spellID = 6807, name = "Maul", forms = ns.Constants.DefaultFormsFor(6807) },
    { spellID = 1126, name = "Mark of the Wild" },
}
local shiftGroup = ns.Group.Create("essential")
shiftGroup.unlocked = false
shiftGroup:Layout()

local function TrackedAfterShift(powerToken)
    _G.UnitPowerType = function() return 0, powerToken end
    ns.Auras:ClearCache()
    dispatch(nil, "UPDATE_SHAPESHIFT_FORM")
    local ids = {}
    for _, icon in ipairs(shiftGroup.icons) do ids[#ids + 1] = icon.spellID end
    table.sort(ids)
    return table.concat(ids, ",")
end

R.shiftToCat = TrackedAfterShift("ENERGY")
R.shiftToBear = TrackedAfterShift("RAGE")
R.shiftToCaster = TrackedAfterShift("MANA")

-- The backfill tags a layout built before the defaults existed, once, and never
-- touches an ability someone tagged by hand.
local legacy = {
    groups = {
        essential = { spells = {
            { spellID = 1082, name = "Claw" },
            { spellID = 6807, name = "Maul", forms = { cat = true, bear = true } },
            { spellID = 1126, name = "Mark of the Wild" },
        } },
    },
}
R.backfillRan = ns.DB:BackfillFormTags(legacy)
R.backfillTagged = legacy.groups.essential.spells[1].forms
    and legacy.groups.essential.spells[1].forms.cat or false
R.backfillKeptManual = legacy.groups.essential.spells[2].forms.cat
    and legacy.groups.essential.spells[2].forms.bear or false
R.backfillLeftUntagged = legacy.groups.essential.spells[3].forms == nil
R.backfillOnlyOnce = ns.DB:BackfillFormTags(legacy)

-- A non-Druid is untouched, and is not stamped as done -- a Druid alt sharing
-- the profile still gets the pass later.
_G.UnitClass = function() return "Rogue", "ROGUE", 4 end
local rogueProfile = { groups = { essential = { spells = { { spellID = 1082, name = "Claw" } } } } }
R.backfillSkipsNonDruid = ns.DB:BackfillFormTags(rogueProfile)
R.backfillLeavesFlagClear = rogueProfile.formTagsApplied == nil
_G.UnitClass = function() return "Druid", "DRUID", 11 end

_G.UnitPowerType = function() return 0, "MANA" end
ns.DB:GetGroup("essential").spells = formTestSpells

-- Form tags round-trip through export/import.
ns.DB:GetGroup("essential").spells[3].forms = { cat = true }
local formExport = ns.Serialization:Export()
local formImport = ns.Serialization:Import(formExport)
local importedClaw
for _, entry in ipairs(formImport.groups.essential.spells) do
    if entry.spellID == 1082 then importedClaw = entry end
end
R.formRoundTrip = importedClaw and importedClaw.forms and importedClaw.forms.cat == true
    and importedClaw.forms.bear == nil and true or false

-- Restore the group, power and the stub's default player buff for the tests
-- downstream (the media/aura checks expect Maelstrom Weapon up on the player).
ns.DB:GetGroup("essential").spells = savedEssential
_G.UnitPowerType = function() return 0, "MANA" end
_G.__aura = { spellId = 187880, name = "Maelstrom Weapon", applications = 5,
              duration = 30, expirationTime = GetTime() + 12, timeMod = 1 }
ns.Auras:ClearCache()

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

-- The right-click menu on a tracked icon. It is a free-floating frame owned by
-- nothing, so what it does on a click, and whether anything ever closes it, is
-- worth pinning down.
_G.UnitClass = function() return "Druid", "DRUID", 11 end
ns.DB:GetGroup("essential").spells = {
    { spellID = 1082, name = "Claw", rankIndependent = true },
}
ns.SpellPicker:Show("cooldowns")

local menuIcon
for _, section in ipairs({ _G.CDMCSettingsFrame }) do
    -- The tracked icon is the first button carrying a group key.
    for _, candidate in ipairs(_G.__frames) do
        if candidate.cdmcIsIcon and candidate.groupKey == "essential" and candidate.spellID == 1082 then
            menuIcon = candidate
        end
    end
end
R.menuIconFound = menuIcon ~= nil

menuIcon:GetScript("OnClick")(menuIcon, "RightButton")
R.menuOpens = _G.__dropdownOpen

local items = _G.__buildDropdown(_G.CDMCFormMenu)
local auraItem, catItem
for _, item in ipairs(items) do
    if item.text and item.text:find("Track its aura", 1, true) then auraItem = item end
    if item.text == "Cat" then catItem = item end
end
R.menuHasAura = auraItem ~= nil
R.menuHasForms = catItem ~= nil

-- The aura toggle is a single decision: it applies and the menu closes.
auraItem.func()
R.menuAuraApplied = ns.DB:GetGroup("essential").spells[1].trackDebuff == true
R.menuClosesAfterAura = _G.__dropdownOpen

-- Form ticks are picked in combination, so that one stays open -- and repaints,
-- since toggling one form changes what the others show.
menuIcon:GetScript("OnClick")(menuIcon, "RightButton")
_G.__buildDropdown(_G.CDMCFormMenu)
local before = _G.__dropdownRefreshed
catItem.func()
R.menuStaysOpenForForms = _G.__dropdownOpen
R.menuRepaintsForms = _G.__dropdownRefreshed > before

-- Nothing else closes it, so the picker has to: hiding the window must not
-- leave a menu floating over the game world.
ns.SpellPicker:Hide()
R.menuClosedWithPicker = _G.__dropdownOpen
ns.SpellPicker:Show("cooldowns")
_G.UnitClass = function() return "Shaman", "SHAMAN", 7 end

-- Every tab must render. A panel tab builds its own widgets instead of spell
-- sections, so a mistake there throws rather than looking merely empty.
ns.SpellPicker:Show("profiles")
R.profilesTabShown = _G.CDMCSettingsFrame:IsShown()
ns.SpellPicker:Show("cooldowns")

-- LibSharedMedia wrapper: the library is absent under the stub, so an empty or
-- unknown key falls back to the built-in path.
R.mediaFontFallback = ns.Media.Fetch("font", "", "FALLBACK.ttf")
R.mediaBarFallback = ns.Media.Fetch("statusbar", "Unregistered", "FALLBACK.tga")

-- The built-in media we register with LibSharedMedia: every path must sit under
-- Interface\, since LSM silently refuses anything else and the picker would then
-- offer a name that fetches nothing. (The library itself is absent here, so this
-- checks the table rather than the registration.)
local badMedia = 0
local mediaCount = 0
for _, entries in pairs(ns.Media.BUILTIN) do
    for _, path in pairs(entries) do
        mediaCount = mediaCount + 1
        if not path:lower():find("^interface") then badMedia = badMedia + 1 end
    end
end
R.builtinMediaBadPaths = badMedia
R.builtinMediaRegistered = mediaCount > 0
R.builtinMediaWithoutLSM = ns.Media.RegisterBuiltins()

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

-- Styling (#34): border, background colour, tick segments, percentage text, and
-- that the new appearance fields round-trip. Reset the power bar's visibility so
-- it renders regardless of target.
local styleBar = ns.bars.power
ns.DB:GetBar("power").appearance.visibility = "Always"
ns.DB:GetBar("power").appearance.borderSize = 2
ns.DB:GetBar("power").appearance.borderColor = "0,0,0,1"
ns.DB:GetBar("power").appearance.bgColor = "0,0,0,0.25"
styleBar:Layout()
R.borderShown = styleBar.borders.top:IsShown()
R.bgAlpha = ("%.2f"):format(styleBar.frame.background.__color[4])

ns.DB:GetBar("power").appearance.borderSize = 0
styleBar:Layout()
R.borderHidden = styleBar.borders.top:IsShown()

-- Percentage text: power is 40/100 -> "40%".
_G.UnitPower = function() return 40 end
_G.UnitPowerMax = function() return 100 end
ns.DB:GetBar("power").appearance.showPercent = true
styleBar:Update()
R.percentText = styleBar.text:GetText()
ns.DB:GetBar("power").appearance.showPercent = false

-- Smooth fill still lays out (the eased path rides an OnUpdate the stub never
-- fires; this only proves it does not error).
ns.DB:GetBar("power").appearance.animate = true
styleBar:Layout()
R.animateLaidOut = (styleBar.frame:GetWidth() or 0) > 0
ns.DB:GetBar("power").appearance.animate = false

-- Tick segment style on the class-resource bar: a continuous fill with divider
-- ticks instead of pips. Run as a Rogue so the source is combo points.
_G.UnitClass = function() return "Rogue", "ROGUE", 4 end
_G.GetComboPoints = function() return 3 end
ns.DB:GetBar("combo").appearance.segmentStyle = "ticks"
local tickBar = ns.ResourceBar.Create("combo")
tickBar:Layout()
tickBar:Update()
R.tickStatusShown = tickBar.statusBar:IsShown()
R.tickCount = #tickBar.ticks
R.tickFill = tickBar.statusBar:GetValue()
R.tickPipsHidden = tickBar.pips[1] == nil or (not tickBar.pips[1]:IsShown())
ns.DB:GetBar("combo").appearance.segmentStyle = "pips"
_G.GetComboPoints = function() return 0 end
_G.UnitClass = function() return "Shaman", "SHAMAN", 7 end

-- Border art (#38): a LibSharedMedia border draws through the backdrop API when
-- the client has one, and falls back to the solid edges when it does not. The
-- library is absent under the stub, so the fetch is stood in for -- what is under
-- test is the rendering path, not LSM itself.
local realFetch = ns.Media.Fetch
ns.Media.Fetch = function(mediatype, key, fallback)
    if mediatype == "border" and key == "Chunky" then
        return "Interface/Test/ChunkyBorder"
    end
    return realFetch(mediatype, key, fallback)
end

ns.DB:GetBar("power").appearance.borderSize = 2
ns.DB:GetBar("power").appearance.borderTexture = "Chunky"
styleBar:Layout()
R.borderEdgeFile = styleBar.borderFrame.__backdrop and styleBar.borderFrame.__backdrop.edgeFile
R.borderFrameShown = styleBar.borderFrame:IsShown()
R.borderSolidHiddenWithArt = styleBar.borders.top:IsShown()

-- An unknown border name is not art: the solid edges come back rather than the
-- bar losing its border altogether.
ns.DB:GetBar("power").appearance.borderTexture = "Not Registered"
styleBar:Layout()
R.borderUnknownFallsBack = styleBar.borders.top:IsShown()

-- No backdrop API (Classic Era may ship without it): same fallback, no error.
ns.DB:GetBar("power").appearance.borderTexture = "Chunky"
_G.__setBackdropPresent(false)
styleBar:Layout()
R.borderNoBackdropFallsBack = styleBar.borders.top:IsShown()
R.borderFrameHiddenNoBackdrop = styleBar.borderFrame:IsShown()
_G.__setBackdropPresent(true)

ns.Media.Fetch = realFetch
ns.DB:GetBar("power").appearance.borderTexture = ""

-- Fill colour override: pinned, the bar draws it instead of the power colour.
ns.DB:GetBar("power").appearance.fillColor = "1,0,0,1"
styleBar:Update()
R.fillOverride = ("%.2f/%.2f/%.2f"):format(styleBar.statusBar.__barColor[1],
    styleBar.statusBar.__barColor[2], styleBar.statusBar.__barColor[3])
ns.DB:GetBar("power").appearance.fillColor = ""
styleBar:Update()
R.fillAuto = ("%.2f/%.2f/%.2f"):format(styleBar.statusBar.__barColor[1],
    styleBar.statusBar.__barColor[2], styleBar.statusBar.__barColor[3])

-- Font outline: the flags reach SetFont, and "" really means none.
ns.DB:GetBar("power").appearance.fontOutline = "THICKOUTLINE"
styleBar:Layout()
R.fontOutline = styleBar.text.__fontFlags
ns.DB:GetBar("power").appearance.fontOutline = ""
styleBar:Layout()
R.fontOutlineNone = styleBar.text.__fontFlags

-- A chosen face, then back to Default: the built-in font has to return, which it
-- only does because the font object is re-applied before the face is read.
local realFontFetch = ns.Media.Fetch
ns.Media.Fetch = function(mediatype, key, fallback)
    if mediatype == "font" and key == "Blocky" then return "Interface/Test/Blocky.ttf" end
    return realFontFetch(mediatype, key, fallback)
end
ns.DB:GetBar("power").appearance.fontFace = "Blocky"
styleBar:Layout()
R.fontFaceApplied = styleBar.text.__fontFile
ns.DB:GetBar("power").appearance.fontFace = ""
styleBar:Layout()
R.fontFaceDefault = styleBar.text.__fontFile
ns.Media.Fetch = realFontFetch

-- The colour swatches drive Blizzard's picker and write a packed string back;
-- right-click puts the default back.
ns.BarPanel:Show("power")
local bgSwatch = _G.CDMCBarPanel.bgColor
bgSwatch:GetScript("OnClick")(bgSwatch, "LeftButton")
_G.ColorPickerFrame:SetColorRGB(0.2, 0.4, 0.6)
_G.ColorPickerFrame.__color[4] = 0.8
_G.ColorPickerFrame.__info.swatchFunc()
R.swatchWrites = ns.DB:GetBar("power").appearance.bgColor

bgSwatch:GetScript("OnClick")(bgSwatch, "RightButton")
R.swatchResets = ns.DB:GetBar("power").appearance.bgColor

-- Cancelling restores what was stored, which for the unset fill override is ""
-- and not the colour the picker was seeded with.
local fillSwatch = _G.CDMCBarPanel.fillColor
fillSwatch:GetScript("OnClick")(fillSwatch, "LeftButton")
_G.ColorPickerFrame:SetColorRGB(1, 1, 0)
_G.ColorPickerFrame.__info.swatchFunc()
R.fillSwatchWrites = ns.DB:GetBar("power").appearance.fillColor ~= ""
_G.ColorPickerFrame.__info.cancelFunc()
R.fillSwatchCancels = ns.DB:GetBar("power").appearance.fillColor
ns.BarPanel:Hide()

-- New styling fields round-trip through export/import.
ns.DB:GetBar("power").appearance.borderSize = 3
ns.DB:GetBar("power").appearance.bgColor = "0.1,0.2,0.3,0.4"
ns.DB:GetBar("power").appearance.borderTexture = "Chunky"
ns.DB:GetBar("power").appearance.fillColor = "0.500,0.250,0.125,1.000"
ns.DB:GetBar("power").appearance.fontOutline = "OUTLINE"
ns.DB:GetBar("combo").appearance.segmentStyle = "ticks"
local styleImport = ns.Serialization:Import(ns.Serialization:Export())
R.rtBorderSize = styleImport.bars.power.appearance.borderSize
R.rtBgColor = styleImport.bars.power.appearance.bgColor
R.rtSegment = styleImport.bars.combo.appearance.segmentStyle
R.rtBorderTexture = styleImport.bars.power.appearance.borderTexture
R.rtFillColor = styleImport.bars.power.appearance.fillColor
R.rtFontOutline = styleImport.bars.power.appearance.fontOutline
ns.DB:GetBar("combo").appearance.segmentStyle = "pips"
ns.DB:GetBar("power").appearance.borderTexture = ""
ns.DB:GetBar("power").appearance.fillColor = ""
ns.DB:GetBar("power").appearance.fontOutline = ""

-- PackColor is UnpackColor's inverse: what a swatch writes reads back the same.
R.packRoundTrip = ("%.2f/%.2f/%.2f/%.2f"):format(
    ns.Constants.UnpackColor(ns.Constants.PackColor(0.25, 0.5, 0.75, 0.6), 0, 0, 0, 0))

-- LibEQOL Edit Mode registration. In game this is the surface a player clicks --
-- the library owns selection, so our own click-to-open panel never fires -- and
-- it went untested until a dropdown shipped blank.
R.libEQOLRegistered = ns.EditMode:Register() and true or false

local lem = _G.__editMode

-- Every dropdown must carry a `values` list. The dialog's dropdown builds its
-- menu from `values` (or a `generator`) and ignores `optionfunc`, so a setting
-- with only the latter renders as an empty box with no menu.
local emptyDropdowns, dropdownCount = {}, 0
for _, settings in pairs(lem.settings) do
    for _, setting in ipairs(settings) do
        if setting.kind == lem.SettingType.Dropdown then
            dropdownCount = dropdownCount + 1
            if type(setting.values) ~= "table" or #setting.values == 0 then
                emptyDropdowns[#emptyDropdowns + 1] = setting.name
            end
        end
    end
end
R.dropdownCount = dropdownCount
R.emptyDropdowns = table.concat(emptyDropdowns, ",")

-- Icon Direction's choices follow the orientation, and the dialog holds the very
-- table registered at login -- so the setter has to refill it in place.
local function FindSetting(frame, name)
    for _, setting in ipairs(lem.settings[frame] or {}) do
        if setting.name == name then return setting end
    end
end

local essentialFrame = ns.groups.essential.frame
local direction = FindSetting(essentialFrame, "Icon Direction")
local orientation = FindSetting(essentialFrame, "Orientation")
R.directionBefore = direction.values[1].text .. "," .. direction.values[2].text

local sameTable = direction.values
orientation.set(nil, "Vertical")
R.directionAfter = direction.values[1].text .. "," .. direction.values[2].text
R.directionSameTable = direction.values == sameTable
R.directionValueFixed = ns.DB:GetGroup("essential").appearance.iconDirection
orientation.set(nil, "Horizontal")

-- The styling options belong in the Edit Mode dialog itself: LibEQOL owns the
-- click while it drives Edit Mode, so a panel that opens on a click is not a
-- surface a player can reach there.
local powerSettings = lem.settings[ns.bars.power.frame] or {}
local byName = {}
for _, setting in ipairs(powerSettings) do
    if setting.name then byName[setting.name] = setting end
end

local missing = {}
for _, name in ipairs({ "Bar Texture", "Border Size", "Border Texture", "Border Colour",
                        "Background Colour", "Custom Fill Colour", "Font", "Font Outline",
                        "Text Align", "Show Percentage", "Smooth Fill", "Edge Spark" }) do
    if not byName[name] then missing[#missing + 1] = name end
end
R.barStyleMissing = table.concat(missing, ",")

-- Every styling row hangs off the collapsible header, so the basics at the top
-- of the dialog are not buried under fourteen more.
local header, orphans = nil, 0
for _, setting in ipairs(powerSettings) do
    if setting.kind == lem.SettingType.Collapsible then header = setting.id end
end
for _, name in ipairs({ "Bar Texture", "Border Size", "Font", "Edge Spark" }) do
    if byName[name].parentId ~= header then orphans = orphans + 1 end
end
R.styleHeader = tostring(header)
R.styleOrphans = orphans
-- The rows that were there before stay at the top level.
R.enabledNotNested = byName["Enabled"].parentId == nil

-- Combo-only rows sit on the class-resource bar and nowhere else.
local comboSettings = lem.settings[ns.bars.combo.frame] or {}
local comboNames = {}
for _, setting in ipairs(comboSettings) do
    if setting.name then comboNames[setting.name] = true end
end
R.comboHasSource = comboNames["Resource Source"] and true or false
R.powerHasSource = byName["Resource Source"] and true or false

-- A media dropdown speaks display strings: "" reads as Default, and a name
-- registered after login still reaches the menu, since the list is refilled from
-- `get` (the only hook the dialog gives us).
ns.DB:GetBar("power").appearance.barTexture = ""
R.mediaDropdownDefault = byName["Bar Texture"].get()
byName["Bar Texture"].set(nil, "Solid")
R.mediaDropdownSet = ns.DB:GetBar("power").appearance.barTexture
byName["Bar Texture"].set(nil, "Default")
R.mediaDropdownCleared = ns.DB:GetBar("power").appearance.barTexture

-- A label/value dropdown maps both ways.
byName["Font Outline"].set(nil, "Thick Outline")
R.choiceDropdownSet = ns.DB:GetBar("power").appearance.fontOutline
R.choiceDropdownGet = byName["Font Outline"].get()

-- Colours arrive as {r,g,b,a} and are stored packed.
byName["Border Colour"].set(nil, { r = 0.25, g = 0.5, b = 0.75, a = 0.5 })
R.colorSettingStored = ns.DB:GetBar("power").appearance.borderColor
local readBack = byName["Border Colour"].get()
R.colorSettingRead = ("%.2f/%.2f"):format(readBack.r, readBack.a)

-- The fill override: the checkbox holds "is there one at all", the swatch holds
-- the colour, and unticking clears it back to the resource's own.
byName["Custom Fill Colour"].set(nil, true)
R.fillCheckOn = byName["Custom Fill Colour"].get() and true or false
byName["Custom Fill Colour"].colorSet(nil, { r = 1, g = 0, b = 0, a = 1 })
R.fillCheckColor = ns.DB:GetBar("power").appearance.fillColor
byName["Custom Fill Colour"].set(nil, false)
R.fillCheckOff = ns.DB:GetBar("power").appearance.fillColor

-- The UI probe walks the client for templates and libraries; under the stub
-- everything answers yes, so this only proves it runs without erroring -- which
-- is the point, since it is what a player is asked to run when something looks
-- wrong.
ns.Core:PrintUIProbe()
R.uiProbeRan = true

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
    check("unflagged bar ignores target dot", results["dotUnflaggedPhase"], "ready")
    check("dot flag surfaces in tracked buffs", results["dotBuffActive"], True)
    check("unflagged buff ignores target dot", results["dotBuffUnflagged"], False)
    check("dot flag drives icon countdown", results["dotIconRemaining"], 9)
    check("self-buff drives the icon countdown", results["selfBuffIcon"], 21)
    check("self-buff drives tracked buffs", results["selfBuffTracked"], 21)
    check("self-buff drives the cooldown bar", results["selfBuffBar"], "active")
    check("unflagged self-buff still cooldown-only", results["selfBuffUnflaggedIcon"], 0)
    check("self-buff auto-flags for aura tracking", results["selfBuffAutoFlagged"], True)
    check("flagged ability with no aura is inactive", results["selfBuffGone"], False)
    check("target dot ignores others' casts", results["dotIgnoresOthers"], "ready")
    check("target dot falls back to ready with no target", results["dotNoTarget"], "ready")
    check("flame shock icon shows dot not cd", results["flameShockRemaining"], 15)
    check("flame shock desaturates on cooldown", results["flameShockOnCdUsable"], False)
    check("flame shock keeps dot when cd ready", results["flameShockReadyRemaining"], 15)
    check("flame shock usable when cd ready", results["flameShockReadyUsable"], True)
    check("dot flag round-trips", results["dotFlagRoundTrip"], True)
    check("druid form cat shows cat + untagged", results["formCat"], "1082,1126")
    check("druid form bear shows bear + untagged", results["formBear"], "1126,6807")
    check("druid form caster shows caster + untagged", results["formCaster"], "1126,5176")
    check("druid form moonkin shows moonkin + untagged", results["formMoonkin"], "1126,5176")
    check("non-druid ignores form tags", results["formNonDruid"], "1082,1126,5176,6807")
    check("form tags round-trip", results["formRoundTrip"], True)
    check("core event handler reachable", results["eventHandlerFound"], True)
    check("cat ability tagged by default", results["defaultTagCat"], True)
    check("bear ability tagged by default", results["defaultTagBear"], True)
    check("caster spell left untagged", results["defaultTagCaster"], True)
    check("each entry gets its own tag table", results["defaultTagCopies"], True)
    check("shapeshift event shows cat set", results["shiftToCat"], "1082,1126")
    check("shapeshift event shows bear set", results["shiftToBear"], "1126,6807")
    check("shapeshift event shows caster set", results["shiftToCaster"], "1126")
    check("backfill runs for a druid", results["backfillRan"], True)
    check("backfill tags an untagged ability", results["backfillTagged"], True)
    check("backfill keeps hand-set tags", results["backfillKeptManual"], True)
    check("backfill leaves unlisted spells alone", results["backfillLeftUntagged"], True)
    check("backfill runs only once", results["backfillOnlyOnce"], False)
    check("backfill skips a non-druid", results["backfillSkipsNonDruid"], False)
    check("backfill leaves a non-druid unflagged", results["backfillLeavesFlagClear"], True)
    check("highlight on proc", results["glowOn"], True)
    check("highlight clears", results["glowOff"], False)
    check("highlight off when disabled", results["glowDisabled"], False)
    check("bar hidden again when locked", results["barHiddenAgain"], False)
    check("bar shown when enabled", results["barShownWhenEnabled"], True)
    check("bar position reverted", results["barPositionReverted"], 11)
    check("export format", results["exportPrefix"], "CDMC3:")
    check("round-trip bar width", results["importedBarWidth"], 317)
    check("round-trip spell name", results["importedSpellName"], "Maelstrom Weapon")
    check("picker opens", results["pickerShown"], True)
    check("share window opens", results["shareShown"], True)
    check("edit panel opens", results["panelShown"], True)
    check("highlight checkbox enables", results["highlightCheckboxOn"], True)
    check("highlight checkbox disables", results["highlightCheckboxOff"], False)
    check("tracked icon found for the menu", results["menuIconFound"], True)
    check("right-click opens the entry menu", results["menuOpens"], True)
    check("menu offers aura tracking", results["menuHasAura"], True)
    check("menu offers form tags for a druid", results["menuHasForms"], True)
    check("aura toggle applies", results["menuAuraApplied"], True)
    check("menu closes after the aura toggle", results["menuClosesAfterAura"], False)
    check("menu stays open for form ticks", results["menuStaysOpenForForms"], True)
    check("form ticks repaint the menu", results["menuRepaintsForms"], True)
    check("closing the picker closes the menu", results["menuClosedWithPicker"], False)
    check("profiles tab renders", results["profilesTabShown"], True)
    check("media font fallback", results["mediaFontFallback"], "FALLBACK.ttf")
    check("media bar fallback", results["mediaBarFallback"], "FALLBACK.tga")
    check("built-in media paths are under Interface", results["builtinMediaBadPaths"], 0)
    check("built-in media is offered", results["builtinMediaRegistered"], True)
    check("built-in media skipped without LSM", results["builtinMediaWithoutLSM"], False)
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
    check("border shows when sized", results["borderShown"], True)
    check("border hides at size 0", results["borderHidden"], False)
    check("background colour applies", results["bgAlpha"], "0.25")
    check("percentage text", results["percentText"], "40%")
    check("smooth-fill bar lays out", results["animateLaidOut"], True)
    check("tick style shows status bar", results["tickStatusShown"], True)
    check("tick divider count", results["tickCount"], 4)
    check("tick style fills the bar", results["tickFill"], 3)
    check("tick style hides pips", results["tickPipsHidden"], True)
    check("border art uses the edge file", results["borderEdgeFile"], "Interface/Test/ChunkyBorder")
    check("border art frame shown", results["borderFrameShown"], True)
    check("border art replaces the solid edges", results["borderSolidHiddenWithArt"], False)
    check("unknown border falls back to solid", results["borderUnknownFallsBack"], True)
    check("no backdrop falls back to solid", results["borderNoBackdropFallsBack"], True)
    check("no backdrop hides the border frame", results["borderFrameHiddenNoBackdrop"], False)
    check("fill colour override applies", results["fillOverride"], "1.00/0.00/0.00")
    check("fill colour returns to the resource's own", results["fillAuto"], "0.00/0.55/1.00")
    check("font outline applies", results["fontOutline"], "THICKOUTLINE")
    check("empty outline means none", results["fontOutlineNone"], "")
    check("font face applies", results["fontFaceApplied"], "Interface/Test/Blocky.ttf")
    check("font face returns to the built-in", results["fontFaceDefault"], "Fonts\\FRIZQT__.TTF")
    check("swatch writes a packed colour", results["swatchWrites"], "0.200,0.400,0.600,0.800")
    check("right-click resets a swatch", results["swatchResets"], "0,0,0,0.5")
    check("fill swatch pins a colour", results["fillSwatchWrites"], True)
    check("cancel restores the unset fill", results["fillSwatchCancels"], "")
    check("border size round-trips", results["rtBorderSize"], 3)
    check("bg colour round-trips", results["rtBgColor"], "0.1,0.2,0.3,0.4")
    check("segment style round-trips", results["rtSegment"], "ticks")
    check("border texture round-trips", results["rtBorderTexture"], "Chunky")
    check("fill colour round-trips", results["rtFillColor"], "0.500,0.250,0.125,1.000")
    check("font outline round-trips", results["rtFontOutline"], "OUTLINE")
    check("packed colour round-trips", results["packRoundTrip"], "0.25/0.50/0.75/0.60")
    check("ui probe runs", results["uiProbeRan"], True)
    check("LibEQOL registration succeeds", results["libEQOLRegistered"], True)
    check("edit mode dropdowns registered", results["dropdownCount"] > 0, True)
    check("no dropdown registered without values", results["emptyDropdowns"], "")
    check("icon direction follows horizontal", results["directionBefore"], "Down,Up")
    check("icon direction follows vertical", results["directionAfter"], "Right,Left")
    check("icon direction list refilled in place", results["directionSameTable"], True)
    check("stale icon direction corrected", results["directionValueFixed"], "Right")
    check("bar styling is in the edit mode dialog", results["barStyleMissing"], "")
    check("styling sits under a collapsible header", results["styleHeader"], "cdmcBarStyle")
    check("no styling row outside that header", results["styleOrphans"], 0)
    check("existing rows stay at the top level", results["enabledNotNested"], True)
    check("resource source on the class bar", results["comboHasSource"], True)
    check("resource source not on other bars", results["powerHasSource"], False)
    check("media dropdown shows Default for ''", results["mediaDropdownDefault"], "Default")
    check("media dropdown stores the name", results["mediaDropdownSet"], "Solid")
    check("media dropdown clears on Default", results["mediaDropdownCleared"], "")
    check("choice dropdown stores the value", results["choiceDropdownSet"], "THICKOUTLINE")
    check("choice dropdown shows the label", results["choiceDropdownGet"], "Thick Outline")
    check("colour setting packs the value", results["colorSettingStored"], "0.250,0.500,0.750,0.500")
    check("colour setting reads back", results["colorSettingRead"], "0.25/0.50")
    check("fill override ticks on", results["fillCheckOn"], True)
    check("fill override takes a colour", results["fillCheckColor"], "1.000,0.000,0.000,1.000")
    check("fill override clears when unticked", results["fillCheckOff"], "")
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
