local addonName, ns = ...

local Compat = ns.Compat

-- Scans the player's spellbook and answers two questions for the rest of the
-- addon: "what can this character actually cast?" and "given a spell stored in
-- a profile, which rank should be displayed right now?".

local Spellbook = {}
ns.Spellbook = Spellbook

-- Array of { spellID, name, subName, icon, rank, tab } in spellbook order.
Spellbook.spells = {}

-- name -> highest known spellID for that name.
Spellbook.bestRankByName = {}

-- spellID -> true for every rank the character currently knows.
Spellbook.knownIDs = {}

-- spellID -> icon, for spells whose own icon is not the one to show. Runes use
-- this so the engraving art wins over the ability's generic texture.
Spellbook.iconOverrides = {}

-- name -> spellID for abilities granted by an engraved rune. These always beat
-- the spellbook, because an engraved rune slot reports the ability's *name*
-- while keeping the placeholder's spell ID -- and that ID has no cooldown and
-- applies no aura, so resolving to it silently tracks nothing.
Spellbook.runeAbilityByName = {}

--- The icon to display for a spell.
function Spellbook:GetIcon(spellID)
    local override = self.iconOverrides[spellID]
    if override then return override end

    local _, icon = Compat.GetSpellInfo(spellID)
    return icon
end

--- Engraved runes appear in the spellbook as per-slot placeholders whose spell
--- IDs carry no cooldown, usability or aura. They are filtered out of the
--- pickable list because tracking one can only ever produce a dead icon; the
--- real abilities are added separately by AddRuneAbilities.
---
--- Matched by name, which is English-only for now -- the placeholder IDs are
--- not contiguous enough to key on reliably.
local function IsRunePlaceholder(name)
    return name ~= nil and name:find("Rune Ability", 1, true) ~= nil
end
Spellbook.IsRunePlaceholder = IsRunePlaceholder

local function ParseRank(subName)
    if not subName or subName == "" then return nil end
    return tonumber(subName:match("%d+"))
end

--- Scans using whichever spellbook API is currently selected, then falls back
--- to the other one if it found nothing.
---
--- Which of the two APIs a given Classic build keeps is not something we can
--- reliably detect by feature-probing -- a build can expose C_SpellBook while
--- the old globals still work, or expose it while they have been removed. An
--- empty result is unambiguous, so the scan simply tries the other path and
--- keeps whichever produced spells.
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

                -- Reject only the types we positively know are not castable
                -- spells. An unrecognised type is kept: showing something odd
                -- beats an empty picker when a build reports a type we have not
                -- seen before.
                local isCastable = itemType ~= "FLYOUT"
                    and itemType ~= "FUTURESPELL"
                    and itemType ~= "PETACTION"

                -- The spellbook does not always hand back a name; the spell
                -- info does, and the name is what rank resolution keys on.
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

--- Adds the real abilities behind any engraved runes.
---
--- The spellbook lists a rune as a slot placeholder ("Legs Rune Ability") whose
--- spell ID reports no cooldown and no usability, so tracking that entry gives
--- a permanently idle icon. The ability IDs from C_Engraving are the ones that
--- actually have cooldowns, so they are added alongside.
function Spellbook:AddRuneAbilities()
    self.runeCount = 0

    -- Cleared here rather than in the spellbook scan, which runs first: a
    -- re-engraved slot must not keep the previous rune's art.
    wipe(self.iconOverrides)
    wipe(self.runeAbilityByName)

    for _, rune in ipairs(Compat.GetEngravedRuneAbilities()) do
        local name, spellIcon = Compat.GetSpellInfo(rune.spellID)
        local icon = rune.icon or spellIcon

        if rune.icon then
            self.iconOverrides[rune.spellID] = rune.icon
        end

        if name then
            -- Overwritten unconditionally. The spellbook scan runs first and
            -- will already have claimed this name for the slot placeholder,
            -- whose ID tracks nothing; the real ability has to win.
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

            -- A rune ability has a single rank, so it is its own best rank
            -- unless the spellbook already claimed that name.
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

--- Turns a stored profile entry into the spell ID that should be displayed.
--- Returns nil when the character cannot cast the spell at all, which is how
--- unlearned ranks and unequipped SoD runes end up hidden rather than deleted.
function Spellbook:Resolve(entry)
    if not entry or not entry.spellID then return nil end

    if entry.rankIndependent then
        -- Prefer the name recorded at save time; fall back to whatever the
        -- stored ID resolves to now, which covers profiles written before the
        -- name was captured.
        local name = entry.name
        if not name then
            name = Compat.GetSpellInfo(entry.spellID)
        end

        if name then
            -- A rune ability always wins, even over an exact stored ID: the
            -- stored one is very often the slot placeholder, which resolves to
            -- the right name but tracks nothing.
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

--- Resolves an entry for a particular group.
---
--- Aura groups deliberately bypass the "must be a known spell" requirement: a
--- buff can be picked directly off the player, and such an aura's spell ID is
--- frequently neither castable nor present in the spellbook -- true of most
--- Season of Discovery rune buffs. Demanding it be known would reject exactly
--- the auras the buff picker exists to add.
function Spellbook:ResolveForGroup(entry, isAuraGroup)
    local spellID = self:Resolve(entry)
    if spellID then return spellID end

    if isAuraGroup and entry and entry.spellID then
        return entry.spellID
    end

    return nil
end

--- Convenience wrapper returning spellID, name, icon for a stored entry.
function Spellbook:ResolveInfo(entry, isAuraGroup)
    local spellID = self:ResolveForGroup(entry, isAuraGroup)
    if not spellID then return nil end

    local name = Compat.GetSpellInfo(spellID)
    return spellID, name, self:GetIcon(spellID)
end

--- Every castable spell, deduplicated to the highest known rank. This is what
--- the spell picker lists.
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
