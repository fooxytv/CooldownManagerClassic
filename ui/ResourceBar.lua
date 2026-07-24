local addonName, ns = ...

local Const = ns.Constants

local Bar = {}
Bar.__index = Bar
ns.ResourceBar = Bar

ns.bars = {}

local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

local function GetPowerColor(token)
    local blizzard = _G.PowerBarColor and PowerBarColor[token]
    if blizzard and blizzard.r then
        return blizzard.r, blizzard.g, blizzard.b
    end

    local fallback = Const.POWER_COLORS[token]
    if fallback then
        return fallback[1], fallback[2], fallback[3]
    end

    return 0.6, 0.6, 0.6
end

-- Classic keeps combo points on the target rather than as a player power, so
-- GetComboPoints is tried before the modern power type.
local function GetComboPoints()
    if _G.GetComboPoints then
        local points = GetComboPoints("player", "target")
        if points then return points end
    end

    if _G.UnitPower and _G.Enum and Enum.PowerType and Enum.PowerType.ComboPoints then
        return UnitPower("player", Enum.PowerType.ComboPoints) or 0
    end

    return 0
end

local function GetMaxComboPoints()
    if _G.UnitPowerMax and _G.Enum and Enum.PowerType and Enum.PowerType.ComboPoints then
        local max = UnitPowerMax("player", Enum.PowerType.ComboPoints)
        if max and max > 0 then return max end
    end
    return _G.MAX_COMBO_POINTS or 5
end

local function ReadResource(key)
    if key == "health" then
        local current = UnitHealth("player") or 0
        local max = UnitHealthMax("player") or 0
        local c = Const.HEALTH_COLOR
        return current, max, c[1], c[2], c[3]
    end

    if key == "power" then
        -- UnitPowerType follows druid shapeshifts, so form changes need no
        -- class-specific handling.
        local powerType, powerToken = UnitPowerType("player")
        local current = UnitPower("player", powerType) or 0
        local max = UnitPowerMax("player", powerType) or 0
        local r, g, b = GetPowerColor(powerToken or "MANA")
        return current, max, r, g, b
    end

    if key == "combo" then
        local c = Const.COMBO_COLOR
        return GetComboPoints(), GetMaxComboPoints(), c[1], c[2], c[3]
    end

    return 0, 0, 0.6, 0.6, 0.6
end

function Bar.Create(key)
    local self = setmetatable({}, Bar)
    self.key = key
    self.pips = {}

    local frame = CreateFrame("Frame", "CDMCBar" .. key:gsub("^%l", string.upper), UIParent)
    frame:SetSize(220, 18)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame.cdmcBar = self
    self.frame = frame

    frame.background = frame:CreateTexture(nil, "BACKGROUND")
    frame.background:SetAllPoints()
    frame.background:SetColorTexture(0, 0, 0, 0.5)

    -- Created for every bar, but hidden for combo points, which draw as pips.
    local statusBar = CreateFrame("StatusBar", nil, frame)
    statusBar:SetAllPoints()
    statusBar:SetStatusBarTexture(BAR_TEXTURE)
    statusBar:SetMinMaxValues(0, 1)
    statusBar:SetValue(1)
    self.statusBar = statusBar

    local text = statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("CENTER")
    self.text = text

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("BOTTOM", frame, "TOP", 0, 4)
    label:SetText(Const.BAR_LABELS[key] or key)
    label:Hide()
    self.label = label

    ns.bars[key] = self
    return self
end

function Bar:GetSettings()
    return ns.DB:GetBar(self.key)
end

function Bar:ApplyPosition()
    local settings = self:GetSettings()
    if not settings then return end

    local pos = settings.position
    self.frame:ClearAllPoints()
    self.frame:SetPoint(pos.point or "CENTER", UIParent, pos.relativePoint or "CENTER",
        pos.x or 0, pos.y or 0)
end

function Bar:SavePosition()
    local settings = self:GetSettings()
    if not settings then return end

    local point, _, relativePoint, x, y = self.frame:GetPoint(1)
    if not point then return end

    settings.position.point = point
    settings.position.relativePoint = relativePoint or "CENTER"
    settings.position.x = math.floor(x + 0.5)
    settings.position.y = math.floor(y + 0.5)
end

function Bar:Layout()
    local settings = self:GetSettings()
    if not settings then return end

    local appearance = settings.appearance
    local width = appearance.width or Const.DEFAULT_BAR_APPEARANCE.width
    local height = appearance.height or Const.DEFAULT_BAR_APPEARANCE.height

    self.frame:SetSize(width, height)

    if self.key == "combo" then
        self:LayoutPips(width, height, appearance)
    else
        self.statusBar:Show()
        for _, pip in ipairs(self.pips) do pip:Hide() end
    end

    self:ApplyPosition()
    self:UpdateVisibility()
    self:Update()
end

function Bar:LayoutPips(width, height, appearance)
    self.statusBar:Hide()

    local maxPoints = GetMaxComboPoints()
    local spacing = appearance.pipSpacing or Const.DEFAULT_BAR_APPEARANCE.pipSpacing
    local pipWidth = (width - spacing * (maxPoints - 1)) / maxPoints

    for index = 1, maxPoints do
        local pip = self.pips[index]
        if not pip then
            pip = self.frame:CreateTexture(nil, "ARTWORK")
            self.pips[index] = pip
        end

        pip:SetSize(math.max(pipWidth, 1), height)
        pip:ClearAllPoints()
        pip:SetPoint("LEFT", self.frame, "LEFT", (index - 1) * (pipWidth + spacing), 0)
        pip:Show()
    end

    for index = maxPoints + 1, #self.pips do
        self.pips[index]:Hide()
    end
end

function Bar:Update()
    local settings = self:GetSettings()
    if not settings then return end

    -- A disabled bar still renders while unlocked. It is forced visible so it
    -- can be positioned and switched on, and an empty box gives no clue which
    -- resource it is or whether the setting took effect.
    if settings.enabled == false and not self.unlocked then return end

    local appearance = settings.appearance
    local current, max, r, g, b = ReadResource(self.key)

    if self.key == "combo" then
        local c = Const.COMBO_COLOR
        for index, pip in ipairs(self.pips) do
            if index <= current then
                pip:SetColorTexture(c[1], c[2], c[3], 1)
            else
                pip:SetColorTexture(0.25, 0.25, 0.25, 0.6)
            end
        end
        self.text:Hide()
        return
    end

    self.statusBar:SetStatusBarColor(r, g, b)
    self.statusBar:SetMinMaxValues(0, math.max(max, 1))
    self.statusBar:SetValue(current)

    if appearance.showText ~= false and max > 0 then
        self.text:SetText(("%d / %d"):format(current, max))
        self.text:Show()
    else
        self.text:Hide()
    end
end

local function InCombat()
    return InCombatLockdown() or UnitAffectingCombat("player")
end

function Bar:UpdateVisibility()
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

    -- Or a class with no combo points shows an empty row of pips forever.
    if visible and self.key == "combo" and GetMaxComboPoints() == 0 then
        visible = false
    end

    self.frame:SetShown(visible)
end

local function OnDragStart(frame)
    frame:StartMoving()
end

local function OnDragStop(frame)
    frame:StopMovingOrSizing()
    if frame.cdmcBar then
        frame.cdmcBar:SavePosition()
        frame.cdmcBar:ApplyPosition()
    end
end

function Bar:SetUnlocked(unlocked)
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

    self.label:SetShown(unlocked)
    self:UpdateVisibility()

    -- Contents too, not just visibility: a disabled bar renders nothing, so
    -- unlocking one would otherwise reveal an empty box.
    self:Update()
end
