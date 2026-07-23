local addonName, ns = ...

local Const = ns.Constants
local Compat = ns.Compat

local Icon = {}
ns.Icon = Icon

local iconPool = {}
local iconCount = 0

--------------------------------------------------------------------------------
-- Blizzard art availability
--------------------------------------------------------------------------------

-- Blizzard_CooldownViewer ships in the Classic Era build but is gated to the
-- `standard` game type, so the Lua is present while the art may or may not be.
-- Each atlas is probed once and the icon falls back to a plain trimmed square
-- when it is missing, rather than rendering an invisible texture.
local function AtlasExists(name)
    if not _G.C_Texture or not C_Texture.GetAtlasInfo then return false end
    local ok, info = pcall(C_Texture.GetAtlasInfo, name)
    return ok and info ~= nil
end

Icon.art = {
    mask        = AtlasExists(Const.ART.mask),
    iconOverlay = AtlasExists(Const.ART.iconOverlay),
    oorShadow   = AtlasExists(Const.ART.oorShadow),
}
Icon.art.available = Icon.art.mask or Icon.art.iconOverlay

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------

local function FormatTime(seconds)
    if seconds >= 3600 then
        return ("%dh"):format(math.floor(seconds / 3600 + 0.5))
    elseif seconds >= 60 then
        return ("%dm"):format(math.floor(seconds / 60 + 0.5))
    elseif seconds >= 10 then
        return ("%d"):format(math.floor(seconds))
    end
    return ("%.1f"):format(seconds)
end
ns.FormatTime = FormatTime

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function OnEnter(self)
    if not self.spellID then return end
    local group = ns.DB:GetGroup(self.groupKey)
    if group and group.appearance.showTooltips == false then return end

    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    Compat.SetTooltipSpellByID(GameTooltip, self.spellID)
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
        -- The mask is what gives Blizzard's icons their rounded-square shape.
        local mask = frame:CreateMaskTexture()
        mask:SetAllPoints()
        mask:SetAtlas(Const.ART.mask)
        if frame.texture.AddMaskTexture then
            frame.texture:AddMaskTexture(mask)
            frame.mask = mask
        end
    end

    if not frame.mask then
        -- No mask available: trim the stock icon border instead so adjacent
        -- icons still read as a clean row.
        frame.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    frame.cooldown = CreateFrame("Cooldown", "$parentCooldown", frame, "CooldownFrameTemplate")
    frame.cooldown:SetAllPoints()
    frame.cooldown:SetDrawBling(false)
    if frame.cooldown.SetHideCountdownNumbers then
        -- We draw our own text so the display is consistent regardless of the
        -- player's countdownForCooldowns setting.
        frame.cooldown:SetHideCountdownNumbers(true)
    end
    if Icon.art.available then
        if frame.cooldown.SetSwipeTexture then
            frame.cooldown:SetSwipeTexture(Const.ART.swipe)
        end
        -- The edge texture is needed even though real cooldowns do not draw an
        -- edge: it is what the global cooldown is rendered with.
        if frame.cooldown.SetEdgeTexture then
            frame.cooldown:SetEdgeTexture(Const.ART.edge)
        end
    end

    -- Drawn above the icon, below the text. Anchored with per-template insets
    -- so the bevel sits outside the icon exactly as Blizzard anchors it.
    if Icon.art.iconOverlay then
        frame.overlay = frame:CreateTexture(nil, "OVERLAY")
        frame.overlay:SetAtlas(Const.ART.iconOverlay)
    end

    -- Fallback border, used for the active-aura highlight and as the whole
    -- border treatment when the Blizzard atlases are absent.
    frame.border = frame:CreateTexture(nil, "OVERLAY")
    frame.border:SetPoint("TOPLEFT", -2, 2)
    frame.border:SetPoint("BOTTOMRIGHT", 2, -2)
    frame.border:SetColorTexture(1, 1, 1, 1)
    frame.border:Hide()

    -- Proc-style pulsing outline, used when a tracked aura hits its stack
    -- threshold. Hand-rolled rather than using ActionButton_ShowOverlayGlow so
    -- there is no dependency on SpellActivationOverlay being present.
    frame.glow = frame:CreateTexture(nil, "OVERLAY", nil, 2)
    frame.glow:SetPoint("TOPLEFT", -6, 6)
    frame.glow:SetPoint("BOTTOMRIGHT", 6, -6)
    frame.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    frame.glow:SetBlendMode("ADD")
    frame.glow:SetVertexColor(1, 0.9, 0.3)
    frame.glow:Hide()

    local pulse = frame.glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.25)
    fade:SetDuration(0.5)
    frame.glowPulse = pulse

    frame.timeText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightOutline")
    frame.timeText:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.timeText:SetJustifyH("CENTER")

    frame.countText = frame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    frame.countText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)

    frame:SetScript("OnEnter", OnEnter)
    frame:SetScript("OnLeave", OnLeave)

    return frame
end

--- Icons are pooled because the spell picker can rebuild a group repeatedly.
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
    frame.glowPulse:Stop()
    frame.glow:Hide()
    iconPool[#iconPool + 1] = frame
end

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

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

    -- Via Spellbook so rune abilities get their engraving art rather than the
    -- generic texture the underlying spell carries.
    local texture = ns.Spellbook:GetIcon(spellID)
    frame.texture:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")

    local size = appearance.iconSize or Const.DEFAULT_APPEARANCE.iconSize
    frame:SetSize(size, size)

    -- Scale Blizzard's overlay insets if the player has resized the icons away
    -- from the template's native size.
    if frame.overlay then
        local base = Const.GROUP_APPEARANCE[frame.groupKey]
        local scale = (base and base.iconSize and base.iconSize > 0) and (size / base.iconSize) or 1
        local insetX = (appearance.overlayInsetX or 8) * scale
        local insetY = (appearance.overlayInsetY or 7) * scale

        frame.overlay:ClearAllPoints()
        frame.overlay:SetPoint("TOPLEFT", -insetX, insetY)
        frame.overlay:SetPoint("BOTTOMRIGHT", insetX, -insetY)
    end

    -- Buff swipes run in reverse and are darkened, so a buff winds down rather
    -- than filling up like a cooldown.
    local isAura = Const.AURA_GROUPS[frame.groupKey]
    if frame.cooldown.SetReverse then
        frame.cooldown:SetReverse(isAura and true or false)
    end
    -- Swipe colour is not set here: Update owns it, because the same icon
    -- alternates between cooldown, aura and global-cooldown colouring.

    ApplyFont(frame.timeText, appearance.timeFont, math.max(9, size * 0.42))
    ApplyFont(frame.countText, appearance.countFont, math.max(8, size * 0.30))
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

--- Applies a tracker state table (from Cooldowns or Auras) to the widget.
--- Returns true when the icon is animating and needs periodic text updates.
function Icon:Update(frame, state, appearance)
    if not state then return false end

    if state.swipeDuration and state.swipeDuration > 0 then
        -- The swipe colour is set per update rather than once at configure
        -- time, because the same icon alternates between a real cooldown and
        -- the much fainter global cooldown sweep.
        if frame.cooldown.SetSwipeColor then
            local color
            if state.isGCD then
                color = Const.GCD_SWIPE_COLOR
            elseif state.aura then
                color = Const.BUFF_SWIPE_COLOR
            else
                color = Const.COOLDOWN_SWIPE_COLOR
            end
            frame.cooldown:SetSwipeColor(color[1], color[2], color[3], color[4])
        end

        -- Always a filled sweep, never the edge spark. CMC renders the GCD as
        -- edge-only, but that reads as a spinning needle rather than something
        -- subtle; a faint dark fill is quieter and matches how the real
        -- cooldowns are drawn.
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

    local desaturate = appearance.desaturateUnavailable ~= false and not state.available
    if frame.texture.SetDesaturated then
        frame.texture:SetDesaturated(desaturate)
    end

    -- Tint follows Blizzard's RefreshIconColor: white when usable, blue when
    -- the only thing missing is power (energy, mana, rage), grey when the spell
    -- is unusable for any other reason.
    local colors = Const.ITEM_COLORS
    local tint
    if state.aura then
        tint = colors.usable
    elseif appearance.colorByUsability == false then
        tint = state.available and colors.usable or colors.notUsable
    elseif state.usable then
        tint = colors.usable
    elseif state.notEnoughPower then
        tint = colors.notEnoughPower
    else
        tint = colors.notUsable
    end
    frame.texture:SetVertexColor(tint[1], tint[2], tint[3])

    -- No active-aura highlight. A tracked buff is only on screen while it is up
    -- (see hideWhenInactive), so a border would just be noise on top of that --
    -- the swipe and the timer already say everything.
    frame.border:Hide()

    -- The stack glow is the exception: it marks a threshold worth reacting to,
    -- not merely that the aura exists.
    local threshold = appearance.glowAtStacks or 0
    local stacks = state.charges or 0
    if threshold > 0 and stacks >= threshold then
        if not frame.glow:IsShown() then
            frame.glow:Show()
            frame.glowPulse:Play()
        end
    elseif frame.glow:IsShown() then
        frame.glowPulse:Stop()
        frame.glow:Hide()
    end

    local showText = appearance.showCountdownText ~= false and not state.suppressText
    if showText and state.remaining and state.remaining > 0 then
        frame.timeText:SetText(FormatTime(state.remaining))
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
