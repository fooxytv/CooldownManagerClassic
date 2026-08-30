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

local COMBAT_RULES = {
    WARRIOR = {
        { spell = "Overpower", window = 5, trigger = "target_dodged" },
        { spell = "Revenge", window = 5, trigger = "player_avoided" },
    },
    ROGUE = {
        { spell = "Riposte", window = 5, trigger = "player_parried" },
    },
}

local TRIGGERS = {
    target_dodged  = function(miss, byPlayer) return byPlayer and miss == "DODGE" end,
    player_avoided = function(miss, _, onPlayer)
        return onPlayer and (miss == "DODGE" or miss == "PARRY" or miss == "BLOCK")
    end,
    player_parried = function(miss, _, onPlayer) return onPlayer and miss == "PARRY" end,
}

local activeRules
local activeCombatRules
local glowNames = {}
local overlaySpells = {}
local overlayAny = false
local reactiveUntil = {}
local reactiveAny = false

function Highlights:ResolveRules()
    activeRules = {}
    activeCombatRules = {}

    local _, classToken = UnitClass("player")

    local classRules = RULES[classToken or ""]
    if classRules then
        for _, rule in ipairs(classRules) do
            if not rule.sod or ns.Compat.isSoD then
                activeRules[#activeRules + 1] = rule
            end
        end
    end

    local combatRules = COMBAT_RULES[classToken or ""]
    if combatRules then
        for _, rule in ipairs(combatRules) do
            activeCombatRules[#activeCombatRules + 1] = rule
        end
    end
end

function Highlights:HasCombatRules()
    if not activeCombatRules then self:ResolveRules() end
    return #activeCombatRules > 0
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

-- Whether a Classic client fires a proc overlay at all is the question behind
-- #76: if it does, following it is how the glow stays in step with the action
-- bar; if it never fires, the bar is lighting from plain usability and there is
-- nothing here to follow. Counted rather than reasoned about, and reported by
-- /cdmc status, because the answer differs per flavour and per ability.
Highlights.overlayEventCount = 0
Highlights.overlayLastSpell = nil

function Highlights:OnOverlayShow(spellID)
    if not spellID then return end
    overlaySpells[spellID] = true
    overlayAny = true

    self.overlayEventCount = (self.overlayEventCount or 0) + 1
    self.overlayLastSpell = ns.Spellbook:GetName(spellID) or tostring(spellID)
end

function Highlights:OnOverlayHide(spellID)
    if not spellID then return end
    overlaySpells[spellID] = nil
    overlayAny = next(overlaySpells) ~= nil
end

function Highlights:OnCombatLogEvent()
    if not activeCombatRules or #activeCombatRules == 0 then return end
    if not (ns.DB and ns.DB:AreHighlightsEnabled()) then return end

    -- Positions, 1-indexed, after the eleven shared parameters:
    --   SWING_MISSED   12 missType
    --   SPELL_MISSED   12 spellId, 13 spellName, 14 school, 15 missType
    --   SWING_DAMAGE   12 amount .. 16 blocked
    --   SPELL_DAMAGE   12 spellId .. 15 amount .. 19 blocked
    local _, subevent, _, sourceGUID, _, _, _, destGUID,
          _, _, _, arg12, arg13, _, arg15, arg16, _, _, arg19
          = CombatLogGetCurrentEventInfo()

    local playerGUID = UnitGUID("player")

    if subevent == "SPELL_CAST_SUCCESS" then
        if sourceGUID == playerGUID and arg13 and reactiveUntil[arg13] then
            reactiveUntil[arg13] = nil
            reactiveAny = next(reactiveUntil) ~= nil
            self:Apply()
        end
        return
    end

    -- Only a *full* block arrives as a miss. A partial one lands as damage
    -- carrying a blocked amount, which is the common case for anyone holding a
    -- shield -- so reading misses alone dropped most of the blocks a tank
    -- actually gets, and the glow fired far less often than the action bar.
    local miss
    if subevent == "SWING_MISSED" then
        miss = arg12
    elseif subevent == "SPELL_MISSED" or subevent == "RANGE_MISSED" then
        miss = arg15
    elseif subevent == "SWING_DAMAGE" then
        if (arg16 or 0) > 0 then miss = "BLOCK" end
    elseif subevent == "SPELL_DAMAGE" or subevent == "RANGE_DAMAGE" then
        if (arg19 or 0) > 0 then miss = "BLOCK" end
    else
        return
    end
    if not miss then return end

    local byPlayer = sourceGUID == playerGUID
    local onPlayer = destGUID == playerGUID
    if not (byPlayer or onPlayer) then return end

    local now = GetTime()
    local armed, longest = false, 0
    for _, rule in ipairs(activeCombatRules) do
        local predicate = TRIGGERS[rule.trigger]
        if predicate and predicate(miss, byPlayer, onPlayer) then
            reactiveUntil[rule.spell] = now + rule.window
            reactiveAny = true
            armed = true
            if rule.window > longest then longest = rule.window end
        end
    end

    if armed then
        self:Apply()
        C_Timer.After(longest + 0.1, function() ns.Highlights:Apply() end)
    end
end

local function IsQueued(spellID)
    if not spellID then return false end
    if not ns.Compat.IsSpellQueued(spellID) then return false end
    -- IsCurrentSpell is also true while a spell is being cast, which is not a
    -- queued swing.
    return (ns.Compat.GetSpellCastTime(spellID) or 0) <= 0
end

-- A glow should mean "press this now", which is what the action bar means by
-- lighting a button. Arming a rule only says the trigger happened: a Warrior
-- can be parried in a stance the reactive ability cannot be used from, or
-- parried again while it is still recharging. Without this the glow fires in
-- both.
--
-- The client is asked rather than any stance or form rule being written down
-- here. Season of Discovery already breaks such a rule -- Gladiator Stance
-- makes Defensive Stance abilities castable where they otherwise are not -- and
-- a rune added later would break it again. IsSpellUsable knows; a table here
-- would only be a second, staler opinion.
--
-- state.available is deliberately true during the global cooldown -- every
-- ability is briefly on cooldown each global, and dropping the glow for that
-- would flicker it off and on continuously through a rotation.
local function Castable(spellID)
    if not spellID then return false end
    if not ns.Compat.IsSpellUsable(spellID) then return false end
    return ns.Cooldowns:GetState(spellID, false).available and true or false
end

function Highlights:Apply()
    if not activeRules then self:ResolveRules() end

    wipe(glowNames)

    local anyEnabled = ns.DB and ns.DB:AreHighlightsEnabled()
    if anyEnabled then
        for _, rule in ipairs(activeRules) do
            if self:RuleActive(rule) then
                for _, name in ipairs(rule.glow) do
                    glowNames[name] = true
                end
            end
        end

        if overlayAny then
            for spellID in pairs(overlaySpells) do
                local name = ns.Spellbook:GetName(spellID)
                if name then glowNames[name] = true end
            end
        end

        if reactiveAny then
            local now = GetTime()
            local stillAny = false
            for name, expiry in pairs(reactiveUntil) do
                if expiry > now then
                    glowNames[name] = true
                    stillAny = true
                else
                    reactiveUntil[name] = nil
                end
            end
            reactiveAny = stillAny
        end
    end

    for _, key in ipairs(Const.GROUP_ORDER) do
        if not Const.AURA_GROUPS[key] then
            local group = ns.groups[key]
            if group then
                local on = anyEnabled and ns.DB:IsGroupHighlightEnabled(key)
                local widget = group.widget == ns.BuffBar and ns.BuffBar or ns.Icon
                for _, item in ipairs(group.icons) do
                    local name = item.entry and item.entry.name
                    -- Castable is only asked once a rule already wants this
                    -- icon lit, which is almost never more than one of them:
                    -- Lua stops at the first false, so the cooldown lookup does
                    -- not run for every tracked spell on every pass.
                    local wanted = on and name ~= nil and glowNames[name] == true
                    widget:SetGlow(item, wanted and Castable(item.spellID))
                    widget:SetQueued(item, on and IsQueued(item.spellID))
                end
            end
        end
    end
end

function Highlights:OnProfileChanged()
    activeRules = nil
    activeCombatRules = nil
end
