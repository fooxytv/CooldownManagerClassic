--[[
Copyright (C) 2023 FooxyTV (simon@fooxy.tv)
All rights reserved.

Programming by: FooxyTV
]]

local addonName, ns = ...

local Const = ns.Constants

local DB = {}
ns.DB = DB

local function DeepCopy(source)
    if type(source) ~= "table" then return source end
    local copy = {}
    for k, v in pairs(source) do
        copy[k] = DeepCopy(v)
    end
    return copy
end
ns.DeepCopy = DeepCopy

-- Never overwrites an existing value, so it doubles as the migration path when
-- a new option is added. See RunMigrations for changes that must be forced.
local function ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            ApplyDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
    return target
end
ns.ApplyDefaults = ApplyDefaults

-- Keyed on class, so all your rogues share a layout but your shaman gets its own.
--
-- Returns nil rather than falling back to "Default" when the class is not known
-- yet. That fallback silently bound every character that hit it to one shared
-- profile, so a shaman inherited a rogue's abilities and neither could be
-- customised separately -- see SelectProfileForCharacter.
function DB.GetDefaultProfileNameForPlayer()
    local localizedClass = UnitClass("player")
    if not localizedClass or localizedClass == "" then return nil end
    return localizedClass
end

function DB.GetCharacterKey()
    local name = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Unknown"
    return name .. " - " .. realm
end

-- Keeps the groups from overlapping on a fresh install.
local GROUP_DEFAULT_Y = {
    essential    = -140,
    utility      = -190,
    buffs        = -240,
    cooldownbars = -290,
}

local function DefaultGroup(key)
    -- Shared defaults first, then Blizzard's per-category sizing on top.
    local appearance = DeepCopy(Const.DEFAULT_APPEARANCE)
    for option, value in pairs(Const.GROUP_APPEARANCE[key] or {}) do
        appearance[option] = value
    end

    return {
        enabled = true,
        -- Array of { spellID = n, name = "...", rankIndependent = bool }
        spells = {},
        position = {
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = GROUP_DEFAULT_Y[key] or 0,
        },
        appearance = appearance,
    }
end

local function DefaultBar(key)
    return {
        -- Off by default: these duplicate the stock player frame, so they are
        -- opt-in for people replacing it rather than adding to it.
        enabled = false,
        position = {
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = Const.BAR_DEFAULT_Y[key] or 0,
        },
        appearance = DeepCopy(Const.DEFAULT_BAR_APPEARANCE),
    }
end

local function DefaultProfile()
    local profile = {
        version = Const.PROFILE_FORMAT_VERSION,
        groups = {},
        bars = {},
    }
    for _, key in ipairs(Const.GROUP_ORDER) do
        profile.groups[key] = DefaultGroup(key)
    end
    for _, key in ipairs(Const.BAR_ORDER) do
        profile.bars[key] = DefaultBar(key)
    end
    return profile
end
DB.DefaultProfile = DefaultProfile

local DEFAULT_GLOBAL = {
    locked = true,
    debug = false,
    -- On by default: the only practical way to find the ID of a buff that is
    -- not in the spellbook.
    showTooltipIDs = true,
    -- Which picker sections are rolled up, keyed "tab:section". A display
    -- preference rather than part of a layout, so it lives here and not in the
    -- profile -- switching profile should not re-open everything.
    collapsedSections = {},
    -- Layouts the player saved themselves, by name. Per account rather than per
    -- profile, so one can seed a new character (see Presets:SaveCurrentAs).
    customPresets = {},
}

-- Migrations, for changes ApplyDefaults cannot make: it never overwrites a
-- stored value, so a changed *default* never reaches an existing profile.
-- Guarded by dbVersion so each runs exactly once.

-- v2: profiles before this had a flat 40px on every group.
local function MigrateGroupAppearance(root)
    for _, profile in pairs(root.profiles) do
        if type(profile) == "table" and type(profile.groups) == "table" then
            for key, group in pairs(profile.groups) do
                local blizzard = Const.GROUP_APPEARANCE[key]
                if blizzard and type(group.appearance) == "table" then
                    for option, value in pairs(blizzard) do
                        group.appearance[option] = value
                    end
                end
            end
        end
    end
end

-- v3: a tracked rune placeholder is a permanently dead icon -- its spell ID
-- never reports a cooldown, usability or aura -- so they are removed outright
-- rather than left for the user to find.
local function MigrateRunePlaceholders(root)
    local removed = 0

    for _, profile in pairs(root.profiles) do
        if type(profile) == "table" and type(profile.groups) == "table" then
            for _, group in pairs(profile.groups) do
                if type(group.spells) == "table" then
                    for index = #group.spells, 1, -1 do
                        local entry = group.spells[index]
                        local name = entry.name or ns.Compat.GetSpellInfo(entry.spellID)
                        if ns.Spellbook.IsRunePlaceholder(name) then
                            table.remove(group.spells, index)
                            removed = removed + 1
                        end
                    end
                end

                if type(group.appearance) == "table" then
                    group.appearance.showGCD = true
                end
            end
        end
    end

    return removed
end

function DB:RunMigrations(root)
    local from = root.dbVersion or 1
    if from >= Const.DB_VERSION then return end

    if from < 2 then
        MigrateGroupAppearance(root)
    end

    if from < 3 then
        self.removedPlaceholders = MigrateRunePlaceholders(root)
    end

    root.dbVersion = Const.DB_VERSION
    return from
end

function DB:Initialize()
    _G.CooldownManagerClassicDB = _G.CooldownManagerClassicDB or {}
    local root = _G.CooldownManagerClassicDB
    self.root = root

    root.dbVersion = root.dbVersion or Const.DB_VERSION
    root.profiles = root.profiles or {}
    root.profileKeys = root.profileKeys or {}
    root.global = ApplyDefaults(root.global or {}, DEFAULT_GLOBAL)

    if not root.profiles["Default"] then
        root.profiles["Default"] = DefaultProfile()
    end

    -- After the profile table exists, since migrations rewrite stored profiles.
    self.migratedFrom = self:RunMigrations(root)

    -- Deliberately not bound to a character here. This runs on ADDON_LOADED,
    -- which does not guarantee UnitClass("player") has data yet, and choosing a
    -- profile from a nil class is what put several characters on one. Default
    -- is a placeholder so nothing between here and PLAYER_LOGIN sees a nil
    -- profile; SelectProfileForCharacter replaces it.
    self.currentProfileName = "Default"
    self.profile = root.profiles["Default"]
    self:NormalizeProfile(self.profile)

    return self.profile
end

-- Was this character put on "Default" by the old nil-class fallback?
--
-- Signature: pointed at "Default" while at least one other character is too,
-- and this character has a class profile it could be using instead. A single
-- character deliberately sitting on Default is left alone.
local function IsSharedDefaultBinding(root, charKey, profileName, className)
    if profileName ~= "Default" then return false end
    if not className or className == "Default" then return false end

    for key, name in pairs(root.profileKeys) do
        if name == "Default" and key ~= charKey then return true end
    end
    return false
end

-- Binds this character to its profile. Called at PLAYER_LOGIN, where the class
-- is finally reliable. An existing assignment is kept, unless it was made by
-- the shared-Default bug.
function DB:SelectProfileForCharacter()
    local root = self.root
    local charKey = DB.GetCharacterKey()
    local className = DB.GetDefaultProfileNameForPlayer()
    local profileName = root.profileKeys[charKey]

    if profileName and IsSharedDefaultBinding(root, charKey, profileName, className) then
        -- Default keeps its contents: another character is still using it, and
        -- it may hold this one's real layout. Core reports the switch so it can
        -- be undone with /cdmc profile use Default.
        self.repairedFromShared = profileName
        profileName = nil
    end

    if not profileName or not root.profiles[profileName] then
        profileName = className or profileName or "Default"
        if not root.profiles[profileName] then
            root.profiles[profileName] = DefaultProfile()
        end
        root.profileKeys[charKey] = profileName
    end

    self.currentProfileName = profileName
    self.profile = root.profiles[profileName]

    self:NormalizeProfile(self.profile)
    self:BackfillFormTags(self.profile)

    return self.profile
end

-- Gives a Druid's existing entries the form tags they would have been created
-- with today (#43), so form-aware tracking starts working on a layout that was
-- built before the defaults existed.
--
-- Called from here rather than NormalizeProfile because it needs the class and
-- the spell names, and neither is reliable at ADDON_LOADED -- the same reason
-- profile binding waits for PLAYER_LOGIN. A non-Druid leaves without stamping
-- the flag, so a Druid sharing the profile is still backfilled later.
function DB:BackfillFormTags(profile)
    if not profile or profile.formTagsApplied then return false end

    local _, class = UnitClass("player")
    if class ~= "DRUID" then return false end

    local tagged = 0
    for _, group in pairs(profile.groups or {}) do
        for _, entry in ipairs(group.spells or {}) do
            -- Only entries with no tags at all: a hand-tagged ability, including
            -- one deliberately tagged for every form, is left as it is.
            if type(entry) == "table" and entry.forms == nil then
                local forms = Const.DefaultFormsFor(entry.spellID)
                if forms then
                    entry.forms = forms
                    tagged = tagged + 1
                end
            end
        end
    end

    profile.formTagsApplied = true
    self.formTagsBackfilled = tagged

    return true
end

function DB:NormalizeProfile(profile)
    profile.version = profile.version or Const.PROFILE_FORMAT_VERSION
    profile.groups = profile.groups or {}
    profile.bars = profile.bars or {}

    for _, key in ipairs(Const.BAR_ORDER) do
        if type(profile.bars[key]) ~= "table" then
            profile.bars[key] = DefaultBar(key)
        end
        ApplyDefaults(profile.bars[key], DefaultBar(key))
    end

    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = profile.groups[key]
        if type(group) ~= "table" then
            group = DefaultGroup(key)
            profile.groups[key] = group
        end
        ApplyDefaults(group, DefaultGroup(key))

        -- Tolerate the shorthand presets and hand-written imports use, where a
        -- group is a plain array of spell IDs.
        for index, entry in ipairs(group.spells) do
            if type(entry) == "number" then
                group.spells[index] = { spellID = entry, rankIndependent = true }
            end
        end
    end

    return profile
end

function DB:GetProfile()
    return self.profile
end

function DB:GetGroup(key)
    return self.profile and self.profile.groups[key]
end

function DB:GetBar(key)
    return self.profile and self.profile.bars and self.profile.bars[key]
end

function DB:GetGlobal()
    return self.root.global
end

-- Reactive highlighting is per group: each cooldown group opts in on its own, so
-- it can be on for Essential Cooldowns but off for Utility. Aura (tracked-buff)
-- groups never highlight and are skipped by the all-groups helpers below.
function DB:IsGroupHighlightEnabled(key)
    local group = self:GetGroup(key)
    local value = group and group.appearance and group.appearance.highlightsEnabled
    if value == nil then value = Const.DEFAULT_APPEARANCE.highlightsEnabled end
    return value == true
end

function DB:SetGroupHighlightEnabled(key, enabled)
    local group = self:GetGroup(key)
    if group and group.appearance then
        group.appearance.highlightsEnabled = enabled and true or false
    end
end

-- True when any highlight-capable group has it on. Backs the slash command's
-- toggle and the engine's cheap "is anything on?" short-circuit.
function DB:AreHighlightsEnabled()
    for _, key in ipairs(Const.GROUP_ORDER) do
        if not Const.AURA_GROUPS[key] and self:IsGroupHighlightEnabled(key) then
            return true
        end
    end
    return false
end

-- Sets every highlight-capable group at once -- the /cdmc highlight command,
-- which stays a single on/off switch over all groups.
function DB:SetHighlightsEnabled(enabled)
    for _, key in ipairs(Const.GROUP_ORDER) do
        if not Const.AURA_GROUPS[key] then
            self:SetGroupHighlightEnabled(key, enabled)
        end
    end
end

function DB:ListProfiles()
    local names = {}
    for name in pairs(self.root.profiles) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

function DB:GetCurrentProfileName()
    return self.currentProfileName
end

function DB:SetProfile(name)
    if not self.root.profiles[name] then
        return false, ("No profile named %q."):format(name)
    end

    self.root.profileKeys[DB.GetCharacterKey()] = name
    self.currentProfileName = name
    self.profile = self.root.profiles[name]
    self:NormalizeProfile(self.profile)

    ns.Core:OnProfileChanged()
    return true
end

-- copyFrom takes a profile name or a table outright (preset and import use the
-- table form).
function DB:CreateProfile(name, copyFrom)
    if not name or name == "" then
        return false, "Profile name cannot be empty."
    end
    if self.root.profiles[name] then
        return false, ("A profile named %q already exists."):format(name)
    end

    local profile
    if type(copyFrom) == "table" then
        profile = DeepCopy(copyFrom)
    elseif type(copyFrom) == "string" and self.root.profiles[copyFrom] then
        profile = DeepCopy(self.root.profiles[copyFrom])
    else
        profile = DefaultProfile()
    end

    self.root.profiles[name] = self:NormalizeProfile(profile)
    return true
end

function DB:DeleteProfile(name)
    if not self.root.profiles[name] then
        return false, ("No profile named %q."):format(name)
    end
    if name == self.currentProfileName then
        return false, "Cannot delete the profile currently in use."
    end
    -- Deletion repoints characters at "Default", so it has to outlive them: it
    -- is otherwise recreated only on the next login, and until then those
    -- characters point at a profile that does not exist.
    if name == "Default" then
        return false, "Cannot delete the Default profile."
    end

    self.root.profiles[name] = nil
    for charKey, profileName in pairs(self.root.profileKeys) do
        if profileName == name then
            self.root.profileKeys[charKey] = "Default"
        end
    end
    return true
end

function DB:ResetProfile()
    self.root.profiles[self.currentProfileName] = DefaultProfile()
    self.profile = self.root.profiles[self.currentProfileName]
    ns.Core:OnProfileChanged()
end

function DB:GroupContains(groupKey, spellID)
    local group = self:GetGroup(groupKey)
    if not group then return nil end

    local name = ns.Compat.GetSpellInfo(spellID)
    for index, entry in ipairs(group.spells) do
        if entry.spellID == spellID then return index end
        -- A rank-independent entry matches any rank of the same spell.
        if entry.rankIndependent and name and entry.name == name then return index end
    end
    return nil
end

function DB:AddSpell(groupKey, spellID, rankIndependent)
    local group = self:GetGroup(groupKey)
    if not group then return false, "Unknown group." end
    if self:GroupContains(groupKey, spellID) then return false, "Already tracked." end

    local name = ns.Compat.GetSpellInfo(spellID)
    group.spells[#group.spells + 1] = {
        spellID = spellID,
        name = name,
        rankIndependent = rankIndependent ~= false,
    }

    ns.Core:RefreshGroup(groupKey)
    return true
end

function DB:RemoveSpell(groupKey, spellID)
    local index = self:GroupContains(groupKey, spellID)
    if not index then return false end

    table.remove(self:GetGroup(groupKey).spells, index)
    ns.Core:RefreshGroup(groupKey)
    return true
end

function DB:MoveSpell(groupKey, fromIndex, toIndex)
    local group = self:GetGroup(groupKey)
    if not group then return false end

    local count = #group.spells
    if fromIndex < 1 or fromIndex > count or toIndex < 1 or toIndex > count then
        return false
    end

    local entry = table.remove(group.spells, fromIndex)
    table.insert(group.spells, toIndex, entry)

    ns.Core:RefreshGroup(groupKey)
    return true
end

function DB:SetGroupPosition(groupKey, point, relativePoint, x, y)
    local group = self:GetGroup(groupKey)
    if not group then return end

    group.position.point = point
    group.position.relativePoint = relativePoint or point
    group.position.x = x or 0
    group.position.y = y or 0
end

-- Takes a key, not the bar table, so Edit Mode's drag callback resolves the
-- profile at drag time: closing over the table registered with the frame writes
-- the new position into the old profile after a profile switch.
function DB:SetBarPosition(barKey, point, relativePoint, x, y)
    local bar = self:GetBar(barKey)
    if not bar then return end

    bar.position.point = point
    bar.position.relativePoint = relativePoint or point
    bar.position.x = x or 0
    bar.position.y = y or 0
end
