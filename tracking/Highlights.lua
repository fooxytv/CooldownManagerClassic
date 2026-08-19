local addonName, ns = ...

local Const = ns.Constants

local Highlights = {}
ns.Highlights = Highlights

local RULES = {
    SHAMAN = {
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
        {
            aura = "Shadow Trance",
            glow = { "Shadow Bolt" },
        },
    },
}

local activeRules

local glowNames = {}

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

function Highlights:RuleActive(rule)
    local data = ns.Auras:LookupByName(rule.aura)
    if not data then return false end

    if rule.minStacks then
        local stacks = data.applications or data.count or 0
        if stacks < rule.minStacks then return false end
    end

    return true
end

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

function Highlights:OnProfileChanged()
    activeRules = nil
end
