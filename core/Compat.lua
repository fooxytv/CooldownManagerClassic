local addonName, ns = ...

-- Thin wrappers over the APIs that moved into C_* namespaces during the 1.15
-- line. Everything above this file talks to Compat and never to the globals
-- directly, so adding a new flavour means editing one file.

local Compat = {}
ns.Compat = Compat

local C_Spell_     = _G.C_Spell
local C_SpellBook_ = _G.C_SpellBook
local C_UnitAuras_ = _G.C_UnitAuras

--------------------------------------------------------------------------------
-- Flavour detection
--------------------------------------------------------------------------------

local projectId = _G.WOW_PROJECT_ID or 0

if projectId == (_G.WOW_PROJECT_CLASSIC or -1) then
    Compat.flavor = "era"
elseif projectId == (_G.WOW_PROJECT_BURNING_CRUSADE_CLASSIC or -2) then
    Compat.flavor = "tbc"
elseif projectId == (_G.WOW_PROJECT_WRATH_CLASSIC or -3) then
    Compat.flavor = "wrath"
elseif projectId == (_G.WOW_PROJECT_CATACLYSM_CLASSIC or -4) then
    Compat.flavor = "cata"
elseif projectId == (_G.WOW_PROJECT_MISTS_CLASSIC or -5) then
    Compat.flavor = "mop"
elseif projectId == (_G.WOW_PROJECT_MAINLINE or -6) then
    Compat.flavor = "retail"
else
    Compat.flavor = "unknown"
end

Compat.interfaceVersion = select(4, GetBuildInfo()) or 0

-- Season of Discovery runs on the Era client, so it is only distinguishable by
-- the engraving system being switched on.
Compat.isSoD = false
if Compat.flavor == "era" and _G.C_Engraving and C_Engraving.IsEngravingEnabled then
    local ok, enabled = pcall(C_Engraving.IsEngravingEnabled)
    Compat.isSoD = (ok and enabled) or false
end

-- The value stamped into exported profiles so an import can warn on mismatch.
function Compat.GetProfileFlavor()
    if Compat.isSoD then return "sod" end
    return Compat.flavor
end

--------------------------------------------------------------------------------
-- Spell info
--------------------------------------------------------------------------------

--- Returns name, icon, spellID for a spell ID or name.
function Compat.GetSpellInfo(identifier)
    if not identifier then return nil end

    if C_Spell_ and C_Spell_.GetSpellInfo then
        local info = C_Spell_.GetSpellInfo(identifier)
        if info then
            return info.name, info.iconID, info.spellID
        end
        return nil
    end

    local name, _, icon, _, _, _, spellID = GetSpellInfo(identifier)
    if not name then return nil end
    return name, icon, spellID or (type(identifier) == "number" and identifier or nil)
end

function Compat.IsSpellKnown(spellID)
    if not spellID then return false end

    -- Every source is tried in turn rather than committing to the C_SpellBook
    -- namespace on sight: on some builds the namespace exists but these
    -- particular functions do not, and returning early there would report every
    -- spell as unknown.
    if C_SpellBook_ then
        if C_SpellBook_.IsSpellKnown and C_SpellBook_.IsSpellKnown(spellID) then
            return true
        end
        if C_SpellBook_.IsSpellKnownOrInSpellBook and C_SpellBook_.IsSpellKnownOrInSpellBook(spellID) then
            return true
        end
    end

    if _G.IsSpellKnown and IsSpellKnown(spellID) then return true end
    if _G.IsPlayerSpell and IsPlayerSpell(spellID) then return true end
    return false
end

--------------------------------------------------------------------------------
-- Cooldowns and charges
--------------------------------------------------------------------------------

--- Returns start, duration, enabled, modRate. Never returns nil.
function Compat.GetSpellCooldown(spellID)
    if not spellID then return 0, 0, false, 1 end

    if C_Spell_ and C_Spell_.GetSpellCooldown then
        local info = C_Spell_.GetSpellCooldown(spellID)
        if not info then return 0, 0, false, 1 end
        return info.startTime or 0, info.duration or 0, info.isEnabled and true or false, info.modRate or 1
    end

    if _G.GetSpellCooldown then
        local start, duration, enabled, modRate = GetSpellCooldown(spellID)
        return start or 0, duration or 0, (enabled == 1 or enabled == true), modRate or 1
    end

    return 0, 0, false, 1
end

--- Returns currentCharges, maxCharges, start, duration, modRate, or nil when
--- the spell has no charge system (the common case on Era).
function Compat.GetSpellCharges(spellID)
    if not spellID then return nil end

    if C_Spell_ and C_Spell_.GetSpellCharges then
        local info = C_Spell_.GetSpellCharges(spellID)
        if not info then return nil end
        return info.currentCharges, info.maxCharges, info.cooldownStartTime,
               info.cooldownDuration, info.chargeModRate or 1
    end

    if _G.GetSpellCharges then
        return GetSpellCharges(spellID)
    end

    return nil
end

--- Returns usable, notEnoughPower. Drives the icon tint the same way Blizzard's
--- CooldownViewerCooldownItemMixin:RefreshIconColor does.
function Compat.IsSpellUsable(spellID)
    if not spellID then return true, false end

    if C_Spell_ and C_Spell_.IsSpellUsable then
        local usable, noPower = C_Spell_.IsSpellUsable(spellID)
        return usable and true or false, noPower and true or false
    end

    if _G.IsUsableSpell then
        local usable, noPower = IsUsableSpell(spellID)
        return usable and true or false, noPower and true or false
    end

    return true, false
end

--------------------------------------------------------------------------------
-- Auras
--------------------------------------------------------------------------------

local function ScanPlayerAura(spellID, filter)
    if C_UnitAuras_ and C_UnitAuras_.GetAuraDataByIndex then
        for i = 1, 40 do
            local data = C_UnitAuras_.GetAuraDataByIndex("player", i, filter)
            if not data then break end
            if data.spellId == spellID then return data end
        end
        return nil
    end

    if not _G.UnitAura then return nil end
    for i = 1, 40 do
        local name, icon, count, dispelType, duration, expirationTime,
              source, isStealable, nameplateShowPersonal, auraSpellID = UnitAura("player", i, filter)
        if not name then break end
        if auraSpellID == spellID then
            return {
                name = name,
                icon = icon,
                applications = count,
                dispelName = dispelType,
                duration = duration,
                expirationTime = expirationTime,
                sourceUnit = source,
                isStealable = isStealable,
                spellId = auraSpellID,
            }
        end
    end
    return nil
end

local function ScanPlayerAuraByName(auraName, filter)
    if C_UnitAuras_ and C_UnitAuras_.GetAuraDataByIndex then
        for i = 1, 40 do
            local data = C_UnitAuras_.GetAuraDataByIndex("player", i, filter)
            if not data then break end
            if data.name == auraName then return data end
        end
        return nil
    end

    if not _G.UnitAura then return nil end
    for i = 1, 40 do
        local name, icon, count, dispelType, duration, expirationTime,
              source, isStealable, _, auraSpellID = UnitAura("player", i, filter)
        if not name then break end
        if name == auraName then
            return {
                name = name,
                icon = icon,
                applications = count,
                dispelName = dispelType,
                duration = duration,
                expirationTime = expirationTime,
                sourceUnit = source,
                isStealable = isStealable,
                spellId = auraSpellID,
            }
        end
    end
    return nil
end

--- Walks every aura on the player, passing full aura data to the callback.
---
--- Deliberately separate from GetPlayerAuras, which projects down to just
--- spellID/name/icon for the picker. Anything that needs to *display* an aura
--- needs its duration, expiration and stack count too, and indexing the
--- projection instead of the real thing silently drops all three.
function Compat.ForEachPlayerAura(callback)
    local function Walk(filter)
        for i = 1, 40 do
            if C_UnitAuras_ and C_UnitAuras_.GetAuraDataByIndex then
                local data = C_UnitAuras_.GetAuraDataByIndex("player", i, filter)
                if not data then return end
                callback(data)
            elseif _G.UnitAura then
                local name, icon, count, dispelType, duration, expirationTime,
                      source, isStealable, _, auraSpellID, _, _, _, _, timeMod = UnitAura("player", i, filter)
                if not name then return end
                callback({
                    name = name,
                    icon = icon,
                    applications = count,
                    dispelName = dispelType,
                    duration = duration,
                    expirationTime = expirationTime,
                    sourceUnit = source,
                    isStealable = isStealable,
                    spellId = auraSpellID,
                    timeMod = timeMod,
                })
            else
                return
            end
        end
    end

    Walk("HELPFUL")
    Walk("HARMFUL")
end

--- Returns an aura data table for a buff or debuff on the player, or nil.
function Compat.GetPlayerAura(spellID)
    if not spellID then return nil end

    if C_UnitAuras_ and C_UnitAuras_.GetPlayerAuraBySpellID then
        local data = C_UnitAuras_.GetPlayerAuraBySpellID(spellID)
        if data then return data end
        -- GetPlayerAuraBySpellID only matches the exact ID; fall through so a
        -- lower-rank application of the same spell is still found.
    end

    local byID = ScanPlayerAura(spellID, "HELPFUL") or ScanPlayerAura(spellID, "HARMFUL")
    if byID then return byID end

    -- Last resort: match on name. The aura a spell applies very often has a
    -- different spell ID from the spell you cast -- true of most Season of
    -- Discovery runes -- so an ID-only match silently tracks nothing.
    local name = Compat.GetSpellInfo(spellID)
    if not name then return nil end

    return ScanPlayerAuraByName(name, "HELPFUL") or ScanPlayerAuraByName(name, "HARMFUL")
end

--------------------------------------------------------------------------------
-- Spellbook
--------------------------------------------------------------------------------

-- Enum.SpellBookSpellBank.Player is 0. Defaulting to that rather than treating a
-- missing enum as "no modern API" matters: a build can expose the C_SpellBook
-- functions without the enum, and refusing the modern path there would fall
-- back to globals that no longer exist, yielding an empty spellbook and no error.
local PLAYER_BANK = (_G.Enum and _G.Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
local LEGACY_BOOKTYPE = _G.BOOKTYPE_SPELL or "spell"

Compat.hasModernSpellBook = C_SpellBook_ ~= nil
    and C_SpellBook_.GetSpellBookItemInfo ~= nil
    and C_SpellBook_.GetNumSpellBookSkillLines ~= nil

Compat.hasLegacySpellBook = _G.GetNumSpellTabs ~= nil
    and _G.GetSpellBookItemInfo ~= nil

-- One flag drives every spellbook call, because the skill-line offsets and the
-- per-slot lookups have to index the same space: a modern offset fed into a
-- legacy item lookup silently reads the wrong slots.
local useModernSpellBook = Compat.hasModernSpellBook

local function DescribePath()
    if useModernSpellBook then return "C_SpellBook" end
    if Compat.hasLegacySpellBook then return "legacy" end
    return "none"
end

Compat.spellBookPath = DescribePath()

--- Switches which spellbook API is used. Spellbook:Scan() calls this to retry
--- on the other path when the preferred one returns nothing, so we do not have
--- to know up front which APIs a given Classic build kept.
function Compat.SetSpellBookPath(useModern)
    if useModern and not Compat.hasModernSpellBook then return false end
    if not useModern and not Compat.hasLegacySpellBook then return false end

    useModernSpellBook = useModern
    Compat.spellBookPath = DescribePath()
    return true
end

function Compat.IsUsingModernSpellBook()
    return useModernSpellBook
end

local function NormalizeItemType(itemType)
    if type(itemType) == "string" then
        return itemType:upper()
    end
    local E = _G.Enum and _G.Enum.SpellBookItemType
    if E then
        if itemType == E.Spell then return "SPELL" end
        if itemType == E.Flyout then return "FLYOUT" end
        if itemType == E.FutureSpell then return "FUTURESPELL" end
        if itemType == E.PetAction then return "PETACTION" end
    end
    return "UNKNOWN"
end

function Compat.GetNumSpellTabs()
    if useModernSpellBook then
        return C_SpellBook_.GetNumSpellBookSkillLines() or 0
    end
    return (_G.GetNumSpellTabs and GetNumSpellTabs()) or 0
end

--- Returns name, itemIndexOffset, numSpellBookItems for a skill line.
function Compat.GetSpellTabInfo(index)
    if useModernSpellBook then
        local info = C_SpellBook_.GetSpellBookSkillLineInfo(index)
        if not info then return nil end
        return info.name, info.itemIndexOffset, info.numSpellBookItems
    end
    if _G.GetSpellTabInfo then
        local name, _, offset, numSpells = GetSpellTabInfo(index)
        return name, offset, numSpells
    end
    return nil
end

--- Returns spellID, itemType, name, subName for a spellbook slot.
--- itemType is normalised to a string: SPELL, FLYOUT, FUTURESPELL, PETACTION.
function Compat.GetSpellBookItem(index)
    if useModernSpellBook then
        local info = C_SpellBook_.GetSpellBookItemInfo(index, PLAYER_BANK)
        if not info then return nil end
        local name, subName
        if C_SpellBook_.GetSpellBookItemName then
            name, subName = C_SpellBook_.GetSpellBookItemName(index, PLAYER_BANK)
        end
        return info.spellID, NormalizeItemType(info.itemType), name or info.name, subName
    end

    if _G.GetSpellBookItemInfo then
        local itemType, id = GetSpellBookItemInfo(index, LEGACY_BOOKTYPE)
        local name, subName
        if _G.GetSpellBookItemName then
            name, subName = GetSpellBookItemName(index, LEGACY_BOOKTYPE)
        end
        return id, NormalizeItemType(itemType), name, subName
    end

    return nil
end

--- Reports what each spellbook API actually returns for the first slot, so a
--- failed scan can be diagnosed without guessing which functions this build has.
function Compat.ProbeSpellBook()
    local lines = {}

    lines[#lines + 1] = ("C_SpellBook: %s | modern usable: %s | legacy usable: %s | bank: %s")
        :format(tostring(C_SpellBook_ ~= nil), tostring(Compat.hasModernSpellBook),
                tostring(Compat.hasLegacySpellBook), tostring(PLAYER_BANK))

    if Compat.hasModernSpellBook then
        local ok, lines1 = pcall(C_SpellBook_.GetNumSpellBookSkillLines)
        local okInfo, info = pcall(C_SpellBook_.GetSpellBookItemInfo, 1, PLAYER_BANK)
        lines[#lines + 1] = ("  modern: skillLines=%s slot1=%s spellID=%s name=%s")
            :format(tostring(ok and lines1), tostring(okInfo and info ~= nil),
                    tostring(okInfo and info and info.spellID),
                    tostring(okInfo and info and info.name))
    end

    if Compat.hasLegacySpellBook then
        local ok, tabs = pcall(GetNumSpellTabs)
        local okInfo, itemType, id = pcall(GetSpellBookItemInfo, 1, LEGACY_BOOKTYPE)
        lines[#lines + 1] = ("  legacy: tabs=%s slot1Type=%s spellID=%s")
            :format(tostring(ok and tabs), tostring(okInfo and itemType), tostring(okInfo and id))
    end

    return lines
end

function Compat.IsSpellBookItemPassive(index)
    if useModernSpellBook and C_SpellBook_.IsSpellBookItemPassive then
        return C_SpellBook_.IsSpellBookItemPassive(index, PLAYER_BANK) and true or false
    end
    if _G.IsPassiveSpell then
        return IsPassiveSpell(index, LEGACY_BOOKTYPE) and true or false
    end
    return false
end

function Compat.PickupSpellBookItem(index)
    if useModernSpellBook and C_SpellBook_.PickupSpellBookItem then
        C_SpellBook_.PickupSpellBookItem(index, PLAYER_BANK)
    elseif _G.PickupSpellBookItem then
        PickupSpellBookItem(index, LEGACY_BOOKTYPE)
    end
end

--- Every aura currently on the player, as { spellID, name, icon }.
---
--- Used to populate the buff picker directly from what is on you right now,
--- which sidesteps discovery entirely: an aura whose spell is not in the
--- spellbook, or whose buff ID differs from the ability that applied it, can
--- still be picked while it is up.
function Compat.GetPlayerAuras(includeHarmful)
    local results, seen = {}, {}

    local function Collect(filter)
        for i = 1, 40 do
            if C_UnitAuras_ and C_UnitAuras_.GetAuraDataByIndex then
                local data = C_UnitAuras_.GetAuraDataByIndex("player", i, filter)
                if not data then return end
                if data.spellId and not seen[data.spellId] then
                    seen[data.spellId] = true
                    results[#results + 1] = {
                        spellID = data.spellId,
                        name = data.name,
                        icon = data.icon,
                    }
                end
            elseif _G.UnitAura then
                local name, icon, _, _, _, _, _, _, _, auraSpellID = UnitAura("player", i, filter)
                if not name then return end
                if auraSpellID and not seen[auraSpellID] then
                    seen[auraSpellID] = true
                    results[#results + 1] = {
                        spellID = auraSpellID,
                        name = name,
                        icon = icon,
                    }
                end
            else
                return
            end
        end
    end

    Collect("HELPFUL")
    if includeHarmful then Collect("HARMFUL") end
    return results
end

--- Returns hasEnchant, remainingSeconds, charges for a weapon hand.
---
--- GetWeaponEnchantInfo gained the enchantID returns partway through WoW's
--- history, so the arity is checked rather than assumed: reading the modern
--- layout on a client using the old one would treat the off-hand flag as an
--- enchant ID and report nonsense.
function Compat.GetWeaponEnchant(hand)
    if not _G.GetWeaponEnchantInfo then return false, 0, 0 end

    local count = select("#", GetWeaponEnchantInfo())
    local hasMain, mainExpiration, mainCharges,
          hasOff, offExpiration, offCharges

    if count >= 8 then
        hasMain, mainExpiration, mainCharges, _,
        hasOff, offExpiration, offCharges = GetWeaponEnchantInfo()
    else
        hasMain, mainExpiration, mainCharges,
        hasOff, offExpiration, offCharges = GetWeaponEnchantInfo()
    end

    if hand == "off" then
        -- Expiration is milliseconds.
        return hasOff and true or false, (offExpiration or 0) / 1000, offCharges or 0
    end

    return hasMain and true or false, (mainExpiration or 0) / 1000, mainCharges or 0
end

--------------------------------------------------------------------------------
-- Season of Discovery runes
--------------------------------------------------------------------------------

-- Engraved runes appear in the spellbook as generic slot placeholders ("Legs
-- Rune Ability" and friends) whose spell IDs never carry a cooldown. The real
-- ability is a separate spell ID reachable only through C_Engraving, so runes
-- have to be resolved through that API or they can never be tracked.

-- Rune-capable equipment slots. Iterating all of them is cheaper than tracking
-- which slots each phase unlocked.
local RUNE_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 15 }

--- Returns an array of { spellID, slot, runeName } for every engraved rune
--- ability. Empty on any client without engraving.
function Compat.GetEngravedRuneAbilities()
    local results = {}

    -- The C_Engraving table exists on every Era client, Season of Discovery or
    -- not, so its mere presence is not enough. Without this a standard Era
    -- character had SoD rune abilities offered in the picker -- spells it can
    -- never cast. isSoD is gated on IsEngravingEnabled, which is the real test.
    if not Compat.isSoD then
        return results
    end

    if not _G.C_Engraving or not C_Engraving.GetRuneForEquipmentSlot then
        return results
    end

    -- The rune list is lazily populated; without this the per-slot lookups can
    -- return nothing on a fresh login.
    if C_Engraving.RefreshRunesList then
        pcall(C_Engraving.RefreshRunesList)
    end

    for _, slot in ipairs(RUNE_SLOTS) do
        local ok, rune = pcall(C_Engraving.GetRuneForEquipmentSlot, slot)
        if ok and type(rune) == "table" then
            local abilityIDs = rune.learnedAbilitySpellIDs or rune.abilitySpellIDs

            -- iconTexture is the curated rune art, which is usually better than
            -- whatever icon the underlying ability spell carries.
            local icon = rune.iconTexture or rune.icon

            if type(abilityIDs) == "table" then
                for _, spellID in ipairs(abilityIDs) do
                    results[#results + 1] = {
                        spellID = spellID,
                        slot = slot,
                        runeName = rune.name,
                        icon = icon,
                    }
                end
            elseif rune.spellID then
                results[#results + 1] = {
                    spellID = rune.spellID,
                    slot = slot,
                    runeName = rune.name,
                    icon = icon,
                }
            end
        end
    end

    return results
end

--------------------------------------------------------------------------------
-- Tooltips
--------------------------------------------------------------------------------

--- Shows the right tooltip for anything we track, including pseudo-spells.
---
--- Weapon enchants use reserved negative IDs, which SetSpellByID rejects
--- outright with "Invalid spell ID", so they are routed to the weapon's own
--- item tooltip instead.
function Compat.SetTooltipForTracked(tooltip, spellID)
    if not tooltip or type(spellID) ~= "number" then return end

    local enchant = ns.Constants.WEAPON_ENCHANT_BY_ID[spellID]
    if enchant then
        if tooltip.SetInventoryItem and GetInventoryItemLink("player", enchant.inventorySlot) then
            tooltip:SetInventoryItem("player", enchant.inventorySlot)
        else
            tooltip:SetText(enchant.label)
        end
        return
    end

    Compat.SetTooltipSpellByID(tooltip, spellID)
end

function Compat.SetTooltipSpellByID(tooltip, spellID)
    if not tooltip or type(spellID) ~= "number" then return end

    -- Negative and zero IDs are our own pseudo-spells; the API errors on them.
    if spellID <= 0 then return end

    if tooltip.SetSpellByID then
        tooltip:SetSpellByID(spellID)
    elseif _G.C_TooltipInfo and C_TooltipInfo.GetSpellByID then
        local data = C_TooltipInfo.GetSpellByID(spellID)
        if data and _G.TooltipUtil then
            TooltipUtil.SurfaceArgs(data)
        end
    end
end
