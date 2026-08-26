local addonName, ns = ...

local Keybinds = {}
ns.Keybinds = Keybinds

local map = {}

local function CommandForSlot(slot)
    if slot >= 1 and slot <= 12 then return "ACTIONBUTTON" .. slot end
    if slot >= 61 and slot <= 72 then return "MULTIACTIONBAR1BUTTON" .. (slot - 60) end
    if slot >= 49 and slot <= 60 then return "MULTIACTIONBAR2BUTTON" .. (slot - 48) end
    if slot >= 25 and slot <= 36 then return "MULTIACTIONBAR3BUTTON" .. (slot - 24) end
    if slot >= 37 and slot <= 48 then return "MULTIACTIONBAR4BUTTON" .. (slot - 36) end
    return nil
end

local function ButtonNameForSlot(slot)
    if slot >= 1 and slot <= 12 then return "ActionButton" .. slot end
    if slot >= 61 and slot <= 72 then return "MultiBarBottomLeftButton" .. (slot - 60) end
    if slot >= 49 and slot <= 60 then return "MultiBarBottomRightButton" .. (slot - 48) end
    if slot >= 25 and slot <= 36 then return "MultiBarRightButton" .. (slot - 24) end
    if slot >= 37 and slot <= 48 then return "MultiBarLeftButton" .. (slot - 36) end
    return nil
end

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

function Keybinds:Get(spellID)
    local name = ns.Spellbook:GetName(spellID) or ns.Compat.GetSpellInfo(spellID)
    return name and map[name] or nil
end
