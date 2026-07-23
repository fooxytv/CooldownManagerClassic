local addonName, ns = ...

local Const = ns.Constants
local Compat = ns.Compat

local Cooldowns = {}
ns.Cooldowns = Cooldowns

--- Reads the live cooldown and charge state for a spell.
---
--- The returned table is reused per spell ID rather than allocated fresh, so
--- callers must consume it before asking for another spell.
local cache = {}

--------------------------------------------------------------------------------
-- Global cooldown
--------------------------------------------------------------------------------

-- The GCD is tracked once for the whole display rather than per spell.
--
-- Classic has no equivalent of retail's spell 61304 to read the GCD from, and
-- detecting it per spell fails whenever a particular spell ID does not report
-- one -- rune placeholders being the obvious case. Instead, any tracked spell
-- showing a short cooldown identifies the GCD, and that single timer is then
-- applied to every icon that is not on a real cooldown of its own.

Cooldowns.gcdStart = 0
Cooldowns.gcdDuration = 0

function Cooldowns:IsGlobalCooldownActive()
    return self.gcdDuration > 0
        and (self.gcdStart + self.gcdDuration) > GetTime()
end

--- Finds the current global cooldown from any of the given spells.
function Cooldowns:RefreshGlobalCooldown(spellIDs)
    -- A GCD already in flight needs no re-detection; re-reading it every tick
    -- would only risk latching onto a different spell's short cooldown.
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

    local start, duration, enabled, modRate = Compat.GetSpellCooldown(spellID)
    local charges, maxCharges, chargeStart, chargeDuration, chargeModRate = Compat.GetSpellCharges(spellID)

    state.spellID = spellID
    state.start = start
    state.duration = duration
    state.enabled = enabled
    state.modRate = modRate
    state.charges = charges
    state.maxCharges = maxCharges

    -- A spell on the global cooldown is still usable as far as the display is
    -- concerned, so it must not be drawn as unavailable.
    state.isGCD = duration > 0 and duration <= Const.GCD_THRESHOLD

    if charges and maxCharges and maxCharges > 1 then
        -- With charges available the icon stays lit; the swipe shows progress
        -- towards the next charge instead.
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
            -- Not on a cooldown of its own, so show the shared global cooldown.
            -- Taking it from the global timer rather than this spell's own
            -- reading means icons whose spell ID reports no cooldown still
            -- sweep along with everything else.
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

    -- A GCD sweep should not print a countdown over every icon.
    state.suppressText = state.isGCD

    -- Cooldowns paused by the client (enabled == false) read as a running
    -- cooldown of unknown length; treat them as unavailable but static.
    if not enabled then
        state.available = false
    end

    state.active = state.remaining > 0

    return state
end

-- Merged state for a duration bar: the effect the ability applies takes
-- precedence over its recharge. `phase` tells the widget which it is.
--
--   active    the ability's aura is on the player -- show its remaining
--             duration (Barkskin's 8s), bright
--   cooldown  no effect up but the ability is recharging -- show the recharge,
--             dimmed
--   ready     neither: the ability is available now
--
-- The aura is matched by the ability's own spell ID, which is the same ID for
-- the great majority of self-buff defensives (Barkskin, Vampiric Blood, Ignore
-- Pain). Where the applied aura has a different ID it simply is not found and
-- the bar shows the recharge, which is no worse than an icon would manage.
local barCache = {}
function Cooldowns:GetBarState(spellID)
    local state = barCache[spellID]
    if not state then
        state = {}
        barCache[spellID] = state
    end

    local aura = ns.Auras:GetState(spellID)
    if aura and aura.active and (aura.remaining or 0) > 0 then
        state.phase = "active"
        state.swipeDuration = aura.swipeDuration
        state.remaining = aura.remaining
        state.active = true
        -- The effect is up, so the icon reads as "on" rather than greyed.
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
