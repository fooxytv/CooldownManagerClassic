local addonName, ns = ...

-- Keybind text for tracked icons. Classic has no C_CooldownViewer binding
-- service, so the hotkey is recovered from the action bars: every action slot is
-- resolved to the spell (or macro's spell) it holds, and the slot's binding is
-- read from the standard binding command, falling back to the on-screen button's
-- HotKey text.
--
-- Keyed by spell *name* so it spans ranks -- the bar may hold a different rank
-- from the tracked entry, but both resolve to the same name.

local Keybinds = {}
ns.Keybinds = Keybinds

local map = {}

-- Action slot -> binding command name. Pages 13-24 have no stable binding of
-- their own (they share the main bar's), so they are left out.
local function CommandForSlot(slot)
    if slot >= 1 and slot <= 12 then return "ACTIONBUTTON" .. slot end
    if slot >= 61 and slot <= 72 then return "MULTIACTIONBAR1BUTTON" .. (slot - 60) end
    if slot >= 49 and slot <= 60 then return "MULTIACTIONBAR2BUTTON" .. (slot - 48) end
    if slot >= 25 and slot <= 36 then return "MULTIACTIONBAR3BUTTON" .. (slot - 24) end
    if slot >= 37 and slot <= 48 then return "MULTIACTIONBAR4BUTTON" .. (slot - 36) end
    return nil
end

-- The on-screen button for a slot, for the HotKey-text fallback.
local function ButtonNameForSlot(slot)
    if slot >= 1 and slot <= 12 then return "ActionButton" .. slot end
    if slot >= 61 and slot <= 72 then return "MultiBarBottomLeftButton" .. (slot - 60) end
    if slot >= 49 and slot <= 60 then return "MultiBarBottomRightButton" .. (slot - 48) end
    if slot >= 25 and slot <= 36 then return "MultiBarRightButton" .. (slot - 24) end
    if slot >= 37 and slot <= 48 then return "MultiBarLeftButton" .. (slot - 36) end
    return nil
end

-- Abbreviate a binding string the way an action button does: lowercase modifier
-- letters and short mouse/scroll tokens, so "SHIFT-BUTTON4" reads as "sm4".
local ABBREV = {
    ["SHIFT%-"]       = "s",
    ["CTRL%-"]        = "c",
    ["ALT%-"]         = "a",
    ["BUTTON"]        = "m",
    ["MOUSEWHEELUP"]  = "mwu",
    ["MOUSEWHEELDOWN"] = "mwd",
    ["NUMPAD"]        = "n",
    ["SPACE"]         = "sp",
    ["PAGEUP"]        = "pu",
    ["PAGEDOWN"]      = "pd",
}

local function Abbreviate(key)
    if not key or key == "" then return nil end
    key = key:upper()
    for pattern, replacement in pairs(ABBREV) do
        key = key:gsub(pattern, replacement)
    end
    return key
end

local function HotkeyForSlot(slot)
    local command = CommandForSlot(slot)
    if command and _G.GetBindingKey then
        local key = GetBindingKey(command)
        if key then return Abbreviate(key) end
    end

    -- Fallback: whatever the on-screen button is already showing. Matches
    -- macro-driven and third-party bindings the command lookup misses, when the
    -- default button exists.
    local button = ButtonNameForSlot(slot)
    local widget = button and _G[button]
    local hotkey = widget and widget.HotKey
    if hotkey then
        local text = hotkey:GetText()
        if text and text ~= "" and text ~= _G.RANGE_INDICATOR then
            return text
        end
    end

    return nil
end

--- Rebuilds the spell-name -> hotkey map from the current action bars. First
--- binding found for a name wins.
function Keybinds:Rebuild()
    wipe(map)
    if not _G.GetActionInfo then return end

    for slot = 1, 120 do
        local actionType, id = GetActionInfo(slot)
        local spellID
        if actionType == "spell" then
            spellID = id
        elseif actionType == "macro" and _G.GetMacroSpell then
            spellID = GetMacroSpell(id)
        end

        if spellID then
            local name = ns.Compat.GetSpellInfo(spellID)
            if name and not map[name] then
                local hotkey = HotkeyForSlot(slot)
                if hotkey then map[name] = hotkey end
            end
        end
    end
end

--- The hotkey for a tracked spell, or nil if it is not on any bar.
function Keybinds:Get(spellID)
    local name = ns.Spellbook:GetName(spellID) or ns.Compat.GetSpellInfo(spellID)
    return name and map[name] or nil
end
