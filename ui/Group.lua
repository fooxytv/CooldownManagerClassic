local addonName, ns = ...

local Const = ns.Constants

local Group = {}
Group.__index = Group
ns.Group = Group

ns.groups = {}

function Group.Create(key)
    local self = setmetatable({}, Group)

    self.key = key
    self.icons = {}

    local frame = CreateFrame("Frame", "CDMCGroup" .. key:gsub("^%l", string.upper), UIParent)
    frame:SetSize(40, 40)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame.cdmcGroup = self
    self.frame = frame

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("BOTTOM", frame, "TOP", 0, 4)
    label:SetText(Const.GROUP_LABELS[key] or key)
    label:Hide()
    self.label = label

    ns.groups[key] = self
    return self
end

local GROWTH_TO_SELF_POINT = {
    CENTER = "CENTER",
    RIGHT  = "LEFT",
    LEFT   = "RIGHT",
}

function Group:GetSettings()
    return ns.DB:GetGroup(self.key)
end

function Group:GetSelfPoint()
    local settings = self:GetSettings()
    local growth = settings and settings.appearance.growth or "CENTER"
    return GROWTH_TO_SELF_POINT[growth] or "CENTER"
end

function Group:ApplyPosition()
    local settings = self:GetSettings()
    if not settings then return end

    local pos = settings.position
    self.frame:ClearAllPoints()
    self.frame:SetPoint(self:GetSelfPoint(), UIParent, pos.relativePoint or "CENTER", pos.x or 0, pos.y or 0)
end

function Group:SavePosition()
    local settings = self:GetSettings()
    if not settings then return end

    local point, _, relativePoint, x, y = self.frame:GetPoint(1)
    if not point then return end

    settings.position.point = point
    settings.position.relativePoint = relativePoint or "CENTER"
    settings.position.x = math.floor(x + 0.5)
    settings.position.y = math.floor(y + 0.5)
end

function Group:SetGrowth(growth)
    local settings = self:GetSettings()
    if not settings then return end

    local centerX, centerY = self.frame:GetCenter()
    settings.appearance.growth = growth
    self:Layout()

    if centerX and centerY then
        local parentX, parentY = UIParent:GetCenter()
        local width, height = self.frame:GetSize()
        local selfPoint = self:GetSelfPoint()

        local anchorX = centerX
        if selfPoint == "LEFT" then
            anchorX = centerX - width / 2
        elseif selfPoint == "RIGHT" then
            anchorX = centerX + width / 2
        end

        settings.position.relativePoint = "CENTER"
        settings.position.x = math.floor(anchorX - parentX + 0.5)
        settings.position.y = math.floor(centerY - parentY + 0.5)
        self:ApplyPosition()
    end
end

local GROWTH_HINTS = {
    CENTER = "<-  grows from centre  ->",
    RIGHT  = "grows right  ->",
    LEFT   = "<-  grows left",
}

function Group:UpdateEditLabel()
    local settings = self:GetSettings()
    local growth = settings and settings.appearance.growth or "CENTER"

    self.label:SetText(("%s   |cff888888%s|r"):format(
        Const.GROUP_LABELS[self.key] or self.key,
        GROWTH_HINTS[growth] or ""
    ))
end

function Group:GetWidget()
    local settings = self:GetSettings()
    if settings and settings.appearance.display == "Bars" then
        return ns.BuffBar, "bars"
    end
    return ns.Icon, "icons"
end

function Group:ReleaseAll(widget)
    widget = widget or self.widget or ns.Icon
    for i = #self.icons, 1, -1 do
        widget:Release(self.icons[i])
        self.icons[i] = nil
    end
end

function Group:Layout()
    local settings = self:GetSettings()
    if not settings then return end

    local appearance = settings.appearance
    local spacing = appearance.spacing or Const.DEFAULT_APPEARANCE.spacing

    local widget, widgetKind = self:GetWidget()
    if widgetKind ~= self.widgetKind then
        self:ReleaseAll(self.widget)
        self.widgetKind = widgetKind
    end
    self.widget = widget

    local itemWidth, itemHeight = widget:GetItemSize(appearance)

    local isAuraGroup = Const.AURA_GROUPS[self.key]
    local hideInactive = isAuraGroup
        and appearance.hideWhenInactive ~= false
        and not self.unlocked

    local currentForm
    if not self.unlocked and select(2, UnitClass("player")) == "DRUID" then
        currentForm = ns.Compat.GetShapeshiftForm()
    end

    local resolved = {}
    for _, entry in ipairs(settings.spells) do
        local spellID = ns.Spellbook:ResolveForGroup(entry, isAuraGroup)
        local formOK = not currentForm or Const.FormAllows(entry.forms, currentForm)
        if spellID and formOK
            and not (hideInactive and not ns.Auras:GetTrackedState(spellID, entry.trackDebuff).active)
        then
            resolved[#resolved + 1] = { entry = entry, spellID = spellID }
        end
    end

    self.activeKey = self:ComputeActiveKey()

    for i = #resolved + 1, #self.icons do
        widget:Release(self.icons[i])
        self.icons[i] = nil
    end

    for i, item in ipairs(resolved) do
        local icon = self.icons[i]
        if not icon then
            icon = widget:Acquire(self.frame, self.key)
            self.icons[i] = icon
        end
        widget:Configure(icon, item.entry, item.spellID, appearance, self.key)
    end

    local count = #resolved
    if count == 0 then
        self.frame:SetSize(itemWidth, itemHeight)
        self:ApplyPosition()
        self:UpdateVisibility()
        return
    end

    local horizontal = (appearance.orientation or "Horizontal") ~= "Vertical"
    local lines = math.max(1, math.min(appearance.rows or 1, count))
    local perLine = math.ceil(count / lines)

    local columnCount = horizontal and perLine or lines
    local rowCount = horizontal and lines or perLine

    local stepX = itemWidth + spacing
    local stepY = itemHeight + spacing
    local totalWidth = columnCount * itemWidth + (columnCount - 1) * spacing
    local totalHeight = rowCount * itemHeight + (rowCount - 1) * spacing
    self.frame:SetSize(math.max(totalWidth, 1), math.max(totalHeight, 1))

    local direction = appearance.iconDirection or (horizontal and "Down" or "Right")

    for i, icon in ipairs(self.icons) do
        local index = i - 1
        local line = math.floor(index / perLine)
        local positionInLine = index % perLine

        local column, row
        if horizontal then
            column, row = positionInLine, line
        else
            column, row = line, positionInLine
        end

        if horizontal and direction == "Up" then
            row = (rowCount - 1) - row
        elseif not horizontal and direction == "Left" then
            column = (columnCount - 1) - column
        end

        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", self.frame, "TOPLEFT", column * stepX, -row * stepY)
        icon:SetShown(settings.enabled ~= false)
    end

    self:ApplyPosition()
    self:UpdateVisibility()
end

local function InCombat()
    return InCombatLockdown() or UnitAffectingCombat("player")
end

function Group:UpdateVisibility()
    local settings = self:GetSettings()
    if not settings then return end

    local appearance = settings.appearance
    self.frame:SetAlpha((appearance.opacity or 100) / 100)

    if self.unlocked then
        self.frame:Show()
        return
    end

    if settings.enabled == false then
        self.frame:Hide()
        return
    end

    local visibility = appearance.visibility or "Always"
    local visible = true
    if visibility == "Hidden" then
        visible = false
    elseif visibility == "InCombat" then
        visible = InCombat()
    elseif visibility == "OutOfCombat" then
        visible = not InCombat()
    end

    if visible and #self.icons == 0 and appearance.hideWhenEmpty ~= false then
        visible = false
    end

    self.frame:SetShown(visible)
end

function Group:ComputeActiveKey()
    local settings = self:GetSettings()
    if not settings or not Const.AURA_GROUPS[self.key] then return 0 end
    if settings.appearance.hideWhenInactive == false then return 0 end

    local hash = 0
    for _, entry in ipairs(settings.spells) do
        local spellID = ns.Spellbook:ResolveForGroup(entry, true)
        if spellID and ns.Auras:GetTrackedState(spellID, entry.trackDebuff).active then
            hash = (hash * 31 + spellID) % 2147483647
        end
    end
    return hash
end

function Group:Update()
    local settings = self:GetSettings()
    if not settings or settings.enabled == false then return false end

    if Const.AURA_GROUPS[self.key]
        and settings.appearance.hideWhenInactive ~= false
        and not self.unlocked
    then
        if self:ComputeActiveKey() ~= self.activeKey then
            self:Layout()
        end
    end

    local appearance = settings.appearance
    local animating = false

    local durationBars = Const.DURATION_BAR_GROUPS[self.key]
    local auraGroup = Const.AURA_GROUPS[self.key]

    local widget = self.widget or ns.Icon
    for _, icon in ipairs(self.icons) do
        if icon.spellID then
            local trackDebuff = icon.entry and icon.entry.trackDebuff
            local state
            if durationBars then
                state = ns.Cooldowns:GetBarState(icon.spellID, trackDebuff)
            elseif auraGroup then
                state = ns.Auras:GetTrackedState(icon.spellID, trackDebuff)
            else
                state = ns.Cooldowns:GetIconState(icon.spellID, appearance.showGCD, trackDebuff)
            end
            if widget:Update(icon, state, appearance) then
                animating = true
            end
        end
    end

    return animating
end

local function OnDragStart(frame)
    frame:StartMoving()
end

local function OnDragStop(frame)
    frame:StopMovingOrSizing()
    if frame.cdmcGroup then
        frame.cdmcGroup:SavePosition()
        frame.cdmcGroup:ApplyPosition()
    end
end

local function OnMouseUp(frame)
    if frame.cdmcGroup and frame.cdmcGroup.unlocked then
        if ns.BarPanel then ns.BarPanel:Hide() end
        ns.EditModePanel:Show(frame.cdmcGroup.key)
    end
end

function Group:SetUnlocked(unlocked)
    self.unlocked = unlocked

    local frame = self.frame
    frame:EnableMouse(unlocked)
    if unlocked then
        frame:RegisterForDrag("LeftButton")
    else
        frame:RegisterForDrag()
    end
    frame:SetScript("OnDragStart", unlocked and OnDragStart or nil)
    frame:SetScript("OnDragStop", unlocked and OnDragStop or nil)
    frame:SetScript("OnMouseUp", unlocked and OnMouseUp or nil)

    if unlocked then
        if not self.dragBackdrop then
            local backdrop = frame:CreateTexture(nil, "BACKGROUND")
            backdrop:SetAllPoints()
            backdrop:SetColorTexture(0.1, 0.6, 1.0, 0.25)
            self.dragBackdrop = backdrop
        end
        self.dragBackdrop:Show()
        self:UpdateEditLabel()
        self.label:Show()
        frame:Show()
    else
        if self.dragBackdrop then self.dragBackdrop:Hide() end
        self.label:Hide()
        self:Layout()
    end
end
