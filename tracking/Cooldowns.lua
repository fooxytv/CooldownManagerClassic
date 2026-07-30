local addonName, ns = ...

local Const = ns.Constants
local Compat = ns.Compat

local Cooldowns = {}
ns.Cooldowns = Cooldowns

-- State tables are reused per spell ID, not allocated fresh, so a caller must
-- consume one before asking for another spell.
local cache = {}

-- Tracked once for the whole display: Classic has no equivalent of retail's
-- spell 61304 to read the GCD from, and detecting it per spell fails whenever a
-- given spell ID does not report one -- rune placeholders being the obvious
-- case. Any tracked spell showing a short cooldown identifies it instead.
Cooldowns.gcdStart = 0
Cooldowns.gcdDuration = 0

function Cooldowns:IsGlobalCooldownActive()
    return self.gcdDuration > 0
        and (self.gcdStart + self.gcdDuration) > GetTime()
end

function Cooldowns:RefreshGlobalCooldown(spellIDs)
    -- Re-reading one already in flight risks latching onto a different spell's
    -- short cooldown.
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

    -- Still usable as far as the display is concerned, so not drawn as
    -- unavailable.
    state.isGCD = duration > 0 and duration <= Const.GCD_THRESHOLD

    if charges and maxCharges and maxCharges > 1 then
        -- The icon stays lit while charges remain; the swipe shows progress
        -- towards the next one instead.
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
            -- From the shared timer, not this spell's own reading: icons whose
            -- spell ID reports no cooldown still sweep with everything else.
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

    -- enabled == false is a cooldown the client has paused: it reads as running
    -- but of unknown length, so it is unavailable but static.
    if not enabled then
        state.available = false
    end

    state.active = state.remaining > 0

    return state
end

-- Effect takes precedence over recharge. `phase` tells the widget which:
--   active    the aura is up -- show its remaining duration, bright
--   cooldown  no effect, but recharging -- show the recharge, dimmed
--   ready     available now
--
-- Matched on the ability's own spell ID, which is the same ID for most
-- self-buff defensives. Where the applied aura differs it is simply not found
-- and the bar shows the recharge, which is no worse than an icon manages.
local barCache = {}
function Cooldowns:GetBarState(spellID)
    local state = barCache[spellID]
    if not state then
        state = {}
        barCache[spellID] = state
    end

    -- The aura the ability leaves on the player (a defensive's own buff), then
    -- the DoT it leaves on the target (Moonfire, Sunfire -- no player buff, no
    -- real cooldown, so the target debuff is the only thing to count down).
    -- Either drives the "active" phase; the first that is up wins.
    local aura = ns.Auras:GetState(spellID)
    if not (aura and aura.active and (aura.remaining or 0) > 0) then
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
