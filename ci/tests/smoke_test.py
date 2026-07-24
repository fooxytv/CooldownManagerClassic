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
local health = ns.ResourceBar.Create("health")
ns.DB:GetBar("health").enabled = false
health:Layout()
R.barHiddenWhenDisabled = health.frame:IsShown()

ns.EditMode:SetManualUnlock(true)
R.barShownWhenUnlocked = health.frame:IsShown()
R.barDraggable = health.unlocked and true or false
R.barRendersWhenUnlocked = health.text:GetText()

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

R.artMask = ns.Icon.art.mask and true or false
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
    check("bar hidden again when locked", results["barHiddenAgain"], False)
    check("bar shown when enabled", results["barShownWhenEnabled"], True)
    check("bar position reverted", results["barPositionReverted"], 11)
    check("export format", results["exportPrefix"], "CDMC2:")
    check("round-trip bar width", results["importedBarWidth"], 317)
    check("round-trip spell name", results["importedSpellName"], "Maelstrom Weapon")
    check("picker opens", results["pickerShown"], True)
    check("share window opens", results["shareShown"], True)
    check("edit panel opens", results["panelShown"], True)
    check("atlas probe", results["artMask"], with_art)


run(with_art=True)
run(with_art=False)

print()
if failures:
    print(f"smoke_test: {len(failures)} failure(s)")
    sys.exit(1)
print("smoke_test: all checks passed")
