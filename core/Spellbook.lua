--[[
Copyright (C) 2023 FooxyTV (simon@fooxy.tv)
All rights reserved.

Programming by: FooxyTV
]]

local addonName, ns = ...

local Compat = ns.Compat

local Spellbook = {}
ns.Spellbook = Spellbook

Spellbook.spells = {}

Spellbook.bestRankByName = {}

Spellbook.knownIDs = {}

Spellbook.iconOverrides = {}

Spellbook.runeAbilityByName = {}

function Spellbook:GetIcon(spellID)
    local enchant = ns.Constants.WEAPON_ENCHANT_BY_ID[spellID]
    if enchant then
        return GetInventoryItemTexture("player", enchant.inventorySlot)
            or "Interface\\Icons\\INV_Misc_QuestionMark"
    end

    local override = self.iconOverrides[spellID]
    if override then return override end

    local _, icon = Compat.GetSpellInfo(spellID)
    return icon
end

function Spellbook:GetName(spellID)
    local enchant = ns.Constants.WEAPON_ENCHANT_BY_ID[spellID]
    if enchant then return enchant.label end

    return (Compat.GetSpellInfo(spellID))
end

local function IsRunePlaceholder(name)
    return name ~= nil and name:find("Rune Ability", 1, true) ~= nil
end
Spellbook.IsRunePlaceholder = IsRunePlaceholder

local function ParseRank(subName)
    if not subName or subName == "" then return nil end
    return tonumber(subName:match("%d+"))
end

function Spellbook:Scan()
    self:ScanWithCurrentPath()
    self:AddRuneAbilities()

    if #self.spells == 0 then
        local other = not Compat.IsUsingModernSpellBook()
        if Compat.SetSpellBookPath(other) then
            self:ScanWithCurrentPath()

            self:AddRuneAbilities()

            if #self.spells == 0 then
                Compat.SetSpellBookPath(not other)
            else
                ns.Debug(("spellbook scan fell back to the %s API (%d spells)")
                    :format(Compat.spellBookPath, #self.spells))
            end
        end
    end

    return self.spells
end

function Spellbook:ScanWithCurrentPath()
    wipe(self.spells)
    wipe(self.bestRankByName)
    wipe(self.knownIDs)

    local bestRank = {}

    local numTabs = Compat.GetNumSpellTabs()
    for tab = 1, numTabs do
        local tabName, offset, numSpells = Compat.GetSpellTabInfo(tab)
        if offset and numSpells then
            for i = offset + 1, offset + numSpells do
                local spellID, itemType, name, subName = Compat.GetSpellBookItem(i)

                local isCastable = itemType ~= "FLYOUT"
                    and itemType ~= "FUTURESPELL"
                    and itemType ~= "PETACTION"

                if spellID and not name then
                    name = Compat.GetSpellInfo(spellID)
                end

                if spellID and name and isCastable and not Compat.IsSpellBookItemPassive(i) then
                    local _, icon = Compat.GetSpellInfo(spellID)
                    local rank = ParseRank(subName)

                    self.spells[#self.spells + 1] = {
                        spellID = spellID,
                        name = name,
                        subName = subName,
                        icon = icon,
                        rank = rank,
                        tab = tabName,
                    }
                    self.knownIDs[spellID] = true

                    local previous = bestRank[name]
                    if previous == nil or (rank or math.huge) >= previous then
                        bestRank[name] = rank or math.huge
                        self.bestRankByName[name] = spellID
                    end
                end
            end
        end
    end

    return self.spells
end

function Spellbook:AddRuneAbilities()
    self.runeCount = 0

    wipe(self.iconOverrides)
    wipe(self.runeAbilityByName)

    for _, rune in ipairs(Compat.GetEngravedRuneAbilities()) do
        local name, spellIcon = Compat.GetSpellInfo(rune.spellID)
        local icon = rune.icon or spellIcon

        if rune.icon then
            self.iconOverrides[rune.spellID] = rune.icon
        end

        if name then
            self.runeAbilityByName[name] = rune.spellID
            self.bestRankByName[name] = rune.spellID
        end

        if name and not self.knownIDs[rune.spellID] then
            self.spells[#self.spells + 1] = {
                spellID = rune.spellID,
                name = name,
                icon = icon,
                tab = "Runes",
                isRune = true,
                runeSlot = rune.slot,
            }
            self.knownIDs[rune.spellID] = true

            if not self.bestRankByName[name] then
                self.bestRankByName[name] = rune.spellID
            end

            self.runeCount = self.runeCount + 1
        end
    end

    return self.runeCount
end

function Spellbook:IsKnown(spellID)
    if self.knownIDs[spellID] then return true end
    return Compat.IsSpellKnown(spellID)
end

function Spellbook:Resolve(entry)
    if not entry or not entry.spellID then return nil end

    if ns.Constants.IsWeaponEnchantID(entry.spellID) then
        return entry.spellID
    end

    if entry.rankIndependent then
        local name = entry.name
        if not name then
            name = Compat.GetSpellInfo(entry.spellID)
        end

        if name then
            local rune = self.runeAbilityByName[name]
            if rune then return rune end

            local best = self.bestRankByName[name]
            if best then return best end
        end
    end

    if self:IsKnown(entry.spellID) then
        return entry.spellID
    end

    return nil
end

function Spellbook:ResolveForGroup(entry, isAuraGroup)
    local spellID = self:Resolve(entry)
    if spellID then return spellID end

    if isAuraGroup and entry and entry.spellID then
        return entry.spellID
    end

    return nil
end

function Spellbook:ResolveInfo(entry, isAuraGroup)
    local spellID = self:ResolveForGroup(entry, isAuraGroup)
    if not spellID then return nil end

    return spellID, self:GetName(spellID), self:GetIcon(spellID)
end

function Spellbook:GetPickableSpells()
    local seen, results = {}, {}

    for _, spell in ipairs(self.spells) do
        local best = self.bestRankByName[spell.name] or spell.spellID
        if not seen[best] and not IsRunePlaceholder(spell.name) then
            seen[best] = true
            local name = Compat.GetSpellInfo(best)
            results[#results + 1] = {
                spellID = best,
                name = name or spell.name,
                icon = self:GetIcon(best) or spell.icon,
                tab = spell.tab,
            }
        end
    end

    table.sort(results, function(a, b)
        if a.tab ~= b.tab then return (a.tab or "") < (b.tab or "") end
        return (a.name or "") < (b.name or "")
    end)

    return results
end
