--[[
Copyright (C) 2023 FooxyTV (simon@fooxy.tv)
All rights reserved.

Programming by: FooxyTV
]]

local addonName, ns = ...

local Compat = {}
ns.Compat = Compat

local C_Spell_     = _G.C_Spell
local C_SpellBook_ = _G.C_SpellBook
local C_UnitAuras_ = _G.C_UnitAuras
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

-- A missing atlas renders nothing and raises no error, so the art has to be
-- probed rather than assumed: Blizzard_CooldownViewer's Lua ships on Era but is
-- gated to the `standard` game type, and the atlases may not be there.
function Compat.AtlasExists(name)
    if not name or not C_Texture or not C_Texture.GetAtlasInfo then return false end
    local ok, info = pcall(C_Texture.GetAtlasInfo, name)
    return ok and info ~= nil
end

-- Backdrops draw LibSharedMedia border art (an "edge file"), and the API is not
-- guaranteed: on a client built from the modern engine a plain frame has no
-- SetBackdrop unless it inherits BackdropTemplate, while older builds carry the
-- method outright. Frames that may want one are created with this template --
-- nil where the mixin is absent, which CreateFrame accepts -- and every use goes
-- through the two functions below, which report failure rather than erroring so
-- the caller can fall back to its own art.
Compat.backdropTemplate = _G.BackdropTemplateMixin and "BackdropTemplate" or nil

--- Draws `edgeFile` as the frame's border, tinted, and shows the frame. Returns
--- false when this client has no backdrop API.
function Compat.SetBorderTexture(frame, edgeFile, edgeSize, r, g, b, a)
    if not frame or not edgeFile or not frame.SetBackdrop then return false end

    local ok = pcall(frame.SetBackdrop, frame, {
        edgeFile = edgeFile,
        edgeSize = math.max(edgeSize or 8, 1),
    })
    if not ok then return false end

    if frame.SetBackdropBorderColor then
        frame:SetBackdropBorderColor(r or 0, g or 0, b or 0, a or 1)
    end

    frame:Show()
    return true
end

function Compat.ClearBorderTexture(frame)
    if not frame then return end
    if frame.SetBackdrop then pcall(frame.SetBackdrop, frame, nil) end
    frame:Hide()
end

-- Blizzard's colour picker, across the two shapes it has had: 10.2 replaced the
-- loose fields with a single setup call, and which one a Classic build carries
-- depends on when it was branched. Returns false when neither is there, so a
-- swatch stays inert rather than erroring.
--
-- `onChange(r, g, b, a)` fires as the user drags; `onCancel()` puts back what
-- was there before. Alpha is read back from the frame rather than from the
-- slider's value, because the legacy slider holds transparency, not alpha.
function Compat.ShowColorPicker(r, g, b, a, hasOpacity, onChange, onCancel)
    local picker = _G.ColorPickerFrame
    if not picker or not picker.SetColorRGB then return false end

    local function Read()
        local nr, ng, nb = picker:GetColorRGB()
        local na = 1
        if hasOpacity then
            if picker.GetColorAlpha then
                na = picker:GetColorAlpha()
            elseif _G.OpacitySliderFrame then
                na = 1 - (OpacitySliderFrame:GetValue() or 0)
            end
        end
        onChange(nr or r, ng or g, nb or b, na)
    end

    local function Cancel()
        if onCancel then onCancel() end
    end

    if picker.SetupColorPickerAndShow then
        picker:SetupColorPickerAndShow({
            r = r, g = g, b = b,
            opacity = a,
            hasOpacity = hasOpacity and true or false,
            swatchFunc = Read,
            opacityFunc = Read,
            cancelFunc = Cancel,
        })
        return true
    end

    -- The legacy fields take transparency where the modern table takes alpha.
    local transparency = 1 - (a or 1)
    picker.func, picker.opacityFunc, picker.cancelFunc = Read, Read, Cancel
    picker.hasOpacity = hasOpacity and true or false
    picker.opacity = transparency
    picker.previousValues = { r = r, g = g, b = b, opacity = transparency }
    picker:SetColorRGB(r, g, b)
    -- Hidden first so OnShow re-runs when the picker is already open.
    picker:Hide()
    picker:Show()
    return true
end

-- C_Engraving exists on every Era client, SoD or not, so the table's presence
-- proves nothing -- IsEngravingEnabled is the real test.
Compat.isSoD = false
if Compat.flavor == "era" and _G.C_Engraving and C_Engraving.IsEngravingEnabled then
    local ok, enabled = pcall(C_Engraving.IsEngravingEnabled)
    Compat.isSoD = (ok and enabled) or false
end

function Compat.GetProfileFlavor()
    if Compat.isSoD then return "sod" end
    return Compat.flavor
end

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

    -- Not an early return: some builds have the namespace but not these
    -- functions, and committing to it there reports every spell as unknown.
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

-- Not Era's 32-buff cap: the C_UnitAuras path has no such limit and this addon
-- reaches the other Classic flavours, where a lower bound truncates the scan.
-- Every loop stops at the first nil index, so the ceiling costs nothing.
local MAX_AURA_INDEX = 255

local function ScanPlayerAura(spellID, filter)
    if C_UnitAuras_ and C_UnitAuras_.GetAuraDataByIndex then
        for i = 1, MAX_AURA_INDEX do
            local data = C_UnitAuras_.GetAuraDataByIndex("player", i, filter)
            if not data then break end
            if data.spellId == spellID then return data end
        end
        return nil
    end

    if not _G.UnitAura then return nil end
    for i = 1, MAX_AURA_INDEX do
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
        for i = 1, MAX_AURA_INDEX do
            local data = C_UnitAuras_.GetAuraDataByIndex("player", i, filter)
            if not data then break end
            if data.name == auraName then return data end
        end
        return nil
    end

    if not _G.UnitAura then return nil end
    for i = 1, MAX_AURA_INDEX do
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

-- Passes full aura data. Not merged with GetPlayerAuras, which projects down to
-- spellID/name/icon and would silently drop duration, expiration and stacks.
function Compat.ForEachPlayerAura(callback)
    local function Walk(filter)
        for i = 1, MAX_AURA_INDEX do
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

-- Walks the harmful auras `unit` carries that the player applied, passing full
-- aura data. The player-source filter is load-bearing for DoT tracking: two
-- players' Moonfires on the same target must not read each other's. Reads
-- nothing when the unit does not exist (no target, dead target).
function Compat.ForEachPlayerDebuffOn(unit, callback)
    if not UnitExists(unit) then return end

    for i = 1, MAX_AURA_INDEX do
        if C_UnitAuras_ and C_UnitAuras_.GetAuraDataByIndex then
            local data = C_UnitAuras_.GetAuraDataByIndex(unit, i, "HARMFUL")
            if not data then return end
            if data.sourceUnit == "player" then callback(data) end
        elseif _G.UnitAura then
            local name, icon, count, dispelType, duration, expirationTime,
                  source, isStealable, _, auraSpellID, _, _, _, _, timeMod = UnitAura(unit, i, "HARMFUL")
            if not name then return end
            if source == "player" then
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
            end
        else
            return
        end
    end
end

-- The player's current Druid form as a canonical key (see Const.DRUID_FORMS):
-- "cat", "bear", "moonkin", or "caster". Returns "caster" for every non-Druid
-- and for a Druid in no form, travel, aquatic or flight.
--
-- Read from reliable signals rather than GetShapeshiftForm's stance index or
-- GetShapeshiftFormInfo's flavour-dependent return shape (the reasoning #26 used
-- for the resource bars): the active power names cat and bear outright, and
-- moonkin is the one Mana form that carries a self-buff, so it is told apart from
-- caster by that aura.
function Compat.GetShapeshiftForm()
    local _, class = UnitClass("player")
    if class ~= "DRUID" then return "caster" end

    local _, powerToken = UnitPowerType("player")
    if powerToken == "ENERGY" then return "cat" end
    if powerToken == "RAGE" then return "bear" end

    if Compat.GetPlayerAura(ns.Constants.DRUID_MOONKIN_SPELL) then
        return "moonkin"
    end

    return "caster"
end

function Compat.GetPlayerAura(spellID)
    if not spellID then return nil end

    if C_UnitAuras_ and C_UnitAuras_.GetPlayerAuraBySpellID then
        local data = C_UnitAuras_.GetPlayerAuraBySpellID(spellID)
        if data then return data end
        -- Deliberately falls through: this only matches the exact ID, and a
        -- lower-rank application of the same spell has a different one.
    end

    local byID = ScanPlayerAura(spellID, "HELPFUL") or ScanPlayerAura(spellID, "HARMFUL")
    if byID then return byID end

    -- The aura a spell applies often has a different ID from the spell cast --
    -- true of most SoD runes -- so an ID-only match tracks nothing.
    local name = Compat.GetSpellInfo(spellID)
    if not name then return nil end

    return ScanPlayerAuraByName(name, "HELPFUL") or ScanPlayerAuraByName(name, "HARMFUL")
end

-- Total count of an item across the player's bags. Used for resources that are
-- physical items in Classic -- soul shards above all -- rather than a power.
function Compat.GetItemCount(itemID)
    if not itemID then return 0 end

    if _G.C_Item and C_Item.GetItemCount then
        return C_Item.GetItemCount(itemID) or 0
    end
    if _G.GetItemCount then
        return GetItemCount(itemID) or 0
    end
    return 0
end

-- Defaults to 0 rather than treating a missing enum as "no modern API": a build
-- can expose the C_SpellBook functions without the enum, and refusing the modern
-- path there falls back to globals that are gone -- empty spellbook, no error.
local PLAYER_BANK = (_G.Enum and _G.Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
local LEGACY_BOOKTYPE = _G.BOOKTYPE_SPELL or "spell"

Compat.hasModernSpellBook = C_SpellBook_ ~= nil
    and C_SpellBook_.GetSpellBookItemInfo ~= nil
    and C_SpellBook_.GetNumSpellBookSkillLines ~= nil

Compat.hasLegacySpellBook = _G.GetNumSpellTabs ~= nil
    and _G.GetSpellBookItemInfo ~= nil

-- One flag drives every spellbook call: skill-line offsets and per-slot lookups
-- must index the same space, or a modern offset reads the wrong legacy slots.
local useModernSpellBook = Compat.hasModernSpellBook

local function DescribePath()
    if useModernSpellBook then return "C_SpellBook" end
    if Compat.hasLegacySpellBook then return "legacy" end
    return "none"
end

Compat.spellBookPath = DescribePath()

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

-- Populates the buff picker from what is on the player right now, which
-- sidesteps discovery: an aura whose spell is not in the spellbook, or whose
-- buff ID differs from the ability that applied it, is still pickable while up.
function Compat.GetPlayerAuras(includeHarmful)
    local results, seen = {}, {}

    local function Collect(filter)
        for i = 1, MAX_AURA_INDEX do
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

-- GetWeaponEnchantInfo gained the enchantID returns partway through WoW's
-- history, so the arity is counted rather than assumed: destructuring the modern
-- layout on an old client reads the off-hand flag as an enchant ID.
function Compat.GetWeaponEnchant(hand)
    if not _G.GetWeaponEnchantInfo then return false, 0, 0 end

    local count = select("#", GetWeaponEnchantInfo())
    -- Declared local: a bare `_` here would write the global of that name on
    -- every call. The enchant ID itself is genuinely unwanted.
    local _
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

-- Every rune-capable slot. Cheaper than tracking which phase unlocked what.
local RUNE_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 15 }

-- Runes sit in the spellbook as placeholders ("Legs Rune Ability") whose IDs
-- never carry a cooldown, so the real ability has to come from C_Engraving.
function Compat.GetEngravedRuneAbilities()
    local results = {}

    -- Not redundant with the C_Engraving check below: the table is present on
    -- plain Era too, and without this gate a non-SoD character was offered rune
    -- abilities in the picker that it can never cast.
    if not Compat.isSoD then
        return results
    end

    if not _G.C_Engraving or not C_Engraving.GetRuneForEquipmentSlot then
        return results
    end

    -- The rune list is lazily populated; without this the per-slot lookups
    -- return nothing on a fresh login.
    if C_Engraving.RefreshRunesList then
        pcall(C_Engraving.RefreshRunesList)
    end

    for _, slot in ipairs(RUNE_SLOTS) do
        local ok, rune = pcall(C_Engraving.GetRuneForEquipmentSlot, slot)
        if ok and type(rune) == "table" then
            local abilityIDs = rune.learnedAbilitySpellIDs or rune.abilitySpellIDs
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

-- Weapon enchants use reserved negative IDs, which SetSpellByID rejects with
-- "Invalid spell ID", so they route to the weapon's own item tooltip.
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
