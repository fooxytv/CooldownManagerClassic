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

    ns.Cooldowns:RefreshGlobalCooldown(CollectGCDCandidates())
    ns.Range:Poll()

    local animating = false
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.groups[key]
        if group and group:Update() then
            animating = true
        end
    end

    ns.Highlights:Apply()

    if animating then
        self:StartTicker(Const.UPDATE_INTERVAL)
    elseif ns.Range:IsWatching() then
        -- Nothing is counting down, but the player and the target can still walk
        -- apart. Stopping here would leave the range colour frozen wherever it
        -- last landed.
        self:StartTicker(Const.RANGE_UPDATE_INTERVAL)
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
    -- Range is memoised by spell ID but resolved through the spellbook, so a
    -- newly learned rank changes the answer for an ID that has not moved.
    ns.Range:Clear()
    self:RefreshAll()
end

local eventFrame = CreateFrame("Frame")

local EVENTS = {
    "PLAYER_ENTERING_WORLD",
    "SPELLS_CHANGED",
    "LEARNED_SPELL_IN_SKILL_LINE",
    "LEARNED_SPELL_IN_TAB",
    "SPELL_UPDATE_COOLDOWN",
    "SPELL_UPDATE_CHARGES",
    "SPELL_UPDATE_USABLE",
    "PLAYER_TALENT_UPDATE",
    "CHARACTER_POINTS_CHANGED",
    "PLAYER_SPECIALIZATION_CHANGED",
    "ACTIVE_TALENT_GROUP_CHANGED",
    "PLAYER_EQUIPMENT_CHANGED",
    "PLAYER_REGEN_ENABLED",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_TARGET_CHANGED",
    "UPDATE_SHAPESHIFT_FORM",
    "RUNE_UPDATED",
    "ENGRAVING_SUCCESS",
    "BAG_UPDATE_DELAYED",
    "ACTIONBAR_SLOT_CHANGED",
    "UPDATE_BINDINGS",
    "CURRENT_SPELL_CAST_CHANGED",
    "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW",
    "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE",
}


local OVERLAY_GLOW_EVENTS = {
    SPELL_ACTIVATION_OVERLAY_GLOW_SHOW = true,
    SPELL_ACTIVATION_OVERLAY_GLOW_HIDE = true,
}

local UNIT_EVENTS = {
    "UNIT_HEALTH",
    "UNIT_MAXHEALTH",
    "UNIT_POWER_UPDATE",
    "UNIT_POWER_FREQUENT",
    "UNIT_MAXPOWER",
    "UNIT_DISPLAYPOWER",
    "UNIT_INVENTORY_CHANGED",
}

local RESOURCE_ONLY_EVENTS = {
    UNIT_HEALTH = true,
    UNIT_MAXHEALTH = true,
    UNIT_POWER_UPDATE = true,
    UNIT_POWER_FREQUENT = true,
    UNIT_MAXPOWER = true,
    UNIT_DISPLAYPOWER = true,
    BAG_UPDATE_DELAYED = true,
}

local RESCAN_EVENTS = {
    SPELLS_CHANGED = true,
    LEARNED_SPELL_IN_SKILL_LINE = true,
    LEARNED_SPELL_IN_TAB = true,
    PLAYER_TALENT_UPDATE = true,
    CHARACTER_POINTS_CHANGED = true,
    PLAYER_SPECIALIZATION_CHANGED = true,
    ACTIVE_TALENT_GROUP_CHANGED = true,
    PLAYER_EQUIPMENT_CHANGED = true,
    RUNE_UPDATED = true,
    ENGRAVING_SUCCESS = true,
}

local KEYBIND_EVENTS = {
    ACTIONBAR_SLOT_CHANGED = true,
    UPDATE_BINDINGS = true,
}

local function RegisterIfValid(event)
    if C_EventUtils and C_EventUtils.IsEventValid then
        if not C_EventUtils.IsEventValid(event) then return false end
    end
    return pcall(eventFrame.RegisterEvent, eventFrame, event)
end

local function RegisterUnitIfValid(event, ...)
    if C_EventUtils and C_EventUtils.IsEventValid then
        if not C_EventUtils.IsEventValid(event) then return false end
    end
    if eventFrame.RegisterUnitEvent then
        local ok = pcall(eventFrame.RegisterUnitEvent, eventFrame, event, ...)
        if ok then return true end
    end
    return pcall(eventFrame.RegisterEvent, eventFrame, event)
end

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

    if arg1 ~= nil and event:sub(1, 5) == "UNIT_" and arg1 ~= "player"
        and not (event == "UNIT_AURA" and arg1 == "target")
    then
        return
    end

    if event == "UNIT_AURA" then
        if arg1 == "target" then
            ns.Auras:MarkTargetDirty()
        else
            ns.Auras:MarkDirty()
            Core:CheckAuraWatch()
        end
    end

    if event == "PLAYER_TARGET_CHANGED" then
        ns.Auras:MarkTargetDirty()
    end

    if event == "UPDATE_SHAPESHIFT_FORM" then
        for _, group in pairs(ns.groups) do
            group:Layout()
        end
    end

    if OVERLAY_GLOW_EVENTS[event] then
        if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
            ns.Highlights:OnOverlayShow(arg1)
        else
            ns.Highlights:OnOverlayHide(arg1)
        end
        ns.Highlights:Apply()
        return
    end

    if event == "CURRENT_SPELL_CAST_CHANGED" then
        ns.Highlights:Apply()
        return
    end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        ns.Highlights:OnCombatLogEvent()
        return
    end

    if RESOURCE_ONLY_EVENTS[event] then
        if event == "UNIT_DISPLAYPOWER" then
            for _, key in ipairs({ "power", "combo" }) do
                local bar = ns.bars[key]
                if bar then bar:Layout() end
            end
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

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")

function Core:Initialize()
    if self.initialized then return end

    if not ns.DB.root then ns.DB:Initialize() end

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

    self:RefreshAll()

    for _, event in ipairs(EVENTS) do
        RegisterIfValid(event)
    end

    for _, event in ipairs(UNIT_EVENTS) do
        RegisterUnitIfValid(event, "player")
    end

    if ns.Highlights:HasCombatRules() then
        RegisterIfValid("COMBAT_LOG_EVENT_UNFILTERED")
    end

    self.auraEventRegistered = RegisterUnitIfValid("UNIT_AURA", "player", "target")

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

function Core:PrintUIProbe()
    local out = function(line) DEFAULT_CHAT_FRAME:AddMessage("  " .. line) end
    local function yes(value) return value and "|cff00ff00yes|r" or "|cffff5555no|r" end

    local function hasTemplate(frameType, template)
        local ok = pcall(CreateFrame, frameType, nil, UIParent, template)
        return ok
    end

    ns.Print("ui probe")

    local version = ns.Compat.GetAddonVersion()

    out(("addon |cffffff00%s|r  build has: border art %s  colour picker %s  bar styling %s")
        :format(version,
                yes(ns.Compat.SetBorderTexture ~= nil),
                yes(ns.Compat.ShowColorPicker ~= nil),
                yes(ns.Media.RegisterBuiltins ~= nil)))

    out(("edit mode: LibEQOL %s  EditModeManagerFrame %s  active %s")
        :format(yes(ns.EditMode.usingLibEQOL), yes(_G.EditModeManagerFrame ~= nil),
                yes(ns.EditMode.active)))
    if ns.EditMode.registrationError then
        out("|cffff5555LibEQOL registration failed:|r " .. tostring(ns.EditMode.registrationError))
    end

    out(("dialog templates: dropdown-row %s  dropdown-button %s  checkbox-row %s")
        :format(yes(hasTemplate("Frame", "SettingsDropdownWithButtonsTemplate")),
                yes(hasTemplate("DropdownButton", "WowStyle1DropdownTemplate")),
                yes(hasTemplate("Frame", "EditModeSettingCheckboxTemplate"))))

    out(("our templates: UIDropDownMenu %s  SearchBox %s  Backdrop %s")
        :format(yes(hasTemplate("Frame", "UIDropDownMenuTemplate")),
                yes(hasTemplate("EditBox", "SearchBoxTemplate")),
                yes(ns.Compat.backdropTemplate ~= nil)))

    local picker = _G.ColorPickerFrame
    out(("colour picker: frame %s  modern setup %s")
        :format(yes(picker ~= nil), yes(picker ~= nil and picker.SetupColorPickerAndShow ~= nil)))

    -- Every atlas in Const.ART, probed against this client. This is the only
    -- way to answer whether a given flavour ships a piece of Cooldown Manager
    -- art: the UI source cannot say, because the Blizzard addon that uses it is
    -- gated to retail, and atlas existence lives in the client's texture
    -- database rather than in any Lua. Entries carrying a path separator are
    -- plain textures, not atlases, so they are skipped -- probing them would
    -- report "no" and read as missing art.
    local atlasKeys = {}
    for key, value in pairs(Const.ART) do
        if type(value) == "string" and not value:find("\\", 1, true) then
            atlasKeys[#atlasKeys + 1] = key
        end
    end
    table.sort(atlasKeys)

    local atlasLine, label = {}, "atlases:"
    for index, key in ipairs(atlasKeys) do
        atlasLine[#atlasLine + 1] = ("%s %s"):format(key, yes(ns.Compat.AtlasExists(Const.ART[key])))
        if #atlasLine == 3 or index == #atlasKeys then
            out(("%s %s"):format(label, table.concat(atlasLine, "  ")))
            atlasLine, label = {}, "        "
        end
    end

    out(("shared media: library %s  borders |cffffff00%d|r  bar textures |cffffff00%d|r  fonts |cffffff00%d|r")
        :format(yes(ns.Media.lib ~= nil), #ns.Media.List("border"),
                #ns.Media.List("statusbar"), #ns.Media.List("font")))

    for _, key in ipairs(Const.BAR_ORDER) do
        local bar = ns.DB:GetBar(key)
        local appearance = bar and bar.appearance or {}
        out(("  bar %-7s enabled %s  border %s/%s  texture %q  fill %q")
            :format(key, yes(bar and bar.enabled),
                    tostring(appearance.borderSize), tostring(appearance.borderTexture ~= "" and appearance.borderTexture or "solid"),
                    tostring(appearance.barTexture), tostring(appearance.fillColor)))
    end

    out("|cff888888If the dialog templates read no, that client cannot draw LibEQOL's|r")
    out("|cff888888dropdowns -- open Blizzard's Edit Mode and select the bar.|r")
end

function Core:PrintStatus()
    local Compat = ns.Compat
    local out = function(line) DEFAULT_CHAT_FRAME:AddMessage("  " .. line) end

    ns.Print("status")

    -- First line, because it is the question every other line depends on: a
    -- report against the wrong build wastes both ends of the conversation.
    out(("version: |cffffff00%s|r"):format(Compat.GetAddonVersion()))

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

    -- Which range API answered matters more than the answer: "no range colour"
    -- on a client where neither call exists looks identical to a target that is
    -- simply in range. Asked of Compat rather than re-derived from _G here, so
    -- what this prints is the branch the code takes and not a second opinion.
    local rangeAPI = Compat.DescribeRangeAPI()
    if rangeAPI == "absent" then rangeAPI = "|cffff5555absent|r" end
    out(("Range: API |cffffff00%s|r  watching: |cffffff00%s|r  hostile target: |cffffff00%s|r")
        :format(rangeAPI, tostring(ns.Range:IsWatching()),
                tostring(UnitExists("target") and UnitCanAttack("player", "target") or false)))

    out(("Edit Mode: |cffffff00%s|r  active: |cffffff00%s|r  profile: |cffffff00%s|r")
        :format(ns.EditMode:IsAvailable() and "available" or "absent",
                tostring(ns.EditMode.active), tostring(ns.DB:GetCurrentProfileName())))

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
        "|cff888888move groups/bars and change their settings in Blizzard's Edit Mode|r",
        "|cffffff00/cdmc preset|r [list | <name>] - load a starter layout",
        "|cffffff00/cdmc export|r / |cffffff00import|r - share a profile",
        "|cffffff00/cdmc profile|r [list | use | new | copy | delete] <name>",
        "|cffffff00/cdmc reset|r - reset the current profile",
        "|cffffff00/cdmc auras|r - list your current buffs with their IDs",
        "|cffffff00/cdmc watch|r - log auras as they are gained and lost",
        "|cffffff00/cdmc add <id>|r - track a spell or aura ID by hand",
        "|cffffff00/cdmc highlight|r [on | off] - reactive proc glow on tracked icons",
        "|cffffff00/cdmc ids|r - toggle spell IDs on tooltips",
        "|cffffff00/cdmc status|r - diagnostics",
        "|cffffff00/cdmc ui|r - what this client's UI supports",
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

SlashCmdList["CDMC"] = function(input)
    input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local command, rest = input:match("^(%S*)%s*(.*)$")
    command = (command or ""):lower()

    if command == "" then
        ns.SpellPicker:Toggle()

    elseif command == "preset" then
        if rest == "" then
            ns.Presets:ApplyDefaultForPlayer(true)
        elseif rest:lower() == "list" then
            local presets, class = ns.Presets:ListForPlayer()
            ns.Print(("layouts for %s:"):format(class and class:lower() or "this class"))
            for _, preset in ipairs(presets) do
                DEFAULT_CHAT_FRAME:AddMessage(("  |cffffff00%s|r%s")
                    :format(preset.name, preset.custom and " |cff888888(saved)|r" or ""))
            end
        else
            local ok, result = ns.Presets:ApplyByKey(rest, true)
            if ok then
                ns.Print(("Loaded the %s layout."):format(result))
            else
                ns.Print("|cffff5555" .. tostring(result) .. "|r")
            end
        end

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

    elseif command == "ui" then
        Core:PrintUIProbe()

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
