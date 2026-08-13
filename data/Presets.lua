local addonName, ns = ...

local Const = ns.Constants

-- Starter layouts. One rank of each spell is enough: entries are stored
-- rank-independent, so Resolve() looks the ID up by name and swaps in whichever
-- rank the character knows -- which also carries a preset across clients where
-- the ID differs but the name does not.
--
-- Listed generously. An entry the character has not learned simply does not
-- resolve, so a level 20 rogue sees only what they can cast.
local Presets = {}
ns.Presets = Presets

Presets.byClass = {
    ROGUE = {
        name = "Rogue",
        groups = {
            essential = {
                1752,   -- Sinister Strike
                53,     -- Backstab
                2098,   -- Eviscerate
                5171,   -- Slice and Dice
                8676,   -- Ambush
                13750,  -- Adrenaline Rush
                13877,  -- Blade Flurry
            },
            utility = {
                1776,   -- Gouge
                1766,   -- Kick
                2983,   -- Sprint
                5277,   -- Evasion
                1856,   -- Vanish
                6770,   -- Sap
                2094,   -- Blind
                408,    -- Kidney Shot
                1833,   -- Cheap Shot
            },
            buffs = {
                5171,   -- Slice and Dice
                1784,   -- Stealth
                5277,   -- Evasion
                2983,   -- Sprint
                13750,  -- Adrenaline Rush
                13877,  -- Blade Flurry
            },
        },
    },

    -- Base Era abilities only. Rune IDs are deliberately absent: they resolve
    -- through C_Engraving already, and hard-coding them adds entries that break
    -- whenever a slot is re-engraved.
    SHAMAN = {
        name = "Shaman",
        groups = {
            essential = {
                403,    -- Lightning Bolt
                421,    -- Chain Lightning
                8042,   -- Earth Shock
                8050,   -- Flame Shock
                8056,   -- Frost Shock
            },
            utility = {
                370,    -- Purge
                2645,   -- Ghost Wolf
                331,    -- Healing Wave
                8004,   -- Lesser Healing Wave
                2484,   -- Earthbind Totem
                8017,   -- Rockbiter Weapon
            },
            buffs = {
                324,    -- Lightning Shield
                8017,   -- Rockbiter Weapon
                8232,   -- Windfury Weapon
            },
        },
    },

    DRUID = {
        name = "Balance Druid",
        groups = {
            essential = {
                5176,   -- Wrath
                2912,   -- Starfire
                8921,   -- Moonfire
                16914,  -- Hurricane
                29166,  -- Innervate
            },
            utility = {
                22812,  -- Barkskin
                20484,  -- Rebirth
                770,    -- Faerie Fire
                339,    -- Entangling Roots
                1850,   -- Dash
            },
            buffs = {
                16870,  -- Clearcasting (from Omen of Clarity)
                1126,   -- Mark of the Wild
                467,    -- Thorns
                29166,  -- Innervate
            },
        },
    },
}

function Presets:GetForClass(class)
    return self.byClass[class]
end

function Presets:GetForPlayer()
    local _, class = UnitClass("player")
    return self:GetForClass(class), class
end

-- Without `overwrite` an existing group is left alone, so the automatic
-- first-login application cannot clobber a configured profile.
function Presets:Apply(preset, overwrite)
    if not preset then return false end

    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.DB:GetGroup(key)
        local ids = preset.groups[key]

        if group and ids then
            if overwrite or #group.spells == 0 then
                wipe(group.spells)
                for _, spellID in ipairs(ids) do
                    group.spells[#group.spells + 1] = {
                        spellID = spellID,
                        rankIndependent = true,
                    }
                end
            end
        end
    end

    ns.Core:RefreshAll()
    return true
end

function Presets:ApplyDefaultForPlayer(overwrite)
    local preset, class = self:GetForPlayer()

    if not preset then
        ns.Print(("No starter layout for %s yet — use /cdmc to pick your spells."):format(
            class and class:lower() or "this class"))
        return false
    end

    local applied = self:Apply(preset, overwrite)
    if applied then
        ns.Print(("Loaded the %s starter layout."):format(preset.name))
    end
    return applied
end

function Presets:IsProfileEmpty()
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.DB:GetGroup(key)
        if group and #group.spells > 0 then return false end
    end
    return true
end
