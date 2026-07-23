local addonName, ns = ...

local Const = ns.Constants

local Core = {}
ns.Core = Core

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

local PREFIX = "|cff33ccffCooldown Manager|r: "

function ns.Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(message))
end

function ns.Debug(message)
    if ns.DB and ns.DB.root and ns.DB:GetGlobal().debug then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. "|cff888888" .. tostring(message) .. "|r")
    end
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local ticker

function Core:StartTicker()
    if ticker then return end
    ticker = C_Timer.NewTicker(Const.UPDATE_INTERVAL, function()
        Core:UpdateAll()
    end)
end

function Core:StopTicker()
    if not ticker then return end
    ticker:Cancel()
    ticker = nil
end

--- Pushes live cooldown and aura state into the icons. The ticker only runs
--- while something is actually counting down; the rest of the time the display
--- is driven purely by events.
local gcdCandidates = {}

--- Every tracked cooldown spell, reused as the pool the global cooldown is
--- detected from.
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

    -- Detected once per pass, before any group renders, so every icon shares
    -- the same global cooldown timer.
    ns.Cooldowns:RefreshGlobalCooldown(CollectGCDCandidates())

    local animating = false
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.groups[key]
        if group and group:Update() then
            animating = true
        end
    end

    -- The ticker also runs whenever a buff is tracked, not only while something
    -- is counting down. Aura changes otherwise reach us only through UNIT_AURA,
    -- so a single missed or unregistered event leaves a tracked buff invisible
    -- indefinitely. Polling a handful of icons is far cheaper than that failure.
    if animating or self:HasTrackedAuras() then
        self:StartTicker()
    else
        self:StopTicker()
    end
end

--- Whether any aura group has entries, which decides if the ticker must keep
--- running to notice buffs coming and going.
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

--- Rebuilds one group's icons from the profile.
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
    self:RefreshAll()
end

--- The spellbook changed, so cached rank resolution is stale.
function Core:RescanSpellbook()
    ns.Spellbook:Scan()
    ns.Cooldowns:ClearCache()
    ns.Auras:ClearCache()
    self:RefreshAll()
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")

-- Some of these do not exist on every client (RUNE_UPDATED is SoD only), and
-- registering an unknown event raises an error, so each registration is
-- attempted individually.
local EVENTS = {
    "PLAYER_ENTERING_WORLD",
    "SPELLS_CHANGED",
    "LEARNED_SPELL_IN_TAB",
    "SPELL_UPDATE_COOLDOWN",
    "SPELL_UPDATE_CHARGES",
    "SPELL_UPDATE_USABLE",
    "PLAYER_TALENT_UPDATE",
    "CHARACTER_POINTS_CHANGED",
    "PLAYER_EQUIPMENT_CHANGED",
    "PLAYER_REGEN_ENABLED",
    "PLAYER_REGEN_DISABLED",
    -- Resource bars
    "UNIT_HEALTH",
    "UNIT_MAXHEALTH",
    "UNIT_POWER_UPDATE",
    "UNIT_POWER_FREQUENT",
    "UNIT_MAXPOWER",
    "UNIT_DISPLAYPOWER",
    "PLAYER_TARGET_CHANGED",
    "RUNE_UPDATED",
    "ENGRAVING_SUCCESS",
    -- Weapon swaps change which enchant is on which hand, and the enchant icon
    -- is the weapon's own.
    "UNIT_INVENTORY_CHANGED",
}

-- Events that mean "the set of castable spells may have changed".
local RESCAN_EVENTS = {
    SPELLS_CHANGED = true,
    LEARNED_SPELL_IN_TAB = true,
    PLAYER_TALENT_UPDATE = true,
    CHARACTER_POINTS_CHANGED = true,
    PLAYER_EQUIPMENT_CHANGED = true,
    RUNE_UPDATED = true,
    ENGRAVING_SUCCESS = true,
}

-- Rescans are debounced because SPELLS_CHANGED fires in bursts during login
-- and on every talent change.
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

    if event == "UNIT_AURA" then
        Core:CheckAuraWatch()
    end

    if RESCAN_EVENTS[event] then
        QueueRescan()
        return
    end

    -- Entering or leaving combat changes nothing about the icons themselves,
    -- only whether a group with a combat visibility rule should be on screen.
    if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
        for _, group in pairs(ns.groups) do
            group:UpdateVisibility()
        end
        for _, bar in pairs(ns.bars) do
            bar:UpdateVisibility()
        end
    end

    -- A shapeshift changes which power the resource bar is showing, so the bar
    -- has to be rebuilt rather than just refreshed.
    if event == "UNIT_DISPLAYPOWER" then
        local bar = ns.bars.power
        if bar then bar:Layout() end
    end

    for _, bar in pairs(ns.bars) do
        bar:Update()
    end

    Core:UpdateAll()
end

eventFrame:SetScript("OnEvent", OnEvent)

-- Registered up front rather than in the EVENTS loop below, which only runs
-- once PLAYER_LOGIN has already fired.
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function Core:Initialize()
    if self.initialized then return end

    -- ADDON_LOADED normally beat us here, but a stale SavedVariables file can
    -- leave the DB uninitialised.
    if not ns.DB.root then ns.DB:Initialize() end

    ns.Spellbook:Scan()
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
        pcall(eventFrame.RegisterEvent, eventFrame, event)
    end

    -- Recorded so /cdmc status can show whether aura events are actually
    -- reaching us; a silent failure here makes every tracked buff invisible.
    self.auraEventRegistered = pcall(eventFrame.RegisterUnitEvent, eventFrame, "UNIT_AURA", "player")
    if not self.auraEventRegistered then
        self.auraEventRegistered = pcall(eventFrame.RegisterEvent, eventFrame, "UNIT_AURA")
    end

    ns.Print(("loaded (%s). Type /cdmc to choose your spells."):format(ns.Compat.GetProfileFlavor()))

    local removed = ns.DB.removedPlaceholders
    if removed and removed > 0 then
        ns.Print(("removed %d dead rune-slot placeholder%s - re-add your runes in /cdmc, they now appear under their real names.")
            :format(removed, removed == 1 and "" or "s"))
    end
end

--------------------------------------------------------------------------------
-- Import / export dialogs
--------------------------------------------------------------------------------

StaticPopupDialogs["CDMC_EXPORT"] = {
    text = "Copy this profile string:",
    button1 = CLOSE or "Close",
    hasEditBox = true,
    editBoxWidth = 350,
    OnShow = function(self, data)
        local editBox = self.editBox or self.EditBox
        if not editBox then return end
        editBox:SetText(data or "")
        editBox:HighlightText()
        editBox:SetFocus()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["CDMC_IMPORT"] = {
    text = "Paste a profile string:",
    button1 = ACCEPT or "Accept",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    editBoxWidth = 350,
    OnShow = function(self)
        local editBox = self.editBox or self.EditBox
        if editBox then
            editBox:SetText("")
            editBox:SetFocus()
        end
    end,
    OnAccept = function(self)
        local editBox = self.editBox or self.EditBox
        Core:ImportString(editBox and editBox:GetText() or "")
    end,
    EditBoxOnEnterPressed = function(self)
        Core:ImportString(self:GetText())
        self:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

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

    -- Imports land in a new profile rather than overwriting the active one, so
    -- a bad string is never destructive.
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

--------------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------------

--- Dumps everything needed to work out why an icon is not on screen. A spell
--- can go missing at four separate stages -- the spellbook scan, rank
--- resolution, the layout, or the frame being hidden -- and none of them raise
--- a Lua error, so each one is reported separately here.
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

    -- Always shown: cheap, and it is the line that identifies which spellbook
    -- API this build actually supports.
    for _, line in ipairs(Compat.ProbeSpellBook()) do
        out("|cff888888" .. line .. "|r")
    end

    local art = ns.Icon.art
    out(("Blizzard art: mask |cffffff00%s|r  overlay |cffffff00%s|r  OOR shadow |cffffff00%s|r")
        :format(tostring(art.mask), tostring(art.iconOverlay), tostring(art.oorShadow)))
    if not art.available then
        out("|cffffcc00Cooldown Manager atlases absent - using the plain icon fallback.|r")
    end

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

                -- For a buff, whether the aura is found matters more than the
                -- cooldown: an unfound aura is invisible when hideWhenInactive
                -- is on, which looks identical to it not being tracked at all.
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
                    out(("    %s %s (%s) aura=%s%s stacks=%s glowAt=%s")
                        :format(aura and "|cff55ff55up|r" or "|cffff5555--|r",
                                tostring(ns.Spellbook:GetName(id) or entry.name), tostring(id),
                                aura and "FOUND" or "not on player",
                                aura and (" id=" .. tostring(aura.spellId)) or "",
                                tostring(stacks),
                                tostring(settings.appearance.glowAtStacks or 0)))
                elseif not id then
                    out(("    |cffff5555--|r stored=%s name=%q live=%s -> unresolved")
                        :format(tostring(entry.spellID), tostring(entry.name), tostring(liveName)))
                else
                    -- The live cooldown numbers matter for working out why a
                    -- rune ability shows no swipe: a duration of 0 means the
                    -- client is not reporting a cooldown for it at all.
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

--- Captures the cooldown of every tracked spell on the next cooldown update.
---
--- The global cooldown lasts about a second, which is far too short to catch by
--- typing /cdmc status, so this arms a one-shot report that fires the moment
--- the client tells us a cooldown changed.
--- Samples cooldowns continuously for a few seconds and reports the largest
--- duration seen per spell.
---
--- A single snapshot is useless here: SPELL_UPDATE_COOLDOWN also fires when a
--- cooldown *ends*, and in combat it fires constantly, so catching the ~1s
--- global cooldown by chance almost never happens. Polling and keeping the
--- maximum removes the timing problem entirely.
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

--------------------------------------------------------------------------------
-- Aura watch
--------------------------------------------------------------------------------

-- Reports every aura gained or lost on the player, with IDs.
--
-- This settles whether an ability applies a trackable aura at all. If casting
-- it produces no gain here, nothing can track it as a buff -- the effect is
-- either passive, a stance, or purely server-side -- and no amount of work on
-- our aura matching will help.

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

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function PrintHelp()
    ns.Print("commands:")
    local lines = {
        "|cffffff00/cdmc|r - open the spell picker",
        "|cffffff00/cdmc unlock|r / |cffffff00lock|r - move the groups",
        "|cffffff00/cdmc preset|r - load your class starter layout",
        "|cffffff00/cdmc export|r / |cffffff00import|r - share a profile",
        "|cffffff00/cdmc profile|r [list | use | new | copy | delete] <name>",
        "|cffffff00/cdmc reset|r - reset the current profile",
        "|cffffff00/cdmc auras|r - list your current buffs with their IDs",
        "|cffffff00/cdmc watch|r - log auras as they are gained and lost",
        "|cffffff00/cdmc add <id>|r - track a spell or aura ID by hand",
        "|cffffff00/cdmc ids|r - toggle spell IDs on tooltips",
        "|cffffff00/cdmc status|r - diagnostics",
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
        ns.Print(("profile %q %sd."):format(name, action))
    else
        ns.Print("|cffff5555" .. tostring(err) .. "|r")
    end
end

SLASH_CDMC1 = "/cdmc"
SLASH_CDMC2 = "/cooldownmanager"

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
        local text, err = ns.Serialization:Export()
        if text then
            StaticPopup_Show("CDMC_EXPORT", nil, nil, text)
        else
            ns.Print("|cffff5555" .. tostring(err) .. "|r")
        end

    elseif command == "import" then
        StaticPopup_Show("CDMC_IMPORT")

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
        -- Lists what is on you right now with IDs, so a buff that the picker
        -- cannot discover can still be identified and entered by hand.
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

    elseif command == "ids" then
        local global = ns.DB:GetGlobal()
        global.showTooltipIDs = not (global.showTooltipIDs ~= false)
        ns.Print("tooltip spell IDs " .. (global.showTooltipIDs and "on" or "off") .. ".")

    elseif command == "debug" then
        local global = ns.DB:GetGlobal()
        global.debug = not global.debug
        ns.Print("debug " .. (global.debug and "on" or "off") .. ".")

    else
        PrintHelp()
    end
end
