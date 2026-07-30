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
    local source
    if override == "none" then
        return nil
    elseif override and Const.CLASS_RESOURCE_INFO[override] then
        source = override
    else
        local _, classToken = UnitClass("player")
        source = Const.CLASS_RESOURCE_SOURCE[classToken or ""]
    end

    -- Maelstrom Weapon only exists in Season of Discovery. Gate it whether the
    -- source was auto-detected or pinned by a profile, so a non-SoD character
    -- never shows an always-empty Maelstrom bar.
    if source == "maelstrom" and not ns.Compat.isSoD then
        return nil
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
    self.statusBar:SetStatusBarTexture(ns.Media.Fetch("statusbar", appearance.barTexture, BAR_TEXTURE))

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
            self:LayoutPips(width, height, appearance, maxPoints)
        else
            self.statusBar:Show()
            for _, pip in ipairs(self.pips) do pip:Hide() end
        end
    else
        self.statusBar:Show()
        for _, pip in ipairs(self.pips) do pip:Hide() end
    end

    self:ApplyPosition()
    self:UpdateVisibility()
    self:Update()
end

function Bar:LayoutPips(width, height, appearance, maxPoints)
    self.statusBar:Hide()

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
    self.statusBar:SetMinMaxValues(0, math.max(max, 1))
    self.statusBar:SetValue(current)

    if appearance.showText ~= false and max > 0 then
        self.text:SetText(("%d / %d"):format(current, max))
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
        for _, pip in ipairs(self.pips) do pip:Hide() end
        self.text:Hide()
        return
    end

    if info.mode == "pips" then
        local current, max = ReadPipSource(source)
        local empty = Const.COMBO_COLORS.empty

        -- Combo keeps its warm-up gradient (hue says whether to spend); other
        -- pip sources use their own flat fill colour.
        local fill
        if source == "combo" then
            local colors = Const.COMBO_COLORS
            fill = colors.building
            if current >= max then
                fill = colors.full
            elseif current == max - 1 then
                fill = colors.nearlyFull
            end
        else
            fill = Const.MAELSTROM_COLOR
        end

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
    self.statusBar:SetMinMaxValues(0, size)
    self.statusBar:SetValue(within)

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
