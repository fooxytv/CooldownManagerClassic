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

local GROUP_DEFAULT_Y = {
    essential    = -140,
    utility      = -190,
    buffs        = -240,
    cooldownbars = -290,
}

local function DefaultGroup(key)
    local appearance = DeepCopy(Const.DEFAULT_APPEARANCE)
    for option, value in pairs(Const.GROUP_APPEARANCE[key] or {}) do
        appearance[option] = value
    end

    return {
        enabled = true,
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
    showTooltipIDs = true,
    collapsedSections = {},
    customPresets = {},
}

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

    self.migratedFrom = self:RunMigrations(root)

    self.currentProfileName = "Default"
    self.profile = root.profiles["Default"]
    self:NormalizeProfile(self.profile)

    return self.profile
end

local function IsSharedDefaultBinding(root, charKey, profileName, className)
    if profileName ~= "Default" then return false end
    if not className or className == "Default" then return false end

    for key, name in pairs(root.profileKeys) do
        if name == "Default" and key ~= charKey then return true end
    end
    return false
end

function DB:SelectProfileForCharacter()
    local root = self.root
    local charKey = DB.GetCharacterKey()
    local className = DB.GetDefaultProfileNameForPlayer()
    local profileName = root.profileKeys[charKey]

    if profileName and IsSharedDefaultBinding(root, charKey, profileName, className) then
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

function DB:BackfillFormTags(profile)
    if not profile or profile.formTagsApplied then return false end

    local _, class = UnitClass("player")
    if class ~= "DRUID" then return false end

    local tagged = 0
    for _, group in pairs(profile.groups or {}) do
        for _, entry in ipairs(group.spells or {}) do
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

function DB:AreHighlightsEnabled()
    for _, key in ipairs(Const.GROUP_ORDER) do
        if not Const.AURA_GROUPS[key] and self:IsGroupHighlightEnabled(key) then
            return true
        end
    end
    return false
end

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

function DB:SetBarPosition(barKey, point, relativePoint, x, y)
    local bar = self:GetBar(barKey)
    if not bar then return end

    bar.position.point = point
    bar.position.relativePoint = relativePoint or point
    bar.position.x = x or 0
    bar.position.y = y or 0
end
