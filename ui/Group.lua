local addonName, ns = ...

local Const = ns.Constants

local Group = {}
Group.__index = Group
ns.Group = Group

ns.groups = {}

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

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

    -- Shown only while the group is unlocked or Edit Mode is active.
    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("BOTTOM", frame, "TOP", 0, 4)
    label:SetText(Const.GROUP_LABELS[key] or key)
    label:Hide()
    self.label = label

    ns.groups[key] = self
    return self
end

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

-- Which of the frame's own corners stays put as icons are added or removed.
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

--- Records where the frame currently sits. Called after a drag finishes.
function Group:SavePosition()
    local settings = self:GetSettings()
    if not settings then return end

    local point, _, relativePoint, x, y = self.frame:GetPoint(1)
    if not point then return end

    -- The parent is always UIParent, so only the offsets and the relative
    -- corner are worth persisting.
    settings.position.point = point
    settings.position.relativePoint = relativePoint or "CENTER"
    settings.position.x = math.floor(x + 0.5)
    settings.position.y = math.floor(y + 0.5)
end

--- Changing growth changes which corner the frame is anchored by, so the
--- offsets are rewritten to keep the group visually where it was.
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

-- Shown above each group while it is being moved, so it is obvious which way
-- the row will expand as spells are added.
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

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

--- Which widget module draws this group's entries. Retail splits tracked buffs
--- into two Edit Mode systems, icons and bars; here it is one group with a
--- display setting, so the module is chosen per layout rather than per group.
function Group:GetWidget()
    local settings = self:GetSettings()
    if Const.AURA_GROUPS[self.key]
        and settings
        and settings.appearance.display == "Bars"
    then
        return ns.BuffBar, "bars"
    end
    return ns.Icon, "icons"
end

--- Hands every live widget back to its own pool. Called with the *previous*
--- module when the display setting changes, since an icon must not be returned
--- to the bar pool or vice versa.
function Group:ReleaseAll(widget)
    widget = widget or self.widget or ns.Icon
    for i = #self.icons, 1, -1 do
        widget:Release(self.icons[i])
        self.icons[i] = nil
    end
end

--- Rebuilds the icon row from the profile. Entries the character cannot cast
--- are skipped rather than removed, so unlearned ranks and unequipped runes
--- reappear on their own.
function Group:Layout()
    local settings = self:GetSettings()
    if not settings then return end

    local appearance = settings.appearance
    local spacing = appearance.spacing or Const.DEFAULT_APPEARANCE.spacing

    -- Switching between icons and bars empties the row first: the two widgets
    -- come from separate pools and are not interchangeable.
    local widget, widgetKind = self:GetWidget()
    if widgetKind ~= self.widgetKind then
        self:ReleaseAll(self.widget)
        self.widgetKind = widgetKind
    end
    self.widget = widget

    local itemWidth, itemHeight = widget:GetItemSize(appearance)

    -- Tracked buffs can be set to occupy the bar only while they are active, in
    -- which case the row collapses around whatever is currently up.
    -- While unlocked every tracked buff is shown regardless of whether it is
    -- currently on the player. Otherwise adding a buff that is not up right now
    -- renders nothing at all, which is indistinguishable from it being broken,
    -- and an all-inactive group cannot be positioned.
    local isAuraGroup = Const.AURA_GROUPS[self.key]
    local hideInactive = isAuraGroup
        and appearance.hideWhenInactive ~= false
        and not self.unlocked

    local resolved = {}
    for _, entry in ipairs(settings.spells) do
        local spellID = ns.Spellbook:ResolveForGroup(entry, isAuraGroup)
        if spellID and not (hideInactive and not ns.Auras:GetState(spellID).active) then
            resolved[#resolved + 1] = { entry = entry, spellID = spellID }
        end
    end

    -- Recorded so Update can tell when the active set changed and relayout.
    self.activeKey = self:ComputeActiveKey()

    -- Return any widgets beyond the new count to the pool.
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

    -- Split the icons across `rows` lines. With Horizontal orientation those
    -- lines run left-to-right and stack vertically; with Vertical they run
    -- top-to-bottom and stack horizontally.
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

        -- Reverse the stacking axis so extra lines grow the other way.
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

--------------------------------------------------------------------------------
-- Visibility
--------------------------------------------------------------------------------

local function InCombat()
    return InCombatLockdown() or UnitAffectingCombat("player")
end

--- Applies opacity and the visibility rule. Kept separate from Layout so the
--- combat events can call it without rebuilding every icon.
function Group:UpdateVisibility()
    local settings = self:GetSettings()
    if not settings then return end

    local appearance = settings.appearance
    self.frame:SetAlpha((appearance.opacity or 100) / 100)

    -- While the group is being moved it always stays visible, otherwise it
    -- could vanish from under the cursor mid-drag.
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

--------------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------------

--- A fingerprint of which tracked auras are currently active, used to notice
--- when a hide-when-inactive group needs rebuilding.
function Group:ComputeActiveKey()
    local settings = self:GetSettings()
    if not settings or not Const.AURA_GROUPS[self.key] then return 0 end
    if settings.appearance.hideWhenInactive == false then return 0 end

    -- A running numeric hash rather than a table plus table.concat: this runs on
    -- every update tick, and building a string there is needless garbage.
    local hash = 0
    for _, entry in ipairs(settings.spells) do
        local spellID = ns.Spellbook:ResolveForGroup(entry, true)
        if spellID and ns.Auras:GetState(spellID).active then
            hash = (hash * 31 + spellID) % 2147483647
        end
    end
    return hash
end

--- Refreshes every icon. Returns true if anything is counting down and the
--- group therefore needs the periodic ticker.
function Group:Update()
    local settings = self:GetSettings()
    if not settings or settings.enabled == false then return false end

    -- A buff coming or going changes which icons belong in the row, so the
    -- group is rebuilt before the per-icon refresh below.
    if Const.AURA_GROUPS[self.key]
        and settings.appearance.hideWhenInactive ~= false
        and not self.unlocked
    then
        if self:ComputeActiveKey() ~= self.activeKey then
            self:Layout()
        end
    end

    local tracker = Const.AURA_GROUPS[self.key] and ns.Auras or ns.Cooldowns
    local appearance = settings.appearance
    local animating = false

    local widget = self.widget or ns.Icon
    for _, icon in ipairs(self.icons) do
        if icon.spellID then
            local state = tracker:GetState(icon.spellID, appearance.showGCD)
            if widget:Update(icon, state, appearance) then
                animating = true
            end
        end
    end

    return animating
end

--------------------------------------------------------------------------------
-- Unlocked (drag) mode
--------------------------------------------------------------------------------

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

--- Clicking a group while it is unlocked opens that group's settings panel,
--- which is how Blizzard's Edit Mode selects a system.
local function OnMouseUp(frame)
    if frame.cdmcGroup and frame.cdmcGroup.unlocked then
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
