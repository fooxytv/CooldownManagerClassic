local addonName, ns = ...

-- Appends spell and aura IDs to tooltips, the way WeakAuras and friends do.
--
-- This is the practical way to find the ID of a buff that is not reachable any
-- other way: hover it, read the number, type it in. Season of Discovery rune
-- buffs in particular often have an aura ID that appears nowhere in the
-- spellbook and does not match the ability that applied it.

local Tooltip = {}
ns.Tooltip = Tooltip

local function Enabled()
    return ns.DB and ns.DB.root and ns.DB:GetGlobal().showTooltipIDs ~= false
end

--- Guards against the same tooltip gaining several ID lines, which happens when
--- more than one hook fires for a single display.
local function AlreadyShown(tooltip, id)
    if tooltip.cdmcShownID == id and tooltip.cdmcShownFor == tooltip:GetName() then
        return true
    end
    tooltip.cdmcShownID = id
    tooltip.cdmcShownFor = tooltip:GetName()
    return false
end

local function AppendID(tooltip, label, id)
    if not id or not Enabled() then return end
    if type(id) ~= "number" then return end
    if AlreadyShown(tooltip, id) then return end

    tooltip:AddLine(("|cff888888%s|r |cff00ff00%d|r"):format(label, id))
    tooltip:Show()
end

local function ClearMarker(tooltip)
    tooltip.cdmcShownID = nil
    tooltip.cdmcShownFor = nil
end

function Tooltip:Initialize()
    if self.initialized then return end
    self.initialized = true

    -- Reset the dedupe marker whenever a tooltip is cleared for reuse.
    if GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipCleared", ClearMarker)
    end

    -- Modern path: one post-call per data type covers every tooltip that shows
    -- a spell or an aura, however it was opened.
    if _G.TooltipDataProcessor and _G.Enum and Enum.TooltipDataType then
        if Enum.TooltipDataType.Spell then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, function(tooltip, data)
                AppendID(tooltip, "Spell ID:", data and data.id)
            end)
        end
        if Enum.TooltipDataType.UnitAura then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.UnitAura, function(tooltip, data)
                AppendID(tooltip, "Aura ID:", data and data.id)
            end)
        end
        self.mode = "TooltipDataProcessor"
        return
    end

    -- Legacy path: script hook for spells, plus the aura setters, since a buff
    -- tooltip does not fire OnTooltipSetSpell.
    if GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetSpell", function(tooltip)
            local _, id = tooltip:GetSpell()
            AppendID(tooltip, "Spell ID:", id)
        end)
    end

    local function HookAura(method, defaultFilter)
        if not GameTooltip[method] then return end
        hooksecurefunc(GameTooltip, method, function(tooltip, unit, index, filter)
            if not _G.UnitAura then return end
            local id = select(10, UnitAura(unit, index, filter or defaultFilter))
            AppendID(tooltip, "Aura ID:", id)
        end)
    end

    HookAura("SetUnitBuff", "HELPFUL")
    HookAura("SetUnitDebuff", "HARMFUL")

    self.mode = "legacy"
end
