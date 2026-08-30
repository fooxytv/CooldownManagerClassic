local addonName, ns = ...

local Const = ns.Constants
local Compat = ns.Compat

local LCG = _G.LibStub and LibStub("LibCustomGlow-1.0", true)
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

local function OnMouseUp(self, button)
    if button ~= "RightButton" or not self.entry or not ns.EntryMenu then return end
    ns.EntryMenu.Show("cursor", {
        entry = self.entry,
        groupKey = self.groupKey,
        allowMove = true,
        allowAdd = true,
        onChanged = function() ns.Core:RefreshAll() end,
    })
end

local function OnEnter(self)
    if not self.spellID then return end
    local group = ns.DB:GetGroup(self.groupKey)
    if group and group.appearance.showTooltips == false then return end

    Compat.AnchorTooltip(GameTooltip, self, group and group.appearance.tooltipAnchor)
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
    frame.fillTexture = fill

    local background = bar:CreateTexture(nil, "BACKGROUND")
    if BuffBar.art.barBG then
        background:SetAtlas(Const.ART.barBG)
    else
        background:SetColorTexture(0, 0, 0, 0.6)
    end
    frame.barBG = background

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
    frame:SetScript("OnMouseUp", OnMouseUp)

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
    self:SetQueued(frame, false)
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetParent(UIParent)
    frame.spellID = nil
    frame.entry = nil
    frame.groupKey = nil
    frame.lastTimeText = nil
    barPool[#barPool + 1] = frame
end

function BuffBar:SetGlow(frame, shown)
    shown = shown and true or false
    if frame.glowing == shown then return end
    frame.glowing = shown
    frame.glowRequested = shown

    if not (LCG and LCG.PixelGlow_Start) then return end

    if shown then
        LCG.PixelGlow_Start(frame, nil, nil, nil, nil, nil, nil, nil, false, "cdmc")
    else
        LCG.PixelGlow_Stop(frame, "cdmc")
    end
end

function BuffBar:SetQueued(frame, shown)
    shown = shown and true or false
    if frame.queued == shown then return end
    frame.queued = shown

    if not (LCG and LCG.AutoCastGlow_Start) then return end

    if shown then
        LCG.AutoCastGlow_Start(frame, Const.QUEUED_GLOW_COLOR, nil, nil, nil, nil, nil, "cdmc-queued")
    else
        LCG.AutoCastGlow_Stop(frame, "cdmc-queued")
    end
end

function BuffBar:GetItemSize(appearance)
    local height = appearance.barHeight or T.itemHeight
    local width = appearance.barWidth or 220
    return width, height
end

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

    local base = frame:GetFrameLevel()
    frame.bar:SetFrameLevel(base + 1)
    frame.iconFrame:SetFrameLevel(base + 2)

    local barHeight = T.barHeight * scale
    frame.barBG:ClearAllPoints()
    frame.barBG:SetPoint("TOPLEFT", frame.bar, "TOPLEFT", T.bgInsetLeft * scale, T.bgInsetTop * scale)
    frame.barBG:SetPoint("BOTTOMRIGHT", frame.bar, "BOTTOMRIGHT", T.bgInsetRight * scale, T.bgInsetBottom * scale)

    local fill = Const.BAR_FILL_COLOR
    frame.bar:SetStatusBarColor(fill[1], fill[2], fill[3])

    local barPath = ns.Media.Fetch("statusbar", appearance.barTexture)
    if barPath then
        frame.fillTexture:SetTexture(barPath)
    elseif BuffBar.art.bar then
        frame.fillTexture:SetAtlas(Const.ART.bar)
    else
        frame.fillTexture:SetTexture(Const.FALLBACK_BAR_TEXTURE)
    end

    if not BuffBar.art.pip then
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

    frame.nameText:SetText(ns.Spellbook:GetName(spellID) or (entry and entry.name) or "")

    ns.SetTooltipsShown(frame, appearance.showTooltips ~= false, appearance.rightClickMenu == true)
end

function BuffBar:Update(frame, state, appearance)
    if not state then return false end

    local duration = state.swipeDuration or 0
    local remaining = state.remaining or 0

    if state.isGCD then
        duration, remaining = 0, 0
    end

    local fill = Const.BAR_FILL_COLOR
    local iconDesaturate = false
    local iconTint
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
                frame.bar:SetMinMaxValues(0, 1)
                frame.bar:SetValue(1)
                frame.pip:Hide()
            end
        elseif state.phase == "cooldown" and not effectOnly then
            frame.bar:SetMinMaxValues(0, duration > 0 and duration or 1)
            frame.bar:SetValue(remaining)
            frame.pip:Show()
            fill = Const.BAR_COOLDOWN_COLOR
            iconDesaturate = appearance.desaturateUnavailable ~= false
            iconTint = Const.ITEM_COLORS.notUsable
            timerRemaining = remaining
        else
            -- Nothing is running, so the bar is empty. It used to draw full for
            -- a ready ability, which is indistinguishable from a buff just cast
            -- at its full duration -- and for something with no cooldown at all,
            -- like Battle Shout, the bar was therefore at its fullest exactly
            -- when the buff had dropped.
            --
            -- Readiness is not lost by this: the icon carries it, staying bright
            -- here and dimming below. Letting the bar mean one thing -- time
            -- remaining on something -- is what stops a full bar ever lying.
            local ready = state.phase == "ready"
            frame.bar:SetMinMaxValues(0, 1)
            frame.bar:SetValue(0)
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

    -- Applied after the phase and usability chains rather than inside them: both
    -- paths above land here, and out of range outranks whatever either picked.
    -- Behind colorByUsability with the rest of the state colours, and off for
    -- aura groups -- how far away the target stands says nothing about a buff
    -- already on you. Desaturation is left alone: red over grey reads as muddy
    -- rather than urgent.
    if not Const.AURA_GROUPS[frame.groupKey]
        and appearance.colorByUsability ~= false and state.outOfRange
    then
        iconTint = Const.ITEM_COLORS.notInRange
    end

    if frame.texture.SetDesaturated then frame.texture:SetDesaturated(iconDesaturate) end
    if iconTint then
        frame.texture:SetVertexColor(iconTint[1], iconTint[2], iconTint[3])
    else
        frame.texture:SetVertexColor(1, 1, 1)
    end

    local showText = appearance.showCountdownText ~= false and not state.suppressText
    if showText and timerRemaining > 0 then
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
