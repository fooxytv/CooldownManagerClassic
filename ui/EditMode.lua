local addonName, ns = ...

local Const = ns.Constants
local EditMode = {}
ns.EditMode = EditMode

EditMode.active = false

local lem = _G.LibStub and LibStub("LibEQOLEditMode-1.0", true)
EditMode.usingLibEQOL = lem ~= nil

local positionSnapshot = nil

function EditMode:IsAvailable()
    return _G.EditModeManagerFrame ~= nil
end

function EditMode:IsBlizzardEditModeActive()
    local manager = _G.EditModeManagerFrame
    return manager ~= nil and manager.editModeActive == true
end

local function ForEachWidget(callback)
    for _, group in pairs(ns.groups) do callback(group) end
    for _, bar in pairs(ns.bars) do callback(bar) end
end

local function TakeSnapshot()
    local snapshot = { groups = {}, bars = {} }

    for _, key in ipairs(Const.GROUP_ORDER) do
        local settings = ns.DB:GetGroup(key)
        if settings then
            snapshot.groups[key] = ns.DeepCopy(settings.position)
        end
    end

    for _, key in ipairs(Const.BAR_ORDER) do
        local settings = ns.DB:GetBar(key)
        if settings then
            snapshot.bars[key] = ns.DeepCopy(settings.position)
        end
    end

    return snapshot
end

local function RestoreSnapshot(snapshot)
    if not snapshot then return end

    for key, position in pairs(snapshot.groups or {}) do
        local settings = ns.DB:GetGroup(key)
        if settings then
            settings.position = ns.DeepCopy(position)
            local group = ns.groups[key]
            if group then group:ApplyPosition() end
        end
    end

    for key, position in pairs(snapshot.bars or {}) do
        local settings = ns.DB:GetBar(key)
        if settings then
            settings.position = ns.DeepCopy(position)
            local bar = ns.bars[key]
            if bar then bar:ApplyPosition() end
        end
    end
end

function EditMode:Enter()
    if self.active then return end
    self.active = true

    positionSnapshot = TakeSnapshot()

    ForEachWidget(function(widget)
        if lem then
            widget.unlocked = true
            widget:UpdateVisibility()
        else
            widget:SetUnlocked(true)
        end
    end)

    -- A disabled bar renders nothing, so under LibEQOL it would be an empty box
    -- in Edit Mode; render its contents so it can be seen and positioned. The
    -- non-LibEQOL SetUnlocked path already does this for itself.
    if lem then
        for _, bar in pairs(ns.bars) do bar:Update() end
    end
end

function EditMode:Exit()
    if not self.active then return end
    self.active = false

    ForEachWidget(function(widget)
        if lem then
            widget.unlocked = false
            widget:UpdateVisibility()
        else
            widget:SetUnlocked(false)
        end
    end)

    positionSnapshot = nil
end

function EditMode:SaveLayouts()
    ForEachWidget(function(widget) widget:SavePosition() end)
    positionSnapshot = TakeSnapshot()
end

function EditMode:RevertChanges()
    RestoreSnapshot(positionSnapshot)
end

local function Appearance(groupKey)
    local settings = ns.DB:GetGroup(groupKey)
    return settings and settings.appearance or nil
end

local function GetOption(groupKey, option, fallback)
    local appearance = Appearance(groupKey)
    local value = appearance and appearance[option]
    if value == nil then value = Const.DEFAULT_APPEARANCE[option] end
    if value == nil then value = fallback end
    return value
end

local function SetOption(groupKey, option, value)
    local appearance = Appearance(groupKey)
    if not appearance then return end

    appearance[option] = value
    ns.Core:RefreshGroup(groupKey)
end

local function DropdownValues(labels)
    local values = {}
    for _, label in ipairs(labels) do
        values[#values + 1] = { text = label }
    end
    return values
end

local MEDIA_DEFAULT = "Default"

local function FillMediaValues(values, mediatype)
    wipe(values)
    values[1] = { text = MEDIA_DEFAULT }
    for _, name in ipairs(ns.Media.List(mediatype)) do
        values[#values + 1] = { text = name }
    end
    return values
end

local function FillDirectionValues(groupKey, values)
    local orientation = GetOption(groupKey, "orientation", "Horizontal")
    local allowed = Const.ICON_DIRECTIONS[orientation] or Const.ICON_DIRECTIONS.Horizontal

    wipe(values)
    for _, direction in ipairs(allowed) do
        values[#values + 1] = { text = direction }
    end

    return values
end

local function BuildSettings(groupKey)
    local directionValues = FillDirectionValues(groupKey, {})
    local fontValues = FillMediaValues({}, "font")

    local settings = {
        {
            order = 1,
            name = "Orientation",
            kind = lem.SettingType.Dropdown,
            default = "Horizontal",
            values = DropdownValues(Const.ORIENTATIONS),
            get = function() return GetOption(groupKey, "orientation", "Horizontal") end,
            set = function(_, value)
                SetOption(groupKey, "orientation", value)
                local allowed = Const.ICON_DIRECTIONS[value] or Const.ICON_DIRECTIONS.Horizontal
                local current = GetOption(groupKey, "iconDirection")
                local stillValid = false
                for _, direction in ipairs(allowed) do
                    if direction == current then stillValid = true end
                end
                if not stillValid then
                    SetOption(groupKey, "iconDirection", allowed[1])
                end
                FillDirectionValues(groupKey, directionValues)
            end,
        },
        {
            order = 2,
            name = "# Rows",
            kind = lem.SettingType.Slider,
            default = 1,
            minValue = 1,
            maxValue = 8,
            valueStep = 1,
            get = function() return GetOption(groupKey, "rows", 1) end,
            set = function(_, value) SetOption(groupKey, "rows", math.floor(value + 0.5)) end,
        },
        {
            order = 3,
            name = "Icon Direction",
            kind = lem.SettingType.Dropdown,
            default = "Down",
            values = directionValues,
            optionfunc = function()
                return FillDirectionValues(groupKey, directionValues)
            end,
            get = function() return GetOption(groupKey, "iconDirection", "Down") end,
            set = function(_, value) SetOption(groupKey, "iconDirection", value) end,
        },
        {
            order = 4,
            name = "Icon Size",
            kind = lem.SettingType.Slider,
            default = Const.DEFAULT_APPEARANCE.iconSize,
            minValue = 16,
            maxValue = 72,
            valueStep = 1,
            get = function() return GetOption(groupKey, "iconSize") end,
            set = function(_, value) SetOption(groupKey, "iconSize", math.floor(value + 0.5)) end,
        },
        {
            order = 5,
            name = "Icon Padding",
            kind = lem.SettingType.Slider,
            default = Const.DEFAULT_APPEARANCE.spacing,
            minValue = -12,
            maxValue = 24,
            valueStep = 1,
            get = function() return GetOption(groupKey, "spacing") end,
            set = function(_, value) SetOption(groupKey, "spacing", math.floor(value + 0.5)) end,
        },
        {
            order = 6,
            name = "Opacity",
            kind = lem.SettingType.Slider,
            default = 100,
            minValue = 10,
            maxValue = 100,
            valueStep = 5,
            get = function() return GetOption(groupKey, "opacity", 100) end,
            set = function(_, value) SetOption(groupKey, "opacity", math.floor(value + 0.5)) end,
        },
        {
            order = 7,
            name = "Visibility",
            kind = lem.SettingType.Dropdown,
            default = "Always Visible",
            values = (function()
                local values = {}
                for _, option in ipairs(Const.VISIBILITY_OPTIONS) do
                    values[#values + 1] = { text = option.label }
                end
                return values
            end)(),
            get = function()
                local current = GetOption(groupKey, "visibility", "Always")
                for _, option in ipairs(Const.VISIBILITY_OPTIONS) do
                    if option.value == current then return option.label end
                end
                return "Always Visible"
            end,
            set = function(_, value)
                for _, option in ipairs(Const.VISIBILITY_OPTIONS) do
                    if option.label == value then
                        SetOption(groupKey, "visibility", option.value)
                        return
                    end
                end
            end,
        },
        {
            order = 7.5,
            name = "Swipe Opacity",
            kind = lem.SettingType.Slider,
            default = 100,
            minValue = 0,
            maxValue = 100,
            valueStep = 5,
            get = function() return GetOption(groupKey, "swipeOpacity", 100) end,
            set = function(_, value) SetOption(groupKey, "swipeOpacity", math.floor(value + 0.5)) end,
        },
        {
            order = 8,
            name = "Show Timer",
            kind = lem.SettingType.Checkbox,
            default = true,
            get = function() return GetOption(groupKey, "showCountdownText", true) and true or false end,
            set = function(_, value) SetOption(groupKey, "showCountdownText", value and true or false) end,
        },
        {
            order = 8.5,
            name = "Right-click Menu",
            kind = lem.SettingType.Checkbox,
            default = false,
            get = function() return GetOption(groupKey, "rightClickMenu", false) and true or false end,
            set = function(_, value) SetOption(groupKey, "rightClickMenu", value and true or false) end,
        },
        {
            order = 9.1,
            name = "Tooltip Anchor",
            kind = lem.SettingType.Dropdown,
            default = "Default Position",
            values = DropdownValues(Const.TOOLTIP_ANCHORS),
            get = function() return GetOption(groupKey, "tooltipAnchor", "Default Position") end,
            set = function(_, value) SetOption(groupKey, "tooltipAnchor", value) end,
        },
        {
            order = 9,
            name = "Show Tooltips",
            kind = lem.SettingType.Checkbox,
            default = true,
            get = function() return GetOption(groupKey, "showTooltips", true) and true or false end,
            set = function(_, value) SetOption(groupKey, "showTooltips", value and true or false) end,
        },
        {
            order = 10,
            name = "Show Global Cooldown",
            kind = lem.SettingType.Checkbox,
            default = false,
            get = function() return GetOption(groupKey, "showGCD", false) and true or false end,
            set = function(_, value) SetOption(groupKey, "showGCD", value and true or false) end,
        },
        {
            order = 10.1,
            name = "Show Keybind",
            kind = lem.SettingType.Checkbox,
            default = false,
            get = function() return GetOption(groupKey, "showKeybind", false) and true or false end,
            set = function(_, value) SetOption(groupKey, "showKeybind", value and true or false) end,
        },
        {
            order = 10.2,
            name = "Reactive Highlights",
            kind = lem.SettingType.Checkbox,
            default = false,
            get = function() return GetOption(groupKey, "highlightsEnabled", false) and true or false end,
            set = function(_, value) SetOption(groupKey, "highlightsEnabled", value and true or false) end,
        },
        {
            order = 10.3,
            name = "Font",
            kind = lem.SettingType.Dropdown,
            default = MEDIA_DEFAULT,
            values = fontValues,
            get = function()
                FillMediaValues(fontValues, "font")
                local current = GetOption(groupKey, "fontFace", "")
                return (current ~= "" and current) or MEDIA_DEFAULT
            end,
            set = function(_, value)
                SetOption(groupKey, "fontFace", value ~= MEDIA_DEFAULT and value or "")
            end,
        },
    }

    if Const.AURA_GROUPS[groupKey] then
        settings[#settings + 1] = {
            order = 11,
            name = "Only Show While Active",
            kind = lem.SettingType.Checkbox,
            default = true,
            get = function() return GetOption(groupKey, "hideWhenInactive", true) and true or false end,
            set = function(_, value) SetOption(groupKey, "hideWhenInactive", value and true or false) end,
        }
    end

    if Const.DISPLAY_TOGGLE_GROUPS[groupKey] then
        settings[#settings + 1] = {
            order = 12,
            name = "Display",
            kind = lem.SettingType.Dropdown,
            default = "Icons",
            values = DropdownValues(Const.BUFF_DISPLAYS),
            get = function() return GetOption(groupKey, "display", "Icons") end,
            set = function(_, value)
                SetOption(groupKey, "display", value)
                if value == "Bars" then
                    SetOption(groupKey, "orientation", "Vertical")
                    SetOption(groupKey, "iconDirection", "Right")
                else
                    SetOption(groupKey, "orientation", "Horizontal")
                    SetOption(groupKey, "iconDirection", "Down")
                end
            end,
        }
    end

    if Const.BAR_CAPABLE_GROUPS[groupKey] then
        settings[#settings + 1] = {
            order = 13,
            name = "Bar Width",
            kind = lem.SettingType.Slider,
            default = 220,
            minValue = 120,
            maxValue = 400,
            valueStep = 5,
            get = function() return GetOption(groupKey, "barWidth", 220) end,
            set = function(_, value) SetOption(groupKey, "barWidth", math.floor(value + 0.5)) end,
        }

        settings[#settings + 1] = {
            order = 14,
            name = "Bar Height",
            kind = lem.SettingType.Slider,
            default = Const.BAR_TEMPLATE.itemHeight,
            minValue = 16,
            maxValue = 60,
            valueStep = 1,
            get = function() return GetOption(groupKey, "barHeight", Const.BAR_TEMPLATE.itemHeight) end,
            set = function(_, value) SetOption(groupKey, "barHeight", math.floor(value + 0.5)) end,
        }

        settings[#settings + 1] = {
            order = 15,
            name = "Bar Content",
            kind = lem.SettingType.Dropdown,
            default = "Icon and Name",
            values = DropdownValues(Const.BAR_CONTENTS),
            get = function() return GetOption(groupKey, "barContent", "Icon and Name") end,
            set = function(_, value) SetOption(groupKey, "barContent", value) end,
        }
    end

    if Const.DURATION_BAR_GROUPS[groupKey] then
        settings[#settings + 1] = {
            order = 16,
            name = "Bar Shows",
            kind = lem.SettingType.Dropdown,
            default = "Effect + Cooldown",
            values = DropdownValues(Const.BAR_MODES),
            get = function() return GetOption(groupKey, "barMode", "Effect + Cooldown") end,
            set = function(_, value) SetOption(groupKey, "barMode", value) end,
        }

        -- Off by default, so a filled bar means something is running and never
        -- reads as a buff at full duration. On is for anyone who would rather
        -- the row looked charged than empty while idle -- a real preference,
        -- unlike most toggles, because both readings are defensible.
        settings[#settings + 1] = {
            order = 16.1,
            name = "Fill When Ready",
            kind = lem.SettingType.Checkbox,
            default = false,
            get = function() return GetOption(groupKey, "fillBarWhenReady", false) and true or false end,
            set = function(_, value) SetOption(groupKey, "fillBarWhenReady", value and true or false) end,
        }
    end

    return settings
end

local function BarAppearance(key)
    local settings = ns.DB:GetBar(key)
    return settings and settings.appearance or nil
end

local function GetBarOption(key, option, fallback)
    local appearance = BarAppearance(key)
    local value = appearance and appearance[option]
    if value == nil then value = Const.DEFAULT_BAR_APPEARANCE[option] end
    if value == nil then value = fallback end
    return value
end

local function SetBarOption(key, option, value)
    local appearance = BarAppearance(key)
    if not appearance then return end

    appearance[option] = value
    local bar = ns.bars[key]
    if bar then bar:Layout() end
end

local function MediaSetting(order, name, key, option, mediatype)
    local values = FillMediaValues({}, mediatype)

    return {
        order = order,
        name = name,
        kind = lem.SettingType.Dropdown,
        default = MEDIA_DEFAULT,
        values = values,
        get = function()
            FillMediaValues(values, mediatype)
            local current = GetBarOption(key, option, "")
            return (current ~= "" and current) or MEDIA_DEFAULT
        end,
        set = function(_, value)
            SetBarOption(key, option, value ~= MEDIA_DEFAULT and value or "")
        end,
    }
end

local function ChoiceSetting(order, name, key, option, choices)
    local values = {}
    for _, choice in ipairs(choices) do
        values[#values + 1] = { text = choice.label }
    end

    return {
        order = order,
        name = name,
        kind = lem.SettingType.Dropdown,
        default = choices[1].label,
        values = values,
        get = function()
            local current = GetBarOption(key, option)
            for _, choice in ipairs(choices) do
                if choice.value == current then return choice.label end
            end
            return choices[1].label
        end,
        set = function(_, value)
            for _, choice in ipairs(choices) do
                if choice.label == value then
                    SetBarOption(key, option, choice.value)
                    return
                end
            end
        end,
    }
end

local function PackedColor(value)
    if type(value) ~= "table" then return nil end
    return Const.PackColor(value.r or value[1], value.g or value[2],
                           value.b or value[3], value.a or value[4] or 1)
end

local function ColorSetting(order, name, key, option, fallback)
    local function Current()
        local r, g, b, a = Const.UnpackColor(GetBarOption(key, option),
            Const.UnpackColor(fallback, 1, 1, 1, 1))
        return { r = r, g = g, b = b, a = a }
    end

    return {
        order = order,
        name = name,
        kind = lem.SettingType.Color,
        hasOpacity = true,
        default = Current(),
        get = Current,
        set = function(_, value)
            local packed = PackedColor(value)
            if packed then SetBarOption(key, option, packed) end
        end,
    }
end

local function BuildBarSettings(key)
    local settings = {
        {
            order = 1,
            name = "Enabled",
            kind = lem.SettingType.Checkbox,
            default = false,
            get = function()
                local bar = ns.DB:GetBar(key)
                return bar and bar.enabled and true or false
            end,
            set = function(_, value)
                local bar = ns.DB:GetBar(key)
                if bar then bar.enabled = value and true or false end
                if ns.bars[key] then ns.bars[key]:Layout() end
            end,
        },
        {
            order = 2,
            name = "Width",
            kind = lem.SettingType.Slider,
            default = Const.DEFAULT_BAR_APPEARANCE.width,
            minValue = 60,
            maxValue = 500,
            valueStep = 5,
            get = function() return GetBarOption(key, "width") end,
            set = function(_, value) SetBarOption(key, "width", math.floor(value + 0.5)) end,
        },
        {
            order = 3,
            name = "Height",
            kind = lem.SettingType.Slider,
            default = Const.DEFAULT_BAR_APPEARANCE.height,
            minValue = 4,
            maxValue = 60,
            valueStep = 1,
            get = function() return GetBarOption(key, "height") end,
            set = function(_, value) SetBarOption(key, "height", math.floor(value + 0.5)) end,
        },
        {
            order = 4,
            name = "Opacity",
            kind = lem.SettingType.Slider,
            default = 100,
            minValue = 10,
            maxValue = 100,
            valueStep = 5,
            get = function() return GetBarOption(key, "opacity", 100) end,
            set = function(_, value) SetBarOption(key, "opacity", math.floor(value + 0.5)) end,
        },
        {
            order = 5,
            name = "Visibility",
            kind = lem.SettingType.Dropdown,
            default = "Always Visible",
            values = (function()
                local values = {}
                for _, option in ipairs(Const.VISIBILITY_OPTIONS) do
                    values[#values + 1] = { text = option.label }
                end
                return values
            end)(),
            get = function()
                local current = GetBarOption(key, "visibility", "Always")
                for _, option in ipairs(Const.VISIBILITY_OPTIONS) do
                    if option.value == current then return option.label end
                end
                return "Always Visible"
            end,
            set = function(_, value)
                for _, option in ipairs(Const.VISIBILITY_OPTIONS) do
                    if option.label == value then
                        SetBarOption(key, "visibility", option.value)
                        return
                    end
                end
            end,
        },
    }

    if key == "combo" then
        settings[#settings + 1] = {
            order = 6,
            name = "Pip Spacing",
            kind = lem.SettingType.Slider,
            default = Const.DEFAULT_BAR_APPEARANCE.pipSpacing,
            minValue = 0,
            maxValue = 12,
            valueStep = 1,
            get = function() return GetBarOption(key, "pipSpacing") end,
            set = function(_, value) SetBarOption(key, "pipSpacing", math.floor(value + 0.5)) end,
        }
    else
        settings[#settings + 1] = {
            order = 6,
            name = "Show Text",
            kind = lem.SettingType.Checkbox,
            default = true,
            get = function() return GetBarOption(key, "showText", true) and true or false end,
            set = function(_, value) SetBarOption(key, "showText", value and true or false) end,
        }
    end

    local STYLE_SECTION = "cdmcBarStyle"
    local style = {}

    settings[#settings + 1] = {
        order = 20,
        name = "Style",
        kind = lem.SettingType.Collapsible,
        id = STYLE_SECTION,
        defaultCollapsed = false,
    }

    style[#style + 1] = MediaSetting(21, "Bar Texture", key, "barTexture", "statusbar")

    style[#style + 1] = {
        order = 22,
        name = "Border Size",
        kind = lem.SettingType.Slider,
        default = Const.DEFAULT_BAR_APPEARANCE.borderSize,
        minValue = 0,
        maxValue = 12,
        valueStep = 1,
        get = function() return GetBarOption(key, "borderSize") end,
        set = function(_, value) SetBarOption(key, "borderSize", math.floor(value + 0.5)) end,
    }

    style[#style + 1] = MediaSetting(23, "Border Texture", key, "borderTexture", "border")
    style[#style + 1] = ColorSetting(24, "Border Colour", key, "borderColor",
        Const.DEFAULT_BAR_APPEARANCE.borderColor)
    style[#style + 1] = ColorSetting(25, "Background Colour", key, "bgColor",
        Const.DEFAULT_BAR_APPEARANCE.bgColor)

    style[#style + 1] = {
        order = 26,
        name = "Custom Fill Colour",
        kind = lem.SettingType.CheckboxColor,
        hasOpacity = false,
        default = false,
        get = function()
            local current = GetBarOption(key, "fillColor", "")
            return current ~= "" and current ~= nil
        end,
        set = function(_, value)
            if not value then
                SetBarOption(key, "fillColor", "")
                return
            end
            local bar = ns.bars[key]
            local statusBar = bar and bar.statusBar
            local r, g, b = 1, 1, 1
            if statusBar and statusBar.GetStatusBarColor then
                local sr, sg, sb = statusBar:GetStatusBarColor()
                if sr then r, g, b = sr, sg, sb end
            end
            SetBarOption(key, "fillColor", Const.PackColor(r, g, b, 1))
        end,
        colorGet = function()
            local r, g, b, a = Const.UnpackColor(GetBarOption(key, "fillColor", ""), 1, 1, 1, 1)
            return { r = r, g = g, b = b, a = a }
        end,
        colorSet = function(_, value)
            local packed = PackedColor(value)
            if packed then SetBarOption(key, "fillColor", packed) end
        end,
    }

    style[#style + 1] = MediaSetting(27, "Font", key, "fontFace", "font")
    style[#style + 1] = ChoiceSetting(28, "Font Outline", key, "fontOutline",
        Const.FONT_OUTLINE_OPTIONS)
    style[#style + 1] = ChoiceSetting(29, "Text Align", key, "textAlign",
        Const.TEXT_ALIGN_OPTIONS)

    style[#style + 1] = {
        order = 30,
        name = "Show Percentage",
        kind = lem.SettingType.Checkbox,
        default = false,
        get = function() return GetBarOption(key, "showPercent") and true or false end,
        set = function(_, value) SetBarOption(key, "showPercent", value and true or false) end,
    }

    style[#style + 1] = {
        order = 31,
        name = "Smooth Fill",
        kind = lem.SettingType.Checkbox,
        default = false,
        get = function() return GetBarOption(key, "animate") and true or false end,
        set = function(_, value) SetBarOption(key, "animate", value and true or false) end,
    }

    style[#style + 1] = {
        order = 32,
        name = "Edge Spark",
        kind = lem.SettingType.Checkbox,
        default = false,
        get = function() return GetBarOption(key, "spark") and true or false end,
        set = function(_, value) SetBarOption(key, "spark", value and true or false) end,
    }

    if key == "combo" then
        style[#style + 1] = ChoiceSetting(33, "Segments", key, "segmentStyle",
            Const.BAR_SEGMENT_OPTIONS)
        style[#style + 1] = ChoiceSetting(34, "Resource Source", key, "resourceSource",
            Const.RESOURCE_SOURCE_OPTIONS)
    end

    for _, setting in ipairs(style) do
        setting.parentId = STYLE_SECTION
        settings[#settings + 1] = setting
    end

    return settings
end

local function ParsePositionArgs(...)
    local anchors = {
        CENTER = true, TOP = true, BOTTOM = true, LEFT = true, RIGHT = true,
        TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true,
    }

    local point, relativePoint, x, y
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) == "string" and anchors[value] then
            if not point then point = value
            elseif not relativePoint then relativePoint = value end
        elseif type(value) == "number" then
            if not x then x = value
            elseif not y then y = value end
        end
    end

    return point, relativePoint or point, x or 0, y or 0
end

function EditMode:RegisterWithLibEQOL()
    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = ns.groups[key]
        local settings = ns.DB:GetGroup(key)

        if group and settings then
            local defaults = {
                point = settings.position.point or "CENTER",
                relativePoint = settings.position.relativePoint or "CENTER",
                x = settings.position.x or 0,
                y = settings.position.y or 0,
            }

            lem:AddFrame(group.frame, function(...)
                local point, relativePoint, x, y = ParsePositionArgs(...)
                if not point then return end
                ns.DB:SetGroupPosition(key, point, relativePoint, x, y)
            end, defaults)

            local selection = group.frame.Selection
            if selection and not selection.system then
                local label = Const.GROUP_LABELS[key] or key
                selection.system = {
                    GetSystemName = function() return label end,
                }
            end

            lem:AddFrameSettings(group.frame, BuildSettings(key))
            lem:SetFrameResetVisible(group.frame, true)

            lem:AddFrameSettingsButton(group.frame, {
                text = "Advanced Cooldown Settings",
                click = function()
                    ns.SpellPicker:Show(key == "buffs" and "buffs" or "cooldowns")
                end,
            })
        end
    end

    for _, key in ipairs(Const.BAR_ORDER) do
        local bar = ns.bars[key]
        local settings = ns.DB:GetBar(key)

        if bar and settings then
            local defaults = {
                point = settings.position.point or "CENTER",
                relativePoint = settings.position.relativePoint or "CENTER",
                x = settings.position.x or 0,
                y = settings.position.y or 0,
            }

            lem:AddFrame(bar.frame, function(...)
                local point, relativePoint, x, y = ParsePositionArgs(...)
                if not point then return end
                ns.DB:SetBarPosition(key, point, relativePoint, x, y)
            end, defaults)

            local selection = bar.frame.Selection
            if selection and not selection.system then
                local label = Const.BAR_LABELS[key] or key
                selection.system = { GetSystemName = function() return label end }
            end

            lem:AddFrameSettings(bar.frame, BuildBarSettings(key))
            lem:SetFrameResetVisible(bar.frame, true)

        end
    end

    lem:RegisterCallback("enter", function() EditMode:Enter() end)
    lem:RegisterCallback("exit", function() EditMode:Exit() end)

    return true
end

function EditMode:Register()
    if lem then
        local ok, err = pcall(self.RegisterWithLibEQOL, self)
        if ok then
            ns.Debug("registered with LibEQOL Edit Mode.")
            return true
        end

        ns.Print("|cffffcc00Edit Mode integration failed, using the basic handles:|r " .. tostring(err))
        self.registrationError = err
        lem = nil
        self.usingLibEQOL = false
    end

    if not self:IsAvailable() then
        ns.Debug("Blizzard Edit Mode not present on this client; frames cannot be moved.")
        return false
    end

    if _G.EventRegistry then
        EventRegistry:RegisterCallback("EditMode.Enter", function() self:Enter() end, self)
        EventRegistry:RegisterCallback("EditMode.Exit", function() self:Exit() end, self)
    end

    local manager = _G.EditModeManagerFrame

    if manager.SaveLayouts then
        hooksecurefunc(manager, "SaveLayouts", function() self:SaveLayouts() end)
    end

    if manager.RevertAllChanges then
        hooksecurefunc(manager, "RevertAllChanges", function() self:RevertChanges() end)
    end

    if not _G.EventRegistry then
        manager:HookScript("OnShow", function() self:Enter() end)
        manager:HookScript("OnHide", function() self:Exit() end)
    end

    if self:IsBlizzardEditModeActive() then
        self:Enter()
    end

    return true
end
