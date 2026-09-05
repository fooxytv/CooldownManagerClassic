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

Const.DB_VERSION = 3

Const.PROFILE_FORMAT_VERSION = 3

Const.GROUP_ORDER = { "essential", "utility", "buffs", "cooldownbars" }

Const.GROUP_LABELS = {
    essential    = "Essential Cooldowns",
    utility      = "Utility",
    buffs        = "Tracked Buffs",
    cooldownbars = "Cooldown Bars",
}

Const.AURA_GROUPS = {
    buffs = true,
}

Const.BAR_CAPABLE_GROUPS = {
    buffs = true,
    cooldownbars = true,
}

Const.DISPLAY_TOGGLE_GROUPS = {
    buffs = true,
}

Const.DURATION_BAR_GROUPS = {
    cooldownbars = true,
}

Const.BAR_MODES = { "Effect + Cooldown", "Effect Only" }

Const.GROWTH_DIRECTIONS = { "CENTER", "LEFT", "RIGHT" }

Const.BAR_ORDER = { "health", "power", "combo" }

Const.BAR_LABELS = {
    health = "Health Bar",
    power  = "Resource Bar",
    combo  = "Class Resource",
}

Const.DEFAULT_BAR_APPEARANCE = {
    width = 220,
    height = 18,
    opacity = 100,
    visibility = "Always",
    showText = true,
    pipSpacing = 2,
    barTexture = "",
    resourceSource = "",

    bgColor = "0,0,0,0.5",
    borderSize = 1,
    borderColor = "0,0,0,1",
    borderTexture = "",
    fillColor = "",
    fontFace = "",
    fontOutline = "",
    segmentStyle = "pips",
    animate = false,
    spark = false,
    textAlign = "CENTER",
    showPercent = false,
}

function Const.UnpackColor(str, dr, dg, db, da)
    if type(str) == "string" then
        local r, g, b, a = str:match("^([%d.]+),([%d.]+),([%d.]+),([%d.]+)$")
        if r then
            return tonumber(r), tonumber(g), tonumber(b), tonumber(a)
        end
    end
    return dr, dg, db, da
end

function Const.PackColor(r, g, b, a)
    return ("%.3f,%.3f,%.3f,%.3f"):format(r or 0, g or 0, b or 0, a == nil and 1 or a)
end

Const.FONT_OUTLINE_OPTIONS = {
    { value = "",                    label = "None" },
    { value = "OUTLINE",             label = "Outline" },
    { value = "THICKOUTLINE",        label = "Thick Outline" },
    { value = "OUTLINE, MONOCHROME", label = "Outline (Sharp)" },
}

Const.BAR_SEGMENT_OPTIONS = {
    { value = "pips",  label = "Pips" },
    { value = "ticks", label = "Tick Marks" },
}

Const.TEXT_ALIGN_OPTIONS = {
    { value = "LEFT",   label = "Left" },
    { value = "CENTER", label = "Center" },
    { value = "RIGHT",  label = "Right" },
}

Const.BAR_DEFAULT_Y = {
    health = -300,
    power  = -322,
    combo  = -344,
}

Const.POWER_COLORS = {
    MANA        = { 0.00, 0.55, 1.00 },
    RAGE        = { 0.90, 0.15, 0.15 },
    ENERGY      = { 1.00, 0.85, 0.10 },
    FOCUS       = { 1.00, 0.50, 0.25 },
    RUNIC_POWER = { 0.00, 0.82, 1.00 },
}

Const.HEALTH_COLOR = { 0.15, 0.75, 0.15 }

Const.COMBO_COLOR = { 1.00, 0.85, 0.10 }
Const.COMBO_COLORS = {
    building   = Const.COMBO_COLOR,
    nearlyFull = { 1.00, 0.50, 0.10 },
    full       = { 0.95, 0.15, 0.15 },
    empty      = { 0.25, 0.25, 0.25, 0.6 },
}

Const.CLASS_RESOURCE_SOURCE = {
    ROGUE   = "combo",
    DRUID   = "combo",
    SHAMAN  = "maelstrom",
    WARLOCK = "soulshards",
}

Const.CLASS_RESOURCE_INFO = {
    combo         = { mode = "pips",  label = "Combo Points" },
    maelstrom     = { mode = "pips",  label = "Maelstrom Weapon" },
    soulshards    = { mode = "count", label = "Soul Shards" },
    demonicfury   = { mode = "power", label = "Demonic Fury" },
    burningembers = { mode = "pips",  label = "Burning Embers" },
}

-- MoP made the Warlock resource a power type and split it by spec. Era and TBC
-- have none of these, so the bag count in SOUL_SHARD_ITEM_ID still carries them.
Const.WARLOCK_POWER_TYPES = {
    soulshards    = { enum = "SoulShards",    value = 7  },
    demonicfury   = { enum = "DemonicFury",   value = 15 },
    burningembers = { enum = "BurningEmbers", value = 14 },
}

Const.WARLOCK_RESOURCE_ORDER = { "soulshards", "demonicfury", "burningembers" }

Const.DEMONIC_FURY_COLOR = { 0.60, 0.35, 0.85 }
Const.BURNING_EMBERS_COLOR = { 0.95, 0.45, 0.15 }

Const.RESOURCE_SOURCE_OPTIONS = {
    { value = "",           label = "Auto" },
    { value = "combo",      label = "Combo Points" },
    { value = "maelstrom",  label = "Maelstrom Weapon" },
    { value = "soulshards", label = "Soul Shards" },
    { value = "demonicfury",   label = "Demonic Fury" },
    { value = "burningembers", label = "Burning Embers" },
    { value = "none",       label = "None" },
}

Const.DRUID_FORMS = { "cat", "bear", "moonkin", "caster" }

Const.FORM_KEY_SET = {}
for _, key in ipairs(Const.DRUID_FORMS) do
    Const.FORM_KEY_SET[key] = true
end

local CAT_ONLY = {
    "Claw", "Rake", "Shred", "Rip", "Ferocious Bite", "Tiger's Fury",
    "Pounce", "Ravage", "Cower", "Prowl", "Dash",
}

local BEAR_ONLY = {
    "Maul", "Swipe", "Bash", "Demoralizing Roar", "Enrage",
    "Frenzied Regeneration", "Growl", "Challenging Roar",
}

Const.DRUID_FORM_ABILITIES = {}
for _, name in ipairs(CAT_ONLY) do
    Const.DRUID_FORM_ABILITIES[name] = { cat = true }
end
for _, name in ipairs(BEAR_ONLY) do
    Const.DRUID_FORM_ABILITIES[name] = { bear = true }
end

function Const.DefaultFormsFor(spellID)
    if not spellID then return nil end

    local _, class = UnitClass("player")
    if class ~= "DRUID" then return nil end

    local name = ns.Compat and ns.Compat.GetSpellInfo and ns.Compat.GetSpellInfo(spellID)
    local forms = name and Const.DRUID_FORM_ABILITIES[name]
    if not forms then return nil end

    local copy = {}
    for key in pairs(forms) do copy[key] = true end
    return copy
end

Const.FORM_TAG_OPTIONS = {
    { value = "cat",     label = "Cat" },
    { value = "bear",    label = "Bear" },
    { value = "moonkin", label = "Moonkin" },
    { value = "caster",  label = "Caster / No Form" },
}

Const.FORM_INITIALS = {
    cat     = "C",
    bear    = "B",
    moonkin = "M",
    caster  = "H",
}

Const.DRUID_MOONKIN_SPELL = 24858

function Const.FormAllows(forms, formKey)
    if type(forms) ~= "table" or not next(forms) then return true end
    return forms[formKey] == true
end

Const.AURA_SPELL_NAMES = {
    ["Moonfire"]        = true,
    ["Sunfire"]         = true,
    ["Insect Swarm"]    = true,
    ["Rip"]             = true,
    ["Rake"]            = true,
    ["Rupture"]         = true,
    ["Garrote"]         = true,
    ["Flame Shock"]     = true,
    ["Corruption"]      = true,
    ["Immolate"]        = true,
    ["Curse of Agony"]  = true,
    ["Serpent Sting"]   = true,
    ["Deadly Poison"]   = true,
    ["Slice and Dice"]  = true,
}

-- Every name above is a spell whose aura is called the same thing it is, which
-- is why matching on the spell's own ID or name finds it. A Death Knight's
-- diseases are not: Icy Touch applies Frost Fever and Plague Strike applies
-- Blood Plague, so both lookups miss and the debuff was untrackable at all --
-- ticking Track DoT on them did nothing.
--
-- Keyed by the casting spell's ID rather than its name. These are Mists
-- abilities with no ranks, so the ID is stable, and unlike the name table it
-- resolves on a client in any language. Each row carries the aura's ID and its
-- English name together so the two cannot drift apart; the name is a fallback
-- for an ID that shifts between builds, and is only reachable on an English
-- client, where the ID would have to be wrong for it to matter.
--
-- `default` is a separate question from whether tracking works at all: an
-- ability is only flagged for you if applying the disease is the point of
-- pressing it. Howling Blast refreshes Frost Fever, but it is cast for damage,
-- so it resolves when you ask for it and stays off until you do.
--
-- Deliberately absent: Outbreak and Unholy Blight apply *both* diseases, and
-- one bar cannot honestly show two durations. Which one wins is a design call,
-- not a table entry.
Const.APPLIED_AURA = {
    [45477] = { id = 55095, name = "Frost Fever",  default = true },  -- Icy Touch
    [45462] = { id = 55078, name = "Blood Plague", default = true },  -- Plague Strike
    [49184] = { id = 55095, name = "Frost Fever"                  },  -- Howling Blast
}

function Const.IsAuraSpell(spellID)
    if not spellID then return false end

    local applied = Const.APPLIED_AURA[spellID]
    if applied then return applied.default == true end

    local name = ns.Compat and ns.Compat.GetSpellInfo and ns.Compat.GetSpellInfo(spellID)
    return name ~= nil and Const.AURA_SPELL_NAMES[name] == true
end

Const.MAELSTROM_WEAPON_AURA = "Maelstrom Weapon"
Const.MAELSTROM_MAX_STACKS = 5
Const.MAELSTROM_COLOR = { 0.25, 0.55, 1.00 }

Const.SOUL_SHARD_ITEM_ID = 6265
Const.SOUL_SHARD_TIER_SIZE = 5
Const.SOUL_SHARD_COLORS = {
    { 0.45, 0.30, 0.55 },
    { 0.60, 0.35, 0.85 },
    { 0.75, 0.45, 1.00 },
    { 0.88, 0.60, 1.00 },
    { 1.00, 0.75, 1.00 },
}

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

Const.GCD_THRESHOLD = 1.6

Const.UPDATE_INTERVAL = 0.1

-- Range moves with no event behind it, so it has to be polled. Faster than the
-- idle rate because a colour that lags a step behind the player's own movement
-- reads as broken; slower than the animation rate because nothing is drawing.
Const.RANGE_UPDATE_INTERVAL = 0.2

Const.IDLE_UPDATE_INTERVAL = 0.5

Const.COLORS = {
    ready       = { 1.0, 1.0, 1.0 },
    unavailable = { 0.4, 0.4, 0.4 },
    active      = { 0.2, 1.0, 0.2 },
    expiring    = { 1.0, 0.3, 0.3 },
}

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
    colorByUsability = true,

    orientation = "Horizontal",
    rows = 1,
    iconDirection = "Down",

    opacity = 100,
    visibility = "Always",

    swipeOpacity = 100,

    fontFace = "",
    barTexture = "",

    showKeybind = false,

    -- Reactive proc / activation highlighting for this group. Per group so it can
    -- be turned on for, say, Essential Cooldowns but not Utility. Opt-in: a
    -- deliberate rotation cue, not something to switch on for everyone.
    highlightsEnabled = false,
}

Const.ORIENTATIONS = { "Horizontal", "Vertical" }

Const.TOOLTIP_ANCHORS = { "Default Position", "Attached", "Cursor" }

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

Const.BAR_VISIBILITY_OPTIONS = {
    { value = "Always",       label = "Always Visible" },
    { value = "InCombat",     label = "In Combat" },
    { value = "OutOfCombat",  label = "Out of Combat" },
    { value = "WithTarget",   label = "With a Target" },
    { value = "HideWhenFull", label = "Hide When Full" },
    { value = "Hidden",       label = "Hidden" },
}

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
        hideWhenInactive = true,

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
        display = "Bars",
        orientation = "Vertical",
        iconDirection = "Right",
        barWidth = 220,
        barHeight = 30,
        barContent = "Icon and Name",
        showGCD = false,
        barMode = "Effect + Cooldown",
        fillBarWhenReady = false,
        hideWhenInactive = false,
    },
}

Const.BUFF_DISPLAYS = { "Icons", "Bars" }

Const.BAR_CONTENTS = { "Icon and Name", "Icon Only", "Name Only" }

Const.BAR_TEMPLATE = {
    itemHeight    = 30,
    barHeight     = 19,
    iconGap       = 2,
    overlayInsetX = 6,
    overlayInsetY = 5,
    bgInsetLeft   = -2,
    bgInsetTop    = 2,
    bgInsetRight  = 4,
    bgInsetBottom = -7,
    nameInsetLeft  = 5,
    nameInsetRight = -25,
    durationInset  = -8,
    applicationsX  = -5,
    applicationsY  = 5,
}

Const.BAR_FILL_COLOR = { 1.0, 0.5, 0.25 }

Const.BAR_COOLDOWN_COLOR = { 0.38, 0.40, 0.48 }

Const.QUEUED_GLOW_COLOR = { 0.30, 0.85, 1.00, 1 }

-- Which of these a Classic client actually ships cannot be reasoned about from
-- Blizzard's UI source: the addon that references them is gated
-- AllowLoadGameType: standard, so every reference there is retail-only, and
-- atlas existence lives in the client's texture database rather than in any Lua.
-- Every consumer probes with Compat.AtlasExists and falls back.
--
-- Measured on Classic Era 1.15.9 via /cdmc ui, 2026-08-30:
--   present -- mask, bar (and the bar art beside it)
--   absent  -- oorShadow, and all five settings-panel atlases below
-- So the icon mask and the bar art land on Era, while the tab glyphs fall back
-- to the ability icons they replaced and produce no visible change there. They
-- are kept as insurance for a client that ships the art, not for an effect
-- today.
-- Do not treat that as permanent; re-run /cdmc ui rather than trusting this
-- list, which is a record of one client on one day, not a contract.
Const.ART = {
    mask        = "UI-HUD-CoolDownManager-Mask",
    iconOverlay = "UI-HUD-CoolDownManager-IconOverlay",
    -- Absent on Era. The out-of-range work deliberately tints the icon rather
    -- than drawing this, and that is why: using it would have drawn nothing at
    -- all on the client the addon is mainly played on.
    oorShadow   = "UI-CooldownManager-OORshadow",
    swipe       = "Interface\\HUD\\UI-HUD-CoolDownManager-Icon-Swipe",
    edge        = "Interface\\Cooldown\\UI-HUD-ActionBar-SecondaryCooldown",
    bar         = "UI-HUD-CoolDownManager-Bar",
    barBG       = "UI-HUD-CoolDownManager-Bar-BG",
    barPip      = "UI-HUD-CoolDownManager-Bar-Pip",

    -- The settings panel's own art, read out of Blizzard's UI source:
    -- Blizzard_CooldownViewer/CooldownViewerSettings.xml names the two tab
    -- glyphs, and they sit on LargeSideTabButtonTemplate (SharedUIPanelTemplates
    -- .xml), a 43x55 plate over the three common-sidetab atlases. Every one is
    -- probed rather than assumed: whether they resolve on a Classic client is
    -- not knowable from the source, since the addon that uses them there is
    -- gated `AllowLoadGameType: standard`.
    tabCooldowns = "icon_cooldownmanager",
    tabBuffs     = "icon_trackedbuffs",
    sideTab      = "common-sidetab",
    sideTabOn    = "common-sidetab-selected",
    sideTabHover = "common-sidetab-hover",
}

Const.FALLBACK_BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
Const.COOLDOWN_SWIPE_COLOR = { 0, 0, 0, 0.7 }
Const.BUFF_SWIPE_COLOR = { 0, 0, 0, 0.7 }
Const.GCD_SWIPE_COLOR = { 0, 0, 0, 0.3 }
