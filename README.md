# Cooldown Manager Classic

A Retail-style grouped cooldown, charge and buff display for WoW Classic, without
the configuration burden of WeakAuras or TellMeWhen.

Install it, open the picker, tick the abilities that matter, and you get centred
rows of icons with swipes, countdowns and buff highlights.

```
       Essential cooldowns
    [ Starfire ] [ Wrath ] [ Innervate ]

           Utility
       [ Barkskin ] [ Rebirth ]

         Tracked buffs
       [ Clearcasting ] [ Thorns ]
```

## Status

Early alpha. Targets **Classic Era 1.15.9** (`## Interface: 11509`), which also
covers Season of Discovery since SoD runs on the Era client.

## Design

Blizzard's Retail Cooldown Manager is backed by `C_CooldownViewer`, a curated
ability database plus a layout service that Classic does not have. So this is
not a port of `Blizzard_CooldownViewer`; it reproduces the *experience* on top of
ordinary Classic APIs — the spellbook, `GetSpellCooldown`, `GetSpellCharges` and
the player's auras.

```
core/Compat.lua       API wrappers - the only file that touches C_Spell,
                      C_SpellBook, C_UnitAuras or their pre-1.15 equivalents
core/Constants.lua    Group order, labels, defaults
core/Database.lua     SavedVariables, profiles, spell list editing
core/Serialization.lua  Profile import/export strings
core/Spellbook.lua    Spellbook scan and rank resolution
core/Core.lua         Events, refresh loop, slash commands

tracking/Cooldowns.lua  Cooldown and charge state
tracking/Auras.lua      Player aura state

ui/Icon.lua           Pooled icon widget
ui/BuffBar.lua        Pooled buff bar widget (icon + draining bar)
ui/Group.lua          Centred icon row, drag handling
ui/EditMode.lua       Edit Mode integration and manual unlock
ui/SpellPicker.lua    Spell selection interface
ui/ProfileShare.lua   Import / export window

data/Presets.lua      Class starter layouts
```

### Spell ranks

Classic gives every rank of a spell its own ID, so a profile exported at level 60
would break for a level 20 character. Entries are stored rank-independent:

```lua
{ spellID = 9912, name = "Wrath", rankIndependent = true }
```

`Spellbook:Resolve()` looks the entry up by name and returns whichever rank the
character actually knows. A spell the character cannot currently cast — an
unlearned rank, or a Season of Discovery rune that is not engraved — is hidden
rather than deleted, and reappears on its own when it becomes available.

### Tracked buffs

Retail draws tracked buffs two ways, through two separate Edit Mode systems:
`BuffIconCooldownViewer` (a row of 40px icons) and `BuffBarCooldownViewer` (a
column of 220x30 bars, each an icon, the spell name, a draining bar and the time
left). Here that is one group with a **Display** setting of `Icons` or `Bars`,
and the bar geometry is Blizzard's, scaled from `Const.BAR_TEMPLATE`.

Both follow `CooldownViewerBuffItemMixin` rather than the cooldown mixins, which
is a real visual difference and not an oversight:

- the swipe is the dark cooldown colour, *not* the pale `ITEM_AURA_COLOR` — see
  `CooldownViewerBuffIconItemMixin:GetCooldownSwipeColor`
- buff icons are never desaturated and never tinted by usability; only
  `CooldownViewerCooldownItemMixin` does that, and the buff templates do not
  inherit it

One deliberate departure: an aura with no timer fills its bar instead of leaving
it empty. Blizzard leaves it empty, which is fine on Retail and misleading in
Classic, where stances, aspects and the like are permanent.

### Cooldown bars

A fourth group, **Cooldown Bars**, that Retail's Cooldown Manager has no
equivalent for. It reuses the buff-bar widget but is a Classic-only addition,
for watching a defensive or utility cooldown at a glance — Barkskin, Vampiric
Blood, Ignore Pain — where a swipe on a small icon is hard to read.

What it tracks is the ability's *effect*, not merely its recharge. For a
Cooldown Bars entry the state is merged in `Cooldowns:GetBarState`: the aura the
ability applies takes precedence, so the bar first shows how long the effect
lasts (Barkskin's 8s), then — in the default **Effect + Cooldown** mode — the
recharge, dimmed, then a full bar when it is ready again. The **Effect Only**
mode drops the recharge for Retail's simpler tracked-bar behaviour: the bar is
filled only while the effect is up.

The aura is matched by the ability's own spell ID, which is the same ID for the
great majority of self-buff defensives. Where the applied aura has a different
ID it is not found and the bar shows the recharge, no worse than an icon.

The group is purely additive — the Essential and Utility icon groups are
untouched. It appears as its own **Cooldown Bars** section in the picker's
Cooldowns tab, and drag a spell into it to track it there.

### Edit Mode

Blizzard has no supported way for an addon to register its own Edit Mode system,
so the groups hook `EditMode.Enter` / `EditMode.Exit` and draw their own drag
handles, with `SaveLayouts` and `RevertAllChanges` hooked for persistence. If the
client has no Edit Mode, `/cdmc unlock` gives the same behaviour.

### Profile strings

```
CDMC2:DRUID:era:<base64 payload>
```

A line-based grammar rather than serialised Lua — addons cannot `loadstring`, so
a general format would need a general parser. Not compatible with Retail Cooldown
Manager strings, which encode internal cooldown IDs.

Format 2 carries the whole profile: every appearance field, each group's
position and enabled state, spell names alongside their IDs, and the resource
bars. Format 1 carried only the spell list plus icon size, spacing, growth and
position, so anything else silently reverted to defaults on import — including,
once bars existed, every bar setting.

Appearance fields are written as sorted `key=<typed value>` lines rather than a
fixed field order, each value tagged `b`/`n`/`s` for its type. A string written
by a build that knows more settings than yours still imports; the keys it does
not recognise simply ride along. Format 1 strings are still read, and a string
claiming a newer format is refused rather than half-parsed.

Import never overwrites the active profile: it lands in a new one named after
the exporting class and switches to it, so a bad string costs nothing.

## Commands

| Command | Effect |
| --- | --- |
| `/cdmc` or `/cdm` | Open the spell picker |
| `/cdme` or `/cdmedit` | Toggle edit mode |
| `/cdmc unlock` / `lock` | Move the groups |
| `/cdmc preset` | Load the class starter layout |
| `/cdmc export` / `import` | Share a profile (or the Share Profile button) |
| `/cdmc profile list \| use \| new \| copy \| delete <name>` | Profile management |
| `/cdmc reset` | Reset the current profile |

## Development

```bash
./ci/scripts/lint.sh                  # luacheck
python ci/scripts/check_globals.py    # undeclared globals / typo'd API names
python ci/tests/smoke_test.py         # load and drive the addon headlessly
./ci/scripts/package.sh               # build ci/dist/<addon>-<version>.zip
./ci/scripts/repackage.sh             # rewrap with the top-level folder for CurseForge
./ci/scripts/deploy.sh era            # package and install into Classic Era
./ci/scripts/deploy.sh anniversary    # ... or Anniversary
./ci/scripts/version.sh minor alpha   # bump the version in every .toc
./ci/scripts/publish.sh patch         # bump, commit and tag
```

Copy `.env` and point the `wow_addons_dir_*` entries at your own installs.
`package.sh` and `repackage.sh` use `zip` when it is available and fall back to
Python otherwise, so the pipeline runs in Git Bash on Windows as well as in the
CI container (`ci/build/scripts/DockerBuild.ps1`).

Pushing a `v*.*.*` tag triggers `.github/workflows/main.yaml`, which lints,
packages and uploads to CurseForge using the `CURSEFORGE_PROJECT_ID` and
`CURSEFORGE_TOKEN` secrets.

## Roadmap

- Buff bars alongside buff icons
- Trinket and consumable tracking (`GetInventoryItemCooldown`)
- Keybind text on icons, read from the action bars
- Per-ability overrides: custom colours, hide the aura, always show
- Drag-to-reorder inside a group, rather than the arrow buttons
- Class presets beyond Balance Druid, keyed on talent distribution
- Talent- and rune-aware automatic profile switching
- Anniversary / TBC support from the same codebase
