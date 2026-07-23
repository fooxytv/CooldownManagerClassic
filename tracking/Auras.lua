local addonName, ns = ...

local Compat = ns.Compat

local Auras = {}
ns.Auras = Auras

local cache = {}

--------------------------------------------------------------------------------
-- Aura index
--------------------------------------------------------------------------------

-- A snapshot of the player's auras, keyed by spell ID and by name.
--
-- Without this, every tracked buff scanned the whole aura list up to three times
-- (by ID helpful, by ID harmful, then by name) on every single update. With a
-- handful of buffs at ten updates a second that is thousands of API calls and
-- table allocations per second, which is exactly how this addon reached 2% CPU
-- and double-digit megabytes.
--
-- The snapshot is rebuilt only when UNIT_AURA says something changed, or after
-- a slow safety interval, and every lookup is then a hash lookup.

local indexByID = {}
local indexByName = {}
local indexDirty = true
local indexBuiltAt = 0

local INDEX_MAX_AGE = 1.0

function Auras:MarkDirty()
    indexDirty = true
end

function Auras:RefreshIndex(force)
    local now = GetTime()
    if not force and not indexDirty and (now - indexBuiltAt) < INDEX_MAX_AGE then
        return
    end

    wipe(indexByID)
    wipe(indexByName)

    for _, aura in ipairs(Compat.GetPlayerAuras(true, true)) do
        if aura.spellID then indexByID[aura.spellID] = aura end
        if aura.name and not indexByName[aura.name] then
            indexByName[aura.name] = aura
        end
    end

    indexDirty = false
    indexBuiltAt = now
end

--- Finds an aura by exact ID, falling back to name.
---
--- The name fallback matters because the aura a spell applies very often has a
--- different spell ID from the spell you cast -- true of most Season of
--- Discovery runes.
function Auras:Lookup(spellID)
    self:RefreshIndex()

    local data = indexByID[spellID]
    if data then return data end

    local name = ns.Spellbook:GetName(spellID)
    if not name then return nil end

    return indexByName[name]
end

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

    -- Reused rather than reallocated: this runs on every update tick.
    state.enchantAura = state.enchantAura or { name = enchant.label }

    state.spellID = spellID
    state.aura = hasEnchant and state.enchantAura or nil
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

    local aura = self:Lookup(spellID)

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
    self:MarkDirty()
end
