--[[
Copyright (C) 2023 FooxyTV (simon@fooxy.tv)
All rights reserved.

Programming by: FooxyTV
]]

local addonName, ns = ...

local Const = ns.Constants

local Core = {}
ns.Core = Core

local PREFIX = "|cff33ccffCooldown Manager|r: "

function ns.Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(message))
end

function ns.Debug(message)
    if ns.DB and ns.DB.root and ns.DB:GetGlobal().debug then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. "|cff888888" .. tostring(message) .. "|r")
    end
end

local ticker
local tickerInterval

function Core:StartTicker(interval)
    if ticker and tickerInterval == interval then return end

    if ticker then
        ticker:Cancel()
        ticker = nil
    end

    tickerInterval = interval
    ticker = C_Timer.NewTicker(interval, function()
        Core:UpdateAll()
    end)
end

function Core:StopTicker()
    if not ticker then return end
    ticker:Cancel()
    ticker = nil
    tickerInterval = nil
end

local gcdCandidates = {}

local function CollectGCDCandidates()
    wipe(gcdCandidates)

    for _, key in ipairs(Const.GROUP_ORDER) do
        if not Const.AURA_GROUPS[key] then
            local group = ns.groups[key]
            if group then
                for _, icon in ipairs(group.icons) do
                    if icon.spellID then
                        gcdCandidates[#gcdCandidates + 1] = icon.spellID
                    end
                end
            end
        end
    end

    return gcdCandidates
end

function Core:UpdateAll()
    if not self.initialized then return end

    -- Once per pass, before any group renders, so every icon shares one timer.
    ns.Cooldowns:RefreshGlobalCooldown(CollectGCDCandidates())

    local animating = false
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.groups[key]
        if group and group:Update() then
            animating = true
        end
    end

    -- Reactive highlights re-evaluate here so they ride the same refresh as the
    -- icons -- crucially UNIT_AURA, which is what a proc arrives on.
    ns.Highlights:Apply()

    -- The idle rate is not redundant: aura changes otherwise reach us only via
    -- UNIT_AURA, and one missed event leaves a tracked buff invisible forever.
    if animating then
        self:StartTicker(Const.UPDATE_INTERVAL)
    elseif self:HasTrackedAuras() then
        self:StartTicker(Const.IDLE_UPDATE_INTERVAL)
    else
        self:StopTicker()
    end
end

function Core:HasTrackedAuras()
    for _, key in ipairs(Const.GROUP_ORDER) do
        if Const.AURA_GROUPS[key] then
            local settings = ns.DB:GetGroup(key)
            if settings and settings.enabled ~= false and #settings.spells > 0 then
                return true
            end
        end
    end
    return false
end

function Core:RefreshGroup(key)
    if not self.initialized then return end

    local group = ns.groups[key]
    if not group then return end

    group:Layout()
    self:UpdateAll()

    if ns.SpellPicker then ns.SpellPicker:Refresh() end
end

function Core:RefreshAll()
    if not self.initialized then return end

    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.groups[key]
        if group then group:Layout() end
    end

    for _, key in ipairs(Const.BAR_ORDER) do
        local bar = ns.bars[key]
        if bar then bar:Layout() end
    end

    self:UpdateAll()
    if ns.SpellPicker then ns.SpellPicker:Refresh() end
end

function Core:OnProfileChanged()
    ns.Highlights:OnProfileChanged()
    self:RefreshAll()
end

function Core:RescanSpellbook()
    ns.Spellbook:Scan()
    ns.Cooldowns:ClearCache()
    ns.Auras:ClearCache()
    self:RefreshAll()
end

local eventFrame = CreateFrame("Frame")

-- Some of these do not exist on every client (RUNE_UPDATED is SoD only), so
-- each registration is checked and attempted individually -- see
-- RegisterIfValid, because pcall alone is not enough.
local EVENTS = {
    "PLAYER_ENTERING_WORLD",
    "SPELLS_CHANGED",
    -- 1.15 renamed LEARNED_SPELL_IN_TAB to LEARNED_SPELL_IN_SKILL_LINE. Both
    -- are listed; only the one this client knows about is registered.
    "LEARNED_SPELL_IN_SKILL_LINE",
    "LEARNED_SPELL_IN_TAB",
    "SPELL_UPDATE_COOLDOWN",
    "SPELL_UPDATE_CHARGES",
    "SPELL_UPDATE_USABLE",
    "PLAYER_TALENT_UPDATE",
    "CHARACTER_POINTS_CHANGED",
    "PLAYER_EQUIPMENT_CHANGED",
    "PLAYER_REGEN_ENABLED",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_TARGET_CHANGED",
    "RUNE_UPDATED",
    "ENGRAVING_SUCCESS",
    -- Soul shards are bag items, so the class-resource bar tracks them through
    -- bag changes rather than a power event.
    "BAG_UPDATE_DELAYED",
    -- Keybind text is read from the action bars, so it is rebuilt when a slot's
    -- contents or the player's bindings change.
    "ACTIONBAR_SLOT_CHANGED",
    "UPDATE_BINDINGS",
}

-- Registered for the player alone. Unfiltered, UNIT_POWER_FREQUENT alone means
-- forty raid members several times a second; RegisterUnitEvent filters in the
-- client, before Lua runs.
local UNIT_EVENTS = {
    "UNIT_HEALTH",
    "UNIT_MAXHEALTH",
    "UNIT_POWER_UPDATE",
    "UNIT_POWER_FREQUENT",
    "UNIT_MAXPOWER",
    "UNIT_DISPLAYPOWER",
    -- Weapon swaps change which enchant is on which hand, and the enchant icon
    -- is the weapon's own.
    "UNIT_INVENTORY_CHANGED",
}

-- These stop at the bars rather than falling through to UpdateAll: re-reading
-- every cooldown because the player's energy ticked is an unbounded refresh loop.
local RESOURCE_ONLY_EVENTS = {
    UNIT_HEALTH = true,
    UNIT_MAXHEALTH = true,
    UNIT_POWER_UPDATE = true,
    UNIT_POWER_FREQUENT = true,
    UNIT_MAXPOWER = true,
    UNIT_DISPLAYPOWER = true,
    -- Bag changes only move the soul-shard class-resource bar; they must not
    -- trigger a full cooldown re-scan and icon re-render.
    BAG_UPDATE_DELAYED = true,
}

-- Events that mean "the set of castable spells may have changed".
local RESCAN_EVENTS = {
    SPELLS_CHANGED = true,
    LEARNED_SPELL_IN_SKILL_LINE = true,
    LEARNED_SPELL_IN_TAB = true,
    PLAYER_TALENT_UPDATE = true,
    CHARACTER_POINTS_CHANGED = true,
    PLAYER_EQUIPMENT_CHANGED = true,
    RUNE_UPDATED = true,
    ENGRAVING_SUCCESS = true,
}

-- Events that only affect the keybind text drawn on cooldown icons.
local KEYBIND_EVENTS = {
    ACTIONBAR_SLOT_CHANGED = true,
    UPDATE_BINDINGS = true,
}

-- The IsEventValid check is not redundant with the pcall: registering an unknown
-- event is not a catchable Lua error -- the client hands it to the error handler
-- itself, so it reaches BugSack anyway. The pcall covers clients with neither.
local function RegisterIfValid(event)
    if C_EventUtils and C_EventUtils.IsEventValid then
        if not C_EventUtils.IsEventValid(event) then return false end
    end
    return pcall(eventFrame.RegisterEvent, eventFrame, event)
end

-- As above, filtered to one unit. Falls back to an unfiltered registration where
-- RegisterUnitEvent is missing, so OnEvent still has to check the unit itself.
local function RegisterUnitIfValid(event, unit)
    if C_EventUtils and C_EventUtils.IsEventValid then
        if not C_EventUtils.IsEventValid(event) then return false end
    end
    if eventFrame.RegisterUnitEvent then
        local ok = pcall(eventFrame.RegisterUnitEvent, eventFrame, event, unit)
        if ok then return true end
    end
    return pcall(eventFrame.RegisterEvent, eventFrame, event)
end

-- Rescans are debounced because SPELLS_CHANGED fires in bursts during login
-- and on every talent change.
-- Keybind rebuilds are debounced too: ACTIONBAR_SLOT_CHANGED fires in bursts as
-- the bars populate on login.
local keybindPending = false
local function QueueKeybindRefresh()
    if keybindPending then return end
    keybindPending = true
    C_Timer.After(0.2, function()
        keybindPending = false
        ns.Keybinds:Rebuild()
        Core:RefreshAll()
    end)
end

local rescanPending = false
local function QueueRescan()
    if rescanPending then return end
    rescanPending = true
    C_Timer.After(0.2, function()
        rescanPending = false
        Core:RescanSpellbook()
    end)
end

local function OnEvent(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then
            ns.DB:Initialize()
            eventFrame:UnregisterEvent("ADDON_LOADED")
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        Core:Initialize()
        return
    end

    if not Core.initialized then return end

    -- Backstop for the unfiltered fallback in RegisterUnitIfValid.
    if arg1 ~= nil and event:sub(1, 5) == "UNIT_" and arg1 ~= "player" then
        return
    end

    if event == "UNIT_AURA" then
        ns.Auras:MarkDirty()
        Core:CheckAuraWatch()
    end

    if RESOURCE_ONLY_EVENTS[event] then
        -- A shapeshift changes which power the bar shows, so it needs a full
        -- rebuild rather than an update.
        if event == "UNIT_DISPLAYPOWER" then
            local bar = ns.bars.power
            if bar then bar:Layout() end
        end
        for _, bar in pairs(ns.bars) do
            bar:Update()
        end
        return
    end

    if RESCAN_EVENTS[event] then
        QueueRescan()
        return
    end

    if KEYBIND_EVENTS[event] then
        QueueKeybindRefresh()
        return
    end

    if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
        for _, group in pairs(ns.groups) do
            group:UpdateVisibility()
        end
        for _, bar in pairs(ns.bars) do
            bar:UpdateVisibility()
        end
    end

    for _, bar in pairs(ns.bars) do
        bar:Update()
    end

    Core:UpdateAll()
end

eventFrame:SetScript("OnEvent", OnEvent)

-- Not in the EVENTS loop: that only runs once PLAYER_LOGIN has already fired.
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")

function Core:Initialize()
    if self.initialized then return end

    -- ADDON_LOADED normally beat us here, but a stale SavedVariables file can
    -- leave the DB uninitialised.
    if not ns.DB.root then ns.DB:Initialize() end

    -- Only now: UnitClass("player") is not reliable at ADDON_LOADED, and
    -- binding a character to a profile from a nil class is what made several of
    -- them share one.
    ns.DB:SelectProfileForCharacter()

    ns.Spellbook:Scan()
    ns.Keybinds:Rebuild()
    ns.Tooltip:Initialize()

    for _, key in ipairs(Const.GROUP_ORDER) do
        ns.Group.Create(key)
    end

    for _, key in ipairs(Const.BAR_ORDER) do
        ns.ResourceBar.Create(key)
    end

    self.initialized = true

    if ns.Presets:IsProfileEmpty() then
        ns.Presets:ApplyDefaultForPlayer(false)
    end

    ns.EditMode:Register()

    -- A profile left unlocked when the player logged out should stay unlocked.
    if ns.DB:GetGlobal().locked == false then
        ns.EditMode:SetManualUnlock(true)
    end

    self:RefreshAll()

    for _, event in ipairs(EVENTS) do
        RegisterIfValid(event)
    end

    for _, event in ipairs(UNIT_EVENTS) do
        RegisterUnitIfValid(event, "player")
    end

    -- Recorded for /cdmc status: a silent failure here makes every tracked buff
    -- invisible, with nothing on screen to say why.
    self.auraEventRegistered = RegisterUnitIfValid("UNIT_AURA", "player")

    ns.Print(("loaded (%s). Type /cdmc to choose your spells."):format(ns.Compat.GetProfileFlavor()))

    local shared = ns.DB.repairedFromShared
    if shared then
        ns.Print(("|cffffcc00this character was sharing the %q profile with your other characters, which is why it showed another class's spells.|r")
            :format(shared))
        ns.Print(("it now has its own %q profile. The old shared layout is untouched: |cffffff00/cdmc profile use %s|r to go back to it.")
            :format(ns.DB:GetCurrentProfileName(), shared))
    end

    local removed = ns.DB.removedPlaceholders
    if removed and removed > 0 then
        ns.Print(("removed %d dead rune-slot placeholder%s - re-add your runes in /cdmc, they now appear under their real names.")
            :format(removed, removed == 1 and "" or "s"))
    end
end

function Core:ImportString(text)
    -- On failure the second return is the error message rather than a class.
    local profile, class, flavor = ns.Serialization:Import(text)
    if not profile then
        ns.Print("|cffff5555" .. tostring(class) .. "|r")
        return
    end

    local _, playerClass = UnitClass("player")
    if class ~= playerClass then
        ns.Print(("|cffffcc00Warning:|r that profile was exported by a %s."):format(class))
    end
    if flavor ~= ns.Compat.GetProfileFlavor() then
        ns.Print(("|cffffcc00Warning:|r that profile was exported on %s."):format(flavor))
    end

    -- Into a new profile, never over the active one: a bad string must not be
    -- destructive.
    local baseName = ("Imported %s"):format(class or "profile")
    local name, suffix = baseName, 1
    while ns.DB.root.profiles[name] do
        suffix = suffix + 1
        name = ("%s %d"):format(baseName, suffix)
    end

    local ok, err = ns.DB:CreateProfile(name, profile)
    if not ok then
        ns.Print("|cffff5555" .. tostring(err) .. "|r")
        return
    end

    ns.DB:SetProfile(name)
    ns.Print(("Imported into profile %q and switched to it."):format(name))
end

-- A spell can go missing at four stages -- spellbook scan, rank resolution,
-- layout, or the frame being hidden -- and none of them raise a Lua error, so
-- each is reported separately.
function Core:PrintStatus()
    local Compat = ns.Compat
    local out = function(line) DEFAULT_CHAT_FRAME:AddMessage("  " .. line) end

    ns.Print("status")

    out(("initialized: |cffffff00%s|r  flavor: |cffffff00%s|r  interface: |cffffff00%d|r  db: |cffffff00v%s|r%s")
        :format(tostring(self.initialized), Compat.GetProfileFlavor(), Compat.interfaceVersion,
                tostring(ns.DB.root and ns.DB.root.dbVersion),
                ns.DB.migratedFrom and (" (migrated from v" .. ns.DB.migratedFrom .. ")") or ""))

    local essential = ns.DB:GetGroup("essential")
    local utility = ns.DB:GetGroup("utility")
    out(("icon sizes: essential |cffffff00%s|r  utility |cffffff00%s|r  (expect 50 / 30)")
        :format(essential and tostring(essential.appearance.iconSize) or "?",
                utility and tostring(utility.appearance.iconSize) or "?"))

    local uniqueNames = 0
    for _ in pairs(ns.Spellbook.bestRankByName) do uniqueNames = uniqueNames + 1 end

    out(("spellbook API: |cffffff00%s|r  tabs: |cffffff00%d|r  scanned: |cffffff00%d|r  unique names: |cffffff00%d|r")
        :format(Compat.spellBookPath, Compat.GetNumSpellTabs(), #ns.Spellbook.spells, uniqueNames))

    local runes = Compat.GetEngravedRuneAbilities()
    out(("engraved runes: |cffffff00%d|r abilities, |cffffff00%d|r added to the spellbook")
        :format(#runes, ns.Spellbook.runeCount or 0))
    for _, rune in ipairs(runes) do
        local runeName = Compat.GetSpellInfo(rune.spellID)
        out(("  |cff888888rune slot %d: %s (%s)|r"):format(rune.slot, tostring(runeName), tostring(rune.spellID)))
    end

    if #ns.Spellbook.spells == 0 then
        out("|cffff5555The spellbook scan found nothing - the picker will be empty|r")
        out("|cffff5555and no icon can ever appear. Raw API probe:|r")
    end

    for _, line in ipairs(Compat.ProbeSpellBook()) do
        out("|cff888888" .. line .. "|r")
    end

    local art = ns.Icon.art
    out(("Blizzard art: mask |cffffff00%s|r  overlay |cffffff00%s|r  OOR shadow |cffffff00%s|r")
        :format(tostring(art.mask), tostring(art.iconOverlay), tostring(art.oorShadow)))
    if not art.available then
        out("|cffffcc00Cooldown Manager atlases absent - using the plain icon fallback.|r")
    end

    local barArt = ns.BuffBar.art
    out(("Buff bar art: fill |cffffff00%s|r  background |cffffff00%s|r  pip |cffffff00%s|r")
        :format(tostring(barArt.bar), tostring(barArt.barBG), tostring(barArt.pip)))

    out(("UNIT_AURA registered: |cffffff00%s|r  ticker: |cffffff00%s|r  tracked auras: |cffffff00%s|r")
        :format(tostring(self.auraEventRegistered), tostring(ticker ~= nil),
                tostring(self:HasTrackedAuras())))

    out(("Edit Mode: |cffffff00%s|r  unlocked: |cffffff00%s|r  profile: |cffffff00%s|r")
        :format(ns.EditMode:IsAvailable() and "available" or "absent",
                tostring(ns.EditMode.manualUnlock), tostring(ns.DB:GetCurrentProfileName())))

    for _, key in ipairs(Const.GROUP_ORDER) do
        local settings = ns.DB:GetGroup(key)
        local group = ns.groups[key]

        if not settings then
            out(("|cffff5555[%s] no settings in profile|r"):format(key))
        elseif not group then
            out(("|cffff5555[%s] stored %d, but no frame was created|r"):format(key, #settings.spells))
        else
            local resolved = 0
            for _, entry in ipairs(settings.spells) do
                if ns.Spellbook:ResolveForGroup(entry, Const.AURA_GROUPS[key]) then
                    resolved = resolved + 1
                end
            end

            local point, _, _, x, y = group.frame:GetPoint(1)
            out(("[|cffffff00%s|r] stored %d  resolved %d  icons %d  shown %s  visible %s  %dx%d  %s %d,%d")
                :format(key, #settings.spells, resolved, #group.icons,
                        tostring(group.frame:IsShown()), tostring(group.frame:IsVisible()),
                        group.frame:GetWidth(), group.frame:GetHeight(),
                        tostring(point), x or 0, y or 0))

            local isAuraGroup = Const.AURA_GROUPS[key]
            if isAuraGroup then
                out(("    |cff888888hideWhenInactive=%s unlocked=%s|r")
                    :format(tostring(settings.appearance.hideWhenInactive),
                            tostring(group.unlocked)))
            end

            for _, entry in ipairs(settings.spells) do
                local id = ns.Spellbook:ResolveForGroup(entry, isAuraGroup)
                local liveName = Compat.GetSpellInfo(entry.spellID)

                if id and Const.IsWeaponEnchantID(id) then
                    local state = ns.Auras:GetState(id)
                    out(("    %s %s enchant=%s remaining=%.0fs")
                        :format(state.active and "|cff55ff55on|r" or "|cffff5555--|r",
                                ns.Spellbook:GetName(id),
                                state.active and "APPLIED" or "none",
                                state.remaining or 0))
                elseif id and isAuraGroup then
                    local aura = Compat.GetPlayerAura(id)
                    local stacks = aura and (aura.applications or aura.count) or 0
                    out(("    %s %s (%s) aura=%s%s stacks=%s")
                        :format(aura and "|cff55ff55up|r" or "|cffff5555--|r",
                                tostring(ns.Spellbook:GetName(id) or entry.name), tostring(id),
                                aura and "FOUND" or "not on player",
                                aura and (" id=" .. tostring(aura.spellId)) or "",
                                tostring(stacks)))
                elseif not id then
                    out(("    |cffff5555--|r stored=%s name=%q live=%s -> unresolved")
                        :format(tostring(entry.spellID), tostring(entry.name), tostring(liveName)))
                else
                    -- duration 0 means the client reports no cooldown at all --
                    -- the usual reason a rune ability shows no swipe.
                    local start, duration, enabled = Compat.GetSpellCooldown(id)
                    local usable, noPower = Compat.IsSpellUsable(id)
                    local isGCD = duration > 0 and duration <= Const.GCD_THRESHOLD

                    out(("    |cff55ff55ok|r %s (%s) cd=%.2f/%.2f enabled=%s gcd=%s usable=%s noPower=%s")
                        :format(tostring(liveName), tostring(id),
                                start or 0, duration or 0, tostring(enabled),
                                tostring(isGCD), tostring(usable), tostring(noPower)))
                end
            end
        end
    end
end

-- Polls rather than listening for SPELL_UPDATE_COOLDOWN, which also fires when a
-- cooldown *ends* and fires constantly in combat -- catching the ~1s GCD by
-- chance almost never works. Keeping the maximum removes the timing problem.
function Core:ArmCooldownProbe()
    if self.probeTicker then
        self.probeTicker:Cancel()
        self.probeTicker = nil
    end

    local samples = {}
    local ticks = 0

    ns.Print("probing for 4 seconds - cast something now.")

    self.probeTicker = C_Timer.NewTicker(0.1, function()
        ticks = ticks + 1

        for _, key in ipairs(Const.GROUP_ORDER) do
            local settings = ns.DB:GetGroup(key)
            if settings then
                for _, entry in ipairs(settings.spells) do
                    local spellID = ns.Spellbook:Resolve(entry)
                    if spellID then
                        local _, duration = ns.Compat.GetSpellCooldown(spellID)
                        local record = samples[spellID]
                        if not record then
                            record = { key = key, maxDuration = 0 }
                            samples[spellID] = record
                        end
                        if (duration or 0) > record.maxDuration then
                            record.maxDuration = duration
                        end
                    end
                end
            end
        end

        if ticks >= 40 then
            Core.probeTicker:Cancel()
            Core.probeTicker = nil
            Core:ReportCooldownProbe(samples)
        end
    end)
end

function Core:ReportCooldownProbe(samples)
    ns.Print("peak cooldown seen over the probe window:")

    for spellID, record in pairs(samples) do
        local name = ns.Spellbook:GetName(spellID)
        local verdict
        if record.maxDuration <= 0 then
            verdict = "|cffff5555never reported a cooldown|r"
        elseif record.maxDuration <= Const.GCD_THRESHOLD then
            verdict = "|cff55ff55GCD|r"
        else
            verdict = "|cffffcc00cooldown|r"
        end

        DEFAULT_CHAT_FRAME:AddMessage(("  [%s] %s (%s) peak=%.2f %s")
            :format(record.key, tostring(name), tostring(spellID), record.maxDuration, verdict))
    end
end

-- Settles whether an ability applies a trackable aura at all: no gain logged
-- here means nothing can track it as a buff, however good the aura matching.
local function SnapshotAuras()
    local snapshot = {}
    for _, aura in ipairs(ns.Compat.GetPlayerAuras(true)) do
        snapshot[aura.spellID] = aura.name
    end
    return snapshot
end

function Core:ToggleAuraWatch()
    self.auraWatch = not self.auraWatch

    if self.auraWatch then
        self.auraSnapshot = SnapshotAuras()
        ns.Print("aura watch |cff55ff55on|r - cast the ability now. /cdmc watch again to stop.")
    else
        self.auraSnapshot = nil
        ns.Print("aura watch off.")
    end
end

function Core:CheckAuraWatch()
    if not self.auraWatch then return end

    local current = SnapshotAuras()
    local previous = self.auraSnapshot or {}

    for spellID, name in pairs(current) do
        if not previous[spellID] then
            DEFAULT_CHAT_FRAME:AddMessage(("  |cff55ff55+ gained|r |cffffff00%s|r  |cff00ff00%d|r")
                :format(tostring(name), spellID))
        end
    end

    for spellID, name in pairs(previous) do
        if not current[spellID] then
            DEFAULT_CHAT_FRAME:AddMessage(("  |cffff5555- lost|r   |cffffff00%s|r  |cff00ff00%d|r")
                :format(tostring(name), spellID))
        end
    end

    self.auraSnapshot = current
end

local function PrintHelp()
    ns.Print("commands:")
    local lines = {
        "|cffffff00/cdmc|r or |cffffff00/cdm|r - open the spell picker",
        "|cffffff00/cdme|r - toggle edit mode (same as unlock / lock)",
        "|cffffff00/cdmc unlock|r / |cffffff00lock|r - move the groups",
        "|cffffff00/cdmc preset|r - load your class starter layout",
        "|cffffff00/cdmc export|r / |cffffff00import|r - share a profile",
        "|cffffff00/cdmc profile|r [list | use | new | copy | delete] <name>",
        "|cffffff00/cdmc reset|r - reset the current profile",
        "|cffffff00/cdmc auras|r - list your current buffs with their IDs",
        "|cffffff00/cdmc watch|r - log auras as they are gained and lost",
        "|cffffff00/cdmc add <id>|r - track a spell or aura ID by hand",
        "|cffffff00/cdmc highlight|r [on | off] - reactive proc glow on tracked icons",
        "|cffffff00/cdmc ids|r - toggle spell IDs on tooltips",
        "|cffffff00/cdmc status|r - diagnostics",
        "|cffffff00/cdmc probe|r - arm the cooldown probe",
        "|cffffff00/cdmc debug|r - toggle debug output",
    }
    for _, line in ipairs(lines) do
        DEFAULT_CHAT_FRAME:AddMessage("  " .. line)
    end
end

local function HandleProfileCommand(action, name)
    local DB = ns.DB

    if action == "list" or action == "" or not action then
        ns.Print(("profiles (current: |cffffff00%s|r):"):format(DB:GetCurrentProfileName()))
        for _, profileName in ipairs(DB:ListProfiles()) do
            DEFAULT_CHAT_FRAME:AddMessage("  " .. profileName)
        end
        return
    end

    if name == "" then
        ns.Print("|cffff5555That command needs a profile name.|r")
        return
    end

    local ok, err
    if action == "use" then
        ok, err = DB:SetProfile(name)
    elseif action == "new" then
        ok, err = DB:CreateProfile(name)
        if ok then DB:SetProfile(name) end
    elseif action == "copy" then
        ok, err = DB:CreateProfile(name, DB:GetCurrentProfileName())
        if ok then DB:SetProfile(name) end
    elseif action == "delete" then
        ok, err = DB:DeleteProfile(name)
    else
        ns.Print(("Unknown profile command %q."):format(action))
        return
    end

    if ok then
        -- Spelled out per action: appending "d" to the verb gave "newd" and
        -- "copyd".
        local PAST_TENSE = {
            use = "is now in use",
            new = "created",
            copy = "copied",
            delete = "deleted",
        }
        ns.Print(("profile %q %s."):format(name, PAST_TENSE[action] or action))
    else
        ns.Print("|cffff5555" .. tostring(err) .. "|r")
    end
end

SLASH_CDMC1 = "/cdmc"
SLASH_CDMC2 = "/cooldownmanager"
SLASH_CDMC3 = "/cdm"

-- Deliberately not "/em": that is a stock alias for /emote on every client, and
-- either the command never fires or the addon breaks emotes for the player.
SLASH_CDMCEDIT1 = "/cdme"
SLASH_CDMCEDIT2 = "/cdmedit"
SlashCmdList["CDMCEDIT"] = function()
    local unlocked = ns.EditMode:ToggleManualUnlock()
    if unlocked then
        ns.Print("edit mode on - drag the groups, then /cdme again to finish.")
    else
        ns.Print("edit mode off.")
    end
end

SlashCmdList["CDMC"] = function(input)
    input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local command, rest = input:match("^(%S*)%s*(.*)$")
    command = (command or ""):lower()

    if command == "" then
        ns.SpellPicker:Toggle()

    elseif command == "unlock" then
        ns.EditMode:SetManualUnlock(true)
        ns.Print("groups unlocked - drag them, then /cdmc lock.")

    elseif command == "lock" then
        ns.EditMode:SetManualUnlock(false)
        ns.Print("groups locked.")

    elseif command == "preset" then
        ns.Presets:ApplyDefaultForPlayer(true)

    elseif command == "export" then
        ns.ProfileShare:ShowExport()

    elseif command == "import" then
        ns.ProfileShare:ShowImport()

    elseif command == "profile" then
        local action, name = rest:match("^(%S*)%s*(.*)$")
        HandleProfileCommand((action or ""):lower(), name or "")

    elseif command == "reset" then
        ns.DB:ResetProfile()
        ns.Print("profile reset.")

    elseif command == "status" then
        Core:PrintStatus()

    elseif command == "probe" then
        Core:ArmCooldownProbe()

    elseif command == "watch" then
        Core:ToggleAuraWatch()

    elseif command == "auras" then
        local auras = ns.Compat.GetPlayerAuras()
        ns.Print(("%d aura%s on you:"):format(#auras, #auras == 1 and "" or "s"))
        for _, aura in ipairs(auras) do
            DEFAULT_CHAT_FRAME:AddMessage(("  |cffffff00%s|r  |cff00ff00%d|r")
                :format(tostring(aura.name), aura.spellID))
        end
        if #auras == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("  |cff888888(nothing - get the buff up first)|r")
        end

    elseif command == "add" then
        local spellID = tonumber(rest)
        if spellID then
            ns.SpellPicker:Show()
            ns.SpellPicker:AddByID(spellID)
        else
            ns.Print("usage: /cdmc add <spellID>")
        end

    elseif command == "highlight" or command == "highlights" then
        local DB = ns.DB
        local want = rest:lower()
        local enabled
        if want == "on" then
            enabled = true
        elseif want == "off" then
            enabled = false
        else
            enabled = not DB:AreHighlightsEnabled()
        end
        DB:SetHighlightsEnabled(enabled)
        Core:RefreshAll()
        ns.Print("reactive spell highlighting " .. (enabled and "on" or "off") .. ".")

    elseif command == "ids" then
        local global = ns.DB:GetGlobal()
        global.showTooltipIDs = (global.showTooltipIDs == false)
        ns.Print("tooltip spell IDs " .. (global.showTooltipIDs and "on" or "off") .. ".")

    elseif command == "debug" then
        local global = ns.DB:GetGlobal()
        global.debug = not global.debug
        ns.Print("debug " .. (global.debug and "on" or "off") .. ".")

    else
        PrintHelp()
    end
end
