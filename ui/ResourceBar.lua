local addonName, ns = ...

local Const = ns.Constants

local Bar = {}
Bar.__index = Bar
ns.ResourceBar = Bar

ns.bars = {}

local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

local VALUE_FONT_OBJECT = "GameFontHighlightSmall"

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

local function ReadComboPoints()
    if _G.GetComboPoints then
        local points = _G.GetComboPoints("player", "target")
        if points then return points end
    end

    if _G.UnitPower and _G.Enum and Enum.PowerType and Enum.PowerType.ComboPoints then
        return UnitPower("player", Enum.PowerType.ComboPoints) or 0
    end

    return 0
end

local function ReadMaxComboPoints()
    if _G.UnitPowerMax and _G.Enum and Enum.PowerType and Enum.PowerType.ComboPoints then
        local max = UnitPowerMax("player", Enum.PowerType.ComboPoints)
        if max and max > 0 then return max end
    end
    return _G.MAX_COMBO_POINTS or 5
end

-- Shards sat in the bags through Wrath and became a power type in Cataclysm;
-- MoP then split the Warlock resource three ways by spec. Probing UnitPowerMax
-- alone is not enough to tell -- it answers for power types the client does not
-- really have -- so the flavour decides first.
local BAG_SHARD_FLAVORS = { era = true, tbc = true, wrath = true }

local function UsesShardItems()
    return BAG_SHARD_FLAVORS[ns.Compat.flavor] == true
end

local function WarlockPowerType(source)
    local info = Const.WARLOCK_POWER_TYPES[source]
    if not info then return nil end

    if _G.Enum and Enum.PowerType and Enum.PowerType[info.enum] then
        return Enum.PowerType[info.enum]
    end

    return info.value
end

local function WarlockPowerMax(source)
    local powerType = WarlockPowerType(source)
    if not powerType or not _G.UnitPowerMax then return 0 end
    return UnitPowerMax("player", powerType) or 0
end

local function PlayerSpec()
    if _G.C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
        return C_SpecializationInfo.GetSpecialization()
    end
    if _G.GetSpecialization then return GetSpecialization() end
    return nil
end

-- Keyed off the spec, as Blizzard's own ShardBar does. Probing UnitPowerMax
-- instead would show a shard bar to a Destruction warlock who has not learned
-- Burning Embers yet, because shards are first in the order and the probe has
-- no way to tell "wrong spec" from "not learned".
local function WarlockSpecResource()
    local spec = PlayerSpec()
    if not spec then return nil end

    local bySpec = {
        [_G.SPEC_WARLOCK_AFFLICTION or 1]  = "soulshards",
        [_G.SPEC_WARLOCK_DEMONOLOGY or 2]  = "demonicfury",
        [_G.SPEC_WARLOCK_DESTRUCTION or 3] = "burningembers",
    }
    return bySpec[spec]
end

local function ResolveWarlockResource()
    if UsesShardItems() then return "soulshards" end

    local source = WarlockSpecResource()
    if source then
        -- The spec is right but the resource is not there yet at low level, so
        -- show nothing rather than a bar that cannot fill.
        if WarlockPowerMax(source) > 0 then return source end
        return nil
    end

    for _, candidate in ipairs(Const.WARLOCK_RESOURCE_ORDER) do
        if WarlockPowerMax(candidate) > 0 then return candidate end
    end
    return nil
end

-- Shards are a bag item on Era and TBC and a power type from MoP on, so the
-- display mode cannot be static.
local function ResourceMode(source)
    local info = source and Const.CLASS_RESOURCE_INFO[source]
    if not info then return nil end
    if source == "soulshards" then
        if not UsesShardItems() and WarlockPowerMax(source) > 0 then
            return "pips"
        end
        return "count"
    end
    return info.mode
end

local function ReadWarlockPower(source)
    local powerType = WarlockPowerType(source)
    if not powerType or not _G.UnitPower then return 0, 0 end
    return UnitPower("player", powerType) or 0, WarlockPowerMax(source)
end

local function ResolveClassResource(override)
    local _, classToken = UnitClass("player")

    local source
    if override == "none" then
        return nil
    elseif override and Const.CLASS_RESOURCE_INFO[override] then
        source = override
    else
        source = Const.CLASS_RESOURCE_SOURCE[classToken or ""]
    end

    if source == "maelstrom" and not ns.Compat.isSoD then
        return nil
    end

    if classToken == "WARLOCK" and Const.WARLOCK_POWER_TYPES[source] then
        source = ResolveWarlockResource()
    end

    if source == "combo" and classToken == "DRUID" then
        local _, powerToken = UnitPowerType("player")
        if powerToken ~= "ENERGY" then return nil end
    end

    return source
end

local function ReadPipSource(source)
    if source == "maelstrom" then
        return ns.Auras:StacksByName(Const.MAELSTROM_WEAPON_AURA), Const.MAELSTROM_MAX_STACKS
    end
    if Const.WARLOCK_POWER_TYPES[source] then
        return ReadWarlockPower(source)
    end
    return ReadComboPoints(), ReadMaxComboPoints()
end

local function SoulShardDisplay(count)
    local size = Const.SOUL_SHARD_TIER_SIZE
    local colors = Const.SOUL_SHARD_COLORS

    if count <= 0 then
        return colors[1], 0, size
    end

    local tier = math.floor(count / size)
    local within = count % size
    if within == 0 then within = size end

    return colors[math.min(tier + 1, #colors)], within, size
end

local function ReadResource(key)
    if key == "health" then
        local current = UnitHealth("player") or 0
        local max = UnitHealthMax("player") or 0
        local c = Const.HEALTH_COLOR
        return current, max, c[1], c[2], c[3]
    end

    if key == "power" then
        local powerType, powerToken = UnitPowerType("player")
        local current = UnitPower("player", powerType) or 0
        local max = UnitPowerMax("player", powerType) or 0
        local r, g, b = GetPowerColor(powerToken or "MANA")
        return current, max, r, g, b
    end

    return 0, 0, 0.6, 0.6, 0.6
end

local function FormatValue(current, max, appearance)
    if appearance.showPercent and max and max > 0 then
        return ("%d%%"):format(math.floor((current / max) * 100 + 0.5))
    end
    return ("%d / %d"):format(current, max)
end

local function PipFillColor(source, current, max)
    if source == "burningembers" then
        return Const.BURNING_EMBERS_COLOR
    end
    if source == "soulshards" then
        return Const.SOUL_SHARD_COLORS[#Const.SOUL_SHARD_COLORS]
    end
    if source == "combo" then
        local colors = Const.COMBO_COLORS
        if current >= max then
            return colors.full
        elseif current == max - 1 then
            return colors.nearlyFull
        end
        return colors.building
    end
    return Const.MAELSTROM_COLOR
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

    self.borders = {
        top    = frame:CreateTexture(nil, "BORDER"),
        bottom = frame:CreateTexture(nil, "BORDER"),
        left   = frame:CreateTexture(nil, "BORDER"),
        right  = frame:CreateTexture(nil, "BORDER"),
    }

    local borderFrame = CreateFrame("Frame", nil, frame, ns.Compat.backdropTemplate)
    borderFrame:SetAllPoints()
    borderFrame:SetFrameLevel((frame:GetFrameLevel() or 1) + 4)
    borderFrame:Hide()
    self.borderFrame = borderFrame

    local statusBar = CreateFrame("StatusBar", nil, frame)
    statusBar:SetAllPoints()
    statusBar:SetStatusBarTexture(BAR_TEXTURE)
    statusBar:SetMinMaxValues(0, 1)
    statusBar:SetValue(1)
    self.statusBar = statusBar

    local spark = statusBar:CreateTexture(nil, "OVERLAY")
    spark:SetColorTexture(1, 1, 1, 0.85)
    spark:SetWidth(16)
    if spark.SetBlendMode then spark:SetBlendMode("ADD") end
    spark:Hide()
    self.spark = spark

    self.ticks = {}

    local text = statusBar:CreateFontString(nil, "OVERLAY", VALUE_FONT_OBJECT)
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

-- Edge art below this reads as a scratch rather than a border, so the border
-- size doubles as a floor for it: the default size of 1 is a hairline for the
-- solid border and a visible frame for a texture.
local MIN_EDGE_SIZE = 6

function Bar:ApplyChrome(appearance)
    local br, bg, bb, ba = Const.UnpackColor(appearance.bgColor, 0, 0, 0, 0.5)
    self.frame.background:SetColorTexture(br, bg, bb, ba)

    local size = appearance.borderSize or Const.DEFAULT_BAR_APPEARANCE.borderSize
    local edges = self.borders
    if not size or size <= 0 then
        for _, tex in pairs(edges) do tex:Hide() end
        ns.Compat.ClearBorderTexture(self.borderFrame)
        return
    end

    local r, g, b, a = Const.UnpackColor(appearance.borderColor, 0, 0, 0, 1)

    local edgeFile = ns.Media.Fetch("border", appearance.borderTexture, nil)
    if edgeFile and ns.Compat.SetBorderTexture(self.borderFrame, edgeFile,
        math.max(size, MIN_EDGE_SIZE), r, g, b, a)
    then
        for _, tex in pairs(edges) do tex:Hide() end
        return
    end

    ns.Compat.ClearBorderTexture(self.borderFrame)

    for _, tex in pairs(edges) do
        tex:SetColorTexture(r, g, b, a)
        tex:Show()
    end

    local frame = self.frame
    edges.top:ClearAllPoints()
    edges.top:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", -size, 0)
    edges.top:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", size, 0)
    edges.top:SetHeight(size)

    edges.bottom:ClearAllPoints()
    edges.bottom:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", -size, 0)
    edges.bottom:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", size, 0)
    edges.bottom:SetHeight(size)

    edges.left:ClearAllPoints()
    edges.left:SetPoint("TOPRIGHT", frame, "TOPLEFT", 0, 0)
    edges.left:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", 0, 0)
    edges.left:SetWidth(size)

    edges.right:ClearAllPoints()
    edges.right:SetPoint("TOPLEFT", frame, "TOPRIGHT", 0, 0)
    edges.right:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", 0, 0)
    edges.right:SetWidth(size)
end

function Bar:ApplyTextAlign(appearance)
    local align = appearance.textAlign or "CENTER"
    local text = self.text
    text:ClearAllPoints()
    if align == "LEFT" then
        text:SetPoint("LEFT", self.statusBar, "LEFT", 3, 0)
    elseif align == "RIGHT" then
        text:SetPoint("RIGHT", self.statusBar, "RIGHT", -3, 0)
    else
        text:SetPoint("CENTER", self.statusBar, "CENTER", 0, 0)
    end
    if text.SetJustifyH then text:SetJustifyH(align) end
end

function Bar:ApplyFont(appearance)
    local text = self.text
    if _G[VALUE_FONT_OBJECT] then
        text:SetFontObject(_G[VALUE_FONT_OBJECT])
    end

    local file, size, flags = text:GetFont()

    file = ns.Media.Fetch("font", appearance.fontFace, file)

    if appearance.fontOutline ~= nil then flags = appearance.fontOutline end

    if file and size then
        text:SetFont(file, size, flags)
    end
end

function Bar:FillColor(appearance, r, g, b)
    local override = appearance.fillColor
    if type(override) == "string" and override ~= "" then
        local orr, og, ob = Const.UnpackColor(override, r, g, b, 1)
        return orr, og, ob
    end
    return r, g, b
end

function Bar:ApplySpark(current, max, appearance)
    local spark = self.spark
    if not (appearance.spark and current and max and max > 0 and current > 0 and current < max) then
        spark:Hide()
        return
    end

    local width = self.statusBar:GetWidth() or (appearance.width or Const.DEFAULT_BAR_APPEARANCE.width)
    local height = self.statusBar:GetHeight() or (appearance.height or Const.DEFAULT_BAR_APPEARANCE.height)
    spark:SetHeight(height)
    spark:ClearAllPoints()
    spark:SetPoint("CENTER", self.statusBar, "LEFT", (current / max) * width, 0)
    spark:Show()
end

function Bar:SetFill(current, max, appearance)
    max = math.max(max or 1, 1)
    current = math.max(0, math.min(current or 0, max))
    self.statusBar:SetMinMaxValues(0, max)

    if appearance.animate then
        self._target = current
        self._max = max
        self._appearance = appearance
        if not self._animating then
            self._animating = true
            self.statusBar:SetScript("OnUpdate", function(bar, elapsed)
                local cur = bar:GetValue() or 0
                local target = self._target or cur
                local scale = self._max or max
                local look = self._appearance or appearance
                local step = target - cur
                if math.abs(step) <= 0.5 then
                    bar:SetValue(target)
                    bar:SetScript("OnUpdate", nil)
                    self._animating = false
                    self:ApplySpark(target, scale, look)
                else
                    local moved = cur + step * math.min(1, (elapsed or 0) * 8)
                    bar:SetValue(moved)
                    self:ApplySpark(moved, scale, look)
                end
            end)
        end
    else
        if self._animating then
            self.statusBar:SetScript("OnUpdate", nil)
            self._animating = false
        end
        self.statusBar:SetValue(current)
    end

    self:ApplySpark(current, max, appearance)
end

function Bar:Layout()
    local settings = self:GetSettings()
    if not settings then return end

    local appearance = settings.appearance
    local width = appearance.width or Const.DEFAULT_BAR_APPEARANCE.width
    local height = appearance.height or Const.DEFAULT_BAR_APPEARANCE.height

    self.frame:SetSize(width, height)
    self.statusBar:SetStatusBarTexture(ns.Media.Fetch("statusbar", appearance.barTexture, BAR_TEXTURE))
    self:ApplyChrome(appearance)
    self:ApplyTextAlign(appearance)
    self:ApplyFont(appearance)

    if self.key == "combo" then
        local source = ResolveClassResource(appearance.resourceSource)
        self.source = source

        local info = source and Const.CLASS_RESOURCE_INFO[source]
        self.label:SetText((info and info.label) or Const.BAR_LABELS.combo)

        if ResourceMode(source) == "pips" then
            local _, maxPoints = ReadPipSource(source)
            if appearance.segmentStyle == "ticks" then
                self:LayoutTicks(width, height, appearance, maxPoints)
            else
                self:LayoutPips(width, height, appearance, maxPoints)
            end
        else
            self.statusBar:Show()
            self:HidePips()
            self:HideTicks()
        end
    else
        self.statusBar:Show()
        self:HidePips()
        self:HideTicks()
    end

    self:ApplyPosition()
    self:UpdateVisibility()
    self:Update()
end

function Bar:HidePips()
    for _, pip in ipairs(self.pips) do pip:Hide() end
end

function Bar:HideTicks()
    for _, tick in ipairs(self.ticks) do tick:Hide() end
end

function Bar:LayoutPips(width, height, appearance, maxPoints)
    self.statusBar:Hide()
    self:HideTicks()

    maxPoints = maxPoints or ReadMaxComboPoints()
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

function Bar:LayoutTicks(width, height, appearance, maxPoints)
    self.statusBar:Show()
    self:HidePips()

    maxPoints = maxPoints or ReadMaxComboPoints()

    for index = 1, maxPoints - 1 do
        local tick = self.ticks[index]
        if not tick then
            tick = self.statusBar:CreateTexture(nil, "OVERLAY")
            self.ticks[index] = tick
        end

        tick:SetColorTexture(0, 0, 0, 0.85)
        tick:SetSize(1, height)
        tick:ClearAllPoints()
        tick:SetPoint("LEFT", self.statusBar, "LEFT", (index / maxPoints) * width, 0)
        tick:Show()
    end

    for index = math.max(maxPoints, 1), #self.ticks do
        self.ticks[index]:Hide()
    end
end

function Bar:Update()
    local settings = self:GetSettings()
    if not settings then return end

    if settings.enabled == false and not self.unlocked then return end

    local appearance = settings.appearance

    self:UpdateVisibility()

    if self.key == "combo" then
        self:UpdateClassResource(appearance)
        return
    end

    local current, max, r, g, b = ReadResource(self.key)

    self.statusBar:SetStatusBarColor(self:FillColor(appearance, r, g, b))
    self:SetFill(current, max, appearance)

    if appearance.showText ~= false and max > 0 then
        self.text:SetText(FormatValue(current, max, appearance))
        self.text:Show()
    else
        self.text:Hide()
    end
end

function Bar:UpdateClassResource(appearance)
    local source = self.source
    if source == nil then
        source = ResolveClassResource(appearance.resourceSource)
    end

    local mode = ResourceMode(source)
    if not mode then
        self.statusBar:SetValue(0)
        self:HidePips()
        self:HideTicks()
        self.text:Hide()
        return
    end

    if mode == "power" then
        local current, max = ReadWarlockPower(source)
        local color = Const.DEMONIC_FURY_COLOR

        self.statusBar:SetStatusBarColor(self:FillColor(appearance, color[1], color[2], color[3]))
        self:SetFill(current, max, appearance)
        self:HidePips()

        if appearance.showText ~= false then
            self.text:SetText(FormatValue(current, max, appearance))
            self.text:Show()
        else
            self.text:Hide()
        end
        return
    end

    if mode == "pips" then
        local current, max = ReadPipSource(source)
        local fill = PipFillColor(source, current, max)
        local fr, fg, fb = self:FillColor(appearance, fill[1], fill[2], fill[3])

        if appearance.segmentStyle == "ticks" then
            self.statusBar:SetStatusBarColor(fr, fg, fb)
            self:SetFill(current, max, appearance)
            self.text:Hide()
            return
        end

        local empty = Const.COMBO_COLORS.empty
        for index, pip in ipairs(self.pips) do
            if index <= current then
                pip:SetColorTexture(fr, fg, fb, 1)
            else
                pip:SetColorTexture(empty[1], empty[2], empty[3], empty[4])
            end
        end
        self.text:Hide()
        return
    end

    local count = ns.Compat.GetItemCount(Const.SOUL_SHARD_ITEM_ID)
    local color, within, size = SoulShardDisplay(count)

    self.statusBar:SetStatusBarColor(self:FillColor(appearance, color[1], color[2], color[3]))
    self:SetFill(within, size, appearance)

    if appearance.showText ~= false then
        self.text:SetText(("%d"):format(count))
        self.text:Show()
    else
        self.text:Hide()
    end
end

local function InCombat()
    return InCombatLockdown() or UnitAffectingCombat("player")
end

function Bar:GetFill()
    if self.key == "combo" then
        local settings = self:GetSettings()
        local override = settings and settings.appearance.resourceSource
        local source = self.source or ResolveClassResource(override)
        local info = source and Const.CLASS_RESOURCE_INFO[source]
        if ResourceMode(source) == "pips" then
            return ReadPipSource(source)
        end
        return nil
    end

    local current, max = ReadResource(self.key)
    return current, max
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
    elseif visibility == "WithTarget" then
        visible = UnitExists("target")
    elseif visibility == "HideWhenFull" then
        local current, max = self:GetFill()
        visible = not (current and max and max > 0 and current >= max)
    end

    if visible and self.key == "combo"
        and not ResolveClassResource(appearance.resourceSource)
    then
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

    self:Update()
end
