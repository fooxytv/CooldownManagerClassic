local addonName, ns = ...

local Const = ns.Constants
local Compat = ns.Compat

local Cooldowns = {}
ns.Cooldowns = Cooldowns

local cache = {}

Cooldowns.gcdStart = 0
Cooldowns.gcdDuration = 0

function Cooldowns:IsGlobalCooldownActive()
    return self.gcdDuration > 0
        and (self.gcdStart + self.gcdDuration) > GetTime()
end

function Cooldowns:RefreshGlobalCooldown(spellIDs)
    if self:IsGlobalCooldownActive() then return end

    self.gcdStart = 0
    self.gcdDuration = 0

    for _, spellID in ipairs(spellIDs) do
        local start, duration = Compat.GetSpellCooldown(spellID)
        if duration and duration > 0 and duration <= Const.GCD_THRESHOLD then
            self.gcdStart = start
            self.gcdDuration = duration
            return
        end
    end
end

function Cooldowns:GetState(spellID, showGCD)
    local state = cache[spellID]
    if not state then
        state = {}
        cache[spellID] = state
    end

    state.usable, state.notEnoughPower = Compat.IsSpellUsable(spellID)

    state.aura = nil

    local start, duration, enabled, modRate = Compat.GetSpellCooldown(spellID)
    local charges, maxCharges, chargeStart, chargeDuration, chargeModRate = Compat.GetSpellCharges(spellID)

    state.spellID = spellID
    state.start = start
    state.duration = duration
    state.enabled = enabled
    state.modRate = modRate
    state.charges = charges
    state.maxCharges = maxCharges

    state.isGCD = duration > 0 and duration <= Const.GCD_THRESHOLD

    if charges and maxCharges and maxCharges > 1 then
        state.available = charges > 0
        state.swipeStart = chargeStart or 0
        state.swipeDuration = (charges < maxCharges and chargeDuration) or 0
        state.swipeModRate = chargeModRate or 1
        state.remaining = 0
        if state.swipeDuration > 0 then
            state.remaining = math.max(0, (state.swipeStart + state.swipeDuration) - GetTime())
        end
    else
        state.available = (duration == 0) or state.isGCD

        local onRealCooldown = duration > 0 and not state.isGCD
        if onRealCooldown then
            state.swipeStart = start
            state.swipeDuration = duration
            state.swipeModRate = modRate
        elseif showGCD and self:IsGlobalCooldownActive() then
            state.swipeStart = self.gcdStart
            state.swipeDuration = self.gcdDuration
            state.swipeModRate = 1
            state.isGCD = true
        else
            state.swipeStart = 0
            state.swipeDuration = 0
            state.swipeModRate = modRate
        end

        state.remaining = 0
        if state.swipeDuration > 0 then
            state.remaining = math.max(0, (state.swipeStart + state.swipeDuration) - GetTime())
        end
    end

    state.suppressText = state.isGCD

    if not enabled then
        state.available = false
    end

    state.active = state.remaining > 0

    return state
end

function Cooldowns:GetIconState(spellID, showGCD, trackAura)
    local state = self:GetState(spellID, showGCD)
    if not trackAura then return state end

    local aura = ns.Auras:GetState(spellID)
    if not (aura and aura.active and (aura.remaining or 0) > 0) then
        aura = ns.Auras:GetTargetDotState(spellID)
    end

    if aura and aura.active and (aura.remaining or 0) > 0 then
        state.swipeStart = aura.swipeStart
        state.swipeDuration = aura.swipeDuration
        state.swipeModRate = aura.swipeModRate
        state.remaining = aura.remaining
        state.active = true
        state.isGCD = false
        state.suppressText = false
        state.aura = aura.aura
    end

    return state
end

local barCache = {}
function Cooldowns:GetBarState(spellID, trackAura)
    local state = barCache[spellID]
    if not state then
        state = {}
        barCache[spellID] = state
    end

    local aura = ns.Auras:GetState(spellID)
    if trackAura and not (aura and aura.active and (aura.remaining or 0) > 0) then
        aura = ns.Auras:GetTargetDotState(spellID)
    end

    if aura and aura.active and (aura.remaining or 0) > 0 then
        state.phase = "active"
        state.swipeDuration = aura.swipeDuration
        state.remaining = aura.remaining
        state.active = true
        state.available = true
        state.usable = true
        state.notEnoughPower = false
        state.charges = aura.charges
        state.isGCD = false
        state.suppressText = false
        return state
    end

    local cd = self:GetState(spellID, false)
    state.phase = (cd.remaining or 0) > 0 and "cooldown" or "ready"
    state.swipeDuration = cd.swipeDuration
    state.remaining = cd.remaining
    state.active = cd.active
    state.available = cd.available
    state.usable = cd.usable
    state.notEnoughPower = cd.notEnoughPower
    state.charges = cd.charges
    state.isGCD = cd.isGCD
    state.suppressText = cd.suppressText
    return state
end

function Cooldowns:ClearCache()
    wipe(cache)
    wipe(barCache)
end
