local addonName, ns = ...

local Const = ns.Constants
local Compat = ns.Compat

local Icon = {}
ns.Icon = Icon

local iconPool = {}
local iconCount = 0

-- Probed once. A missing atlas renders an invisible texture, so the icon falls
-- back to a plain trimmed square instead -- see Compat.AtlasExists.
local AtlasExists = Compat.AtlasExists

Icon.art = {
    mask        = AtlasExists(Const.ART.mask),
    iconOverlay = AtlasExists(Const.ART.iconOverlay),
    oorShadow   = AtlasExists(Const.ART.oorShadow),
}
Icon.art.available = Icon.art.mask or Icon.art.iconOverlay

-- Ceil, not round: the displayed time must never be less than what remains.
-- Rounding read "1m" at 89 seconds left, and under-promising protection is the
-- worse error. It also counts through the last minute instead of skipping it.
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

-- As Blizzard's CooldownViewerItemMixin:SetTooltipsShown -- motion only, never
-- clicks, so a widget under the cursor cannot swallow a click meant for the
-- world. Frames are created with mouse input off, so without this no tooltip
-- script ever fires.
function ns.SetTooltipsShown(frame, shown)
    if frame.SetMouseClickEnabled then
        frame:SetMouseClickEnabled(false)
    end
    if frame.SetMouseMotionEnabled then
        frame:SetMouseMotionEnabled(shown)
    else
        frame:EnableMouse(shown)
    end
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
        -- Trim the stock icon border instead, so a row still reads as clean.
        frame.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    frame.cooldown = CreateFrame("Cooldown", "$parentCooldown", frame, "CooldownFrameTemplate")
    frame.cooldown:SetAllPoints()
    frame.cooldown:SetDrawBling(false)
    if frame.cooldown.SetHideCountdownNumbers then
        -- We draw our own, so the display does not follow the player's
        -- countdownForCooldowns setting.
        frame.cooldown:SetHideCountdownNumbers(true)
    end
    if Icon.art.available then
        if frame.cooldown.SetSwipeTexture then
            frame.cooldown:SetSwipeTexture(Const.ART.swipe)
        end
        -- Needed even though real cooldowns draw no edge: the GCD uses it.
        if frame.cooldown.SetEdgeTexture then
            frame.cooldown:SetEdgeTexture(Const.ART.edge)
        end
    end

    if Icon.art.iconOverlay then
        frame.overlay = frame:CreateTexture(nil, "OVERLAY")
        frame.overlay:SetAtlas(Const.ART.iconOverlay)
    end

    -- The whole border treatment when the Blizzard atlases are absent.
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

    frame:SetScript("OnEnter", OnEnter)
    frame:SetScript("OnLeave", OnLeave)

    return frame
end

-- Pooled: the spell picker can rebuild a group on every keystroke.
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
    frame.cooldown:Clear()
    iconPool[#iconPool + 1] = frame
end

local function ApplyFont(fontString, fontObject, fallbackSize)
    if fontObject and _G[fontObject] then
        fontString:SetFontObject(_G[fontObject])
    end

    -- Font objects are fixed-size, so rescale to the icon once applied.
    local file, _, flags = fontString:GetFont()
    if file and fallbackSize then
        fontString:SetFont(file, fallbackSize, flags)
    end
end

function Icon:Configure(frame, entry, spellID, appearance, groupKey)
    frame.entry = entry
    frame.spellID = spellID
    frame.groupKey = groupKey or frame.groupKey

    -- Via Spellbook, not GetSpellInfo: rune abilities need their engraving art
    -- and weapon enchants borrow the weapon's icon.
    local texture = ns.Spellbook:GetIcon(spellID)
    frame.texture:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")

    local size = appearance.iconSize or Const.DEFAULT_APPEARANCE.iconSize
    frame:SetSize(size, size)

    -- Scaled against the template's native size, so a resized icon keeps the
    -- bevel in proportion.
    if frame.overlay then
        local base = Const.GROUP_APPEARANCE[frame.groupKey]
        local scale = (base and base.iconSize and base.iconSize > 0) and (size / base.iconSize) or 1
        local insetX = (appearance.overlayInsetX or 8) * scale
        local insetY = (appearance.overlayInsetY or 7) * scale

        frame.overlay:ClearAllPoints()
        frame.overlay:SetPoint("TOPLEFT", -insetX, insetY)
        frame.overlay:SetPoint("BOTTOMRIGHT", insetX, -insetY)
    end

    -- Reversed so a buff winds down rather than filling up like a cooldown.
    -- The swipe *colour* is not set here -- Update owns it, because one icon
    -- alternates between cooldown, aura and GCD colouring.
    local isAura = Const.AURA_GROUPS[frame.groupKey]
    if frame.cooldown.SetReverse then
        frame.cooldown:SetReverse(isAura and true or false)
    end

    ApplyFont(frame.timeText, appearance.timeFont, math.max(9, size * 0.42))
    ApplyFont(frame.countText, appearance.countFont, math.max(8, size * 0.30))

    ns.SetTooltipsShown(frame, appearance.showTooltips ~= false)
end

-- Both widget modules answer this: Group lays out on a grid and does not care
-- which kind it is holding.
function Icon:GetItemSize(appearance)
    local size = appearance.iconSize or Const.DEFAULT_APPEARANCE.iconSize
    return size, size
end

-- Takes a state table from either Cooldowns or Auras. Returns true while the
-- icon is animating and needs periodic text updates.
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

        -- Always a filled sweep, never the edge spark: Blizzard draws the GCD
        -- edge-only, which reads as a spinning needle rather than something
        -- subtle.
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

    -- Tracked buffs are never greyed or tinted: RefreshIconColor and
    -- RefreshIconDesaturation live on CooldownViewerCooldownItemMixin, which
    -- Blizzard's buff templates do not inherit.
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

        -- Follows Blizzard's RefreshIconColor.
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

    -- No active-aura highlight: a tracked buff is only on screen while it is up
    -- (see hideWhenInactive), so a border adds nothing the swipe has not said.
    frame.border:Hide()

    local showText = appearance.showCountdownText ~= false and not state.suppressText
    if showText and state.remaining and state.remaining > 0 then
        -- Only set when the string actually changes: SetText on every icon on
        -- every tick is the largest source of garbage in this addon, and most
        -- ticks render the same string as the last.
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

    -- Charges and aura stacks share the corner slot; neither appears at 1.
    local count = state.charges
    if count and count > 1 then
        frame.countText:SetText(count)
        frame.countText:Show()
    else
        frame.countText:Hide()
    end

    return (state.remaining or 0) > 0
end
