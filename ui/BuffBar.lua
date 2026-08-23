local addonName, ns = ...

local Const = ns.Constants
local Compat = ns.Compat

-- Optional: absent in the headless test, which never loads the library.
local LCG = _G.LibStub and LibStub("LibCustomGlow-1.0", true)

-- Mirrors Retail's CooldownViewerBuffBarItemTemplate: a 220x30 frame holding a
-- 30x30 masked icon and a 19px StatusBar, name left, time right, a pip on the
-- fill edge and the stack count in the icon corner. The bar *drains* -- its
-- value is the time left, not the time elapsed.
--
-- Const.BAR_TEMPLATE offsets are all at that native 30px height and scaled from
-- barHeight, so a resized bar keeps the art in proportion.
local BuffBar = {}
ns.BuffBar = BuffBar

local barPool = {}
local barCount = 0

local T = Const.BAR_TEMPLATE

BuffBar.art = {
    bar   = Compat.AtlasExists(Const.ART.bar),
    barBG = Compat.AtlasExists(Const.ART.barBG),
    pip   = Compat.AtlasExists(Const.ART.barPip),
}

local function OnEnter(self)
    if not self.spellID then return end
    local group = ns.DB:GetGroup(self.groupKey)
    if group and group.appearance.showTooltips == false then return end

    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    Compat.SetTooltipForTracked(GameTooltip, self.spellID)
    GameTooltip:Show()
end

local function OnLeave()
    GameTooltip:Hide()
end

local function CreateBar(parent)
    barCount = barCount + 1

    local frame = CreateFrame("Frame", "CDMCBuffBar" .. barCount, parent)
    frame:SetSize(T.itemHeight * 220 / 30, T.itemHeight)

    -- A frame rather than a bare texture: the mask, bevel and stack count all
    -- anchor to it as a unit, as the template nests them under $parent.Icon.
    local iconFrame = CreateFrame("Frame", nil, frame)
    iconFrame:SetPoint("LEFT")
    frame.iconFrame = iconFrame

    frame.texture = iconFrame:CreateTexture(nil, "ARTWORK")
    frame.texture:SetAllPoints()

    if ns.Icon.art.mask and iconFrame.CreateMaskTexture then
        local mask = iconFrame:CreateMaskTexture()
        mask:SetAllPoints()
        mask:SetAtlas(Const.ART.mask)
        if frame.texture.AddMaskTexture then
            frame.texture:AddMaskTexture(mask)
            frame.mask = mask
        end
    end

    if not frame.mask then
        frame.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    if ns.Icon.art.iconOverlay then
        frame.overlay = iconFrame:CreateTexture(nil, "OVERLAY")
        frame.overlay:SetAtlas(Const.ART.iconOverlay)
    end

    frame.countText = iconFrame:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    frame.countText:SetJustifyH("RIGHT")

    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    frame.bar = bar

    local fill = bar:CreateTexture(nil, "ARTWORK")
    if BuffBar.art.bar then
        fill:SetAtlas(Const.ART.bar)
    else
        fill:SetTexture(Const.FALLBACK_BAR_TEXTURE)
    end
    bar:SetStatusBarTexture(fill)
    -- Kept so Configure can swap in a LibSharedMedia texture and restore the
    -- built-in one when the choice is cleared.
    frame.fillTexture = fill

    local background = bar:CreateTexture(nil, "BACKGROUND")
    if BuffBar.art.barBG then
        background:SetAtlas(Const.ART.barBG)
    else
        background:SetColorTexture(0, 0, 0, 0.6)
    end
    frame.barBG = background

    -- Anchored to the fill texture, not the bar: it rides the leading edge.
    local pip = bar:CreateTexture(nil, "OVERLAY")
    if BuffBar.art.pip then
        pip:SetAtlas(Const.ART.barPip, true)
    else
        pip:SetColorTexture(1, 1, 1, 0.9)
    end
    pip:Hide()
    frame.pip = pip

    frame.nameText = bar:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    frame.nameText:SetJustifyH("LEFT")
    frame.nameText:SetJustifyV("MIDDLE")
    frame.nameText:SetWordWrap(false)

    frame.timeText = bar:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    frame.timeText:SetJustifyH("LEFT")

    frame:SetScript("OnEnter", OnEnter)
    frame:SetScript("OnLeave", OnLeave)

    return frame
end

function BuffBar:Acquire(parent, groupKey)
    local frame = table.remove(barPool)
    if not frame then
        frame = CreateBar(parent)
    else
        frame:SetParent(parent)
    end

    frame.groupKey = groupKey
    frame:Show()
    return frame
end

function BuffBar:Release(frame)
    -- Stop any proc glow first, or the bar returns to the pool still glowing and
    -- reappears lit when reused for an unrelated spell.
    self:SetGlow(frame, false)
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetParent(UIParent)
    frame.spellID = nil
    frame.entry = nil
    frame.groupKey = nil
    frame.lastTimeText = nil
    barPool[#barPool + 1] = frame
end

-- Starts or stops the proc / activation glow on a bar. A bar is a rectangle, so
-- ButtonGlow (built for square action buttons) does not fit -- PixelGlow traces
-- an animated border around the whole frame instead. No-ops when the state is
-- unchanged so a running glow is not restarted every refresh tick.
function BuffBar:SetGlow(frame, shown)
    shown = shown and true or false
    if frame.glowing == shown then return end
    frame.glowing = shown

    -- Observable without the glow library, which the headless test does not load.
    frame.glowRequested = shown

    if not (LCG and LCG.PixelGlow_Start) then return end

    if shown then
        LCG.PixelGlow_Start(frame, nil, nil, nil, nil, nil, nil, nil, false, "cdmc")
    else
        LCG.PixelGlow_Stop(frame, "cdmc")
    end
end

function BuffBar:GetItemSize(appearance)
    local height = appearance.barHeight or T.itemHeight
    local width = appearance.barWidth or 220
    return width, height
end

-- Blizzard's SetBarContent. Hiding the icon slides the bar left into the space
-- it occupied rather than leaving a gap.
local function ApplyBarContent(frame, content, scale)
    local showIcon = content ~= "Name Only"
    local showName = content ~= "Icon Only"

    frame.iconFrame:SetShown(showIcon)
    frame.nameText:SetShown(showName)

    frame.bar:ClearAllPoints()
    if showIcon then
        frame.bar:SetPoint("LEFT", frame.iconFrame, "RIGHT", T.iconGap * scale, 0)
    else
        frame.bar:SetPoint("LEFT", frame, "LEFT", 0, 0)
    end
    frame.bar:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    frame.bar:SetHeight(T.barHeight * scale)
end

local function ApplyFont(fontString, fontObject, size, fontFace)
    if fontObject and _G[fontObject] then
        fontString:SetFontObject(_G[fontObject])
    end

    local file, _, flags = fontString:GetFont()
    file = ns.Media.Fetch("font", fontFace, file)
    if file and size then
        fontString:SetFont(file, size, flags)
    end
end

function BuffBar:Configure(frame, entry, spellID, appearance, groupKey)
    frame.entry = entry
    frame.spellID = spellID
    frame.groupKey = groupKey or frame.groupKey

    local width, height = self:GetItemSize(appearance)
    local scale = height / T.itemHeight

    frame:SetSize(width, height)
    frame.iconFrame:SetSize(height, height)

    local texture = ns.Spellbook:GetIcon(spellID)
    frame.texture:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")

    if frame.overlay then
        frame.overlay:ClearAllPoints()
        frame.overlay:SetPoint("TOPLEFT", -T.overlayInsetX * scale, T.overlayInsetY * scale)
        frame.overlay:SetPoint("BOTTOMRIGHT", T.overlayInsetX * scale, -T.overlayInsetY * scale)
    end

    frame.countText:ClearAllPoints()
    frame.countText:SetPoint("BOTTOMRIGHT", frame.iconFrame, "BOTTOMRIGHT",
        T.applicationsX * scale, T.applicationsY * scale)

    ApplyBarContent(frame, appearance.barContent or "Icon and Name", scale)

    -- Reapplied on every Configure because frame levels are absolute and the
    -- widget is pooled across parents. The icon sits above the bar so the bevel
    -- overlaps its left edge rather than being cut by it.
    local base = frame:GetFrameLevel()
    frame.bar:SetFrameLevel(base + 1)
    frame.iconFrame:SetFrameLevel(base + 2)

    local barHeight = T.barHeight * scale
    frame.barBG:ClearAllPoints()
    frame.barBG:SetPoint("TOPLEFT", frame.bar, "TOPLEFT", T.bgInsetLeft * scale, T.bgInsetTop * scale)
    frame.barBG:SetPoint("BOTTOMRIGHT", frame.bar, "BOTTOMRIGHT", T.bgInsetRight * scale, T.bgInsetBottom * scale)

    local fill = Const.BAR_FILL_COLOR
    frame.bar:SetStatusBarColor(fill[1], fill[2], fill[3])

    -- A LibSharedMedia bar texture overrides the atlas / fallback chosen at
    -- build; clearing the choice restores the built-in look.
    local barPath = ns.Media.Fetch("statusbar", appearance.barTexture)
    if barPath then
        frame.fillTexture:SetTexture(barPath)
    elseif BuffBar.art.bar then
        frame.fillTexture:SetAtlas(Const.ART.bar)
    else
        frame.fillTexture:SetTexture(Const.FALLBACK_BAR_TEXTURE)
    end

    if not BuffBar.art.pip then
        -- The atlas carries its own size; the fallback needs one given to it.
        frame.pip:SetSize(math.max(2, 2 * scale), barHeight + 4 * scale)
    end

    frame.pip:ClearAllPoints()
    frame.pip:SetPoint("CENTER", frame.bar:GetStatusBarTexture(), "RIGHT", 0, -1 * scale)

    frame.nameText:ClearAllPoints()
    frame.nameText:SetPoint("TOPLEFT", frame.bar, "TOPLEFT", T.nameInsetLeft * scale, 0)
    frame.nameText:SetPoint("BOTTOMRIGHT", frame.bar, "BOTTOMRIGHT", T.nameInsetRight * scale, 0)

    frame.timeText:ClearAllPoints()
    frame.timeText:SetPoint("RIGHT", frame.bar, "RIGHT", T.durationInset * scale, 0)

    local fontSize = math.max(8, barHeight * 0.62)
    ApplyFont(frame.nameText, "NumberFontNormal", fontSize, appearance.fontFace)
    ApplyFont(frame.timeText, "NumberFontNormal", fontSize, appearance.fontFace)
    ApplyFont(frame.countText, appearance.countFont or "NumberFontNormalSmall",
        math.max(8, height * 0.30), appearance.fontFace)

    -- Here rather than in Update: the name only changes with the entry.
    frame.nameText:SetText(ns.Spellbook:GetName(spellID) or (entry and entry.name) or "")

    ns.SetTooltipsShown(frame, appearance.showTooltips ~= false)
end

-- Serves three cases, told apart by state.phase and the group:
--   duration bar (phase set)  effect bright, then recharge dimmed
--   tracked-buff bar (aura)   the aura's remaining duration
--   plain cooldown bar        the recharge, then full when ready
-- Returns true while counting down, so the group knows it needs the ticker.
function BuffBar:Update(frame, state, appearance)
    if not state then return false end

    local duration = state.swipeDuration or 0
    local remaining = state.remaining or 0

    -- The GCD never drives a bar: a 1.5s drain on every cast would make the
    -- column flicker. A real cooldown wins in GetState, so only GCDs land here.
    if state.isGCD then
        duration, remaining = 0, 0
    end

    local fill = Const.BAR_FILL_COLOR
    local iconDesaturate = false
    local iconTint                 -- nil means full colour
    local timerRemaining = 0

    if state.phase then
        local effectOnly = appearance.barMode == "Effect Only"

        if state.phase == "active" then
            if duration > 0 then
                frame.bar:SetMinMaxValues(0, duration)
                frame.bar:SetValue(remaining)
                frame.pip:Show()
                timerRemaining = remaining
            else
                -- Permanent effect, no timer.
                frame.bar:SetMinMaxValues(0, 1)
                frame.bar:SetValue(1)
                frame.pip:Hide()
            end
        elseif state.phase == "cooldown" and not effectOnly then
            -- Dimmed and greyed, so it ranks below an ability that is up.
            frame.bar:SetMinMaxValues(0, duration > 0 and duration or 1)
            frame.bar:SetValue(remaining)
            frame.pip:Show()
            fill = Const.BAR_COOLDOWN_COLOR
            iconDesaturate = appearance.desaturateUnavailable ~= false
            iconTint = Const.ITEM_COLORS.notUsable
            timerRemaining = remaining
        else
            -- Ready, or Effect Only with nothing up. Hybrid fills bright to
            -- signal "available"; Effect Only reserves the bar for the effect,
            -- so it stays empty until that is back.
            local ready = state.phase == "ready"
            frame.bar:SetMinMaxValues(0, 1)
            frame.bar:SetValue((ready and not effectOnly) and 1 or 0)
            frame.pip:Hide()
            if not ready then
                iconDesaturate = appearance.desaturateUnavailable ~= false
                iconTint = Const.ITEM_COLORS.notUsable
            end
        end

        frame.bar:SetStatusBarColor(fill[1], fill[2], fill[3])
    else
        local isAura = Const.AURA_GROUPS[frame.groupKey]

        if duration > 0 and remaining > 0 then
            frame.bar:SetMinMaxValues(0, duration)
            frame.bar:SetValue(remaining)
            frame.pip:Show()
            timerRemaining = remaining
        elseif isAura then
            -- Deliberately unlike Blizzard, who leave a timerless aura's bar
            -- empty -- a rarity on Retail. In Classic half the tracked buffs
            -- are permanent (stances, aspects, Thorns) and an empty bar reads
            -- as "expired", so a timerless aura fills instead.
            frame.bar:SetMinMaxValues(0, 1)
            frame.bar:SetValue(state.active and 1 or 0)
            frame.pip:Hide()
        else
            frame.bar:SetMinMaxValues(0, 1)
            frame.bar:SetValue(1)
            frame.pip:Hide()
        end

        if not isAura then
            iconDesaturate = appearance.desaturateUnavailable ~= false and not state.available
            local colors = Const.ITEM_COLORS
            if appearance.colorByUsability == false then
                iconTint = state.available and colors.usable or colors.notUsable
            elseif state.usable then
                iconTint = colors.usable
            elseif state.notEnoughPower then
                iconTint = colors.notEnoughPower
            else
                iconTint = colors.notUsable
            end
        end
    end

    if frame.texture.SetDesaturated then frame.texture:SetDesaturated(iconDesaturate) end
    if iconTint then
        frame.texture:SetVertexColor(iconTint[1], iconTint[2], iconTint[3])
    else
        frame.texture:SetVertexColor(1, 1, 1)
    end

    local showText = appearance.showCountdownText ~= false and not state.suppressText
    if showText and timerRemaining > 0 then
        -- Only touched when the rendered string changes; see Icon:Update.
        local text = ns.FormatTime(timerRemaining)
        if frame.lastTimeText ~= text then
            frame.timeText:SetText(text)
            frame.lastTimeText = text
        end

        if timerRemaining <= 5 then
            local c = Const.COLORS.expiring
            frame.timeText:SetTextColor(c[1], c[2], c[3])
        else
            frame.timeText:SetTextColor(1, 1, 1)
        end
        frame.timeText:Show()
    else
        frame.timeText:Hide()
        frame.lastTimeText = nil
    end

    local count = state.charges
    if count and count > 1 then
        frame.countText:SetText(count)
        frame.countText:Show()
    else
        frame.countText:Hide()
    end

    return timerRemaining > 0
end
