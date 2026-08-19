local addonName, ns = ...

local Compat = ns.Compat

local Auras = {}
ns.Auras = Auras

local cache = {}

local indexByID = {}
local indexByName = {}
local indexDirty = true
local indexBuiltAt = 0

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

    Compat.ForEachPlayerAura(function(aura)
        if aura.spellId then indexByID[aura.spellId] = aura end
        if aura.name and not indexByName[aura.name] then
            indexByName[aura.name] = aura
        end
    end)

    indexDirty = false
    indexBuiltAt = now
end

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

function Auras:Lookup(spellID)
    self:RefreshIndex()

    local data = indexByID[spellID]
    if data then return data end

    local name = ns.Spellbook:GetName(spellID)
    if not name then return nil end

    return indexByName[name]
end

function Auras:LookupByName(name)
    if not name then return nil end
    self:RefreshIndex()
    return indexByName[name]
end

function Auras:StacksByName(name)
    local data = self:LookupByName(name)
    if not data then return 0 end
    return data.applications or data.count or 0
end

local enchantMaxSeen = {}

function Auras:GetWeaponEnchantState(spellID)
    local Const = ns.Constants
    local enchant = Const.WEAPON_ENCHANT_BY_ID[spellID]

    local state = cache[spellID]
    if not state then
        state = {}
        cache[spellID] = state
    end

    local hasEnchant, remaining, charges = Compat.GetWeaponEnchant(enchant.hand)

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

local function FillAuraState(state, spellID, aura)
    state.spellID = spellID
    state.aura = aura
    state.available = aura ~= nil
    state.active = aura ~= nil
    state.charges = aura and (aura.applications or aura.count) or nil
    state.maxCharges = nil
    state.isGCD = false

    if aura and aura.duration and aura.duration > 0 and aura.expirationTime then
        state.swipeStart = aura.expirationTime - aura.duration
        state.swipeDuration = aura.duration
        state.swipeModRate = aura.timeMod or 1
        state.remaining = math.max(0, aura.expirationTime - GetTime())
    else
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

function Auras:LookupTargetDot(spellID)
    self:RefreshTargetIndex()

    local data = targetByID[spellID]
    if data then return data end

    local name = ns.Spellbook:GetName(spellID)
    if not name then return nil end

    return targetByName[name]
end

local targetCache = {}
function Auras:GetTargetDotState(spellID)
    local state = targetCache[spellID]
    if not state then
        state = {}
        targetCache[spellID] = state
    end

    return FillAuraState(state, spellID, self:LookupTargetDot(spellID))
end

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

    return player
end

function Auras:ClearCache()
    wipe(cache)
    wipe(targetCache)
    self:MarkDirty()
    self:MarkTargetDirty()
end
