local addonName, ns = ...

local Const = {}
ns.Constants = Const

Const.ADDON_NAME = addonName
Const.DISPLAY_NAME = "Cooldown Manager Classic"
Const.SHORT_NAME = "CDMC"

-- Bumped when the SavedVariables layout changes in a way that needs migrating.
--   2: per-group sizing taken from Blizzard's CooldownViewer templates
--   3: strip dead rune-slot placeholders, turn the GCD swipe on
Const.DB_VERSION = 3

-- Bumped when the exported profile string format changes.
Const.PROFILE_FORMAT_VERSION = 1

-- Display order of the groups. Anything iterating groups should use this
-- rather than pairs() so the layout is stable.
Const.GROUP_ORDER = { "essential", "utility", "buffs" }

Const.GROUP_LABELS = {
    essential = "Essential Cooldowns",
    utility   = "Utility",
    buffs     = "Tracked Buffs",
}

-- Groups tracked as auras on the player rather than as spell cooldowns.
Const.AURA_GROUPS = {
    buffs = true,
}

Const.GROWTH_DIRECTIONS = { "CENTER", "LEFT", "RIGHT" }

-- Cooldowns at or below this are treated as the global cooldown and ignored.
-- Classic gives us no reliable per-class GCD spell to compare against, so a
-- threshold is the pragmatic option.
Const.GCD_THRESHOLD = 1.5

-- How often icon text is refreshed while anything is counting down.
Const.UPDATE_INTERVAL = 0.1

Const.COLORS = {
    ready       = { 1.0, 1.0, 1.0 },
    unavailable = { 0.4, 0.4, 0.4 },
    active      = { 0.2, 1.0, 0.2 },
    expiring    = { 1.0, 0.3, 0.3 },
}

-- Icon tints, matching CooldownViewerConstants in Blizzard's CooldownViewer.lua.
-- Note that "not enough power" is blue rather than grey: for a rogue out of
-- energy the icon goes blue, and grey is reserved for genuinely unusable.
Const.ITEM_COLORS = {
    usable        = { 1.0, 1.0, 1.0, 1.0 },
    notEnoughPower = { 0.5, 0.5, 1.0, 1.0 },
    notUsable     = { 0.4, 0.4, 0.4, 1.0 },
    notInRange    = { 0.64, 0.15, 0.15, 1.0 },
}

Const.DEFAULT_APPEARANCE = {
    iconSize = 40,
    spacing = 4,
    growth = "CENTER",
    showTooltips = true,
    desaturateUnavailable = true,
    showCountdownText = true,
    hideWhenEmpty = true,
    showGCD = true,
    -- Tint by usability (blue when out of power, grey when unusable).
    colorByUsability = true,

    -- Grid layout. `rows` is the number of lines the icons are split across;
    -- with Horizontal orientation those lines are rows, with Vertical they are
    -- columns. iconDirection decides which way the extra lines stack.
    orientation = "Horizontal",
    rows = 1,
    iconDirection = "Down",

    opacity = 100,
    visibility = "Always",
}

Const.ORIENTATIONS = { "Horizontal", "Vertical" }

-- Which directions make sense depends on the orientation: horizontal lines
-- stack up or down, vertical lines stack left or right.
Const.ICON_DIRECTIONS = {
    Horizontal = { "Down", "Up" },
    Vertical   = { "Right", "Left" },
}

Const.VISIBILITY_OPTIONS = {
    { value = "Always",       label = "Always Visible" },
    { value = "InCombat",     label = "In Combat" },
    { value = "OutOfCombat",  label = "Out of Combat" },
    { value = "Hidden",       label = "Hidden" },
}

-- Per-group sizing and fonts, taken from Blizzard's own CooldownViewer.xml so
-- the display matches the Retail Cooldown Manager rather than approximating it:
--
--   CooldownViewerEssentialItemTemplate   50x50, GameFontHighlightHugeOutline
--   CooldownViewerUtilityItemTemplate     30x30, GameFontHighlightOutline
--   CooldownViewerBuffIconItemTemplate    40x40
--
-- overlayInset* are the UI-HUD-CoolDownManager-IconOverlay anchor offsets for
-- each template; they are scaled proportionally if the player resizes icons.
Const.GROUP_APPEARANCE = {
    essential = {
        iconSize = 50,
        overlayInsetX = 9,
        overlayInsetY = 8,
        timeFont = "GameFontHighlightHugeOutline",
        countFont = "NumberFontNormal",
    },
    utility = {
        iconSize = 30,
        overlayInsetX = 6,
        overlayInsetY = 5,
        timeFont = "GameFontHighlightOutline",
        countFont = "NumberFontNormalSmall",
    },
    buffs = {
        iconSize = 40,
        overlayInsetX = 8,
        overlayInsetY = 7,
        timeFont = "GameFontHighlightOutline",
        countFont = "NumberFontNormal",
        -- Blizzard's CooldownViewerBuffIconItemTemplate sets
        -- allowHideWhenInactive, so a tracked buff only occupies the bar while
        -- it is actually on you. The row collapses rather than leaving a gap.
        hideWhenInactive = true,
    },
}

-- Blizzard's Cooldown Manager art. The UI code ships in the Classic Era build
-- but is gated to the `standard` game type, so whether the atlases themselves
-- are present has to be checked at run time -- see Icon.lua, which falls back to
-- a plain trimmed icon when they are missing.
Const.ART = {
    mask        = "UI-HUD-CoolDownManager-Mask",
    iconOverlay = "UI-HUD-CoolDownManager-IconOverlay",
    oorShadow   = "UI-CooldownManager-OORshadow",
    swipe       = "Interface\\HUD\\UI-HUD-CoolDownManager-Icon-Swipe",
    edge        = "Interface\\Cooldown\\UI-HUD-ActionBar-SecondaryCooldown",
}

-- Buff swipes run in reverse and are darkened, matching
-- CooldownViewerBuffIconItemTemplate.
-- Swipe colours from CooldownViewerConstants in Blizzard's CooldownViewer.lua.
-- A dark translucent sweep rather than a bright white one is what makes the
-- Retail display read as calm; Blizzard also disables the edge spark entirely
-- (cooldownShowDrawEdge = false).
Const.COOLDOWN_SWIPE_COLOR = { 0, 0, 0, 0.7 }        -- ITEM_COOLDOWN_COLOR
Const.BUFF_SWIPE_COLOR = { 1, 0.95, 0.57, 0.7 }      -- ITEM_AURA_COLOR

-- The global cooldown fires on almost every cast, so it is drawn much lighter
-- than a real cooldown: dark enough to read as a sweep, faint enough that it
-- never looks like the ability is unavailable.
Const.GCD_SWIPE_COLOR = { 0, 0, 0, 0.3 }
