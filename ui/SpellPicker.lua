local addonName, ns = ...

local Const = ns.Constants
local Compat = ns.Compat

local SpellPicker = {}
ns.SpellPicker = SpellPicker

local ICON_SIZE = 36
local ICON_GAP = 6
local ICONS_PER_ROW = 7
local SECTION_HEADER_HEIGHT = 24
local SECTION_GAP = 8
local CONTENT_WIDTH = ICONS_PER_ROW * (ICON_SIZE + ICON_GAP)

-- The picker's icons are drawn the way the live ones are: the Cooldown Manager
-- mask and bezel where the client ships them, the plain crop where it does not,
-- off the same Compat.AtlasExists probe ui/Icon.lua makes at load. The insets
-- are Icon:Configure's own defaults, scaled from the 40px icon they are written
-- for down to the picker's smaller cell.
--
-- Deliberately no fallback bezel for clients missing the atlas: the live icons
-- have none either, so adding one here alone would put the picker out of step
-- with the game. A border for those clients is #22, where it is configurable.
local ICON_OVERLAY_INSET_X = 8
local ICON_OVERLAY_INSET_Y = 7

local function ApplyIconArt(frame, texture, size)
    if ns.Icon.art.mask and frame.CreateMaskTexture then
        local mask = frame:CreateMaskTexture()
        mask:SetAllPoints()
        mask:SetAtlas(Const.ART.mask)
        if texture.AddMaskTexture then
            texture:AddMaskTexture(mask)
            frame.iconMask = mask
        end
    end

    if not frame.iconMask then
        texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    if not ns.Icon.art.iconOverlay then return end

    local scale = size / (Const.DEFAULT_APPEARANCE.iconSize or 40)
    local overlay = frame:CreateTexture(nil, "OVERLAY")
    overlay:SetAtlas(Const.ART.iconOverlay)
    overlay:SetPoint("TOPLEFT", -ICON_OVERLAY_INSET_X * scale, ICON_OVERLAY_INSET_Y * scale)
    overlay:SetPoint("BOTTOMRIGHT", ICON_OVERLAY_INSET_X * scale, -ICON_OVERLAY_INSET_Y * scale)
    frame.iconOverlay = overlay
end

local COLLAPSE_TEXTURES = {
    expanded  = "Interface\\Buttons\\UI-MinusButton-Up",
    collapsed = "Interface\\Buttons\\UI-PlusButton-Up",
}

local TABS = {
    cooldowns = {
        title = "Cooldown Settings",
        sections = {
            { key = "essential",    label = "Essential Cooldowns" },
            { key = "utility",      label = "Utility Cooldowns" },
            { key = "cooldownbars", label = "Cooldown Bars" },
            { key = nil,            label = "Not Displayed" },
        },
    },
    buffs = {
        title = "Buff Settings",
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

local TAB_ORDER = { "cooldowns", "buffs", "profiles" }

local PANEL_TABS = { options = true, profiles = true }

local OPTION_SLIDERS = {
    { option = "iconSize", label = "Icon Size", min = 16, max = 72, step = 1 },
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

local working = {}

local drag = nil

local function LoadWorking()
    wipe(working)
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.DB:GetGroup(key)
        working[key] = group and ns.DeepCopy(group.spells) or {}
    end
end

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

    if tabKey == "buffs" then
        for _, aura in ipairs(ns.Compat.GetPlayerAuras()) do
            Add(aura.spellID, aura.name)
        end

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
    ApplyIconArt(dragVisual, dragVisual.texture, ICON_SIZE)

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

    if SpellPicker.CloseEntryMenu then SpellPicker.CloseEntryMenu() end

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

local function DropInto(targetGroup, targetIndex)
    if not drag then return end
    drag.handled = true

    local entry = RemoveFrom(drag.fromGroup, drag.spellID)
        or {
            spellID = drag.spellID,
            name = drag.entry and drag.entry.name,
            rankIndependent = true,
            trackDebuff = Const.IsAuraSpell(drag.spellID) or nil,
            forms = Const.DefaultFormsFor(drag.spellID),
        }

    if targetGroup and working[targetGroup] then
        local list = working[targetGroup]

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
    if self.highlight then self.highlight:Show() end
    if not self.spellID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    Compat.SetTooltipForTracked(GameTooltip, self.spellID)
    GameTooltip:Show()
end

local function OnIconLeave(self)
    if self and self.highlight then self.highlight:Hide() end
    GameTooltip:Hide()
end

local function IsDruidPlayer()
    return select(2, UnitClass("player")) == "DRUID"
end

local function FormBadge(entry)
    local forms = entry and entry.forms
    if type(forms) ~= "table" or not next(forms) then return nil end

    local out = {}
    for _, key in ipairs(Const.DRUID_FORMS) do
        if forms[key] then out[#out + 1] = Const.FORM_INITIALS[key] end
    end
    return table.concat(out)
end

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

local formMenu

local function CloseEntryMenu()
    if _G.CloseDropDownMenus then CloseDropDownMenus() end
end
SpellPicker.CloseEntryMenu = CloseEntryMenu

local function RefreshEntryMenu()
    if formMenu and _G.UIDropDownMenu_Refresh then
        UIDropDownMenu_Refresh(formMenu, false, 1)
    end
end

-- LoadWorking replaces these tables on every refresh, so look the entry up
-- again rather than handing the menu a table it will outlive.
local function WorkingEntry(groupKey, spellID)
    local list = groupKey and working[groupKey]
    if not list then return nil end
    for _, entry in ipairs(list) do
        if entry.spellID == spellID then return entry end
    end
    return nil
end

local function ShowEntryMenu(button)
    if ns.EntryMenu then
        local groupKey, spellID = button.groupKey, button.spellID
        ns.EntryMenu.Show("cursor", {
            entry = function() return WorkingEntry(groupKey, spellID) end,
            groupKey = groupKey,
            onChanged = function()
                CommitEdit()
                SpellPicker:Refresh()
            end,
        })
        return
    end

    if not formMenu then
        formMenu = CreateFrame("Frame", "CDMCFormMenu", UIParent, "UIDropDownMenuTemplate")
    end

    CloseEntryMenu()

    UIDropDownMenu_Initialize(formMenu, function()
        local entry = button.entry
        if not entry then return end

        local dot = UIDropDownMenu_CreateInfo()
        dot.text = "Track its aura (buff or DoT)"
        dot.isNotRadio = true
        dot.checked = entry.trackDebuff and true or false
        dot.func = function()
            entry.trackDebuff = not entry.trackDebuff or nil
            CommitEdit()
            CloseEntryMenu()
            SpellPicker:Refresh()
        end
        UIDropDownMenu_AddButton(dot)

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
                info.keepShownOnClick = true
                info.func = function()
                    ToggleEntryForm(entry, opt.value)
                    CommitEdit()
                    SpellPicker:Refresh()
                    RefreshEntryMenu()
                end
                UIDropDownMenu_AddButton(info)
            end

            local note = UIDropDownMenu_CreateInfo()
            note.text = "|cff888888(all forms show while unlocked)|r"
            note.isTitle = true
            note.notCheckable = true
            UIDropDownMenu_AddButton(note)
        end
    end, "MENU")

    ToggleDropDownMenu(1, nil, formMenu, "cursor", 0, 0)
end

-- Bar entries preview the widget the game actually builds rather than a
-- stand-in, configured from the group's own appearance, so a bar texture or
-- content mode picked in Edit Mode shows up in the picker for free.
--
-- Part-filled rather than full: it shows the pip and the fill edge, and does
-- not read as "this spell is on cooldown right now". suppressText keeps the
-- countdown off, there being no real timer behind it.
local PREVIEW_STATE = {
    phase = "active",
    swipeDuration = 1,
    remaining = 0.6,
    suppressText = true,
}

local function PreviewAppearance(appearance, width, height)
    local copy = {}
    for key, value in pairs(appearance) do copy[key] = value end
    copy.barWidth = width
    copy.barHeight = height
    copy.showTooltips = false
    -- The picker button owns the clicks on this row. Left on, BuffBar:Configure
    -- would make the preview click-enabled and its own OnMouseUp would open the
    -- live group's entry menu from inside the picker.
    copy.rightClickMenu = false
    return copy
end

-- A child of its button, so it follows the button wherever the pool sends it.
-- Parenting it to the section instead meant tracking a parent that could go
-- stale the moment a pooled button moved between sections.
--
-- Never handed back to BuffBar's shared pool. It lives on this pooled picker
-- button instead, so the count stays bounded by the rows on screen rather than
-- interleaving with the bars the live groups are drawing.
local function EnsureBarPreview(button)
    if not button.barPreview then
        local preview = ns.BuffBar:Acquire(button, nil)
        preview:SetPoint("TOPLEFT", button, "TOPLEFT")
        ns.SetTooltipsShown(preview, false)
        button.barPreview = preview
    end
    return button.barPreview
end

local function CreateIconButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(ICON_SIZE, ICON_SIZE)
    button:RegisterForDrag("LeftButton")
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    ApplyIconArt(button, button.icon, ICON_SIZE)

    -- Above the bar preview rather than on the button itself: a HIGHLIGHT-layer
    -- texture is covered by any child frame, and the preview is one. Toggled by
    -- hand in OnIconEnter/OnIconLeave, since only a Button's own HIGHLIGHT layer
    -- responds to the mouse on its own.
    button.hoverLayer = CreateFrame("Frame", nil, button)
    button.hoverLayer:SetAllPoints()
    button.hoverLayer:SetFrameLevel(button:GetFrameLevel() + 20)

    button.highlight = button.hoverLayer:CreateTexture(nil, "OVERLAY")
    button.highlight:SetAllPoints()
    button.highlight:SetColorTexture(1, 1, 1, 0.25)
    button.highlight:Hide()

    button.formText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.formText:SetPoint("BOTTOMLEFT", 1, 1)
    button.formText:SetTextColor(0.4, 0.8, 1)
    button.formText:Hide()

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
                    trackDebuff = Const.IsAuraSpell(self.spellID) or nil,
                    forms = Const.DefaultFormsFor(self.spellID),
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
    if button.barPreview then button.barPreview:Hide() end
    if button.highlight then button.highlight:Hide() end
    buttonPool[#buttonPool + 1] = button
end

local sectionPool = {}
local activeSections = {}

local function SectionKey(definition)
    return currentTab .. ":" .. (definition.key or "notDisplayed")
end

local function IsSectionCollapsed(definition)
    local global = ns.DB:GetGlobal()
    local collapsed = global and global.collapsedSections
    return collapsed ~= nil and collapsed[SectionKey(definition)] == true
end

local function SetSectionCollapsed(definition, collapsed)
    local global = ns.DB:GetGlobal()
    if not global then return end
    global.collapsedSections = global.collapsedSections or {}
    global.collapsedSections[SectionKey(definition)] = collapsed or nil
end

local function CreateSection(parent)
    local section = CreateFrame("Frame", nil, parent)
    section:SetWidth(CONTENT_WIDTH)
    section:EnableMouse(true)

    local header = CreateFrame("Button", nil, section)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:SetHeight(SECTION_HEADER_HEIGHT)
    section.header = header

    header.bg = header:CreateTexture(nil, "BACKGROUND")
    header.bg:SetAllPoints()
    header.bg:SetColorTexture(0.13, 0.13, 0.16, 0.95)

    header.edge = header:CreateTexture(nil, "BORDER")
    header.edge:SetPoint("BOTTOMLEFT", 0, 0)
    header.edge:SetPoint("BOTTOMRIGHT", 0, 0)
    header.edge:SetHeight(1)
    header.edge:SetColorTexture(0, 0, 0, 0.9)

    header:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    section.label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    section.label:SetPoint("LEFT", 8, 0)
    section.label:SetTextColor(1, 0.82, 0)

    section.count = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    section.count:SetPoint("RIGHT", -28, 0)

    local toggle = CreateFrame("Button", nil, header)
    toggle:SetSize(16, 16)
    toggle:SetPoint("RIGHT", -6, 0)
    toggle:SetNormalTexture(COLLAPSE_TEXTURES.expanded)
    section.toggle = toggle

    local function ToggleSection()
        if drag or not section.definition then return end
        SetSectionCollapsed(section.definition, not IsSectionCollapsed(section.definition))
        SpellPicker:Refresh()
    end

    toggle:SetScript("OnClick", ToggleSection)
    header:SetScript("OnClick", ToggleSection)

    section.bg = section:CreateTexture(nil, "BACKGROUND")
    section.bg:SetPoint("TOPLEFT", 0, -SECTION_HEADER_HEIGHT)
    section.bg:SetPoint("BOTTOMRIGHT", 0, 0)
    section.bg:SetColorTexture(0, 0, 0, 0.25)

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

local function BuildSection(parent, definition, entries, yOffset)
    local section = table.remove(sectionPool) or CreateSection(parent)
    section:SetParent(parent)
    section.groupKey = definition.key
    section.definition = definition
    section.label:SetText(definition.label)
    section.count:SetText(#entries > 0 and tostring(#entries) or "")
    section:ClearAllPoints()
    section:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -yOffset)
    section:Show()
    activeSections[#activeSections + 1] = section

    local collapsed = IsSectionCollapsed(definition)
    section.toggle:SetNormalTexture(collapsed and COLLAPSE_TEXTURES.collapsed
        or COLLAPSE_TEXTURES.expanded)
    section.bg:SetShown(not collapsed)

    if collapsed then
        section:SetHeight(SECTION_HEADER_HEIGHT)
        return SECTION_HEADER_HEIGHT
    end

    local isBarSection = definition.key ~= nil and Const.DURATION_BAR_GROUPS[definition.key]
    local rows = isBarSection and math.max(1, #entries)
        or math.max(1, math.ceil(#entries / ICONS_PER_ROW))
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

        local badge = definition.key and IsDruidPlayer() and FormBadge(entry)
        if badge then
            button.formText:SetText(badge)
            button.formText:Show()
        else
            button.formText:Hide()
        end

        button.dotText:SetShown(definition.key ~= nil and entry.trackDebuff == true)

        local column = isBarSection and 0 or (index - 1) % ICONS_PER_ROW
        local row = isBarSection and (index - 1)
            or math.floor((index - 1) / ICONS_PER_ROW)
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", section, "TOPLEFT",
            ICON_GAP / 2 + column * (ICON_SIZE + ICON_GAP),
            -(SECTION_HEADER_HEIGHT + ICON_GAP / 2 + row * (ICON_SIZE + ICON_GAP)))

        local matches = MatchesSearch(name)

        if isBarSection then
            -- The row spans the section, so the whole bar is draggable and
            -- clickable. The old plate sat outside the button's own rect, which
            -- left everything but the icon inert.
            local rowWidth = CONTENT_WIDTH - ICON_GAP
            button:SetSize(rowWidth, ICON_SIZE)
            button.icon:Hide()
            if button.iconOverlay then button.iconOverlay:Hide() end

            local group = ns.DB:GetGroup(definition.key)
            local appearance = PreviewAppearance(group.appearance, rowWidth, ICON_SIZE)
            local preview = EnsureBarPreview(button)

            ns.BuffBar:Configure(preview, entry, resolvedID or entry.spellID,
                appearance, definition.key)
            ns.BuffBar:Update(preview, PREVIEW_STATE, appearance)

            preview:Show()

            -- Applied after Update, which resets the icon's tint and saturation.
            preview:SetAlpha(matches and 1 or 0.35)
            if preview.texture.SetDesaturated then
                preview.texture:SetDesaturated(not matches)
            end
            if not resolvedID then
                preview.texture:SetVertexColor(1, 0.4, 0.4)
            end
        else
            button:SetSize(ICON_SIZE, ICON_SIZE)
            button.icon:Show()
            if button.iconOverlay then button.iconOverlay:Show() end
            if button.barPreview then button.barPreview:Hide() end

            button.icon:SetAlpha(matches and 1 or 0.25)
            if button.icon.SetDesaturated then
                button.icon:SetDesaturated(not matches)
            end

            if not resolvedID then
                button.icon:SetVertexColor(1, 0.4, 0.4)
            else
                button.icon:SetVertexColor(1, 1, 1)
            end
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

local selectedProfile = nil
local selectedLayout = nil
local profileWidgets = nil

local PROFILE_ROWS = 10
local PROFILE_ROW_HEIGHT = 20
local LAYOUT_ROWS = 8

local function SetProfileStatus(text, isError)
    if not profileWidgets then return end
    profileWidgets.status:SetText(text or "")
    if isError then
        profileWidgets.status:SetTextColor(1, 0.35, 0.35)
    else
        profileWidgets.status:SetTextColor(0.6, 0.9, 0.6)
    end
end

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

    profileWidgets.shareButton = AddButton("Share Profile", 0, 2, function()
        ns.ProfileShare:ShowExport()
    end, "Exports the profile in use as a string to paste to someone else, and imports one they send you.")

    y = y - 3 * (BUTTON_H + 6) - 8

    profileWidgets.status = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    profileWidgets.status:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)
    profileWidgets.status:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, y)
    profileWidgets.status:SetJustifyH("LEFT")
    y = y - 30

    local layoutHeading = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    layoutHeading:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)
    layoutHeading:SetText("Starter layouts:")
    profileWidgets.layoutHeading = layoutHeading
    y = y - 18

    profileWidgets.layoutRows = {}
    for index = 1, LAYOUT_ROWS do
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
            selectedLayout = self.layoutKey
            SetProfileStatus(nil)
            SpellPicker:Refresh()
        end)

        profileWidgets.layoutRows[index] = row
        y = y - PROFILE_ROW_HEIGHT
    end

    y = y - 8

    profileWidgets.applyLayout = AddButton("Apply Layout", 0, 0, function()
        if not selectedLayout then
            SetProfileStatus("Select a layout first.", true)
            return
        end

        local ok, result = ns.Presets:ApplyByKey(selectedLayout, true)
        if ok then
            SetProfileStatus(("Loaded the %s layout. Revert puts back what was here."):format(result))
            SpellPicker:Refresh()
        else
            SetProfileStatus(result, true)
        end
    end, "Replaces what this profile tracks with the selected layout. Revert restores what was here when this window opened.")

    profileWidgets.saveLayout = AddButton("Save Current As", 1, 0, function()
        local name = NewProfileName()
        local ok, result = ns.Presets:SaveCurrentAs(name)
        if ok then
            profileWidgets.nameBox:SetText("")
            selectedLayout = "custom:" .. result
            SetProfileStatus(("Saved this layout as %q. It is offered on every character."):format(result))
            SpellPicker:Refresh()
        else
            SetProfileStatus(result, true)
        end
    end, "Saves what this profile currently tracks as a named layout, under the name typed above. Saved layouts are offered on every character on this account.")

    profileWidgets.deleteLayout = AddButton("Delete Layout", 0, 1, function()
        local preset = selectedLayout and ns.Presets:GetByKey(selectedLayout)
        if not preset or not preset.custom then
            SetProfileStatus("Only a saved layout can be deleted.", true)
            return
        end

        local ok, err = ns.Presets:DeleteCustom(preset.name)
        if ok then
            selectedLayout = nil
            SetProfileStatus(("Deleted the %s layout."):format(preset.name))
            SpellPicker:Refresh()
        else
            SetProfileStatus(err, true)
        end
    end, "Deletes the selected saved layout. The built-in class layouts cannot be deleted.")

    y = y - 2 * (BUTTON_H + 6) - 10

    profileWidgets.height = -y + 10
    return profileWidgets
end

local function ShowProfiles(parent)
    local widgets = EnsureProfileWidgets(parent)
    local current = ns.DB:GetCurrentProfileName()
    local names = ns.DB:ListProfiles()

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
        widgets.status:SetText(("Showing the first %d of %d profiles - use /cdmc profile list for the rest.")
            :format(PROFILE_ROWS, #names))
        widgets.status:SetTextColor(1, 0.8, 0.3)
    end

    widgets.copyButton:Show()
    widgets.createButton:Show()
    widgets.useButton:Show()
    widgets.deleteButton:Show()
    widgets.shareButton:Show()

    local layouts = ns.Presets:ListForPlayer()
    widgets.layoutHeading:Show()

    local selectedPreset = selectedLayout and ns.Presets:GetByKey(selectedLayout)
    if selectedLayout and not selectedPreset then
        selectedLayout = nil
    end

    for index, row in ipairs(widgets.layoutRows) do
        local preset = layouts[index]
        if preset then
            row.layoutKey = preset.key
            row.label:SetText(preset.custom and (preset.name .. " |cff888888(saved)|r") or preset.name)
            row.selectedTexture:SetShown(preset.key == selectedLayout)
            row:Show()
        else
            row.layoutKey = nil
            row:Hide()
        end
    end

    widgets.applyLayout:Show()
    widgets.saveLayout:Show()
    widgets.deleteLayout:Show()
    widgets.applyLayout:SetEnabled(selectedLayout ~= nil)
    widgets.deleteLayout:SetEnabled(selectedPreset ~= nil and selectedPreset.custom == true)

    if #layouts > LAYOUT_ROWS then
        widgets.status:SetText(("Showing the first %d of %d layouts - use /cdmc preset list for the rest.")
            :format(LAYOUT_ROWS, #layouts))
        widgets.status:SetTextColor(1, 0.8, 0.3)
    end

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
    profileWidgets.shareButton:Hide()
    profileWidgets.layoutHeading:Hide()
    for _, row in ipairs(profileWidgets.layoutRows) do row:Hide() end
    profileWidgets.applyLayout:Hide()
    profileWidgets.saveLayout:Hide()
    profileWidgets.deleteLayout:Hide()
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

local function SetDialogTitle(dialog, text)
    if dialog.SetTitle then
        if pcall(dialog.SetTitle, dialog, text) then return end
    end

    local titleText = (dialog.TitleContainer and dialog.TitleContainer.TitleText)
        or dialog.TitleText
        or _G["CDMCSettingsFrameTitleText"]

    if titleText then titleText:SetText(text) end
end

local function SetDialogPortrait(dialog, texture, coords)
    local portrait = (dialog.PortraitContainer and dialog.PortraitContainer.portrait)
        or dialog.portrait
        or _G["CDMCSettingsFramePortrait"]

    if not portrait then return end

    portrait:SetTexture(texture)

    if coords then
        if portrait.SetTexCoord then
            portrait:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        end
        return
    end

    if portrait.SetTexCoord then portrait:SetTexCoord(0, 1, 0, 1) end

    local mask = dialog.PortraitContainer and dialog.PortraitContainer.CircleMask
    if mask and portrait.AddMaskTexture then
        pcall(portrait.AddMaskTexture, portrait, mask)
    end
end

local function ApplyClassPortrait(dialog)
    local _, class = UnitClass("player")
    local coords = class and _G.CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]

    if coords then
        SetDialogPortrait(dialog, "Interface\\TargetingFrame\\UI-Classes-Circles", coords)
    else
        SetDialogPortrait(dialog, "Interface\\Icons\\INV_Misc_PocketWatch_01")
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

    ApplyClassPortrait(frame)

    if frame.Inset then
        frame.Inset:ClearAllPoints()
        frame.Inset:SetPoint("TOPLEFT", 4, -62)
        frame.Inset:SetPoint("BOTTOMRIGHT", -6, 30)
    end

    -- Blizzard draws these tabs as flat glyphs on a side-tab plate rather than
    -- as ability icons; the names come from its own Cooldown Viewer settings
    -- panel. Only Cooldowns and Buffs have a counterpart there -- Profiles is
    -- ours -- so it keeps an ability icon, desaturated so it does not sit as a
    -- full-colour outlier beside two monochrome glyphs.
    local TABS_META = {
        cooldowns = { label = "Cooldowns", icon = "Interface\\Icons\\INV_Misc_PocketWatch_01",
                      atlas = Const.ART.tabCooldowns },
        buffs     = { label = "Buffs",     icon = "Interface\\Icons\\Spell_Holy_WordFortitude",
                      atlas = Const.ART.tabBuffs },
        options   = { label = "Options",   icon = "Interface\\Icons\\Trade_Engineering" },
        profiles  = { label = "Profiles",  icon = "Interface\\Icons\\INV_Misc_Book_09" },
    }

    -- All three plate atlases or none: a plate without its selected and hover
    -- states would leave the tabs with no pressed or hover feedback at all.
    local platedTabs = Compat.AtlasExists(Const.ART.sideTab)
        and Compat.AtlasExists(Const.ART.sideTabOn)
        and Compat.AtlasExists(Const.ART.sideTabHover)

    local anyGlyph = false
    for _, tabKey in ipairs(TAB_ORDER) do
        local meta = TABS_META[tabKey]
        if meta.atlas and Compat.AtlasExists(meta.atlas) then anyGlyph = true end
    end

    frame.tabButtons = {}
    local previousTab
    for _, tabKey in ipairs(TAB_ORDER) do
        local meta = TABS_META[tabKey]
        local glyph = meta.atlas and Compat.AtlasExists(meta.atlas)

        local tab = CreateFrame("CheckButton", nil, frame)
        -- 43x55 and a 3px gap are LargeSideTabButtonTemplate's own numbers; the
        -- 32x32 and 17px gap are what the SpellBook tab art was tuned for.
        tab:SetSize(platedTabs and 43 or 32, platedTabs and 55 or 32)
        if previousTab then
            tab:SetPoint("TOPLEFT", previousTab, "BOTTOMLEFT", 0, platedTabs and -3 or -17)
        else
            tab:SetPoint("TOPLEFT", frame, "TOPRIGHT", -1, -36)
        end

        local background = tab:CreateTexture(nil, "BACKGROUND")
        if platedTabs then
            background:SetAtlas(Const.ART.sideTab, true)
            background:SetPoint("CENTER")
        else
            background:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
            background:SetSize(64, 64)
            background:SetPoint("TOPLEFT", -3, 11)
        end

        local icon = tab:CreateTexture(nil, "ARTWORK")
        if glyph then
            icon:SetAtlas(meta.atlas, true)
            icon:SetPoint("CENTER", platedTabs and -2 or 0, 0)
        else
            icon:SetTexture(meta.icon)
            icon:SetAllPoints()
            if anyGlyph and icon.SetDesaturated then icon:SetDesaturated(true) end
        end
        tab.icon = icon

        if platedTabs then
            local hover = tab:CreateTexture(nil, "HIGHLIGHT")
            hover:SetAtlas(Const.ART.sideTabHover, true)
            hover:SetPoint("CENTER")
            tab:SetHighlightTexture(hover)

            local checked = tab:CreateTexture(nil, "OVERLAY")
            checked:SetAtlas(Const.ART.sideTabOn, true)
            checked:SetPoint("CENTER")
            tab:SetCheckedTexture(checked)
        else
            tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
            local checked = tab:CreateTexture(nil, "BORDER")
            checked:SetTexture("Interface\\Buttons\\CheckButtonHilight")
            checked:SetBlendMode("ADD")
            checked:SetAllPoints()
            tab:SetCheckedTexture(checked)
        end

        tab.tooltipText = meta.label
        tab:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tooltipText)
            GameTooltip:Show()
        end)
        tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
        tab:SetScript("OnClick", function()
            if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then
                PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
            end
            currentTab = tabKey
            SpellPicker:Refresh()
        end)

        frame.tabButtons[tabKey] = tab
        previousTab = tab
    end

    local search
    local ok, built = pcall(CreateFrame, "EditBox", nil, frame, "SearchBoxTemplate")
    if ok and built then
        search = built
        if search.Instructions then
            search.Instructions:SetText("Enter search text")
        end
    else
        search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    end

    search:SetHeight(20)
    search:SetPoint("TOPLEFT", 72, -34)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(self)
        searchText = self:GetText() or ""
        SpellPicker:Refresh()
    end)
    search:HookScript("OnEscapePressed", function(self)
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

    local profileDropdown = CreateFrame("Frame", "CDMCPickerProfile", frame, "UIDropDownMenuTemplate")
    profileDropdown:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -6, 1)
    UIDropDownMenu_SetWidth(profileDropdown, 118)

    for _, piece in ipairs({ "Left", "Middle", "Right" }) do
        local art = _G["CDMCPickerProfile" .. piece]
        if art then art:Hide() end
    end

    local plateEdge = profileDropdown:CreateTexture(nil, "BACKGROUND")
    plateEdge:SetPoint("TOPLEFT", 15, -5)
    plateEdge:SetPoint("BOTTOMRIGHT", -13, 9)
    plateEdge:SetColorTexture(0.35, 0.33, 0.28, 0.9)

    local plate = profileDropdown:CreateTexture(nil, "BORDER")
    plate:SetPoint("TOPLEFT", plateEdge, "TOPLEFT", 1, -1)
    plate:SetPoint("BOTTOMRIGHT", plateEdge, "BOTTOMRIGHT", -1, 1)
    plate:SetColorTexture(0.09, 0.09, 0.11, 0.95)

    local profileText = _G["CDMCPickerProfileText"]
    if profileText then profileText:SetTextColor(1, 0.82, 0) end
    UIDropDownMenu_Initialize(profileDropdown, function()
        for _, name in ipairs(ns.DB:ListProfiles()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = name
            info.checked = (name == ns.DB:GetCurrentProfileName())
            info.func = function()
                ns.DB:SetProfile(name)
                CloseDropDownMenus()
                SpellPicker:Refresh()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    frame.profileDropdown = profileDropdown

    local revert = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    revert:SetSize(100, 22)
    revert:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 4)
    revert:SetText("Revert")
    revert:SetScript("OnClick", function()
        RestoreOpenSnapshot()
        SpellPicker:Refresh()
    end)
    frame.revertButton = revert

    local addBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    addBox:SetSize(56, 18)
    addBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, -35)
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

    local addLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    addLabel:SetPoint("RIGHT", addBox, "LEFT", -6, 0)
    addLabel:SetText("Add ID:")
    frame.addLabel = addLabel

    search:SetPoint("RIGHT", addLabel, "LEFT", -8, 0)

    return frame
end

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
        rankIndependent = false,
        trackDebuff = Const.IsAuraSpell(spellID) or nil,
        forms = Const.DefaultFormsFor(spellID),
    })

    CommitEdit()
    ns.Print(("added %s (%d) to %s.")
        :format(name and ("|cffffff00" .. name .. "|r") or "unknown spell", spellID,
                Const.GROUP_LABELS[target] or target))

    self:Refresh()
end

function SpellPicker:Refresh()
    if not frame or not frame:IsShown() then return end

    LoadWorking()

    local tab = TABS[currentTab]
    SetDialogTitle(frame, tab.title)

    for key, button in pairs(frame.tabButtons) do
        button:SetChecked(key == currentTab)
    end

    ReleaseSections()

    local isPanel = PANEL_TABS[currentTab] or false
    frame.search:SetShown(not isPanel)
    frame.addLabel:SetShown(not isPanel)
    frame.addBox:SetShown(not isPanel)
    frame.revertButton:SetShown(not isPanel)

    UIDropDownMenu_SetText(frame.profileDropdown, ns.DB:GetCurrentProfileName() or "Default")

    if currentTab == "profiles" then
        HideOptions()
        frame.content:SetHeight(math.max(ShowProfiles(frame.content), 350))
        return
    end

    HideProfiles()

    if currentTab == "options" then
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
    ApplyClassPortrait(frame)
    CloseEntryMenu()
    if tabKey and TABS[tabKey] then currentTab = tabKey end
    LoadWorking()
    TakeOpenSnapshot()
    frame:Show()
    self:Refresh()
end

function SpellPicker:Hide()
    CloseEntryMenu()
    if frame then frame:Hide() end
end

function SpellPicker:Toggle(tabKey)
    if frame and frame:IsShown() then
        self:Hide()
    else
        self:Show(tabKey)
    end
end
