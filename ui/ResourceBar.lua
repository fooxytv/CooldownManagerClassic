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
-- the GetComboPoints API is tried before the modern power type.
--
-- Deliberately not named GetComboPoints: `local function f` binds f before the
-- body compiles, so a bare call to the API inside would resolve to this
-- function and recurse until the stack blew.
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

-- The "combo" bar is adaptive: which resource it shows is chosen by class, or
-- pinned by a profile override. Returns a source key from CLASS_RESOURCE_INFO,
-- or nil when this character has no class resource to show (the bar then hides).
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

    -- Maelstrom Weapon only exists in Season of Discovery. Gate it whether the
    -- source was auto-detected or pinned by a profile, so a non-SoD character
    -- never shows an always-empty Maelstrom bar.
    if source == "maelstrom" and not ns.Compat.isSoD then
        return nil
    end

    -- Combo points only exist in cat form for a Druid, where the power is
    -- Energy. Bear (Rage) and moonkin/caster (Mana) have no combo points, so the
    -- bar would sit there as an empty pip row -- the power bar covers those forms
    -- instead. A Rogue always has Energy, so the same rule leaves it untouched.
    -- UnitPowerType is used rather than GetShapeshiftFormID: form IDs vary by
    -- client and flavour, while the power token is reliable and already drives
    -- the power bar. Applies whether the source was auto-detected or pinned.
    if source == "combo" and classToken == "DRUID" then
        local _, powerToken = UnitPowerType("player")
        if powerToken ~= "ENERGY" then return nil end
    end

    return source
end

--- Current and maximum value for a pip source (combo points or Maelstrom).
local function ReadPipSource(source)
    if source == "maelstrom" then
        return ns.Auras:StacksByName(Const.MAELSTROM_WEAPON_AURA), Const.MAELSTROM_MAX_STACKS
    end
    return ReadComboPoints(), ReadMaxComboPoints()
end

--- Splits a soul-shard total into its tier colour and how far it fills the
--- current tier. count 1..5 fills tier 1, 6..10 tier 2, and so on; the colour
--- steps each full tier and clamps at the brightest once the palette runs out.
local function SoulShardDisplay(count)
    local size = Const.SOUL_SHARD_TIER_SIZE
    local colors = Const.SOUL_SHARD_COLORS

    if count <= 0 then
        return colors[1], 0, size
    end

    -- Colour steps with each completed tier -- "how many fives" -- so an exact
    -- multiple reads as that tier's colour with a full bar rather than the
    -- previous tier's.
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
        -- UnitPowerType follows druid shapeshifts, so form changes need no
        -- class-specific handling.
        local powerType, powerToken = UnitPowerType("player")
        local current = UnitPower("player", powerType) or 0
        local max = UnitPowerMax("player", powerType) or 0
        local r, g, b = GetPowerColor(powerToken or "MANA")
        return current, max, r, g, b
    end

    -- The "combo" bar is the adaptive class-resource bar and is read in Update
    -- rather than here, because it may render as pips or as a counted bar.

    return 0, 0, 0.6, 0.6, 0.6
end

-- Value text: a percentage when asked and the resource has a maximum, otherwise
-- the "current / max" reading.
local function FormatValue(current, max, appearance)
    if appearance.showPercent and max and max > 0 then
        return ("%d%%"):format(math.floor((current / max) * 100 + 0.5))
    end
    return ("%d / %d"):format(current, max)
end

-- The fill colour for a segmented source. Combo warms up towards the finisher;
-- every other pip source takes its own flat colour.
local function PipFillColor(source, current, max)
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

    -- Four plain-texture edges make the border. Positioned/coloured in Layout,
    -- hidden when the border size is 0. No backdrop API, so nothing Retail-only.
    self.borders = {
        top    = frame:CreateTexture(nil, "BORDER"),
        bottom = frame:CreateTexture(nil, "BORDER"),
        left   = frame:CreateTexture(nil, "BORDER"),
        right  = frame:CreateTexture(nil, "BORDER"),
    }

    -- Created for every bar, but hidden for combo points, which draw as pips.
    local statusBar = CreateFrame("StatusBar", nil, frame)
    statusBar:SetAllPoints()
    statusBar:SetStatusBarTexture(BAR_TEXTURE)
    statusBar:SetMinMaxValues(0, 1)
    statusBar:SetValue(1)
    self.statusBar = statusBar

    -- A bright leading-edge spark on the fill; shown only when enabled and the
    -- bar is partway full. Additive so it reads as a glow over the fill.
    local spark = statusBar:CreateTexture(nil, "OVERLAY")
    spark:SetColorTexture(1, 1, 1, 0.85)
    spark:SetWidth(16)
    if spark.SetBlendMode then spark:SetBlendMode("ADD") end
    spark:Hide()
    self.spark = spark

    -- Tick-mark dividers for the "ticks" segment style, pooled like the pips.
    self.ticks = {}

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

-- Background colour and the solid edge border, from the packed colour strings.
function Bar:ApplyChrome(appearance)
    local br, bg, bb, ba = Const.UnpackColor(appearance.bgColor, 0, 0, 0, 0.5)
    self.frame.background:SetColorTexture(br, bg, bb, ba)

    local size = appearance.borderSize or Const.DEFAULT_BAR_APPEARANCE.borderSize
    local edges = self.borders
    if not size or size <= 0 then
        for _, tex in pairs(edges) do tex:Hide() end
        return
    end

    local r, g, b, a = Const.UnpackColor(appearance.borderColor, 0, 0, 0, 1)
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

-- Value text alignment. LEFT/RIGHT inset from the edge; CENTER centred.
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

-- Moves the spark to the fill's leading edge, or hides it.
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

-- Sets the fill, easing toward the value when animation is on and snapping
-- otherwise. The eased path rides an OnUpdate on the status bar; it stops itself
-- once it arrives, so an idle bar carries no ticker.
function Bar:SetFill(current, max, appearance)
    max = math.max(max or 1, 1)
    current = math.max(0, math.min(current or 0, max))
    self.statusBar:SetMinMaxValues(0, max)

    if appearance.animate then
        self._target = current
        if not self._animating then
            self._animating = true
            self.statusBar:SetScript("OnUpdate", function(bar, elapsed)
                local cur = bar:GetValue() or 0
                local target = self._target or cur
                local step = target - cur
                if math.abs(step) <= 0.5 then
                    bar:SetValue(target)
                    bar:SetScript("OnUpdate", nil)
                    self._animating = false
                    self:ApplySpark(target, max, appearance)
                else
                    local moved = cur + step * math.min(1, (elapsed or 0) * 8)
                    bar:SetValue(moved)
                    self:ApplySpark(moved, max, appearance)
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

    if self.key == "combo" then
        -- Resolve which resource this character's class-resource bar shows, and
        -- render as pips (combo points, Maelstrom) or a counted bar (soul
        -- shards) accordingly.
        local source = ResolveClassResource(appearance.resourceSource)
        self.source = source

        local info = source and Const.CLASS_RESOURCE_INFO[source]
        self.label:SetText((info and info.label) or Const.BAR_LABELS.combo)

        if info and info.mode == "pips" then
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

-- The tick-mark style: one continuous status bar with (maxPoints-1) divider
-- lines, instead of discrete pips. The fill and value are set in Update.
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

    -- A disabled bar still renders while unlocked. It is forced visible so it
    -- can be positioned and switched on, and an empty box gives no clue which
    -- resource it is or whether the setting took effect.
    if settings.enabled == false and not self.unlocked then return end

    local appearance = settings.appearance

    -- Re-evaluated every refresh so the dynamic rules (hide-when-full,
    -- with-target) track the resource and target changing, not just combat.
    self:UpdateVisibility()

    if self.key == "combo" then
        self:UpdateClassResource(appearance)
        return
    end

    local current, max, r, g, b = ReadResource(self.key)

    self.statusBar:SetStatusBarColor(r, g, b)
    self:SetFill(current, max, appearance)

    if appearance.showText ~= false and max > 0 then
        self.text:SetText(FormatValue(current, max, appearance))
        self.text:Show()
    else
        self.text:Hide()
    end
end

--- Refreshes the adaptive class-resource bar. Combo points and Maelstrom render
--- as pips (combo keeps the warm-up gradient); soul shards fill the status bar
--- within the current tier and print the running total.
function Bar:UpdateClassResource(appearance)
    -- Layout records the resolved source; fall back to resolving here in case
    -- Update runs first (e.g. a driving event before the first Layout).
    local source = self.source
    if source == nil then
        source = ResolveClassResource(appearance.resourceSource)
    end

    local info = source and Const.CLASS_RESOURCE_INFO[source]
    if not info then
        -- No class resource (a mage, or resourceSource "none"). Clear any stale
        -- fill so an unlocked bar in Edit Mode does not show leftover pips or a
        -- half-filled bar from a previous character/profile.
        self.statusBar:SetValue(0)
        self:HidePips()
        self:HideTicks()
        self.text:Hide()
        return
    end

    if info.mode == "pips" then
        local current, max = ReadPipSource(source)
        local fill = PipFillColor(source, current, max)

        -- Tick style: one continuous fill, coloured like the pips, with the
        -- divider ticks laid out in LayoutTicks.
        if appearance.segmentStyle == "ticks" then
            self.statusBar:SetStatusBarColor(fill[1], fill[2], fill[3])
            self:SetFill(current, max, appearance)
            self.text:Hide()
            return
        end

        local empty = Const.COMBO_COLORS.empty
        for index, pip in ipairs(self.pips) do
            if index <= current then
                pip:SetColorTexture(fill[1], fill[2], fill[3], 1)
            else
                pip:SetColorTexture(empty[1], empty[2], empty[3], empty[4])
            end
        end
        self.text:Hide()
        return
    end

    -- Counted bar: soul shards.
    local count = ns.Compat.GetItemCount(Const.SOUL_SHARD_ITEM_ID)
    local color, within, size = SoulShardDisplay(count)

    self.statusBar:SetStatusBarColor(color[1], color[2], color[3])
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

-- Current and maximum value, for the "hide when full" rule. Soul shards have no
-- fixed maximum, so they report nil and are never treated as full.
function Bar:GetFill()
    if self.key == "combo" then
        local settings = self:GetSettings()
        local override = settings and settings.appearance.resourceSource
        local source = self.source or ResolveClassResource(override)
        local info = source and Const.CLASS_RESOURCE_INFO[source]
        if info and info.mode == "pips" then
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

    -- The adaptive class-resource bar hides itself for a character with no class
    -- resource at all (a mage, say), rather than sitting there empty.
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

-- Clicking a bar while unlocked opens its settings panel, mirroring how the
-- icon groups open EditModePanel.
local function OnMouseUp(frame)
    if frame.cdmcBar and frame.cdmcBar.unlocked and ns.BarPanel then
        ns.BarPanel:Show(frame.cdmcBar.key)
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
    frame:SetScript("OnMouseUp", unlocked and OnMouseUp or nil)

    self.label:SetShown(unlocked)
    self:UpdateVisibility()

    -- Contents too, not just visibility: a disabled bar renders nothing, so
    -- unlocking one would otherwise reveal an empty box.
    self:Update()
end
