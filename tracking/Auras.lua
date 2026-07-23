local addonName, ns = ...

local Compat = ns.Compat

local Auras = {}
ns.Auras = Auras

local cache = {}

--- Reads the player's current aura state for a spell. Mirrors the shape of
--- Cooldowns:GetState so the icon widget can render either without branching
--- on which tracker produced it.
function Auras:GetState(spellID)
    local state = cache[spellID]
    if not state then
        state = {}
        cache[spellID] = state
    end

    local aura = Compat.GetPlayerAura(spellID)

    state.spellID = spellID
    state.aura = aura
    state.available = aura ~= nil
    state.active = aura ~= nil
    state.charges = aura and aura.applications or nil
    state.maxCharges = nil
    state.isGCD = false

    if aura and aura.duration and aura.duration > 0 and aura.expirationTime then
        state.swipeStart = aura.expirationTime - aura.duration
        state.swipeDuration = aura.duration
        state.swipeModRate = aura.timeMod or 1
        state.remaining = math.max(0, aura.expirationTime - GetTime())
    else
        -- Either no aura, or one with no timer (a permanent buff or a stance).
        state.swipeStart = 0
        state.swipeDuration = 0
        state.swipeModRate = 1
        state.remaining = 0
    end

    return state
end

function Auras:ClearCache()
    wipe(cache)
end
