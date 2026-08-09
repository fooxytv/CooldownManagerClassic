local addonName, ns = ...

local Const = ns.Constants

-- Settings panel for a resource bar, opened by clicking a bar in Edit Mode --
-- the counterpart to EditModePanel for the icon groups. Kept separate rather
-- than folded into that panel: a bar's options (enable, size, texture,
-- visibility) barely overlap a group's, and the group panel's mixed layout is
-- fiddly enough already.

local Panel = {}
ns.BarPanel = Panel

local panel
local currentBar
local snapshot

local function Settings()
    return currentBar and ns.DB:GetBar(currentBar) or nil
end

local function Appearance()
    local settings = Settings()
    return settings and settings.appearance or nil
end

local function Get(option)
    local appearance = Appearance()
    local value = appearance and appearance[option]
    if value == nil then value = Const.DEFAULT_BAR_APPEARANCE[option] end
    return value
end

-- Layout re-applies size, texture, position, visibility and redraws, so a single
-- call refreshes the bar for any option.
local function Apply()
    local bar = currentBar and ns.bars[currentBar]
    if bar then bar:Layout() end
end

local function Set(option, value)
    local appearance = Appearance()
    if not appearance then return end
    appearance[option] = value
    Apply()
    Panel:Refresh()
end

local widgetIndex = 0

local function CreateSlider(parent, label, option, minValue, maxValue, step)
    widgetIndex = widgetIndex + 1
    local name = "CDMCBarPanelSlider" .. widgetIndex

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
        if not self.settingValue then
            Set(self.option, value)
        end
    end)

    return slider
end

local function CreateDropdown(parent, label, option, getChoices)
    widgetIndex = widgetIndex + 1
    local name = "CDMCBarPanelDropdown" .. widgetIndex

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
            info.checked = (Get(option) == choice.value)
            info.func = function()
                Set(option, choice.value)
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

-- `handlers` (get/set) drives a checkbox that is not an appearance option -- the
-- bar's top-level `enabled` flag.
local function CreateCheckbox(parent, label, option, handlers)
    widgetIndex = widgetIndex + 1
    local name = "CDMCBarPanelCheck" .. widgetIndex

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
            Set(self.option, checked)
        end
    end)

    return check
end

local function MediaChoices(mediatype)
    return function()
        local choices = { { value = "", label = "Default" } }
        for _, name in ipairs(ns.Media.List(mediatype)) do
            choices[#choices + 1] = { value = name, label = name }
        end
        return choices
    end
end

-- Vertical order of the panel's widgets: each one's field on `panel`, its left
-- inset, and the gap to the next. A `barKey` restricts a row to a single bar --
-- the Resource Source dropdown only makes sense for the adaptive class-resource
-- ("combo") bar. LayoutWidgets re-runs on every Show so a skipped row leaves no
-- gap and the panel height tracks what is actually visible.
local WIDGET_LAYOUT = {
    { field = "enabled",        x = 20, gap = 34 },
    { field = "width",          x = 24, gap = 46 },
    { field = "height",         x = 24, gap = 46 },
    { field = "opacity",        x = 24, gap = 40 },
    { field = "border",         x = 24, gap = 46 },
    { field = "showText",       x = 20, gap = 34 },
    { field = "showPercent",    x = 20, gap = 34 },
    { field = "textAlign",      x = 16, gap = 46 },
    { field = "barTexture",     x = 16, gap = 46 },
    { field = "visibility",     x = 16, gap = 50 },
    { field = "segmentStyle",   x = 16, gap = 46, barKey = "combo" },
    { field = "resourceSource", x = 16, gap = 46, barKey = "combo" },
    { field = "animate",        x = 20, gap = 34 },
    { field = "spark",          x = 20, gap = 34 },
    { field = "revert",         x = 20, gap = 26 },
    { field = "reset",          x = 20, gap = 26 },
}

local function LayoutWidgets()
    if not panel then return end

    local y = -32
    for _, item in ipairs(WIDGET_LAYOUT) do
        local widget = panel[item.field]
        if widget then
            if item.barKey and item.barKey ~= currentBar then
                widget:Hide()
            else
                widget:ClearAllPoints()
                widget:SetPoint("TOPLEFT", item.x, y)
                widget:Show()
                y = y - item.gap
            end
        end
    end

    panel:SetHeight(math.abs(y) + 20)
end

local function BuildPanel()
    if panel then return panel end

    panel = CreateFrame("Frame", "CDMCBarPanel", UIParent, "ButtonFrameTemplate")
    panel:SetSize(250, 380)
    panel:SetPoint("CENTER", UIParent, "CENTER", 320, 0)
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()

    if panel.Inset then panel.Inset:Hide() end

    panel.enabled = CreateCheckbox(panel, "Enabled", nil, {
        get = function() local s = Settings() return s and s.enabled ~= false end,
        set = function(value)
            local s = Settings()
            if s then s.enabled = value and true or false end
            Apply()
            Panel:Refresh()
        end,
    })

    panel.width = CreateSlider(panel, "Width", "width", 60, 400, 5)
    panel.height = CreateSlider(panel, "Height", "height", 6, 48, 1)
    panel.opacity = CreateSlider(panel, "Opacity", "opacity", 10, 100, 5)
    panel.border = CreateSlider(panel, "Border", "borderSize", 0, 5, 1)
    panel.showText = CreateCheckbox(panel, "Show Text", "showText")
    panel.showPercent = CreateCheckbox(panel, "Show Percentage", "showPercent")

    panel.textAlign = CreateDropdown(panel, "Text Align", "textAlign", function()
        return Const.TEXT_ALIGN_OPTIONS
    end)

    panel.barTexture = CreateDropdown(panel, "Bar Texture", "barTexture", MediaChoices("statusbar"))

    panel.visibility = CreateDropdown(panel, "Visibility", "visibility", function()
        return Const.BAR_VISIBILITY_OPTIONS
    end)

    -- Combo bar only (see WIDGET_LAYOUT): draw the segmented resource as discrete
    -- pips or as a continuous fill with tick-mark dividers.
    panel.segmentStyle = CreateDropdown(panel, "Segments", "segmentStyle", function()
        return Const.BAR_SEGMENT_OPTIONS
    end)

    -- Shown only for the adaptive class-resource bar (see WIDGET_LAYOUT): it
    -- pins which resource that bar shows, overriding the by-class auto-detection.
    panel.resourceSource = CreateDropdown(panel, "Resource Source", "resourceSource", function()
        return Const.RESOURCE_SOURCE_OPTIONS
    end)

    panel.animate = CreateCheckbox(panel, "Smooth Fill", "animate")
    panel.spark = CreateCheckbox(panel, "Edge Spark", "spark")

    panel.revert = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.revert:SetSize(210, 22)
    panel.revert:SetText("Revert Changes")
    panel.revert:SetScript("OnClick", function() Panel:Revert() end)

    panel.reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.reset:SetSize(210, 22)
    panel.reset:SetText("Reset to Default Position")
    panel.reset:SetScript("OnClick", function() Panel:ResetPosition() end)

    LayoutWidgets()

    return panel
end

function Panel:Refresh()
    if not panel or not panel:IsShown() then return end

    local label = Const.BAR_LABELS[currentBar] or currentBar
    if panel.SetTitle then pcall(panel.SetTitle, panel, label) end
    local titleText = (panel.TitleContainer and panel.TitleContainer.TitleText) or panel.TitleText
    if titleText then titleText:SetText(label) end

    for _, slider in ipairs({ panel.width, panel.height, panel.opacity, panel.border }) do
        local value = tonumber(Get(slider.option)) or 0
        slider.settingValue = true
        slider:SetValue(value)
        slider.settingValue = false
        if slider.labelText then
            slider.labelText:SetText(("%s: %d"):format(slider.labelPrefix, value))
        end
    end

    for _, container in ipairs({
        panel.barTexture, panel.visibility, panel.textAlign,
        panel.segmentStyle, panel.resourceSource,
    }) do
        local current = Get(container.option)
        local text = tostring(current)
        for _, choice in ipairs(container.getChoices()) do
            if choice.value == current then text = choice.label end
        end
        UIDropDownMenu_SetText(container.dropdown, text)
    end

    if panel.enabled.getState then
        panel.enabled:SetChecked(panel.enabled.getState() and true or false)
    end
    panel.showText:SetChecked(Get("showText") ~= false)
    for _, cb in ipairs({ panel.showPercent, panel.animate, panel.spark }) do
        cb:SetChecked(Get(cb.option) == true)
    end
end

function Panel:Revert()
    if not snapshot or not currentBar then return end

    local settings = Settings()
    if not settings then return end

    settings.enabled = snapshot.enabled
    settings.appearance = ns.DeepCopy(snapshot.appearance)
    settings.position = ns.DeepCopy(snapshot.position)

    Apply()
    self:Refresh()
end

function Panel:ResetPosition()
    local settings = Settings()
    if not settings then return end

    local defaults = ns.DB.DefaultProfile().bars[currentBar]
    if defaults then
        settings.position = ns.DeepCopy(defaults.position)
    end
    Apply()
end

function Panel:Show(barKey)
    BuildPanel()

    -- One settings panel at a time.
    if ns.EditModePanel then ns.EditModePanel:Hide() end

    currentBar = barKey or Const.BAR_ORDER[1]

    local settings = Settings()
    if settings then
        snapshot = {
            enabled = settings.enabled,
            appearance = ns.DeepCopy(settings.appearance),
            position = ns.DeepCopy(settings.position),
        }
    end

    -- The Resource Source row is bar-specific, so re-lay-out for this bar before
    -- showing: it appears for the class-resource bar and is skipped otherwise.
    LayoutWidgets()

    panel:Show()
    self:Refresh()
end

function Panel:Hide()
    if panel then panel:Hide() end
end

function Panel:IsShown()
    return panel ~= nil and panel:IsShown()
end
