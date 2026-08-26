local addonName, ns = ...

local Const = ns.Constants

local Presets = {}
ns.Presets = Presets

Presets.byClass = {
    ROGUE = {
        {
            key = "rogue",
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
    },

    SHAMAN = {
        {
            key = "shaman",
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
    },

    DRUID = {
        {
            key = "druid-balance",
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
        {
            key = "druid-feral",
            name = "Feral Druid",
            groups = {
                essential = {
                    1082,   -- Claw
                    1822,   -- Rake
                    5221,   -- Shred
                    22568,  -- Ferocious Bite
                    1079,   -- Rip
                    6807,   -- Maul
                    779,    -- Swipe
                },
                utility = {
                    5217,   -- Tiger's Fury
                    5211,   -- Bash
                    16979,  -- Feral Charge
                    99,     -- Demoralizing Roar
                    6795,   -- Growl
                    5209,   -- Challenging Roar
                    22842,  -- Frenzied Regeneration
                    5229,   -- Enrage
                    1850,   -- Dash
                    22812,  -- Barkskin
                },
                buffs = {
                    5215,   -- Prowl
                    5217,   -- Tiger's Fury
                    22842,  -- Frenzied Regeneration
                    5229,   -- Enrage
                    1126,   -- Mark of the Wild
                    467,    -- Thorns
                },
            },
        },
        {
            key = "druid-restoration",
            name = "Restoration Druid",
            groups = {
                essential = {
                    5185,   -- Healing Touch
                    8936,   -- Regrowth
                    774,    -- Rejuvenation
                    740,    -- Tranquility
                    29166,  -- Innervate
                },
                utility = {
                    20484,  -- Rebirth
                    2782,   -- Remove Curse
                    2893,   -- Abolish Poison
                    339,    -- Entangling Roots
                    16689,  -- Nature's Grasp
                    22812,  -- Barkskin
                },
                buffs = {
                    16870,  -- Clearcasting (from Omen of Clarity)
                    1126,   -- Mark of the Wild
                    467,    -- Thorns
                    774,    -- Rejuvenation
                },
            },
        },
    },
}

function Presets:GetForClass(class)
    return self.byClass[class] or {}
end

function Presets:GetDefaultForClass(class)
    return self:GetForClass(class)[1]
end

function Presets:GetCustom()
    local global = ns.DB:GetGlobal()
    if not global then return {} end
    global.customPresets = global.customPresets or {}
    return global.customPresets
end

function Presets:ListForPlayer()
    local _, class = UnitClass("player")
    local list = {}

    for _, preset in ipairs(self:GetForClass(class)) do
        list[#list + 1] = preset
    end

    local names = {}
    for name in pairs(self:GetCustom()) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        list[#list + 1] = self:GetCustom()[name]
    end

    return list, class
end

function Presets:GetByKey(key)
    if not key then return nil end
    for _, preset in ipairs(self:ListForPlayer()) do
        if preset.key == key or preset.name == key then return preset end
    end
    return nil
end

function Presets:GetForPlayer()
    local _, class = UnitClass("player")
    return self:GetDefaultForClass(class), class
end

function Presets:Apply(preset, overwrite)
    if not preset then return false end

    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.DB:GetGroup(key)
        local ids = preset.groups[key]

        if group and ids then
            if overwrite or #group.spells == 0 then
                wipe(group.spells)
                for _, item in ipairs(ids) do
                    if type(item) == "table" then
                        group.spells[#group.spells + 1] = ns.DeepCopy(item)
                    else
                        group.spells[#group.spells + 1] = {
                            spellID = item,
                            rankIndependent = true,
                            trackDebuff = Const.IsAuraSpell(item) or nil,
                            forms = Const.DefaultFormsFor(item),
                        }
                    end
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

function Presets:ApplyByKey(key, overwrite)
    local preset = self:GetByKey(key)
    if not preset then
        return false, ("No layout named %q."):format(tostring(key))
    end

    self:Apply(preset, overwrite ~= false)
    return true, preset.name
end

function Presets:SaveCurrentAs(name)
    if not name or name == "" then
        return false, "Give the layout a name first."
    end

    for _, preset in ipairs(self:GetForClass(select(2, UnitClass("player")))) do
        if preset.name == name then
            return false, ("%q is a built-in layout name."):format(name)
        end
    end

    local groups = {}
    local total = 0
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.DB:GetGroup(key)
        if group and #group.spells > 0 then
            groups[key] = ns.DeepCopy(group.spells)
            total = total + #group.spells
        end
    end

    if total == 0 then
        return false, "There is nothing tracked to save."
    end

    self:GetCustom()[name] = {
        key = "custom:" .. name,
        name = name,
        custom = true,
        groups = groups,
    }

    return true, name
end

function Presets:DeleteCustom(name)
    local custom = self:GetCustom()
    if not name or not custom[name] then
        return false, ("No saved layout named %q."):format(tostring(name))
    end

    custom[name] = nil
    return true
end

function Presets:IsProfileEmpty()
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.DB:GetGroup(key)
        if group and #group.spells > 0 then return false end
    end
    return true
end
