local addonName, ns = ...

local Const = ns.Constants

-- Two tiers. With LibEQOL the groups become genuine Edit Mode systems -- real
-- selection frames, grid snapping, settings inside Blizzard's own dialog.
-- Without it, our own drag handles and panel, which is also what runs on a
-- client with no Edit Mode at all.
local EditMode = {}
ns.EditMode = EditMode

EditMode.active = false
EditMode.manualUnlock = false

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

-- Groups and resource bars are both draggable Edit Mode systems and are always
-- unlocked, saved and reverted together. ns.bars was omitted from every one of
-- these loops originally, which left the bars unreachable: disabled by default,
-- hidden while disabled, and hidden frames cannot be clicked to reach the
-- setting that would enable them.
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

    -- With LibEQOL the library owns selection and dragging, so ours would get
    -- in the way. Either way everything is forced visible, so an empty,
    -- disabled or combat-hidden widget can still be positioned.
    ForEachWidget(function(widget)
        if lem then
            widget.unlocked = true
            widget:UpdateVisibility()
        else
            widget:SetUnlocked(true)
        end
    end)

    if not lem then
        ns.EditModePanel:Show(Const.GROUP_ORDER[1])
    end
end

function EditMode:Exit()
    if not self.active then return end
    self.active = false

    if not self.manualUnlock then
        ForEachWidget(function(widget)
            if lem then
                widget.unlocked = false
                widget:UpdateVisibility()
            else
                widget:SetUnlocked(false)
            end
        end)
        ns.EditModePanel:Hide()
    end

    positionSnapshot = nil
end

function EditMode:SaveLayouts()
    ForEachWidget(function(widget) widget:SavePosition() end)
    positionSnapshot = TakeSnapshot()
end

function EditMode:RevertChanges()
    RestoreSnapshot(positionSnapshot)
end

function EditMode:SetManualUnlock(unlocked)
    self.manualUnlock = unlocked
    ns.DB:GetGlobal().locked = not unlocked

    ForEachWidget(function(widget) widget:SetUnlocked(unlocked) end)

    if unlocked then
        ns.EditModePanel:Show(Const.GROUP_ORDER[1])
    else
        ns.EditModePanel:Hide()
    end
end

function EditMode:ToggleManualUnlock()
    self:SetManualUnlock(not self.manualUnlock)
    return self.manualUnlock
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

-- LibEQOL dropdowns work in display strings, not values.
local function DropdownValues(labels)
    local values = {}
    for _, label in ipairs(labels) do
        values[#values + 1] = { text = label }
    end
    return values
end

local function BuildSettings(groupKey)
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
                -- The valid directions differ per orientation, so a stale one
                -- has to be corrected rather than left pointing sideways.
                local allowed = Const.ICON_DIRECTIONS[value] or Const.ICON_DIRECTIONS.Horizontal
                local current = GetOption(groupKey, "iconDirection")
                local stillValid = false
                for _, direction in ipairs(allowed) do
                    if direction == current then stillValid = true end
                end
                if not stillValid then
                    SetOption(groupKey, "iconDirection", allowed[1])
                end
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
            optionfunc = function()
                local orientation = GetOption(groupKey, "orientation", "Horizontal")
                return DropdownValues(Const.ICON_DIRECTIONS[orientation] or Const.ICON_DIRECTIONS.Horizontal)
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
            -- Negative padding lets the icons touch or overlap, which the
            -- Blizzard bevel otherwise prevents at zero.
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
                -- Flipped with the display, because bars are wide and stack
                -- downwards where icons run along a row.
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

    -- Combo points show pips rather than a value, so the text toggle is
    -- replaced by pip spacing.
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

    return settings
end

-- LibEQOL reports the new anchor as a loose argument list, so the values are
-- picked out by type rather than by position.
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

            -- Classic's EditModeSystemSelectionBaseMixin:CheckShowInstructionalTooltip
            -- calls self.system:GetSystemName() on mouse-enter. Blizzard's real
            -- systems set that field and an addon-registered frame does not, so
            -- hovering throws without this stub.
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
                -- Through the accessor, not the captured `settings`: see
                -- DB:SetBarPosition.
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

        -- Fall through to the basic path rather than leaving the groups with no
        -- way to be moved at all.
        ns.Print("|cffffcc00Edit Mode integration failed, using the basic handles:|r " .. tostring(err))
        lem = nil
        self.usingLibEQOL = false
    end

    if not self:IsAvailable() then
        ns.Debug("Edit Mode not present on this client; use /cdmc unlock.")
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
