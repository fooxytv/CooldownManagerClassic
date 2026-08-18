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

-- The target's player-cast debuffs (DoTs), kept as their own index so the target
-- changing or its auras ticking never forces the player index to rebuild, and
-- vice versa. Rebuilt on PLAYER_TARGET_CHANGED and the target's UNIT_AURA.
local targetByID = {}
local targetByName = {}
local targetDirty = true
local targetBuiltAt = 0

local INDEX_MAX_AGE = 1.0

function Auras:MarkDirty()
    indexDirty = true
end

function Auras:MarkTargetDirty()
    targetDirty = true
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

-- Snapshot of the player's own debuffs on the current target, keyed by ID and by
-- name -- the DoT source a cooldown bar reads when its ability has no cooldown
-- of its own (Moonfire, Sunfire).
function Auras:RefreshTargetIndex(force)
    local now = GetTime()
    if not force and not targetDirty and (now - targetBuiltAt) < INDEX_MAX_AGE then
        return
    end

    wipe(targetByID)
    wipe(targetByName)

    Compat.ForEachPlayerDebuffOn("target", function(aura)
        if aura.spellId then targetByID[aura.spellId] = aura end
        if aura.name and not targetByName[aura.name] then
            targetByName[aura.name] = aura
        end
    end)

    targetDirty = false
    targetBuiltAt = now
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

-- Projects an aura data table (or nil) onto the shared state shape the icon and
-- bar widgets render. Reused by the player-buff and target-DoT paths so both
-- read timers, stacks and the not-up case identically.
local function FillAuraState(state, spellID, aura)
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

function Auras:GetState(spellID)
    if ns.Constants.IsWeaponEnchantID(spellID) then
        return self:GetWeaponEnchantState(spellID)
    end

    local state = cache[spellID]
    if not state then
        state = {}
        cache[spellID] = state
    end

    return FillAuraState(state, spellID, self:Lookup(spellID))
end

-- The player's own debuff on the target for this spell, or nil. Uses the same
-- name fallback as the player path, since a DoT's aura ID often differs from the
-- cast (many SoD runes, some ranks).
function Auras:LookupTargetDot(spellID)
    self:RefreshTargetIndex()

    local data = targetByID[spellID]
    if data then return data end

    local name = ns.Spellbook:GetName(spellID)
    if not name then return nil end

    return targetByName[name]
end

-- Kept in its own cache, not GetState's: for a DoT the player buff (none) and
-- the target debuff share a spell ID, and one must not overwrite the other.
local targetCache = {}
function Auras:GetTargetDotState(spellID)
    local state = targetCache[spellID]
    if not state then
        state = {}
        targetCache[spellID] = state
    end

    return FillAuraState(state, spellID, self:LookupTargetDot(spellID))
end

-- The state an aura-tracked entry should show. Unflagged, that is the aura on
-- the player. Flagged, the ability is followed by whatever aura it leaves: the
-- player's own buff when one is up, and the debuff on the target otherwise.
--
-- The flag used to *replace* the player lookup with the target one, which meant
-- ticking it on an ability whose payload is a self-buff (Slice and Dice) stopped
-- it being tracked at all. Preferring the player buff also matches
-- Cooldowns:GetBarState, which has always read it first.
function Auras:GetTrackedState(spellID, trackAura)
    local player = self:GetState(spellID)
    if not trackAura then return player end

    if player and player.active and (player.remaining or 0) > 0 then
        return player
    end

    local dot = self:GetTargetDotState(spellID)
    if dot and dot.active and (dot.remaining or 0) > 0 then
        return dot
    end

    -- Neither is up. The player state stands in, so an inactive entry reads the
    -- same as any other.
    return player
end

function Auras:ClearCache()
    wipe(cache)
    wipe(targetCache)
    self:MarkDirty()
    self:MarkTargetDirty()
end
