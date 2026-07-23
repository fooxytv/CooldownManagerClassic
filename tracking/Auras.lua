local addonName, ns = ...

local Compat = ns.Compat

local Auras = {}
ns.Auras = Auras

local cache = {}

--- Reads the player's current aura state for a spell. Mirrors the shape of
--- Cooldowns:GetState so the icon widget can render either without branching
--- on which tracker produced it.
-- The longest remaining time seen per weapon hand. GetWeaponEnchantInfo reports
-- only what is left, never the original duration, so the swipe needs a
-- high-water mark to sweep against. It self-corrects on the next reapplication.
local enchantMaxSeen = {}

--- Weapon enchants are not auras, so they are read separately and shaped to
--- look like one for the rest of the addon.
function Auras:GetWeaponEnchantState(spellID)
    local Const = ns.Constants
    local enchant = Const.WEAPON_ENCHANT_BY_ID[spellID]

    local state = cache[spellID]
    if not state then
        state = {}
        cache[spellID] = state
    end

    local hasEnchant, remaining, charges = Compat.GetWeaponEnchant(enchant.hand)

    state.spellID = spellID
    state.aura = hasEnchant and { name = enchant.label } or nil
    state.available = hasEnchant
    state.active = hasEnchant
    state.charges = (charges and charges > 1) and charges or nil
    state.maxCharges = nil
    state.isGCD = false
    state.remaining = hasEnchant and remaining or 0

    if hasEnchant and remaining > 0 then
        local seen = enchantMaxSeen[enchant.hand] or 0
        if remaining > seen then
            seen = remaining
            enchantMaxSeen[enchant.hand] = seen
        end
        state.swipeStart = GetTime() - (seen - remaining)
        state.swipeDuration = seen
        state.swipeModRate = 1
    else
        enchantMaxSeen[enchant.hand] = nil
        state.swipeStart = 0
        state.swipeDuration = 0
        state.swipeModRate = 1
    end

    return state
end

function Auras:GetState(spellID)
    if ns.Constants.IsWeaponEnchantID(spellID) then
        return self:GetWeaponEnchantState(spellID)
    end

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
    -- `applications` on the modern aura data, `count` on the legacy path.
    state.charges = aura and (aura.applications or aura.count) or nil
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
