local addonName, ns = ...

local Const = ns.Constants
local Compat = ns.Compat

-- Modelled on Blizzard's Advanced Cooldown Settings. Edits commit immediately;
-- Revert restores the profile as it was when the dialog opened.

local SpellPicker = {}
ns.SpellPicker = SpellPicker

local ICON_SIZE = 36
local ICON_GAP = 4
local ICONS_PER_ROW = 10
local SECTION_HEADER_HEIGHT = 20
local SECTION_GAP = 10
local CONTENT_WIDTH = ICONS_PER_ROW * (ICON_SIZE + ICON_GAP)

-- The "Not Displayed" bucket has no group key: dropping into it removes the
-- spell from whichever group it was in.
local TABS = {
    cooldowns = {
        title = "Advanced Cooldown Settings",
        sections = {
            { key = "essential",    label = "Essential Cooldowns" },
            { key = "utility",      label = "Utility Cooldowns" },
            { key = "cooldownbars", label = "Cooldown Bars" },
            { key = nil,            label = "Not Displayed" },
        },
    },
    buffs = {
        title = "Advanced Buff Settings",
        sections = {
            { key = "buffs", label = "Tracked Buffs" },
            { key = nil,     label = "Not Displayed" },
        },
    },
    options = {
        title = "Display Options",
        sections = {},
    },
    profiles = {
        title = "Profiles",
        sections = {},
    },
}

-- The Options tab is hidden, not deleted: every setting it held is also in the
-- Edit Mode panel, and two surfaces for the same options only disagree.
-- Profiles are not in the Edit Mode panel at all, so there is no such clash.
local TAB_ORDER = { "cooldowns", "buffs", "profiles" }

-- Tabs that draw their own panel instead of sections of spell icons. Search and
-- Save/Revert mean nothing on these.
local PANEL_TABS = { options = true, profiles = true }

-- Applied immediately rather than staged: seeing the icons resize as you drag
-- the slider is the point.
local OPTION_SLIDERS = {
    { option = "iconSize", label = "Icon Size", min = 16, max = 72, step = 1 },
    -- Negative minimum on purpose: the Blizzard bevel overhangs the icon by
    -- several pixels, so zero padding still reads as a gap.
    { option = "spacing",  label = "Icon Padding", min = -12, max = 24, step = 1 },
}

local OPTION_TOGGLES = {
    { option = "hideWhenInactive",    label = "Only show while active (buffs)" },
    { option = "showGCD",             label = "Show global cooldown" },
    { option = "colorByUsability",    label = "Tint when unusable (blue = no power)" },
    { option = "showCountdownText",   label = "Show timer" },
    { option = "showTooltips",        label = "Show tooltips" },
    { option = "desaturateUnavailable", label = "Desaturate while on cooldown" },
}

local frame
local currentTab = "cooldowns"
local searchText = ""

-- Staged edits: groupKey -> array of profile entries.
local working = {}

-- In-flight drag: { spellID, fromGroup, fromIndex, entry, handled }
local drag = nil

local function LoadWorking()
    wipe(working)
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.DB:GetGroup(key)
        working[key] = group and ns.DeepCopy(group.spells) or {}
    end
end

-- What Revert goes back to, now that edits commit immediately.
local openSnapshot = {}

local function SaveWorking()
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.DB:GetGroup(key)
        if group and working[key] then
            group.spells = ns.DeepCopy(working[key])
        end
    end
    ns.Core:RefreshAll()
end

-- Commits immediately. Staging until a Save press meant closing the window
-- silently discarded everything just dragged in, which looks identical to the
-- spell never having been tracked.
local function CommitEdit()
    SaveWorking()
end

local function TakeOpenSnapshot()
    wipe(openSnapshot)
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.DB:GetGroup(key)
        openSnapshot[key] = group and ns.DeepCopy(group.spells) or {}
    end
end

local function RestoreOpenSnapshot()
    for _, key in ipairs(Const.GROUP_ORDER) do
        working[key] = ns.DeepCopy(openSnapshot[key] or {})
    end
    SaveWorking()
end

-- Scoped to the tab, not the whole profile: a spell can be both an Essential
-- cooldown and a Tracked Buff, and checking every group would hide it from the
-- Buffs tab the moment it appeared on the Cooldowns one.
--
-- The name test alongside the ID is not belt-and-braces. Entries are stored
-- rank-independent and presets store rank 1, while the picker offers the best
-- rank known; once you out-level rank 1 the IDs differ, and an ID-only test
-- listed the spell as both tracked and Not Displayed -- adding it from there
-- left two icons for one spell.
local function IsTracked(spellID, tabKey)
    local name = Compat.GetSpellInfo(spellID)

    for _, definition in ipairs(TABS[tabKey].sections) do
        local entries = definition.key and working[definition.key]
        if entries then
            for _, entry in ipairs(entries) do
                if entry.spellID == spellID then return true end
                if entry.rankIndependent and name and entry.name == name then return true end
            end
        end
    end
    return false
end

local function GetNotDisplayed(tabKey)
    local results, seen = {}, {}

    local function Add(spellID, name)
        if not spellID or seen[spellID] then return end
        if IsTracked(spellID, tabKey) then return end

        seen[spellID] = true
        results[#results + 1] = {
            spellID = spellID,
            name = name,
            rankIndependent = true,
        }
    end

    for _, spell in ipairs(ns.Spellbook:GetPickableSpells()) do
        Add(spell.spellID, spell.name)
    end

    -- Anything currently on the player is offered too: SoD runes especially
    -- apply a buff whose ID is not the ability cast and is nowhere in the
    -- spellbook, so this is the only way to reach them.
    if tabKey == "buffs" then
        for _, aura in ipairs(ns.Compat.GetPlayerAuras()) do
            Add(aura.spellID, aura.name)
        end

        -- Weapon enchants are always offered, whether or not one is currently
        -- applied: they are a slot to watch rather than a spell you know.
        for _, enchant in ipairs(Const.WEAPON_ENCHANTS) do
            Add(enchant.id, enchant.label)
        end
    end

    return results
end

local function RemoveFrom(groupKey, spellID)
    if not groupKey or not working[groupKey] then return nil end
    for index, entry in ipairs(working[groupKey]) do
        if entry.spellID == spellID then
            return table.remove(working[groupKey], index)
        end
    end
    return nil
end

local dragVisual

local function EnsureDragVisual()
    if dragVisual then return dragVisual end

    dragVisual = CreateFrame("Frame", nil, UIParent)
    dragVisual:SetSize(ICON_SIZE, ICON_SIZE)
    dragVisual:SetFrameStrata("TOOLTIP")
    dragVisual:Hide()

    dragVisual.texture = dragVisual:CreateTexture(nil, "ARTWORK")
    dragVisual.texture:SetAllPoints()
    dragVisual.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    dragVisual:SetScript("OnUpdate", function(self)
        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    end)

    return dragVisual
end

local function BeginDrag(button)
    if not button.spellID then return end

    drag = {
        spellID = button.spellID,
        fromGroup = button.groupKey,
        fromIndex = button.index,
        entry = button.entry,
        handled = false,
    }

    local visual = EnsureDragVisual()
    visual.texture:SetTexture(button.icon:GetTexture())
    visual:Show()
end

local function EndDrag()
    drag = nil
    if dragVisual then dragVisual:Hide() end
end

-- Hit-testing rather than OnReceiveDrag, which only fires when something is
-- genuinely on the cursor. Dragging a plain frame carries no cursor payload, so
-- the drop has to be resolved on OnDragStop instead.
local function GetFrameUnderCursor()
    if _G.GetMouseFoci then
        local foci = GetMouseFoci()
        return foci and foci[1] or nil
    end
    if _G.GetMouseFocus then
        return GetMouseFocus()
    end
    return nil
end

-- A nil targetGroup is the "Not Displayed" bucket: remove it from wherever it was.
local function DropInto(targetGroup, targetIndex)
    if not drag then return end
    drag.handled = true

    local entry = RemoveFrom(drag.fromGroup, drag.spellID)
        or {
            spellID = drag.spellID,
            name = drag.entry and drag.entry.name,
            rankIndependent = true,
            -- Dragged in fresh from Not Displayed: an ability whose value is its
            -- aura defaults to aura tracking. A moved entry keeps whatever flag
            -- it already had.
            trackDebuff = Const.IsAuraSpell(drag.spellID) or nil,
        }

    if targetGroup and working[targetGroup] then
        local list = working[targetGroup]

        -- Or a cross-group move leaves a duplicate behind.
        for index, existing in ipairs(list) do
            if existing.spellID == entry.spellID then
                table.remove(list, index)
                if targetIndex and index < targetIndex then
                    targetIndex = targetIndex - 1
                end
                break
            end
        end

        targetIndex = math.max(1, math.min(targetIndex or (#list + 1), #list + 1))
        table.insert(list, targetIndex, entry)
    end

    EndDrag()
    CommitEdit()
    SpellPicker:Refresh()
end

-- Walks up from whatever is under the cursor until it finds an icon (insert at
-- that position) or a section (append), and cancels if it finds neither.
local function ResolveDrop()
    if not drag then return end

    local target = GetFrameUnderCursor()
    while target do
        if target.cdmcIsIcon and target.spellID ~= drag.spellID then
            DropInto(target.groupKey, target.index)
            return
        end
        if target.cdmcIsSection then
            DropInto(target.groupKey, nil)
            return
        end
        target = target:GetParent()
    end

    EndDrag()
end

local buttonPool = {}

local function OnIconEnter(self)
    if not self.spellID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    Compat.SetTooltipForTracked(GameTooltip, self.spellID)
    GameTooltip:Show()
end

local function OnIconLeave()
    GameTooltip:Hide()
end

local function IsDruidPlayer()
    return select(2, UnitClass("player")) == "DRUID"
end

-- The tag badge for a tracked icon: the initials of the forms it is limited to,
-- or nil for an untagged (all-forms) entry, which shows no badge.
local function FormBadge(entry)
    local forms = entry and entry.forms
    if type(forms) ~= "table" or not next(forms) then return nil end

    local out = {}
    for _, key in ipairs(Const.DRUID_FORMS) do
        if forms[key] then out[#out + 1] = Const.FORM_INITIALS[key] end
    end
    return table.concat(out)
end

-- Flips one form for an entry. Works from the effective set (an untagged entry
-- shows in all forms), and collapses "all forms on" -- or the empty set -- back
-- to untagged, so the badge disappears when a tag adds nothing.
local function ToggleEntryForm(entry, formKey)
    local set = {}
    if type(entry.forms) == "table" and next(entry.forms) then
        for key in pairs(entry.forms) do set[key] = true end
    else
        for _, key in ipairs(Const.DRUID_FORMS) do set[key] = true end
    end

    set[formKey] = not set[formKey] or nil

    local count = 0
    for _ in pairs(set) do count = count + 1 end

    if count == 0 or count == #Const.DRUID_FORMS then
        entry.forms = nil
    else
        entry.forms = set
    end
end

-- Right-click menu on a tracked icon (Druids only): a checkable toggle per form.
-- Checking every form -- the default -- is the same as untagged.
local formMenu
local function ShowEntryMenu(button)
    if not formMenu then
        formMenu = CreateFrame("Frame", "CDMCFormMenu", UIParent, "UIDropDownMenuTemplate")
    end

    UIDropDownMenu_Initialize(formMenu, function()
        local entry = button.entry
        if not entry then return end

        -- Aura tracking applies to every class: the ability is followed by the
        -- aura it leaves rather than (only) its cooldown -- its own buff on the
        -- player when one is up, the debuff on the target otherwise.
        local dot = UIDropDownMenu_CreateInfo()
        dot.text = "Track its aura (buff or DoT)"
        dot.isNotRadio = true
        dot.keepShownOnClick = true
        dot.checked = entry.trackDebuff and true or false
        dot.func = function()
            entry.trackDebuff = not entry.trackDebuff or nil
            CommitEdit()
            SpellPicker:Refresh()
        end
        UIDropDownMenu_AddButton(dot)

        -- Form tags are Druid-only.
        if IsDruidPlayer() then
            local title = UIDropDownMenu_CreateInfo()
            title.text = "Track in forms"
            title.isTitle = true
            title.notCheckable = true
            UIDropDownMenu_AddButton(title)

            for _, opt in ipairs(Const.FORM_TAG_OPTIONS) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = opt.label
                info.isNotRadio = true
                info.keepShownOnClick = true
                info.checked = Const.FormAllows(entry.forms, opt.value)
                info.func = function()
                    ToggleEntryForm(entry, opt.value)
                    CommitEdit()
                    SpellPicker:Refresh()
                end
                UIDropDownMenu_AddButton(info)
            end
        end
    end, "MENU")

    ToggleDropDownMenu(1, nil, formMenu, "cursor", 0, 0)
end

local function CreateIconButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(ICON_SIZE, ICON_SIZE)
    button:RegisterForDrag("LeftButton")
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
    button.highlight:SetAllPoints()
    button.highlight:SetColorTexture(1, 1, 1, 0.25)

    -- Form-tag badge (Druids), lit corner initials of the forms this ability is
    -- limited to. Hidden for untagged entries and non-Druids.
    button.formText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.formText:SetPoint("BOTTOMLEFT", 1, 1)
    button.formText:SetTextColor(0.4, 0.8, 1)
    button.formText:Hide()

    -- Aura-tracking badge, opposite corner, shown when the entry is followed by
    -- the aura it leaves rather than its cooldown.
    button.dotText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.dotText:SetPoint("BOTTOMRIGHT", -1, 1)
    button.dotText:SetTextColor(1, 0.5, 0.3)
    button.dotText:SetText("aura")
    button.dotText:Hide()

    button.cdmcIsIcon = true

    button:SetScript("OnEnter", OnIconEnter)
    button:SetScript("OnLeave", OnIconLeave)
    button:SetScript("OnDragStart", BeginDrag)
    button:SetScript("OnDragStop", ResolveDrop)

    -- Left-click moves a spell between tracked and not-displayed without
    -- dragging; right-click on a tracked icon opens the tracking menu (aura
    -- tracking for any class, plus form tags for Druids).
    button:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            if self.groupKey then
                ShowEntryMenu(self)
            end
            return
        end
        if self.groupKey then
            RemoveFrom(self.groupKey, self.spellID)
        else
            local target = TABS[currentTab].sections[1].key
            if target and working[target] then
                table.insert(working[target], {
                    spellID = self.spellID,
                    name = self.entry and self.entry.name,
                    rankIndependent = true,
                    -- An ability whose value is its aura defaults to aura
                    -- tracking when first added.
                    trackDebuff = Const.IsAuraSpell(self.spellID) or nil,
                })
            end
        end
        CommitEdit()
        SpellPicker:Refresh()
    end)

    return button
end

local function AcquireButton(parent)
    local button = table.remove(buttonPool) or CreateIconButton(parent)
    button:SetParent(parent)
    button:Show()
    return button
end

local function ReleaseButton(button)
    button:Hide()
    button:ClearAllPoints()
    button.spellID = nil
    button.groupKey = nil
    button.index = nil
    button.entry = nil
    if button.formText then button.formText:Hide() end
    if button.dotText then button.dotText:Hide() end
    buttonPool[#buttonPool + 1] = button
end

local sectionPool = {}
local activeSections = {}

local function CreateSection(parent)
    local section = CreateFrame("Frame", nil, parent)
    section:SetWidth(CONTENT_WIDTH)
    section:EnableMouse(true)

    section.bg = section:CreateTexture(nil, "BACKGROUND")
    section.bg:SetPoint("TOPLEFT", 0, -SECTION_HEADER_HEIGHT)
    section.bg:SetPoint("BOTTOMRIGHT", 0, 0)
    section.bg:SetColorTexture(0, 0, 0, 0.25)

    section.label = section:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    section.label:SetPoint("TOPLEFT", 2, -4)
    section.label:SetTextColor(1, 0.82, 0)

    -- Marked so ResolveDrop can find it by walking up from the cursor target;
    -- dropping on the section background appends to the end of that group.
    section.cdmcIsSection = true

    section.buttons = {}
    return section
end

local function ReleaseSections()
    for _, section in ipairs(activeSections) do
        for _, button in ipairs(section.buttons) do
            ReleaseButton(button)
        end
        wipe(section.buttons)
        section:Hide()
        section:ClearAllPoints()
        sectionPool[#sectionPool + 1] = section
    end
    wipe(activeSections)
end

local function MatchesSearch(name)
    if searchText == "" then return true end
    return name ~= nil and name:lower():find(searchText:lower(), 1, true) ~= nil
end

-- Returns the section's height.
local function BuildSection(parent, definition, entries, yOffset)
    local section = table.remove(sectionPool) or CreateSection(parent)
    section:SetParent(parent)
    section.groupKey = definition.key
    section.label:SetText(definition.label)
    section:ClearAllPoints()
    section:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -yOffset)
    section:Show()
    activeSections[#activeSections + 1] = section

    local rows = math.max(1, math.ceil(#entries / ICONS_PER_ROW))
    local height = SECTION_HEADER_HEIGHT + rows * (ICON_SIZE + ICON_GAP) + ICON_GAP
    section:SetHeight(height)

    for index, entry in ipairs(entries) do
        local button = AcquireButton(section)
        local isAuraSection = definition.key ~= nil and Const.AURA_GROUPS[definition.key]
        local resolvedID, resolvedName = ns.Spellbook:ResolveInfo(entry, isAuraSection)

        local name = resolvedName or entry.name
        local icon = ns.Spellbook:GetIcon(resolvedID or entry.spellID)

        button.spellID = entry.spellID
        button.groupKey = definition.key
        button.index = index
        button.entry = entry
        button.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")

        -- Badges only on tracked (not not-displayed) entries: form initials for a
        -- Druid, and a DoT marker for a DoT-tracked ability.
        local badge = definition.key and IsDruidPlayer() and FormBadge(entry)
        if badge then
            button.formText:SetText(badge)
            button.formText:Show()
        else
            button.formText:Hide()
        end

        button.dotText:SetShown(definition.key ~= nil and entry.trackDebuff == true)

        local column = (index - 1) % ICONS_PER_ROW
        local row = math.floor((index - 1) / ICONS_PER_ROW)
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", section, "TOPLEFT",
            column * (ICON_SIZE + ICON_GAP),
            -(SECTION_HEADER_HEIGHT + row * (ICON_SIZE + ICON_GAP)))

        -- Search dims rather than filters, so an icon never moves under the
        -- cursor while you are typing.
        local matches = MatchesSearch(name)
        button.icon:SetAlpha(matches and 1 or 0.25)
        if button.icon.SetDesaturated then
            button.icon:SetDesaturated(not matches)
        end

        -- A spell the character cannot currently cast (unlearned rank, or a
        -- rune that is not engraved) stays in the profile but is marked.
        if not resolvedID then
            button.icon:SetVertexColor(1, 0.4, 0.4)
        else
            button.icon:SetVertexColor(1, 1, 1)
        end

        section.buttons[#section.buttons + 1] = button
    end

    return height
end

local optionsGroup = Const.GROUP_ORDER[1]
local optionWidgets

local function CurrentOptionAppearance()
    local group = ns.DB:GetGroup(optionsGroup)
    return group and group.appearance
end

local function ApplyOption(option, value)
    local appearance = CurrentOptionAppearance()
    if not appearance then return end

    appearance[option] = value
    ns.Core:RefreshGroup(optionsGroup)
end

local function EnsureOptionWidgets(parent)
    if optionWidgets then return optionWidgets end

    optionWidgets = { groupButtons = {}, sliders = {}, toggles = {} }

    -- A wrapping grid, not a row: with four groups a single row overran the
    -- dialog, clipping "Essential Cooldowns" and pushing the last button off.
    local PER_ROW = 2
    local BUTTON_GAP = 4
    local BUTTON_W = (CONTENT_WIDTH - BUTTON_GAP) / PER_ROW
    local BUTTON_H = 22
    local ROW_STEP = BUTTON_H + 4

    for index, key in ipairs(Const.GROUP_ORDER) do
        local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        button:SetSize(BUTTON_W, BUTTON_H)

        local col = (index - 1) % PER_ROW
        local row = math.floor((index - 1) / PER_ROW)
        button:SetPoint("TOPLEFT", parent, "TOPLEFT",
            col * (BUTTON_W + BUTTON_GAP), -4 - row * ROW_STEP)

        button:SetText(Const.GROUP_LABELS[key] or key)
        button:SetScript("OnClick", function()
            optionsGroup = key
            SpellPicker:Refresh()
        end)
        optionWidgets.groupButtons[key] = button
    end

    -- Start the sliders below however many rows of group buttons there were.
    local buttonRows = math.ceil(#Const.GROUP_ORDER / PER_ROW)
    local y = -4 - buttonRows * ROW_STEP - 12
    for index, definition in ipairs(OPTION_SLIDERS) do
        local name = "CDMCOptionSlider" .. index
        local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
        slider:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)
        slider:SetWidth(CONTENT_WIDTH - 60)
        slider:SetMinMaxValues(definition.min, definition.max)
        slider:SetValueStep(definition.step)
        slider:SetObeyStepOnDrag(true)

        local low, high = _G[name .. "Low"], _G[name .. "High"]
        if low then low:SetText(definition.min) end
        if high then high:SetText(definition.max) end

        slider.label = _G[name .. "Text"]
        slider.definition = definition
        slider:SetScript("OnValueChanged", function(self, value)
            value = math.floor(value + 0.5)
            if self.label then
                self.label:SetText(("%s: %d"):format(self.definition.label, value))
            end
            if not self.settingValue then
                ApplyOption(self.definition.option, value)
            end
        end)

        optionWidgets.sliders[#optionWidgets.sliders + 1] = slider
        y = y - 46
    end

    y = y - 6
    for index, definition in ipairs(OPTION_TOGGLES) do
        local name = "CDMCOptionToggle" .. index
        local check = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
        check:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)

        local label = _G[name .. "Text"] or check.text or check.Text
        if label then label:SetText(definition.label) end

        check.definition = definition
        check:SetScript("OnClick", function(self)
            ApplyOption(self.definition.option, self:GetChecked() and true or false)
        end)

        optionWidgets.toggles[#optionWidgets.toggles + 1] = check
        y = y - 28
    end

    optionWidgets.height = -y + 20
    return optionWidgets
end

-- Which profile the list has highlighted. Only a selection: switching to it is
-- a separate button, so picking a profile to copy or delete does not drag the
-- character onto it first.
local selectedProfile = nil
local profileWidgets = nil

local PROFILE_ROWS = 10
local PROFILE_ROW_HEIGHT = 20

local function SetProfileStatus(text, isError)
    if not profileWidgets then return end
    profileWidgets.status:SetText(text or "")
    if isError then
        profileWidgets.status:SetTextColor(1, 0.35, 0.35)
    else
        profileWidgets.status:SetTextColor(0.6, 0.9, 0.6)
    end
end

-- Every action reports through the same place: these all fail for ordinary
-- reasons (duplicate name, empty name, deleting the profile in use) and a
-- silent no-op looks identical to the button being broken.
local function RunProfileAction(ok, err, success)
    if ok then
        SetProfileStatus(success, false)
    else
        SetProfileStatus(tostring(err), true)
    end
    return ok
end

local function NewProfileName()
    local text = profileWidgets and profileWidgets.nameBox:GetText() or ""
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function EnsureProfileWidgets(parent)
    if profileWidgets then return profileWidgets end

    profileWidgets = { rows = {} }

    local y = -6

    profileWidgets.current = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    profileWidgets.current:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)
    y = y - 24

    local heading = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    heading:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)
    heading:SetText("Select a profile:")
    profileWidgets.heading = heading
    y = y - 18

    -- A fixed pool rather than a scroll frame: the list is one entry per class
    -- plus whatever the player has named, so it does not grow without bound.
    for index = 1, PROFILE_ROWS do
        local row = CreateFrame("Button", nil, parent)
        row:SetSize(CONTENT_WIDTH - 16, PROFILE_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)

        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        local selected = row:CreateTexture(nil, "BACKGROUND")
        selected:SetAllPoints()
        selected:SetColorTexture(0.2, 0.5, 0.9, 0.35)
        selected:Hide()
        row.selectedTexture = selected

        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.label:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.label:SetJustifyH("LEFT")

        row:SetScript("OnClick", function(self)
            selectedProfile = self.profileName
            SetProfileStatus(nil)
            SpellPicker:Refresh()
        end)
        row:SetScript("OnDoubleClick", function(self)
            selectedProfile = self.profileName
            RunProfileAction(ns.DB:SetProfile(self.profileName))
        end)

        profileWidgets.rows[index] = row
        y = y - PROFILE_ROW_HEIGHT
    end

    y = y - 14

    local nameLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)
    nameLabel:SetText("New profile name:")
    profileWidgets.nameLabel = nameLabel
    y = y - 20

    local nameBox = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    nameBox:SetSize(CONTENT_WIDTH - 40, 20)
    nameBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
    nameBox:SetAutoFocus(false)
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    profileWidgets.nameBox = nameBox
    y = y - 30

    local BUTTON_W = (CONTENT_WIDTH - 16 - 8) / 2
    local BUTTON_H = 22

    local function AddButton(text, col, row, onClick, tooltip)
        local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        button:SetSize(BUTTON_W, BUTTON_H)
        button:SetPoint("TOPLEFT", parent, "TOPLEFT",
            8 + col * (BUTTON_W + 8), y - row * (BUTTON_H + 6))
        button:SetText(text)
        button:SetScript("OnClick", onClick)
        if tooltip then
            button.tooltipText = tooltip
            button:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.tooltipText, nil, nil, nil, nil, true)
                GameTooltip:Show()
            end)
            button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        return button
    end

    -- The headline case: a second shaman starts from the first shaman's layout
    -- and then diverges. Copy writes a new profile and moves this character to
    -- it, so the source is never edited by accident.
    profileWidgets.copyButton = AddButton("Copy Selected", 0, 0, function()
        local name = NewProfileName()
        if name == "" then
            SetProfileStatus("Type a name for the copy first.", true)
            return
        end
        if not selectedProfile then
            SetProfileStatus("Select a profile to copy from.", true)
            return
        end

        local source = selectedProfile
        if RunProfileAction(ns.DB:CreateProfile(name, source)) then
            ns.DB:SetProfile(name)
            selectedProfile = name
            profileWidgets.nameBox:SetText("")
            SetProfileStatus(("Copied %q to %q and switched to it."):format(source, name))
        end
    end, "Creates a copy of the selected profile under the new name and switches this character to it. The original is left alone.")

    profileWidgets.createButton = AddButton("Create Empty", 1, 0, function()
        local name = NewProfileName()
        if name == "" then
            SetProfileStatus("Type a name for the new profile first.", true)
            return
        end

        if RunProfileAction(ns.DB:CreateProfile(name)) then
            ns.DB:SetProfile(name)
            selectedProfile = name
            profileWidgets.nameBox:SetText("")
            SetProfileStatus(("Created %q and switched to it."):format(name))
        end
    end, "Creates an empty profile under the new name and switches this character to it.")

    profileWidgets.useButton = AddButton("Use Selected", 0, 1, function()
        if not selectedProfile then
            SetProfileStatus("Select a profile first.", true)
            return
        end
        if RunProfileAction(ns.DB:SetProfile(selectedProfile)) then
            SetProfileStatus(("Now using %q."):format(selectedProfile))
        end
    end, "Switches this character to the selected profile. Other characters are unaffected.")

    profileWidgets.deleteButton = AddButton("Delete Selected", 1, 1, function()
        if not selectedProfile then
            SetProfileStatus("Select a profile first.", true)
            return
        end
        local name = selectedProfile
        if RunProfileAction(ns.DB:DeleteProfile(name)) then
            selectedProfile = nil
            SetProfileStatus(("Deleted %q."):format(name))
            SpellPicker:Refresh()
        end
    end, "Deletes the selected profile. The profile in use and the Default profile cannot be deleted.")

    y = y - 2 * (BUTTON_H + 6) - 8

    profileWidgets.status = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    profileWidgets.status:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)
    profileWidgets.status:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, y)
    profileWidgets.status:SetJustifyH("LEFT")
    y = y - 30

    profileWidgets.height = -y + 10
    return profileWidgets
end

local function ShowProfiles(parent)
    local widgets = EnsureProfileWidgets(parent)
    local current = ns.DB:GetCurrentProfileName()
    local names = ns.DB:ListProfiles()

    -- A profile deleted underneath the selection must not stay selected.
    if selectedProfile and not ns.DB.root.profiles[selectedProfile] then
        selectedProfile = nil
    end
    selectedProfile = selectedProfile or current

    widgets.current:SetText(("This character is using: |cffffff00%s|r"):format(tostring(current)))
    widgets.current:Show()
    widgets.heading:Show()
    widgets.nameLabel:Show()
    widgets.nameBox:Show()
    widgets.status:Show()

    for index, row in ipairs(widgets.rows) do
        local name = names[index]
        if name then
            row.profileName = name
            row.label:SetText(name == current
                and ("|cffffff00%s|r  |cff888888(in use)|r"):format(name)
                or name)
            row.selectedTexture:SetShown(name == selectedProfile)
            row:RegisterForClicks("LeftButtonUp")
            row:Show()
        else
            row.profileName = nil
            row:Hide()
        end
    end

    if #names > PROFILE_ROWS then
        -- No silent truncation: the list is a fixed pool, so say so rather than
        -- letting a profile simply not appear.
        widgets.status:SetText(("Showing the first %d of %d profiles - use /cdmc profile list for the rest.")
            :format(PROFILE_ROWS, #names))
        widgets.status:SetTextColor(1, 0.8, 0.3)
    end

    widgets.copyButton:Show()
    widgets.createButton:Show()
    widgets.useButton:Show()
    widgets.deleteButton:Show()

    -- Both are rejected by the DB anyway; disabling says why before the click.
    widgets.deleteButton:SetEnabled(selectedProfile ~= nil
        and selectedProfile ~= current and selectedProfile ~= "Default")
    widgets.useButton:SetEnabled(selectedProfile ~= nil and selectedProfile ~= current)

    return widgets.height
end

local function HideProfiles()
    if not profileWidgets then return end
    profileWidgets.current:Hide()
    profileWidgets.heading:Hide()
    profileWidgets.nameLabel:Hide()
    profileWidgets.nameBox:Hide()
    profileWidgets.status:Hide()
    for _, row in ipairs(profileWidgets.rows) do row:Hide() end
    profileWidgets.copyButton:Hide()
    profileWidgets.createButton:Hide()
    profileWidgets.useButton:Hide()
    profileWidgets.deleteButton:Hide()
end

local function ShowOptions(parent)
    local widgets = EnsureOptionWidgets(parent)
    local appearance = CurrentOptionAppearance()

    for key, button in pairs(widgets.groupButtons) do
        button:SetEnabled(key ~= optionsGroup)
        button:Show()
    end

    for _, slider in ipairs(widgets.sliders) do
        local value = appearance and appearance[slider.definition.option]
            or Const.DEFAULT_APPEARANCE[slider.definition.option] or 0

        -- Guard so setting the value programmatically does not write it back.
        slider.settingValue = true
        slider:SetValue(value)
        slider.settingValue = false

        if slider.label then
            slider.label:SetText(("%s: %d"):format(slider.definition.label, value))
        end
        slider:Show()
    end

    for _, check in ipairs(widgets.toggles) do
        local option = check.definition.option
        local value = appearance and appearance[option]
        if value == nil then value = Const.DEFAULT_APPEARANCE[option] end
        check:SetChecked(value and true or false)
        check:Show()
    end

    return widgets.height
end

local function HideOptions()
    if not optionWidgets then return end
    for _, button in pairs(optionWidgets.groupButtons) do button:Hide() end
    for _, slider in ipairs(optionWidgets.sliders) do slider:Hide() end
    for _, check in ipairs(optionWidgets.toggles) do check:Hide() end
end

-- ButtonFrameTemplate gives the portrait, title bar, close button, inset and
-- bottom button strip that Blizzard's own dialogs use. Its keys moved around
-- between versions, so both the mixin and the direct paths are tried.

local function SetDialogTitle(dialog, text)
    if dialog.SetTitle then
        -- PortraitFrameTemplateMixin:SetTitle reads self.TitleText, but the
        -- FontString's parentKey is scoped to TitleContainer, so on some builds
        -- that resolves to nil and throws.
        if pcall(dialog.SetTitle, dialog, text) then return end
    end

    local titleText = (dialog.TitleContainer and dialog.TitleContainer.TitleText)
        or dialog.TitleText
        or _G["CDMCSettingsFrameTitleText"]

    if titleText then titleText:SetText(text) end
end

local function SetDialogPortrait(dialog, texture)
    local portrait = (dialog.PortraitContainer and dialog.PortraitContainer.portrait)
        or dialog.portrait
        or _G["CDMCSettingsFramePortrait"]

    if not portrait then return end

    -- Never SetTexCoord here: this texture is masked by the template's
    -- CircleMask, and a non-default TexCoord on a masked texture breaks the
    -- masking. (SetPortraitToTexture does not exist on Classic at all.)
    portrait:SetTexture(texture)

    -- SetTexture drops the texture's mask associations, so the circle mask has
    -- to be attached again afterwards or the icon renders as a bare square
    -- overhanging the portrait ring.
    local mask = dialog.PortraitContainer and dialog.PortraitContainer.CircleMask
    if mask and portrait.AddMaskTexture then
        pcall(portrait.AddMaskTexture, portrait, mask)
    end
end

local function CreateFrameOnce()
    if frame then return frame end

    frame = CreateFrame("Frame", "CDMCSettingsFrame", UIParent, "ButtonFrameTemplate")
    frame:SetSize(CONTENT_WIDTH + 44, 520)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    tinsert(UISpecialFrames, "CDMCSettingsFrame")

    SetDialogPortrait(frame, "Interface\\Icons\\INV_Misc_PocketWatch_01")

    -- Push the inset down to leave room for the tab row and the search box,
    -- which sit above it rather than inside the scrolling area.
    if frame.Inset then
        frame.Inset:ClearAllPoints()
        frame.Inset:SetPoint("TOPLEFT", 4, -62)
        frame.Inset:SetPoint("BOTTOMRIGHT", -6, 30)
    end

    -- Side tabs down the right edge, as Blizzard's own dialog has them. A row
    -- across the top would collide with the overhanging portrait.
    local TABS_META = {
        cooldowns = { label = "Cooldowns", icon = "Interface\\Icons\\INV_Misc_PocketWatch_01" },
        buffs     = { label = "Buffs",     icon = "Interface\\Icons\\Spell_Holy_WordFortitude" },
        options   = { label = "Options",   icon = "Interface\\Icons\\Trade_Engineering" },
        profiles  = { label = "Profiles",  icon = "Interface\\Icons\\INV_Misc_Book_09" },
    }

    frame.tabButtons = {}
    local previousTab
    for _, tabKey in ipairs(TAB_ORDER) do
        local meta = TABS_META[tabKey]

        local tab = CreateFrame("CheckButton", nil, frame)
        tab:SetSize(32, 32)
        if previousTab then
            tab:SetPoint("TOPLEFT", previousTab, "BOTTOMLEFT", 0, -17)
        else
            tab:SetPoint("TOPLEFT", frame, "TOPRIGHT", -1, -36)
        end

        local background = tab:CreateTexture(nil, "BACKGROUND")
        background:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
        background:SetSize(64, 64)
        background:SetPoint("TOPLEFT", -3, 11)

        -- The icon is its own ARTWORK texture rather than the button's normal
        -- texture. A bare CheckButton stops drawing its normal texture while it
        -- is checked, which blanked the icon on exactly the selected tab; an
        -- explicit texture is shown regardless of check state.
        local icon = tab:CreateTexture(nil, "ARTWORK")
        icon:SetTexture(meta.icon)
        icon:SetAllPoints()
        tab.icon = icon

        tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        -- Drawn behind the icon so "selected" reads as a glow around it, not a
        -- square on top of it.
        local checked = tab:CreateTexture(nil, "BORDER")
        checked:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        checked:SetBlendMode("ADD")
        checked:SetAllPoints()
        tab:SetCheckedTexture(checked)

        tab.tooltipText = meta.label
        tab:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tooltipText)
            GameTooltip:Show()
        end)
        tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
        tab:SetScript("OnClick", function()
            -- The same click the character and spellbook side tabs make.
            if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then
                PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
            end
            currentTab = tabKey
            SpellPicker:Refresh()
        end)

        frame.tabButtons[tabKey] = tab
        previousTab = tab
    end

    local search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    search:SetSize(180, 18)
    -- Kept clear of the portrait, which overhangs the top-left corner.
    search:SetPoint("TOPLEFT", 78, -36)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function(self)
        searchText = self:GetText() or ""
        SpellPicker:Refresh()
    end)
    search:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    frame.search = search

    local anchor = frame.Inset or frame
    local scroll = CreateFrame("ScrollFrame", "CDMCSettingsScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", anchor, "TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -28, 6)
    frame.scroll = scroll

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(CONTENT_WIDTH, 350)
    scroll:SetScrollChild(content)
    frame.content = content

    -- The bottom strip ButtonFrameTemplate reserves is where Blizzard puts
    -- Save, so the buttons go there rather than floating over the inset.
    local save = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    save:SetSize(100, 22)
    save:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 4)
    save:SetText("Done")
    save:SetScript("OnClick", function()
        -- Edits already committed; this just closes the dialog.
        SpellPicker:Hide()
    end)
    frame.saveButton = save

    local revert = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    revert:SetSize(100, 22)
    revert:SetPoint("RIGHT", save, "LEFT", -6, 0)
    revert:SetText("Revert")
    revert:SetScript("OnClick", function()
        RestoreOpenSnapshot()
        SpellPicker:Refresh()
    end)
    frame.revertButton = revert

    local share = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    share:SetSize(100, 22)
    share:SetPoint("RIGHT", revert, "LEFT", -6, 0)
    share:SetText("Share Profile")
    share:SetScript("OnClick", function()
        ns.ProfileShare:ShowExport()
    end)
    frame.shareButton = share

    -- Manual ID entry, for auras that appear nowhere the picker can find them.
    local addLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    addLabel:SetPoint("TOPLEFT", search, "TOPRIGHT", 14, -2)
    addLabel:SetText("Add ID:")

    local addBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    addBox:SetSize(70, 18)
    addBox:SetPoint("LEFT", addLabel, "RIGHT", 10, 0)
    addBox:SetAutoFocus(false)
    addBox:SetNumeric(true)
    addBox:SetScript("OnEnterPressed", function(self)
        SpellPicker:AddByID(tonumber(self:GetText()))
        self:SetText("")
        self:ClearFocus()
    end)
    addBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    frame.addBox = addBox

    -- Kept short: the bottom strip also carries three buttons.
    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 10)
    frame.hint:SetText("Drag icons to move.")

    return frame
end

-- Deliberately unvalidated against the spellbook: the point is to reach IDs the
-- picker cannot discover.
function SpellPicker:AddByID(spellID)
    if not spellID or spellID <= 0 then
        ns.Print("|cffff5555Enter a numeric spell ID.|r")
        return
    end

    local target = TABS[currentTab].sections[1] and TABS[currentTab].sections[1].key
    if not target or not working[target] then
        ns.Print("|cffff5555Switch to the Cooldowns or Buffs tab first.|r")
        return
    end

    for _, entry in ipairs(working[target]) do
        if entry.spellID == spellID then
            ns.Print(("%d is already tracked there."):format(spellID))
            return
        end
    end

    local name = ns.Compat.GetSpellInfo(spellID)
    table.insert(working[target], {
        spellID = spellID,
        name = name,
        -- Exact: a manually entered ID is the specific one the user wants, so
        -- it must not be re-pointed at another rank by name.
        rankIndependent = false,
        trackDebuff = Const.IsAuraSpell(spellID) or nil,
    })

    CommitEdit()
    ns.Print(("added %s (%d) to %s.")
        :format(name and ("|cffffff00" .. name .. "|r") or "unknown spell", spellID,
                Const.GROUP_LABELS[target] or target))

    self:Refresh()
end

function SpellPicker:Refresh()
    if not frame or not frame:IsShown() then return end

    -- Re-read every time, never the copy taken when the dialog opened. Import,
    -- preset, profile switch and reset all replace the profile underneath an
    -- open dialog, and the stale copy would be written back over the new one on
    -- the next click. Edits commit as they happen, so nothing is lost here.
    LoadWorking()

    local tab = TABS[currentTab]
    SetDialogTitle(frame, tab.title)

    -- Side tabs are CheckButtons, so the active one is shown checked rather
    -- than disabled.
    for key, button in pairs(frame.tabButtons) do
        button:SetChecked(key == currentTab)
    end

    ReleaseSections()

    -- Search and Save/Revert only mean anything on the spell tabs.
    local isPanel = PANEL_TABS[currentTab] or false
    frame.search:SetShown(not isPanel)
    frame.saveButton:SetShown(not isPanel)
    frame.revertButton:SetShown(not isPanel)

    if currentTab == "profiles" then
        HideOptions()
        frame.hint:SetText("Each character remembers its own profile.")
        frame.content:SetHeight(math.max(ShowProfiles(frame.content), 350))
        return
    end

    HideProfiles()

    if currentTab == "options" then
        frame.hint:SetText("Changes apply immediately.")
        frame.content:SetHeight(math.max(ShowOptions(frame.content), 350))
        return
    end

    HideOptions()
    frame.hint:SetText("Drag icons to move.")

    local yOffset = 0
    for _, definition in ipairs(tab.sections) do
        local entries = definition.key and working[definition.key] or GetNotDisplayed(currentTab)
        yOffset = yOffset + BuildSection(frame.content, definition, entries, yOffset) + SECTION_GAP
    end

    frame.content:SetHeight(math.max(yOffset, 350))
end

function SpellPicker:Show(tabKey)
    CreateFrameOnce()
    if tabKey and TABS[tabKey] then currentTab = tabKey end
    LoadWorking()
    TakeOpenSnapshot()
    frame:Show()
    self:Refresh()
end

function SpellPicker:Hide()
    if frame then frame:Hide() end
end

function SpellPicker:Toggle(tabKey)
    if frame and frame:IsShown() then
        self:Hide()
    else
        self:Show(tabKey)
    end
end
