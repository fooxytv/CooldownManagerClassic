local addonName, ns = ...

local Const = ns.Constants
local Compat = ns.Compat

-- The settings dialog, modelled on Blizzard's Advanced Cooldown Settings:
-- sections of icons rather than a list, drag and drop to move a spell between
-- sections or reorder it within one, and a search that dims non-matches in
-- place instead of filtering them away.
--
-- Edits are staged in a working copy and only written to the profile on Save,
-- so Revert costs nothing and a mis-drag is never destructive.

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
            { key = "essential", label = "Essential Cooldowns" },
            { key = "utility",   label = "Utility Cooldowns" },
            { key = nil,         label = "Not Displayed" },
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
}

local TAB_ORDER = { "cooldowns", "buffs", "options" }

-- Per-group display settings, shown on the Options tab until the Edit Mode
-- panel takes over. Applied immediately rather than staged, because seeing the
-- icons resize as you drag a slider is the whole point.
local OPTION_SLIDERS = {
    { option = "iconSize", label = "Icon Size", min = 16, max = 72, step = 1 },
    -- Negative padding is allowed on purpose: the Blizzard bevel overhangs the
    -- icon by several pixels, so zero padding still reads as a gap. Going
    -- negative is what lets the icons actually touch or overlap.
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

--------------------------------------------------------------------------------
-- Working copy
--------------------------------------------------------------------------------

local function LoadWorking()
    wipe(working)
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.DB:GetGroup(key)
        working[key] = group and ns.DeepCopy(group.spells) or {}
    end
end

local function SaveWorking()
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.DB:GetGroup(key)
        if group and working[key] then
            group.spells = ns.DeepCopy(working[key])
        end
    end
    ns.Core:RefreshAll()
end

--- Whether a spell is already tracked *by the sections of this tab*.
---
--- Deliberately scoped to the tab rather than the whole profile: a spell can be
--- both an Essential cooldown and a Tracked Buff, which is exactly what happens
--- with things like Blade Dance that are cast on a cooldown and also apply an
--- aura worth watching. Checking every group would hide it from the Buffs tab
--- as soon as it appeared on the Cooldowns one.
local function IsTracked(spellID, tabKey)
    for _, definition in ipairs(TABS[tabKey].sections) do
        local entries = definition.key and working[definition.key]
        if entries then
            for _, entry in ipairs(entries) do
                if entry.spellID == spellID then return true end
            end
        end
    end
    return false
end

--- Everything this tab could track but is not tracking yet.
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

    -- On the buff tab, anything currently on the player is offered too. Some
    -- auras -- Season of Discovery runes especially -- apply a buff whose spell
    -- ID is not the ability you cast and is nowhere in the spellbook, so this
    -- is the only way to reach them.
    if tabKey == "buffs" then
        for _, aura in ipairs(ns.Compat.GetPlayerAuras()) do
            Add(aura.spellID, aura.name)
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

--------------------------------------------------------------------------------
-- Drag and drop
--------------------------------------------------------------------------------

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

--- The frame under the mouse right now.
---
--- OnReceiveDrag is not usable here: it only fires when something is actually
--- on the cursor (a spell or item picked up through the Blizzard APIs). A drag
--- of a plain frame carries no cursor payload, so the drop has to be resolved
--- by hit-testing on OnDragStop instead.
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

--- Moves the dragged spell into targetGroup at targetIndex. A nil targetGroup
--- means the "Not Displayed" bucket, i.e. remove it from wherever it was.
local function DropInto(targetGroup, targetIndex)
    if not drag then return end
    drag.handled = true

    local entry = RemoveFrom(drag.fromGroup, drag.spellID)
        or { spellID = drag.spellID, name = drag.entry and drag.entry.name, rankIndependent = true }

    if targetGroup and working[targetGroup] then
        local list = working[targetGroup]

        -- Clear any copy already in the destination so a cross-group move
        -- cannot leave a duplicate behind.
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
    SpellPicker:Refresh()
end

--- Called when the mouse is released after a drag. Walks up from whatever is
--- under the cursor until it finds an icon (insert at that position) or a
--- section (append), and cancels if it finds neither.
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

--------------------------------------------------------------------------------
-- Icon buttons
--------------------------------------------------------------------------------

local buttonPool = {}

local function OnIconEnter(self)
    if not self.spellID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    Compat.SetTooltipSpellByID(GameTooltip, self.spellID)
    GameTooltip:Show()
end

local function OnIconLeave()
    GameTooltip:Hide()
end

local function CreateIconButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(ICON_SIZE, ICON_SIZE)
    button:RegisterForDrag("LeftButton")

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
    button.highlight:SetAllPoints()
    button.highlight:SetColorTexture(1, 1, 1, 0.25)

    button.cdmcIsIcon = true

    button:SetScript("OnEnter", OnIconEnter)
    button:SetScript("OnLeave", OnIconLeave)
    button:SetScript("OnDragStart", BeginDrag)
    button:SetScript("OnDragStop", ResolveDrop)

    -- Click to move a spell between tracked and not-displayed without dragging.
    button:SetScript("OnClick", function(self)
        if self.groupKey then
            RemoveFrom(self.groupKey, self.spellID)
        else
            local target = TABS[currentTab].sections[1].key
            if target and working[target] then
                table.insert(working[target], {
                    spellID = self.spellID,
                    name = self.entry and self.entry.name,
                    rankIndependent = true,
                })
            end
        end
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
    buttonPool[#buttonPool + 1] = button
end

--------------------------------------------------------------------------------
-- Sections
--------------------------------------------------------------------------------

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

--- Renders one section and returns its height.
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

--------------------------------------------------------------------------------
-- Options tab
--------------------------------------------------------------------------------

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

    -- Which group these settings apply to.
    local previous
    for index, key in ipairs(Const.GROUP_ORDER) do
        local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        button:SetSize(120, 22)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            button:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -4)
        end
        button:SetText(Const.GROUP_LABELS[key] or key)
        button:SetScript("OnClick", function()
            optionsGroup = key
            SpellPicker:Refresh()
        end)
        optionWidgets.groupButtons[key] = button
        previous = button
    end

    local y = -46
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

--------------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------------

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

    -- Cooldowns / Buffs switch, mirroring Blizzard's two side buttons.
    -- Side tabs down the right edge, matching Blizzard's own dialog rather than
    -- a row of buttons across the top -- which also stops them colliding with
    -- the portrait, which deliberately overhangs the top-left corner.
    local TABS_META = {
        cooldowns = { label = "Cooldowns", icon = "Interface\\Icons\\INV_Misc_PocketWatch_01" },
        buffs     = { label = "Buffs",     icon = "Interface\\Icons\\Spell_Holy_WordFortitude" },
        options   = { label = "Options",   icon = "Interface\\Icons\\Trade_Engineering" },
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

        tab:SetNormalTexture(meta.icon)
        tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        tab:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight", "ADD")

        tab.tooltipText = meta.label
        tab:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tooltipText)
            GameTooltip:Show()
        end)
        tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
        tab:SetScript("OnClick", function()
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
    save:SetSize(110, 22)
    save:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 4)
    save:SetText("Save")
    save:SetScript("OnClick", function()
        SaveWorking()
        ns.Print("layout saved.")
    end)
    frame.saveButton = save

    local revert = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    revert:SetSize(110, 22)
    revert:SetPoint("RIGHT", save, "LEFT", -6, 0)
    revert:SetText("Revert")
    revert:SetScript("OnClick", function()
        LoadWorking()
        SpellPicker:Refresh()
    end)
    frame.revertButton = revert

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

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 10)
    frame.hint:SetText("Drag icons between sections, or click to move.")

    return frame
end

--- Adds a spell or aura ID straight into this tab's first tracked section.
--- Nothing is validated against the spellbook: the whole point is to reach IDs
--- the picker cannot discover.
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
    })

    ns.Print(("added %s (%d) to %s - press Save to keep it.")
        :format(name and ("|cffffff00" .. name .. "|r") or "unknown spell", spellID,
                Const.GROUP_LABELS[target] or target))

    self:Refresh()
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

function SpellPicker:Refresh()
    if not frame or not frame:IsShown() then return end

    local tab = TABS[currentTab]
    SetDialogTitle(frame, tab.title)

    -- Side tabs are CheckButtons, so the active one is shown checked rather
    -- than disabled.
    for key, tab in pairs(frame.tabButtons) do
        tab:SetChecked(key == currentTab)
    end

    ReleaseSections()

    -- Search and Save/Revert only mean anything on the spell tabs.
    local isOptions = currentTab == "options"
    frame.search:SetShown(not isOptions)
    frame.saveButton:SetShown(not isOptions)
    frame.revertButton:SetShown(not isOptions)
    frame.hint:SetText(isOptions
        and "Changes apply immediately."
        or "Drag icons between sections, or click to move.")

    if isOptions then
        frame.content:SetHeight(math.max(ShowOptions(frame.content), 350))
        return
    end

    HideOptions()

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
