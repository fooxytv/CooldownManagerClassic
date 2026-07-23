local addonName, ns = ...

local Const = ns.Constants

local DB = {}
ns.DB = DB

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function DeepCopy(source)
    if type(source) ~= "table" then return source end
    local copy = {}
    for k, v in pairs(source) do
        copy[k] = DeepCopy(v)
    end
    return copy
end
ns.DeepCopy = DeepCopy

--- Fills in any key present in defaults but missing from target. Existing
--- values are never overwritten, so this doubles as the migration path when a
--- new option is added.
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

--- The profile a character uses unless it has been pointed elsewhere. Keyed on
--- class, so all your rogues share one layout but your shaman gets its own.
function DB.GetDefaultProfileNameForPlayer()
    local localizedClass = UnitClass("player")
    return localizedClass or "Default"
end

function DB.GetCharacterKey()
    local name = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Unknown"
    return name .. " - " .. realm
end

--------------------------------------------------------------------------------
-- Defaults
--------------------------------------------------------------------------------

-- Default vertical offsets keep the three groups stacked without overlapping
-- on a fresh install.
local GROUP_DEFAULT_Y = {
    essential    = -140,
    utility      = -190,
    buffs        = -240,
    cooldownbars = -290,
}

local function DefaultGroup(key)
    -- Shared defaults first, then the per-group sizing Blizzard uses for that
    -- category, so Essential icons come out larger than Utility ones.
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
        -- Off by default: resource bars duplicate the stock player frame, so
        -- they are opt-in for people replacing it rather than adding to it.
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
    -- Spell and aura IDs on tooltips: the only practical way to find the ID of
    -- a buff that is not in the spellbook.
    showTooltipIDs = true,
}

--------------------------------------------------------------------------------
-- Migrations
--------------------------------------------------------------------------------

-- ApplyDefaults deliberately never overwrites a stored value, which is right
-- for user settings but means a changed *default* can never reach an existing
-- profile. Anything that has to be forced onto old profiles goes here instead,
-- guarded by dbVersion so it runs exactly once.

--- v2: adopt Blizzard's per-category icon sizing. Profiles written before this
--- had a flat 40px on every group, so Essential and Utility never differed.
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

--- v3: drop rune-slot placeholders and switch the GCD swipe on.
---
--- Engraved runes appear in the spellbook as per-slot placeholders ("Legs Rune
--- Ability") whose spell IDs never report a cooldown, usability or aura, so a
--- tracked placeholder is a permanently dead icon. They are removed outright
--- rather than left for the user to find.
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

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

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

    -- A new character gets a profile named after its class rather than sharing
    -- one global Default. The tracked spells are class abilities, so a shared
    -- profile means every alt inherits another class's list and looks broken.
    -- Characters that already have an assignment keep it.
    local charKey = DB.GetCharacterKey()
    local profileName = root.profileKeys[charKey]
    if not profileName or not root.profiles[profileName] then
        profileName = DB.GetDefaultProfileNameForPlayer()
        if not root.profiles[profileName] then
            root.profiles[profileName] = DefaultProfile()
        end
        root.profileKeys[charKey] = profileName
    end

    self.currentProfileName = profileName
    self.profile = root.profiles[profileName]

    self:NormalizeProfile(self.profile)

    return self.profile
end

--- Brings an arbitrary profile table (including a freshly imported one) up to
--- the current shape without discarding user data.
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

        -- Tolerate the shorthand form used by presets and hand-written
        -- imports, where a group is a plain array of spell IDs.
        for index, entry in ipairs(group.spells) do
            if type(entry) == "number" then
                group.spells[index] = { spellID = entry, rankIndependent = true }
            end
        end
    end

    return profile
end

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- Profile management
--------------------------------------------------------------------------------

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

--- Creates a profile, optionally seeded from an existing one. Passing a table
--- as copyFrom seeds directly from that table (used by preset and import).
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

    self.root.profiles[name] = nil
    -- Any character pointing at the deleted profile falls back to Default.
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

--------------------------------------------------------------------------------
-- Spell list editing
--------------------------------------------------------------------------------

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
