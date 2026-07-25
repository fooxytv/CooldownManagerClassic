local addonName, ns = ...

local Const = ns.Constants

-- Reactive spell highlighting -- Retail's Cooldown Manager glows an icon when
-- the spell becomes the thing to press. Classic has no curated activation
-- database, so the trigger is a curated, data-driven rule table: while an aura
-- holds (optionally at a minimum stack count), the spells it names light up.
--
-- Rules match tracked entries by name, so they cover every rank without knowing
-- any spell ID, at the cost of being locale-sensitive (the same trade-off the
-- rest of the addon's name matching makes).

local Highlights = {}
ns.Highlights = Highlights

-- Keyed by class token. `sod = true` gates a rule to Season of Discovery.
--   aura       the buff whose presence arms the rule
--   minStacks  optional; the aura must be at or above this many applications
--   glow       spell names to light up while the rule is active
local RULES = {
    SHAMAN = {
        -- Maelstrom Weapon at max stacks: the next Lightning Bolt / Chain
        -- Lightning / heal is instant, so those are the payoff casts.
        {
            aura = "Maelstrom Weapon",
            minStacks = Const.MAELSTROM_MAX_STACKS,
            sod = true,
            glow = {
                "Lightning Bolt", "Chain Lightning",
                "Healing Wave", "Lesser Healing Wave", "Chain Heal",
            },
        },
    },
    WARLOCK = {
        -- Nightfall procs Shadow Trance, making the next Shadow Bolt instant.
        {
            aura = "Shadow Trance",
            glow = { "Shadow Bolt" },
        },
    },
}

-- Resolved once per class; class does not change within a session.
local activeRules

-- Reused between passes so a refresh allocates nothing.
local glowNames = {}

-- Picks the rules that apply to the current character, dropping SoD-only rules
-- off Season of Discovery.
function Highlights:ResolveRules()
    activeRules = {}

    local _, classToken = UnitClass("player")
    local classRules = RULES[classToken or ""]
    if not classRules then return end

    for _, rule in ipairs(classRules) do
        if not rule.sod or ns.Compat.isSoD then
            activeRules[#activeRules + 1] = rule
        end
    end
end

-- Whether a rule's aura condition is currently met.
function Highlights:RuleActive(rule)
    local data = ns.Auras:LookupByName(rule.aura)
    if not data then return false end

    if rule.minStacks then
        local stacks = data.applications or data.count or 0
        if stacks < rule.minStacks then return false end
    end

    return true
end

-- Recomputes which tracked icons should glow and applies it. Called from the
-- refresh pass, so it rides UNIT_AURA and every other update without its own
-- event registration. Highlighting is opt-in; when it is off, every icon is
-- cleared so turning it off takes effect immediately.
function Highlights:Apply()
    if not activeRules then self:ResolveRules() end

    wipe(glowNames)

    local enabled = ns.DB and ns.DB:AreHighlightsEnabled()
    if enabled then
        for _, rule in ipairs(activeRules) do
            if self:RuleActive(rule) then
                for _, name in ipairs(rule.glow) do
                    glowNames[name] = true
                end
            end
        end
    end

    -- Only cooldown icon groups. Aura groups are skipped (a buff icon is only on
    -- screen while its own aura is up, so a proc glow there is meaningless), and
    -- so are bar-rendered groups: the cooldown-bars group draws BuffBar widgets,
    -- which are not icons and have no border to glow.
    for _, key in ipairs(Const.GROUP_ORDER) do
        if not Const.AURA_GROUPS[key] then
            local group = ns.groups[key]
            if group and group.widget ~= ns.BuffBar then
                for _, icon in ipairs(group.icons) do
                    local name = icon.entry and icon.entry.name
                    ns.Icon:SetGlow(icon, name ~= nil and glowNames[name] == true)
                end
            end
        end
    end
end

-- The active rule set depends only on class, but a profile switch may change the
-- enable state; re-resolving is cheap insurance.
function Highlights:OnProfileChanged()
    activeRules = nil
end
