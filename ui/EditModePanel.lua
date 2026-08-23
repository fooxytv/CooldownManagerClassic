local addonName, ns = ...

local Const = ns.Constants

-- Our own frame alongside Blizzard's Edit Mode dialog rather than inside it:
-- there is no supported way to register a third-party Edit Mode system.

local Panel = {}
ns.EditModePanel = Panel

local panel
local currentGroup
local snapshot

local function Settings()
    return currentGroup and ns.DB:GetGroup(currentGroup) or nil
end

local function Appearance()
    local settings = Settings()
    return settings and settings.appearance or nil
end

local function GetOption(option)
    local appearance = Appearance()
    local value = appearance and appearance[option]
    if value == nil then value = Const.DEFAULT_APPEARANCE[option] end
    return value
end

local function SetOption(option, value)
    local appearance = Appearance()
    if not appearance then return end

    appearance[option] = value
    ns.Core:RefreshGroup(currentGroup)
    Panel:Refresh()
end

local widgetIndex = 0

local function CreateSlider(parent, label, option, minValue, maxValue, step)
    widgetIndex = widgetIndex + 1
    local name = "CDMCPanelSlider" .. widgetIndex

    local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    slider:SetWidth(170)
    slider:SetMinMaxValues(minValue, maxValue)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)

    local low, high = _G[name .. "Low"], _G[name .. "High"]
    if low then low:SetText(minValue) end
    if high then high:SetText(maxValue) end

    slider.labelText = _G[name .. "Text"]
    slider.option = option
    slider.labelPrefix = label

    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        if self.labelText then
            self.labelText:SetText(("%s: %d"):format(self.labelPrefix, value))
        end
        -- Guarded so pushing the stored value into the widget does not write
        -- straight back and fight the user's drag.
        if not self.settingValue then
            SetOption(self.option, value)
        end
    end)

    return slider
end

local function CreateDropdown(parent, label, option, getChoices, onSelect)
    widgetIndex = widgetIndex + 1
    local name = "CDMCPanelDropdown" .. widgetIndex

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(190, 40)

    container.label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    container.label:SetPoint("TOPLEFT", 4, 0)
    container.label:SetText(label)

    local dropdown = CreateFrame("Frame", name, container, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", container, "TOPLEFT", -12, -14)
    UIDropDownMenu_SetWidth(dropdown, 140)

    UIDropDownMenu_Initialize(dropdown, function()
        for _, choice in ipairs(getChoices()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = choice.label
            info.checked = (GetOption(option) == choice.value)
            info.func = function()
                SetOption(option, choice.value)
                if onSelect then onSelect(choice.value) end
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    container.dropdown = dropdown
    container.option = option
    container.getChoices = getChoices
    return container
end

-- `handlers` (optional) with .get/.set drives a checkbox that is not a group
-- appearance option -- e.g. the profile-level reactive-highlight toggle. Without
-- it, the checkbox reads and writes appearance[option] as usual.
local function CreateCheckbox(parent, label, option, handlers)
    widgetIndex = widgetIndex + 1
    local name = "CDMCPanelCheck" .. widgetIndex

    local check = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    local text = _G[name .. "Text"] or check.text or check.Text
    if text then text:SetText(label) end

    check.option = option
    check.getState = handlers and handlers.get
    check:SetScript("OnClick", function(self)
        local checked = self:GetChecked() and true or false
        if handlers and handlers.set then
            handlers.set(checked)
        else
            SetOption(self.option, checked)
        end
    end)

    return check
end

local function SimpleChoices(values)
    return function()
        local choices = {}
        for _, value in ipairs(values) do
            choices[#choices + 1] = { value = value, label = value }
        end
        return choices
    end
end

-- LibSharedMedia names for a picker, led by a "Default" entry (value "") for the
-- built-in look. Empty of media without the library, which still leaves Default.
local function MediaChoices(mediatype)
    return function()
        local choices = { { value = "", label = "Default" } }
        for _, name in ipairs(ns.Media.List(mediatype)) do
            choices[#choices + 1] = { value = name, label = name }
        end
        return choices
    end
end

local function BuildPanel()
    if panel then return panel end

    panel = CreateFrame("Frame", "CDMCEditModePanel", UIParent, "ButtonFrameTemplate")
    panel:SetSize(250, 470)
    panel:SetPoint("CENTER", UIParent, "CENTER", 320, 0)
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()

    if panel.Inset then panel.Inset:Hide() end

    local y = -32

    panel.orientation = CreateDropdown(panel, "Orientation", "orientation",
        SimpleChoices(Const.ORIENTATIONS))
    panel.orientation:SetPoint("TOPLEFT", 16, y)
    y = y - 46

    panel.rows = CreateSlider(panel, "# Rows", "rows", 1, 8, 1)
    panel.rows:SetPoint("TOPLEFT", 24, y)
    y = y - 46

    panel.iconDirection = CreateDropdown(panel, "Icon Direction", "iconDirection", function()
        local orientation = GetOption("orientation") or "Horizontal"
        local values = Const.ICON_DIRECTIONS[orientation] or Const.ICON_DIRECTIONS.Horizontal
        local choices = {}
        for _, value in ipairs(values) do
            choices[#choices + 1] = { value = value, label = value }
        end
        return choices
    end)
    panel.iconDirection:SetPoint("TOPLEFT", 16, y)
    y = y - 46

    panel.iconSize = CreateSlider(panel, "Icon Size", "iconSize", 16, 72, 1)
    panel.iconSize:SetPoint("TOPLEFT", 24, y)
    y = y - 46

    panel.spacing = CreateSlider(panel, "Icon Padding", "spacing", -12, 24, 1)
    panel.spacing:SetPoint("TOPLEFT", 24, y)
    y = y - 46

    panel.opacity = CreateSlider(panel, "Opacity", "opacity", 10, 100, 5)
    panel.opacity:SetPoint("TOPLEFT", 24, y)
    y = y - 46

    panel.visibility = CreateDropdown(panel, "Visibility", "visibility", function()
        return Const.VISIBILITY_OPTIONS
    end)
    panel.visibility:SetPoint("TOPLEFT", 16, y)
    y = y - 44

    panel.showTimer = CreateCheckbox(panel, "Show Timer", "showCountdownText")
    panel.showTimer:SetPoint("TOPLEFT", 20, y)
    y = y - 26

    panel.showTooltips = CreateCheckbox(panel, "Show Tooltips", "showTooltips")
    panel.showTooltips:SetPoint("TOPLEFT", 20, y)
    y = y - 26

    panel.showKeybind = CreateCheckbox(panel, "Show Keybind", "showKeybind")
    panel.showKeybind:SetPoint("TOPLEFT", 20, y)
    y = y - 26

    -- Reactive proc highlighting, per group: this ticks the group being edited,
    -- so highlights can be on for Essential Cooldowns but off for Utility. A
    -- plain appearance option, so SetOption/GetOption handle it.
    panel.showHighlights = CreateCheckbox(panel, "Reactive Highlights", "highlightsEnabled")
    panel.showHighlights:SetPoint("TOPLEFT", 20, y)
    y = y - 34

    -- Common to every group: the font face applies to the timer / count / bar
    -- text alike.
    panel.fontFace = CreateDropdown(panel, "Font", "fontFace", MediaChoices("font"))
    panel.fontFace:SetPoint("TOPLEFT", 16, y)
    y = y - 46

    -- Buff-only rows. Hidden for the cooldown groups, with the buttons below
    -- sliding up rather than leaving a hole mid-panel.
    panel.buffTop = y

    panel.display = CreateDropdown(panel, "Display", "display",
        SimpleChoices(Const.BUFF_DISPLAYS), function(value)
            -- Flipped with the display: bars are wide and stack downwards.
            if value == "Bars" then
                SetOption("orientation", "Vertical")
                SetOption("iconDirection", "Right")
            else
                SetOption("orientation", "Horizontal")
                SetOption("iconDirection", "Down")
            end
        end)
    panel.display:SetPoint("TOPLEFT", 16, y)
    y = y - 46

    panel.barWidth = CreateSlider(panel, "Bar Width", "barWidth", 120, 400, 5)
    panel.barWidth:SetPoint("TOPLEFT", 24, y)
    y = y - 46

    panel.barHeight = CreateSlider(panel, "Bar Height", "barHeight", 16, 60, 1)
    panel.barHeight:SetPoint("TOPLEFT", 24, y)
    y = y - 46

    panel.barContent = CreateDropdown(panel, "Bar Content", "barContent",
        SimpleChoices(Const.BAR_CONTENTS))
    panel.barContent:SetPoint("TOPLEFT", 16, y)
    y = y - 46

    panel.barMode = CreateDropdown(panel, "Bar Shows", "barMode",
        SimpleChoices(Const.BAR_MODES))
    panel.barMode:SetPoint("TOPLEFT", 16, y)
    y = y - 46

    panel.barTexture = CreateDropdown(panel, "Bar Texture", "barTexture",
        MediaChoices("statusbar"))
    panel.barTexture:SetPoint("TOPLEFT", 16, y)
    y = y - 46

    panel.buffBottom = y

    local revert = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    revert:SetSize(210, 22)
    revert:SetText("Revert Changes")
    revert:SetScript("OnClick", function() Panel:Revert() end)

    local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reset:SetSize(210, 22)
    reset:SetText("Reset to Default Position")
    reset:SetScript("OnClick", function() Panel:ResetPosition() end)

    local advanced = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    advanced:SetSize(210, 22)
    advanced:SetText("Advanced Cooldown Settings")
    advanced:SetScript("OnClick", function()
        ns.SpellPicker:Show(currentGroup == "buffs" and "buffs" or "cooldowns")
    end)

    panel.buttons = { revert, reset, advanced }

    return panel
end

function Panel:Revert()
    if not snapshot or not currentGroup then return end

    local settings = Settings()
    if not settings then return end

    settings.appearance = ns.DeepCopy(snapshot.appearance)
    settings.position = ns.DeepCopy(snapshot.position)

    ns.Core:RefreshGroup(currentGroup)
    local group = ns.groups[currentGroup]
    if group then group:ApplyPosition() end

    self:Refresh()
end

function Panel:ResetPosition()
    local settings = Settings()
    if not settings then return end

    local defaults = ns.DB.DefaultProfile().groups[currentGroup]
    if defaults then
        settings.position = ns.DeepCopy(defaults.position)
    end

    local group = ns.groups[currentGroup]
    if group then group:ApplyPosition() end
end

function Panel:Refresh()
    if not panel or not panel:IsShown() then return end

    local label = Const.GROUP_LABELS[currentGroup] or currentGroup
    if panel.SetTitle then
        pcall(panel.SetTitle, panel, label)
    end
    local titleText = (panel.TitleContainer and panel.TitleContainer.TitleText) or panel.TitleText
    if titleText then titleText:SetText(label) end

    -- Three different predicates, not one: bar sizing applies to any bar-capable
    -- group, the Icons/Bars toggle only to the group that has both, and the
    -- Effect/Cooldown mode only to a duration-bar group.
    local isBarGroup = Const.BAR_CAPABLE_GROUPS[currentGroup] and true or false
    local hasDisplayToggle = Const.DISPLAY_TOGGLE_GROUPS[currentGroup] and true or false
    local hasBarMode = Const.DURATION_BAR_GROUPS[currentGroup] and true or false

    local sliders = { panel.rows, panel.iconSize, panel.spacing, panel.opacity }
    local dropdowns = { panel.orientation, panel.iconDirection, panel.visibility, panel.fontFace }
    if isBarGroup then
        sliders[#sliders + 1] = panel.barWidth
        sliders[#sliders + 1] = panel.barHeight
        dropdowns[#dropdowns + 1] = panel.barContent
        dropdowns[#dropdowns + 1] = panel.barTexture
    end
    if hasDisplayToggle then
        dropdowns[#dropdowns + 1] = panel.display
    end
    if hasBarMode then
        dropdowns[#dropdowns + 1] = panel.barMode
    end

    -- Only the rows this group has, top-down, so a hidden row leaves no gap.
    local BAR_ROW = 46
    local rowY = panel.buffTop

    panel.display:SetShown(hasDisplayToggle)
    if hasDisplayToggle then
        panel.display:ClearAllPoints()
        panel.display:SetPoint("TOPLEFT", 16, rowY)
        rowY = rowY - BAR_ROW
    end

    for _, slider in ipairs({ panel.barWidth, panel.barHeight }) do
        slider:SetShown(isBarGroup)
        if isBarGroup then
            slider:ClearAllPoints()
            slider:SetPoint("TOPLEFT", 24, rowY)
            rowY = rowY - BAR_ROW
        end
    end

    panel.barContent:SetShown(isBarGroup)
    if isBarGroup then
        panel.barContent:ClearAllPoints()
        panel.barContent:SetPoint("TOPLEFT", 16, rowY)
        rowY = rowY - BAR_ROW
    end

    panel.barMode:SetShown(hasBarMode)
    if hasBarMode then
        panel.barMode:ClearAllPoints()
        panel.barMode:SetPoint("TOPLEFT", 16, rowY)
        rowY = rowY - BAR_ROW
    end

    panel.barTexture:SetShown(isBarGroup)
    if isBarGroup then
        panel.barTexture:ClearAllPoints()
        panel.barTexture:SetPoint("TOPLEFT", 16, rowY)
        rowY = rowY - BAR_ROW
    end

    local buttonY = rowY
    for _, button in ipairs(panel.buttons) do
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", 20, buttonY)
        buttonY = buttonY - 26
    end
    panel:SetHeight(math.abs(buttonY) + 24)

    for _, slider in ipairs(sliders) do
        local value = tonumber(GetOption(slider.option)) or 0
        slider.settingValue = true
        slider:SetValue(value)
        slider.settingValue = false
        if slider.labelText then
            slider.labelText:SetText(("%s: %d"):format(slider.labelPrefix, value))
        end
    end

    for _, container in ipairs(dropdowns) do
        local current = GetOption(container.option)
        local text = tostring(current)
        for _, choice in ipairs(container.getChoices()) do
            if choice.value == current then text = choice.label end
        end
        UIDropDownMenu_SetText(container.dropdown, text)
    end

    panel.showTimer:SetChecked(GetOption("showCountdownText") and true or false)
    panel.showTooltips:SetChecked(GetOption("showTooltips") and true or false)
    panel.showKeybind:SetChecked(GetOption("showKeybind") and true or false)
    panel.showHighlights:SetChecked(GetOption("highlightsEnabled") and true or false)
end

function Panel:Show(groupKey)
    BuildPanel()

    currentGroup = groupKey or Const.GROUP_ORDER[1]

    local settings = Settings()
    if settings then
        -- Captured so Revert Changes can put everything back.
        snapshot = {
            appearance = ns.DeepCopy(settings.appearance),
            position = ns.DeepCopy(settings.position),
        }
    end

    panel:Show()
    self:Refresh()
end

function Panel:Hide()
    if panel then panel:Hide() end
end

function Panel:IsShown()
    return panel ~= nil and panel:IsShown()
end
