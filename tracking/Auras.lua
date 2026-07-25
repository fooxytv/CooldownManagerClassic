local addonName, ns = ...

local Compat = ns.Compat

local Auras = {}
ns.Auras = Auras

local cache = {}

-- Snapshot of the player's auras, keyed by ID and by name, rebuilt only when
-- UNIT_AURA says something changed. Without it each tracked buff walked the
-- whole aura list three times (ID helpful, ID harmful, name) per update, which
-- is how this addon once reached 2% CPU and double-digit megabytes.
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

    -- Full aura data, not the picker's projection, which drops the duration,
    -- expiration and stack count the display needs.
    Compat.ForEachPlayerAura(function(aura)
        if aura.spellId then indexByID[aura.spellId] = aura end
        if aura.name and not indexByName[aura.name] then
            indexByName[aura.name] = aura
        end
    end)

    indexDirty = false
    indexBuiltAt = now
end

-- The name fallback is load-bearing: the aura a spell applies often has a
-- different ID from the spell cast, true of most SoD runes.
function Auras:Lookup(spellID)
    self:RefreshIndex()

    local data = indexByID[spellID]
    if data then return data end

    local name = ns.Spellbook:GetName(spellID)
    if not name then return nil end

    return indexByName[name]
end

-- The player aura with this exact name, or nil. Reaches an aura by name so a
-- caller that knows the buff's name but not a stable spell ID (Maelstrom Weapon
-- across ranks, a proc buff) can still find it.
function Auras:LookupByName(name)
    if not name then return nil end
    self:RefreshIndex()
    return indexByName[name]
end

-- Current stack count of a player aura found by name, or 0 if it is not up.
-- Used by the class-resource bar for Maelstrom Weapon, an ordinary stacking buff.
function Auras:StacksByName(name)
    local data = self:LookupByName(name)
    if not data then return 0 end
    return data.applications or data.count or 0
end

-- Longest remaining time seen per hand. GetWeaponEnchantInfo reports only what
-- is left, never the original duration, so the swipe needs a high-water mark to
-- sweep against. Self-corrects on the next reapplication.
local enchantMaxSeen = {}

-- Weapon enchants are not auras; this shapes one to look like Auras:GetState so
-- the icon widget renders either without branching.
function Auras:GetWeaponEnchantState(spellID)
    local Const = ns.Constants
    local enchant = Const.WEAPON_ENCHANT_BY_ID[spellID]

    local state = cache[spellID]
    if not state then
        state = {}
        cache[spellID] = state
    end

    local hasEnchant, remaining, charges = Compat.GetWeaponEnchant(enchant.hand)

    -- Reused, not reallocated: this runs on every update tick.
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
    local charges = aura and (aura.applications or aura.count) or nil
    state.charges = charges
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
