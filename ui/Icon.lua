local addonName, ns = ...

local Const = ns.Constants
local Compat = ns.Compat

local Icon = {}
ns.Icon = Icon

local iconPool = {}
local iconCount = 0

local LCG = _G.LibStub and LibStub("LibCustomGlow-1.0", true)

local AtlasExists = Compat.AtlasExists

Icon.art = {
    mask        = AtlasExists(Const.ART.mask),
    iconOverlay = AtlasExists(Const.ART.iconOverlay),
    oorShadow   = AtlasExists(Const.ART.oorShadow),
}
Icon.art.available = Icon.art.mask or Icon.art.iconOverlay

local function FormatTime(seconds)
    if seconds >= 3600 then
        return ("%dh"):format(math.ceil(seconds / 3600))
    elseif seconds >= 60 then
        return ("%dm"):format(math.ceil(seconds / 60))
    elseif seconds >= 10 then
        return ("%d"):format(math.ceil(seconds))
    end
    return ("%.1f"):format(seconds)
end
ns.FormatTime = FormatTime

function ns.SetTooltipsShown(frame, shown, clickable)
    clickable = clickable and true or false
    if frame.SetMouseClickEnabled then
        frame:SetMouseClickEnabled(clickable)
    end

    local wantsMouse = shown or clickable
    if frame.SetMouseMotionEnabled then
        frame:SetMouseMotionEnabled(shown and true or false)
        if not frame.SetMouseClickEnabled then
            frame:EnableMouse(wantsMouse and true or false)
        end
    else
        frame:EnableMouse(wantsMouse and true or false)
    end
end

local function OnMouseUp(self, button)
    if button ~= "RightButton" or not self.entry then return end
    if not ns.EntryMenu then return end
    ns.EntryMenu.Show("cursor", {
        entry = self.entry,
        groupKey = self.groupKey,
        allowMove = true,
        onChanged = function() ns.Core:RefreshAll() end,
    })
end

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

local function CreateIcon(parent)
    iconCount = iconCount + 1

    local frame = CreateFrame("Frame", "CDMCIcon" .. iconCount, parent)
    frame:SetSize(40, 40)

    frame.texture = frame:CreateTexture(nil, "ARTWORK")
    frame.texture:SetAllPoints()

    if Icon.art.mask and frame.CreateMaskTexture then
        local mask = frame:CreateMaskTexture()
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

    frame.cooldown = CreateFrame("Cooldown", "$parentCooldown", frame, "CooldownFrameTemplate")
    frame.cooldown:SetAllPoints()
    frame.cooldown:SetDrawBling(false)
    if frame.cooldown.SetHideCountdownNumbers then
        frame.cooldown:SetHideCountdownNumbers(true)
    end
    if Icon.art.available then
        if frame.cooldown.SetSwipeTexture then
            frame.cooldown:SetSwipeTexture(Const.ART.swipe)
        end
        if frame.cooldown.SetEdgeTexture then
            frame.cooldown:SetEdgeTexture(Const.ART.edge)
        end
    end

    if Icon.art.iconOverlay then
        frame.overlay = frame:CreateTexture(nil, "OVERLAY")
        frame.overlay:SetAtlas(Const.ART.iconOverlay)
    end

    frame.border = frame:CreateTexture(nil, "OVERLAY")
    frame.border:SetPoint("TOPLEFT", -2, 2)
    frame.border:SetPoint("BOTTOMRIGHT", 2, -2)
    frame.border:SetColorTexture(1, 1, 1, 1)
    frame.border:Hide()

    frame.timeText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightOutline")
    frame.timeText:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.timeText:SetJustifyH("CENTER")

    frame.countText = frame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    frame.countText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)

    frame.keybindText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
    frame.keybindText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    frame.keybindText:SetJustifyH("RIGHT")
    frame.keybindText:Hide()

    frame:SetScript("OnEnter", OnEnter)
    frame:SetScript("OnLeave", OnLeave)
    frame:SetScript("OnMouseUp", OnMouseUp)

    return frame
end

function Icon:Acquire(parent, groupKey)
    local frame = table.remove(iconPool)
    if not frame then
        frame = CreateIcon(parent)
    else
        frame:SetParent(parent)
    end

    frame.groupKey = groupKey
    frame:Show()
    return frame
end

function Icon:Release(frame)
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetParent(UIParent)
    frame.spellID = nil
    frame.entry = nil
    frame.groupKey = nil
    self:SetGlow(frame, false)
    self:SetQueued(frame, false)
    frame.cooldown:Clear()
    iconPool[#iconPool + 1] = frame
end

function Icon:SetGlow(frame, shown)
    shown = shown and true or false
    if frame.glowing == shown then return end
    frame.glowing = shown

    frame.glowRequested = shown

    if shown then
        if LCG and LCG.ButtonGlow_Start then
            LCG.ButtonGlow_Start(frame, nil, 0.25)
        else
            frame.border:SetColorTexture(1, 0.82, 0.10, 1)
            frame.border:Show()
        end
    else
        if LCG and LCG.ButtonGlow_Stop then
            LCG.ButtonGlow_Stop(frame)
        end
        frame.border:Hide()
    end
end

function Icon:SetQueued(frame, shown)
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

local function ApplyFont(fontString, fontObject, fallbackSize, fontFace)
    if fontObject and _G[fontObject] then
        fontString:SetFontObject(_G[fontObject])
    end

    local file, _, flags = fontString:GetFont()
    file = ns.Media.Fetch("font", fontFace, file)
    if file and fallbackSize then
        fontString:SetFont(file, fallbackSize, flags)
    end
end

function Icon:Configure(frame, entry, spellID, appearance, groupKey)
    frame.entry = entry
    frame.spellID = spellID
    frame.groupKey = groupKey or frame.groupKey

    local texture = ns.Spellbook:GetIcon(spellID)
    frame.texture:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")

    local size = appearance.iconSize or Const.DEFAULT_APPEARANCE.iconSize
    frame:SetSize(size, size)

    if frame.overlay then
        local base = Const.GROUP_APPEARANCE[frame.groupKey]
        local scale = (base and base.iconSize and base.iconSize > 0) and (size / base.iconSize) or 1
        local insetX = (appearance.overlayInsetX or 8) * scale
        local insetY = (appearance.overlayInsetY or 7) * scale

        frame.overlay:ClearAllPoints()
        frame.overlay:SetPoint("TOPLEFT", -insetX, insetY)
        frame.overlay:SetPoint("BOTTOMRIGHT", insetX, -insetY)
    end

    local isAura = Const.AURA_GROUPS[frame.groupKey]
    local windsDown = isAura or (entry and entry.trackDebuff)
    if frame.cooldown.SetReverse then
        frame.cooldown:SetReverse(windsDown and true or false)
    end

    ApplyFont(frame.timeText, appearance.timeFont, math.max(9, size * 0.42), appearance.fontFace)
    ApplyFont(frame.countText, appearance.countFont, math.max(8, size * 0.30), appearance.fontFace)
    ApplyFont(frame.keybindText, "GameFontHighlightSmallOutline", math.max(8, size * 0.34), appearance.fontFace)

    if appearance.showKeybind and not Const.AURA_GROUPS[frame.groupKey] then
        local key = ns.Keybinds:Get(spellID)
        frame.keybindText:SetText(key or "")
        frame.keybindText:SetShown(key ~= nil)
    else
        frame.keybindText:Hide()
    end

    ns.SetTooltipsShown(frame, appearance.showTooltips ~= false, appearance.rightClickMenu == true)
end

function Icon:GetItemSize(appearance)
    local size = appearance.iconSize or Const.DEFAULT_APPEARANCE.iconSize
    return size, size
end

function Icon:Update(frame, state, appearance)
    if not state then return false end

    if state.swipeDuration and state.swipeDuration > 0 then
        if frame.cooldown.SetSwipeColor then
            local color
            if state.isGCD then
                color = Const.GCD_SWIPE_COLOR
            elseif state.aura then
                color = Const.BUFF_SWIPE_COLOR
            else
                color = Const.COOLDOWN_SWIPE_COLOR
            end
            local scale = (appearance.swipeOpacity or 100) / 100
            frame.cooldown:SetSwipeColor(color[1], color[2], color[3], color[4] * scale)
        end

        if frame.cooldown.SetDrawSwipe then
            frame.cooldown:SetDrawSwipe(true)
        end
        if frame.cooldown.SetDrawEdge then
            frame.cooldown:SetDrawEdge(false)
        end

        frame.cooldown:SetCooldown(state.swipeStart, state.swipeDuration, state.swipeModRate)
    else
        frame.cooldown:Clear()
    end

    if Const.AURA_GROUPS[frame.groupKey] then
        if frame.texture.SetDesaturated then
            frame.texture:SetDesaturated(false)
        end
        frame.texture:SetVertexColor(1, 1, 1)
    else
        local desaturate = appearance.desaturateUnavailable ~= false and not state.available
        if frame.texture.SetDesaturated then
            frame.texture:SetDesaturated(desaturate)
        end

        local colors = Const.ITEM_COLORS
        local tint
        if appearance.colorByUsability == false then
            tint = state.available and colors.usable or colors.notUsable
        elseif state.usable then
            tint = colors.usable
        elseif state.notEnoughPower then
            tint = colors.notEnoughPower
        else
            tint = colors.notUsable
        end
        frame.texture:SetVertexColor(tint[1], tint[2], tint[3])
    end

    if not frame.glowing then
        frame.border:Hide()
    end

    local showText = appearance.showCountdownText ~= false and not state.suppressText
    if showText and state.remaining and state.remaining > 0 then
        local text = FormatTime(state.remaining)
        if frame.lastTimeText ~= text then
            frame.timeText:SetText(text)
            frame.lastTimeText = text
        end

        if state.remaining <= 5 then
            local c = Const.COLORS.expiring
            frame.timeText:SetTextColor(c[1], c[2], c[3])
        else
            frame.timeText:SetTextColor(1, 1, 1)
        end
        frame.timeText:Show()
    else
        frame.timeText:Hide()
    end

    local count = state.charges
    if count and count > 1 then
        frame.countText:SetText(count)
        frame.countText:Show()
    else
        frame.countText:Hide()
    end

    return (state.remaining or 0) > 0
end
