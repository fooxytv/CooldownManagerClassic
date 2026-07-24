--[[
Copyright (C) 2023 FooxyTV (simon@fooxy.tv)
All rights reserved.

Programming by: FooxyTV
]]

local addonName, ns = ...

local Compat = ns.Compat

local Spellbook = {}
ns.Spellbook = Spellbook

-- { spellID, name, subName, icon, rank, tab } in spellbook order.
Spellbook.spells = {}

-- name -> highest known spellID for that name.
Spellbook.bestRankByName = {}

-- spellID -> true for every rank the character currently knows.
Spellbook.knownIDs = {}

-- spellID -> icon, where the spell's own icon is not the one to show.
Spellbook.iconOverrides = {}

-- name -> spellID for rune abilities. These always beat the spellbook: an
-- engraved slot reports the ability's *name* against the placeholder's spell
-- ID, and that ID has no cooldown and applies no aura.
Spellbook.runeAbilityByName = {}

-- Weapon enchants borrow the weapon's icon, having none of their own.
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

-- Matched by name, so English-only for now: the placeholder IDs are not
-- contiguous enough to key on. Filtered out of the picker because tracking one
-- only ever produces a dead icon -- AddRuneAbilities adds the real ability.
local function IsRunePlaceholder(name)
    return name ~= nil and name:find("Rune Ability", 1, true) ~= nil
end
Spellbook.IsRunePlaceholder = IsRunePlaceholder

local function ParseRank(subName)
    if not subName or subName == "" then return nil end
    return tonumber(subName:match("%d+"))
end

-- Feature-probing cannot tell which spellbook API a build kept -- C_SpellBook
-- can be present while the old globals still work, or present while they are
-- gone. An empty result is unambiguous, so it just tries the other path.
function Spellbook:Scan()
    self:ScanWithCurrentPath()
    self:AddRuneAbilities()

    if #self.spells == 0 then
        local other = not Compat.IsUsingModernSpellBook()
        if Compat.SetSpellBookPath(other) then
            self:ScanWithCurrentPath()

            self:AddRuneAbilities()

            if #self.spells == 0 then
                -- Neither worked; go back to the preferred path so the status
                -- report shows the one we would normally use.
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

    -- Tracks the rank we accepted per name so a later, lower rank cannot win.
    local bestRank = {}

    local numTabs = Compat.GetNumSpellTabs()
    for tab = 1, numTabs do
        local tabName, offset, numSpells = Compat.GetSpellTabInfo(tab)
        if offset and numSpells then
            for i = offset + 1, offset + numSpells do
                local spellID, itemType, name, subName = Compat.GetSpellBookItem(i)

                -- A denylist, not an allowlist: an unrecognised type is kept,
                -- because something odd in the picker beats an empty one when a
                -- build reports a type we have not seen.
                local isCastable = itemType ~= "FLYOUT"
                    and itemType ~= "FUTURESPELL"
                    and itemType ~= "PETACTION"

                -- The spellbook does not always return a name, and the name is
                -- what rank resolution keys on.
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

                    -- Ranks are listed ascending, so an unranked spell or a
                    -- higher rank number replaces whatever we had.
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

    -- Cleared here, not in the scan that runs before it: a re-engraved slot
    -- must not keep the previous rune's art.
    wipe(self.iconOverrides)
    wipe(self.runeAbilityByName)

    for _, rune in ipairs(Compat.GetEngravedRuneAbilities()) do
        local name, spellIcon = Compat.GetSpellInfo(rune.spellID)
        local icon = rune.icon or spellIcon

        if rune.icon then
            self.iconOverrides[rune.spellID] = rune.icon
        end

        if name then
            -- Unconditional: the earlier scan has already claimed this name for
            -- the placeholder, whose ID tracks nothing.
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

-- nil means the character cannot cast it, which is how unlearned ranks and
-- unequipped runes end up hidden rather than deleted from the profile.
function Spellbook:Resolve(entry)
    if not entry or not entry.spellID then return nil end

    -- Always "known": there is no spellbook entry to check an enchant against,
    -- only whether one is currently applied.
    if ns.Constants.IsWeaponEnchantID(entry.spellID) then
        return entry.spellID
    end

    if entry.rankIndependent then
        -- Falling back to the stored ID covers profiles written before the name
        -- was captured.
        local name = entry.name
        if not name then
            name = Compat.GetSpellInfo(entry.spellID)
        end

        if name then
            -- Wins even over an exact stored ID: the stored one is very often
            -- the placeholder, which has the right name but tracks nothing.
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

-- Aura groups bypass the "must be known" requirement on purpose: a buff picked
-- off the player is frequently neither castable nor in the spellbook -- true of
-- most SoD rune buffs -- so requiring it would reject the whole point of it.
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
