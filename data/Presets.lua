local addonName, ns = ...

local Const = ns.Constants

-- Starter layouts.
--
-- Only one rank of each spell needs to be listed. Entries are stored
-- rank-independent, so Spellbook:Resolve() looks the ID up by name and swaps in
-- whichever rank the character actually knows. That also means a preset written
-- against Era keeps working on a client where the ID happens to differ, as long
-- as the spell name matches.

local Presets = {}
ns.Presets = Presets

Presets.byClass = {
    -- Listed generously: a rank-independent entry the character has not learned
    -- simply does not resolve, so a level 20 rogue sees only what they can cast
    -- and the rest appear as they are trained.
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

    -- Base Era abilities only. Season of Discovery runes are deliberately not
    -- listed: they resolve through C_Engraving and appear in the picker under
    -- their real names, so hard-coding rune IDs would only add entries that
    -- break whenever a slot is re-engraved.
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

--- The preset for a class, or nil when we do not ship one yet.
function Presets:GetForClass(class)
    return self.byClass[class]
end

function Presets:GetForPlayer()
    local _, class = UnitClass("player")
    return self:GetForClass(class), class
end

--- Writes the class preset into the current profile.
--- Existing spells are replaced only when `overwrite` is true, so the automatic
--- first-login application can never clobber a configured profile.
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

--- True when the profile has never had anything added to it, which is how the
--- first login decides whether to seed a preset.
function Presets:IsProfileEmpty()
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.DB:GetGroup(key)
        if group and #group.spells > 0 then return false end
    end
    return true
end
