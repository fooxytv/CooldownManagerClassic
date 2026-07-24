--[[
Copyright (C) 2023 FooxyTV (simon@fooxy.tv)
All rights reserved.

Programming by: FooxyTV
]]

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
--   1: spell list plus icon size, spacing, growth and position
--   2: every appearance field, spell names, and the resource bars
Const.PROFILE_FORMAT_VERSION = 2

-- Iterate this rather than pairs(), or the layout order is not stable.
Const.GROUP_ORDER = { "essential", "utility", "buffs", "cooldownbars" }

Const.GROUP_LABELS = {
    essential    = "Essential Cooldowns",
    utility      = "Utility",
    buffs        = "Tracked Buffs",
    cooldownbars = "Cooldown Bars",
}

-- Groups tracked as auras on the player rather than as spell cooldowns.
Const.AURA_GROUPS = {
    buffs = true,
}

-- cooldownbars is a Classic-only addition with no Retail equivalent.
Const.BAR_CAPABLE_GROUPS = {
    buffs = true,
    cooldownbars = true,
}

-- cooldownbars is absent on purpose: being a bar is the whole point of it.
Const.DISPLAY_TOGGLE_GROUPS = {
    buffs = true,
}

-- These bars prefer the aura the ability applies (Barkskin's 8s) over the
-- recharge. Tracked buffs are already auras; the icon groups are recharge-only.
Const.DURATION_BAR_GROUPS = {
    cooldownbars = true,
}

-- What a duration bar counts.
--   Effect + Cooldown  the effect while it is up, then the recharge, dimmed
--   Effect Only        just the effect, like Retail's Tracked Bars; empty
--                      while the ability is down
Const.BAR_MODES = { "Effect + Cooldown", "Effect Only" }

Const.GROWTH_DIRECTIONS = { "CENTER", "LEFT", "RIGHT" }

-- Each is an independently positioned Edit Mode system.
Const.BAR_ORDER = { "health", "power", "combo" }

Const.BAR_LABELS = {
    health = "Health Bar",
    power  = "Resource Bar",
    combo  = "Combo Points",
}

Const.DEFAULT_BAR_APPEARANCE = {
    width = 220,
    height = 18,
    opacity = 100,
    visibility = "Always",
    showText = true,
    -- Combo points only: drawn as separate pips rather than a filled bar.
    pipSpacing = 2,
}

Const.BAR_DEFAULT_Y = {
    health = -300,
    power  = -322,
    combo  = -344,
}

-- Fallbacks for clients where PowerBarColor is missing a token.
Const.POWER_COLORS = {
    MANA        = { 0.00, 0.55, 1.00 },
    RAGE        = { 0.90, 0.15, 0.15 },
    ENERGY      = { 1.00, 0.85, 0.10 },
    FOCUS       = { 1.00, 0.50, 0.25 },
    RUNIC_POWER = { 0.00, 0.82, 1.00 },
}

Const.HEALTH_COLOR = { 0.15, 0.75, 0.15 }
Const.COMBO_COLOR = { 1.00, 0.85, 0.10 }

-- Shaman weapon buffs, rogue poisons and sharpening stones are not auras and
-- are invisible to every aura API -- they only come from GetWeaponEnchantInfo.
-- Tracked as pseudo-spells under negative IDs that cannot collide with a real one.
Const.WEAPON_ENCHANTS = {
    { id = -1, hand = "main", inventorySlot = 16, label = "Main Hand Enchant" },
    { id = -2, hand = "off",  inventorySlot = 17, label = "Off Hand Enchant" },
}

Const.WEAPON_ENCHANT_BY_ID = {}
for _, enchant in ipairs(Const.WEAPON_ENCHANTS) do
    Const.WEAPON_ENCHANT_BY_ID[enchant.id] = enchant
end

function Const.IsWeaponEnchantID(spellID)
    return spellID ~= nil and Const.WEAPON_ENCHANT_BY_ID[spellID] ~= nil
end

-- Cooldowns at or below this count as the GCD. Above 1.5 on purpose: a caster
-- GCD reports as exactly 1.50, and an exact comparison misreads it as a real
-- cooldown the moment floating point returns 1.5000001.
Const.GCD_THRESHOLD = 1.6

-- How often icon text is refreshed while anything is counting down.
Const.UPDATE_INTERVAL = 0.1

-- Safety net only -- aura changes arrive by event.
Const.IDLE_UPDATE_INTERVAL = 0.5

Const.COLORS = {
    ready       = { 1.0, 1.0, 1.0 },
    unavailable = { 0.4, 0.4, 0.4 },
    active      = { 0.2, 1.0, 0.2 },
    expiring    = { 1.0, 0.3, 0.3 },
}

-- CooldownViewerConstants in Blizzard's CooldownViewer.lua. notEnoughPower is
-- blue, not grey -- grey is reserved for genuinely unusable.
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

    -- Scales the swipe's alpha. Lower it when the icons are small and the
    -- sweep is competing with the timer text for legibility.
    swipeOpacity = 100,
}

Const.ORIENTATIONS = { "Horizontal", "Vertical" }

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

-- Taken from Blizzard's CooldownViewer.xml, not approximated:
--   CooldownViewerEssentialItemTemplate   50x50, GameFontHighlightHugeOutline
--   CooldownViewerUtilityItemTemplate     30x30, GameFontHighlightOutline
--   CooldownViewerBuffIconItemTemplate    40x40
-- overlayInset* are that template's IconOverlay anchor offsets, scaled
-- proportionally when the player resizes icons.
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
        -- allowHideWhenInactive on Blizzard's template: the row collapses
        -- rather than leaving a gap when the buff is not on you.
        hideWhenInactive = true,

        -- Retail splits this across two Edit Mode systems (Tracked Buffs and
        -- Tracked Buff Bars); there is one group here, so it is a setting.
        display = "Icons",
        barWidth = 220,
        barHeight = 30,
        barContent = "Icon and Name",
    },
    cooldownbars = {
        iconSize = 30,
        overlayInsetX = 6,
        overlayInsetY = 5,
        timeFont = "GameFontHighlightOutline",
        countFont = "NumberFontNormalSmall",
        -- Bars are wide, so they stack in a column rather than a row.
        display = "Bars",
        orientation = "Vertical",
        iconDirection = "Right",
        barWidth = 220,
        barHeight = 30,
        barContent = "Icon and Name",
        -- A 1.5s drain on every cast would make the whole column flicker. The
        -- bar also ignores GCD-length cooldowns even when this is switched on.
        showGCD = false,
        barMode = "Effect + Cooldown",
        -- Unlike tracked buffs, a ready cooldown bar stays put: the point is to
        -- watch it recharge, and a column that collapsed each time would be
        -- unreadable.
        hideWhenInactive = false,
    },
}

Const.BUFF_DISPLAYS = { "Icons", "Bars" }

-- Enum.CooldownViewerBarContent, in the order Blizzard lists it.
Const.BAR_CONTENTS = { "Icon and Name", "Icon Only", "Name Only" }

-- CooldownViewerBuffBarItemTemplate at its native 220x30. Every offset is
-- scaled by barHeight/itemHeight on resize, so the art keeps its proportions.
Const.BAR_TEMPLATE = {
    itemHeight    = 30,
    barHeight     = 19,   -- the StatusBar inside the 30px item
    iconGap       = 2,    -- icon RIGHT -> bar LEFT
    overlayInsetX = 6,    -- IconOverlay, as on the 30px utility template
    overlayInsetY = 5,
    -- BarBG anchors: TOPLEFT(-2, 2), BOTTOMRIGHT(4, -7).
    bgInsetLeft   = -2,
    bgInsetTop    = 2,
    bgInsetRight  = 4,
    bgInsetBottom = -7,
    nameInsetLeft  = 5,
    nameInsetRight = -25, -- leaves the duration its corner
    durationInset  = -8,
    applicationsX  = -5,
    applicationsY  = 5,
}

-- BarTexture colour from the template. Blizzard tints every tracked buff bar
-- the same orange rather than colouring by school or dispel type.
Const.BAR_FILL_COLOR = { 1.0, 0.5, 0.25 }

-- Dim and desaturated so a recharging ability reads as secondary to a live one.
Const.BAR_COOLDOWN_COLOR = { 0.38, 0.40, 0.48 }

-- May be absent at run time -- see Compat.AtlasExists.
Const.ART = {
    mask        = "UI-HUD-CoolDownManager-Mask",
    iconOverlay = "UI-HUD-CoolDownManager-IconOverlay",
    oorShadow   = "UI-CooldownManager-OORshadow",
    swipe       = "Interface\\HUD\\UI-HUD-CoolDownManager-Icon-Swipe",
    edge        = "Interface\\Cooldown\\UI-HUD-ActionBar-SecondaryCooldown",
    -- Buff bar art, from CooldownViewerBuffBarItemTemplate.
    bar         = "UI-HUD-CoolDownManager-Bar",
    barBG       = "UI-HUD-CoolDownManager-Bar-BG",
    barPip      = "UI-HUD-CoolDownManager-Bar-Pip",
}

-- Exists in every Classic build, for when the bar atlas does not.
Const.FALLBACK_BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

Const.COOLDOWN_SWIPE_COLOR = { 0, 0, 0, 0.7 }        -- ITEM_COOLDOWN_COLOR
-- Not a copy-paste of the above: buff icons really do use the *cooldown*
-- colour, not ITEM_AURA_COLOR. CooldownViewerBuffIconItemMixin says so outright
-- ("still using the standard cooldown colors even though this is an aura").
Const.BUFF_SWIPE_COLOR = { 0, 0, 0, 0.7 }            -- ITEM_COOLDOWN_COLOR

-- Lighter than a real cooldown: the GCD fires on almost every cast, and at 0.7
-- it reads as the ability being unavailable.
Const.GCD_SWIPE_COLOR = { 0, 0, 0, 0.3 }
