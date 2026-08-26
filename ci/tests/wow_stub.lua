-- Minimal WoW client stub: enough of the widget and C_* API for the addon's
-- load path, a layout pass and an update tick to run outside the game.

unpack = unpack or table.unpack
loadstring = loadstring or load

-- WoW ships LuaJIT's bit library; Lua 5.4 does not.
bit = bit or {
    band   = function(a, b) return a & b end,
    bor    = function(a, b) return a | b end,
    bxor   = function(a, b) return a ~ b end,
    lshift = function(a, n) return (a << n) & 0xFFFFFFFF end,
    rshift = function(a, n) return (a & 0xFFFFFFFF) >> n end,
    bnot   = function(a) return ~a & 0xFFFFFFFF end,
}

local calls = {}
_G.__calls = calls

local function record(name)
    calls[name] = (calls[name] or 0) + 1
end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

local Widget = {}
Widget.__index = Widget

local frameLevelSeed = 1

local function newWidget(kind, name, parent)
    local self = setmetatable({}, Widget)
    self.__kind = kind
    self.__name = name
    self.__parent = parent
    self.__shown = true
    self.__points = {}
    self.__width, self.__height = 40, 40
    frameLevelSeed = frameLevelSeed + 1
    self.__level = frameLevelSeed
    self.__min, self.__max, self.__value = 0, 1, 0
    self.__text = ""
    return self
end

-- Any widget method not spelled out below is a no-op returning nil. Every call
-- is counted, so a test can assert that something was actually invoked.
-- Widget methods are PascalCase; the fields this addon hangs off a frame
-- (frame.overlay, frame.bar, frame.timeText, ...) are not. So an unknown
-- PascalCase key is treated as a method the stub has not bothered to
-- implement, and anything else stays nil -- which is what an absent child
-- widget looks like in the real client, and what the addon's `if frame.overlay
-- then` guards are testing for.
-- Backdrops are conditional, unlike everything else the metatable makes up: the
-- addon tests for SetBackdrop's presence, because a plain frame on a modern
-- client has none. __setBackdropPresent(false) takes the methods away so the
-- solid-border fallback is exercised too.
_G.__backdropAvailable = true
_G.__setBackdropPresent = function(present)
    _G.__backdropAvailable = present and true or false
end

local backdropMethods = {
    SetBackdrop = function(self, backdrop) self.__backdrop = backdrop end,
    SetBackdropColor = function(self, r, g, b, a) self.__backdropColor = { r, g, b, a } end,
    SetBackdropBorderColor = function(self, r, g, b, a) self.__backdropBorder = { r, g, b, a } end,
}

-- PascalCase keys that are frames hung off a frame rather than methods. Without
-- these the heuristic below hands back a function, and code that reasonably
-- expects a table (`frame.Selection.system`) errors on something the real client
-- would have left nil.
local FIELD_KEYS = {
    Selection = true,
    -- SearchBoxTemplate's placeholder font string.
    Instructions = true,
}

setmetatable(Widget, {
    __index = function(_, key)
        if type(key) ~= "string" then return nil end
        if FIELD_KEYS[key] then return nil end

        local backdrop = backdropMethods[key]
        if backdrop then
            if not _G.__backdropAvailable then return nil end
            return backdrop
        end

        local first = key:sub(1, 1)
        if first ~= first:upper() or first == "_" then return nil end
        return function(...)
            record(key)
            return nil
        end
    end,
})

function Widget:SetPoint(point, ...) record("SetPoint") self.__points[#self.__points + 1] = { point, ... } end
function Widget:ClearAllPoints() record("ClearAllPoints") self.__points = {} end
function Widget:SetAllPoints() record("SetAllPoints") end
function Widget:GetPoint() return self.__points[1] and self.__points[1][1] or "CENTER", nil, "CENTER", 0, 0 end
function Widget:GetNumPoints() return #self.__points end

function Widget:SetSize(w, h) self.__width, self.__height = w, h end
function Widget:SetWidth(w) self.__width = w end
function Widget:SetHeight(h) self.__height = h end
function Widget:GetSize() return self.__width, self.__height end
function Widget:GetWidth() return self.__width end
function Widget:GetHeight() return self.__height end
function Widget:GetCenter() return 400, 300 end
function Widget:GetEffectiveScale() return 1 end

function Widget:Show() self.__shown = true end
function Widget:Hide() self.__shown = false end
function Widget:SetShown(shown) self.__shown = shown and true or false end
function Widget:IsShown() return self.__shown end
function Widget:IsVisible() return self.__shown end

function Widget:SetChecked(checked) self.__checked = checked and true or false end
function Widget:GetChecked() return self.__checked end

function Widget:SetFrameLevel(level) self.__level = level end
function Widget:GetFrameLevel() return self.__level end

function Widget:SetScript(script, handler) self.__scripts = self.__scripts or {}; self.__scripts[script] = handler end
function Widget:GetScript(script) return self.__scripts and self.__scripts[script] end
function Widget:HookScript(script, handler) self:SetScript(script, handler) end
function Widget:RegisterEvent() end
function Widget:UnregisterEvent() end
function Widget:SetParent(parent) self.__parent = parent end
function Widget:GetParent() return self.__parent end
function Widget:GetName() return self.__name end

function Widget:CreateTexture(name, layer)
    record("CreateTexture")
    return newWidget("Texture", name, self)
end

function Widget:CreateMaskTexture(name)
    record("CreateMaskTexture")
    return newWidget("MaskTexture", name, self)
end

function Widget:CreateFontString(name, layer, inherits)
    record("CreateFontString")
    local fs = newWidget("FontString", name, self)
    fs.__font = inherits or "GameFontNormal"
    return fs
end

-- FontString
function Widget:SetText(text) self.__text = text end
function Widget:GetText() return self.__text end
function Widget:GetFont() return self.__fontFile or "Fonts\\FRIZQT__.TTF", self.__fontSize or 12, self.__fontFlags or "" end
function Widget:SetFont(file, size, flags) self.__fontFile, self.__fontSize, self.__fontFlags = file, size, flags end
-- Clears what SetFont put there, as the real API does: the object supplies the
-- file, size and flags again until something overrides them.
function Widget:SetFontObject(object)
    self.__font = object
    self.__fontFile, self.__fontSize, self.__fontFlags = nil, nil, nil
end

-- StatusBar
function Widget:SetMinMaxValues(min, max) self.__min, self.__max = min, max end
function Widget:GetMinMaxValues() return self.__min, self.__max end
function Widget:SetValue(value) self.__value = value end
function Widget:GetValue() return self.__value end
function Widget:SetStatusBarTexture(texture) self.__barTexture = texture end
function Widget:GetStatusBarTexture()
    self.__barTexture = self.__barTexture or newWidget("Texture", nil, self)
    return self.__barTexture
end
function Widget:SetStatusBarColor(r, g, b, a) self.__barColor = { r, g, b, a } end

-- Texture
function Widget:SetAtlas(atlas, useSize) record("SetAtlas") self.__atlas = atlas end
function Widget:SetTexture(file) self.__texture = file end
function Widget:GetTexture() return self.__texture end
function Widget:SetColorTexture(r, g, b, a) self.__color = { r, g, b, a } end
function Widget:SetVertexColor(r, g, b, a) self.__vertex = { r, g, b, a } end
function Widget:SetDesaturated(value) self.__desaturated = value end
function Widget:AddMaskTexture(mask) self.__mask = mask end

-- Cooldown
function Widget:SetCooldown(start, duration, modRate) self.__cooldown = { start, duration, modRate } end
function Widget:Clear() self.__cooldown = nil end
function Widget:SetSwipeColor(r, g, b, a) self.__swipeColor = { r, g, b, a } end

function Widget:SetMouseClickEnabled(enabled) self.__mouseClick = enabled end
function Widget:SetMouseMotionEnabled(enabled) self.__mouseMotion = enabled end
function Widget:EnableMouse(enabled) self.__mouse = enabled end

-- Every frame ever created, so a test can reach one the addon keeps to itself.
-- Core's event frame is a file-local with no name, and the events it dispatches
-- are the seam where two wiring bugs have already hidden.
_G.__frames = {}

_G.CreateFrame = function(kind, name, parent, template)
    record("CreateFrame")
    local frame = newWidget(kind, name, parent)
    _G.__frames[#_G.__frames + 1] = frame
    if name then _G[name] = frame end
    -- Templates the addon leans on for named children.
    if template and template:find("OptionsSliderTemplate") and name then
        _G[name .. "Text"] = newWidget("FontString", name .. "Text", frame)
        _G[name .. "Low"] = newWidget("FontString", name .. "Low", frame)
        _G[name .. "High"] = newWidget("FontString", name .. "High", frame)
    end
    if template and template:find("UICheckButtonTemplate") and name then
        _G[name .. "Text"] = newWidget("FontString", name .. "Text", frame)
    end
    if template and template:find("ButtonFrameTemplate") then
        frame.Inset = newWidget("Frame", nil, frame)
        frame.TitleContainer = { TitleText = newWidget("FontString", nil, frame) }
        frame.PortraitContainer = { portrait = newWidget("Texture", nil, frame) }
        frame.SetTitle = function(_, title) frame.__title = title end
    end
    return frame
end

-- The colour picker in its modern shape (SetupColorPickerAndShow). Real methods
-- rather than the metatable's no-ops, so a test can open it, move the colour and
-- fire the callback the addon handed it.
local colorPicker = newWidget("Frame", "ColorPickerFrame")
colorPicker.__color = { 1, 1, 1, 1 }
colorPicker.SetColorRGB = function(self, r, g, b)
    self.__color[1], self.__color[2], self.__color[3] = r, g, b
end
colorPicker.GetColorRGB = function(self)
    return self.__color[1], self.__color[2], self.__color[3]
end
colorPicker.GetColorAlpha = function(self) return self.__color[4] end
colorPicker.SetupColorPickerAndShow = function(self, info)
    self.__info = info
    self.__color = { info.r, info.g, info.b, info.opacity or 1 }
    self.__shown = true
end
_G.ColorPickerFrame = colorPicker

-- Frames only inherit BackdropTemplate where the mixin exists; Compat reads this
-- to decide whether to pass the template to CreateFrame at all.
_G.BackdropTemplateMixin = {}

-- A stand-in for LibEQOL's Edit Mode. In game that library owns selection and
-- the settings dialog, so everything registered through it -- which is most of
-- what a player actually clicks -- used to run only in the client. Registrations
-- are recorded here for the test to inspect.
--
-- LibStub answers for this one library; every other lookup stays nil, which is
-- what the rest of the addon already expects under the stub.
local editMode = {
    SettingType = {
        Checkbox = "Checkbox",
        Dropdown = "Dropdown",
        Slider = "Slider",
        Color = "Color",
        CheckboxColor = "CheckboxColor",
        Divider = "Divider",
    },
    frames = {},
    settings = {},
    buttons = {},
    callbacks = {},
}

function editMode:AddFrame(frame, callback, defaults)
    self.frames[frame] = { callback = callback, defaults = defaults }
    -- The library gives a registered frame its selection overlay, which the
    -- addon then fills in a system name on.
    frame.Selection = newWidget("Frame", nil, frame)
end

function editMode:AddFrameSettings(frame, settings)
    self.settings[frame] = settings
end

function editMode:AddFrameSettingsButton(frame, data)
    self.buttons[frame] = self.buttons[frame] or {}
    table.insert(self.buttons[frame], data)
end

function editMode:SetFrameResetVisible() end

function editMode:RegisterCallback(event, handler)
    self.callbacks[event] = handler
end

_G.__editMode = editMode
_G.LibStub = function(name)
    if name == "LibEQOLEditMode-1.0" then return editMode end
    return nil
end

_G.UIParent = newWidget("Frame", "UIParent")
_G.GameTooltip = newWidget("GameTooltip", "GameTooltip")
_G.DEFAULT_CHAT_FRAME = newWidget("Frame", "DEFAULT_CHAT_FRAME")

--------------------------------------------------------------------------------
-- Globals the addon reads
--------------------------------------------------------------------------------

for _, font in ipairs({
    "GameFontNormal", "GameFontNormalSmall", "GameFontHighlight", "GameFontHighlightSmall",
    "GameFontHighlightOutline", "GameFontHighlightHugeOutline",
    "NumberFontNormal", "NumberFontNormalSmall", "NumberFontNormalHuge",
}) do
    _G[font] = { __fontObject = font }
end

_G.WOW_PROJECT_ID = 2
_G.WOW_PROJECT_CLASSIC = 2
_G.WOW_PROJECT_MAINLINE = 1

local now = 1000
_G.GetTime = function() return now end
_G.__advance = function(seconds) now = now + seconds end

_G.GetBuildInfo = function() return "1.15.9", "60000", "Jul 2026", 11509 end
_G.GetRealmName = function() return "Test" end
_G.UnitName = function() return "Tester" end
_G.UnitClass = function() return "SHAMAN", "SHAMAN", 7 end
_G.UnitGUID = function(unit) return unit == "player" and "Player-Test" or "Target-Test" end
-- Drivable combat-log payload: set _G.__clog to an array of return values.
_G.CombatLogGetCurrentEventInfo = function()
    local e = _G.__clog
    if not e then return end
    return unpack(e)
end
_G.UnitAffectingCombat = function() return false end
_G.UnitExists = function(unit) return _G.__hasTarget and true or false end
_G.InCombatLockdown = function() return false end
_G.UnitPowerType = function() return 0, "MANA" end
_G.UnitHealth = function() return 100 end
_G.UnitHealthMax = function() return 100 end
_G.UnitPower = function() return 50 end
_G.UnitPowerMax = function() return 100 end
_G.GetComboPoints = function() return 0 end
_G.GetInventoryItemLink = function() return nil end
_G.GetInventoryItemTexture = function() return nil end
_G.GetItemInfo = function() return nil end
_G.GetItemCount = function() return 0 end
_G.RANGE_INDICATOR = "\226\128\162"
-- One spell on the first action slot, bound to Shift-2, so the keybind reader
-- has something to find.
_G.GetActionInfo = function(slot) if slot == 1 then return "spell", 686 end return nil end
_G.GetMacroSpell = function() return nil end
_G.GetBindingKey = function(command) if command == "ACTIONBUTTON1" then return "SHIFT-2" end return nil end
_G.GetWeaponEnchantInfo = function() return false end
_G.IsPlayerSpell = function() return true end
_G.IsSpellKnown = function() return true end
_G.IsPassiveSpell = function() return false end
_G.GetNumSpellTabs = function() return 0 end
_G.GetSpellTabInfo = function() return nil end
-- Dropdown menus, with enough state to test one: the initialiser is kept so a
-- test can build the menu's contents and click an item, and open/closed is
-- tracked because "the menu stays up after you pick something" is a bug that is
-- invisible to a no-op stub.
_G.__dropdownOpen = false
_G.__dropdownButtons = {}
_G.__dropdownRefreshed = 0

_G.CloseDropDownMenus = function() _G.__dropdownOpen = false end
_G.ToggleDropDownMenu = function() _G.__dropdownOpen = true end
_G.UIDropDownMenu_SetWidth = function() end
_G.UIDropDownMenu_Initialize = function(frame, initializer)
    if frame then frame.__initializer = initializer end
end
_G.UIDropDownMenu_CreateInfo = function() return {} end
_G.UIDropDownMenu_AddButton = function(info) table.insert(_G.__dropdownButtons, info) end
_G.UIDropDownMenu_SetText = function() end
_G.UIDropDownMenu_Refresh = function() _G.__dropdownRefreshed = _G.__dropdownRefreshed + 1 end

-- Runs a menu's initialiser, as opening it would, and hands back the items.
_G.__buildDropdown = function(frame)
    _G.__dropdownButtons = {}
    if frame and frame.__initializer then frame.__initializer() end
    return _G.__dropdownButtons
end
_G.StaticPopup_Show = function() end
_G.StaticPopupDialogs = {}
_G.PowerBarColor = {}
_G.hooksecurefunc = function() end
_G.PlaySound = function() end
_G.SOUNDKIT = { IG_CHARACTER_INFO_TAB = 841 }
_G.UISpecialFrames = {}
_G.SlashCmdList = {}
_G.SLASH_CDMC1 = nil
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.tinsert = table.insert
_G.tremove = table.remove
_G.tContains = function(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
_G.strsplit = function(sep, str) return str end
_G.GenerateClosure = function(fn, ...) local args = { ... } return function(...) return fn(unpack(args), ...) end end

_G.C_Timer = {
    After = function(_, fn) _G.__pendingTimers = _G.__pendingTimers or {}; table.insert(_G.__pendingTimers, fn) end,
    NewTicker = function() return { Cancel = function() end } end,
}

-- The Cooldown Manager atlases, as they would be on a client that has them.
local atlases = {
    ["UI-HUD-CoolDownManager-Mask"] = true,
    ["UI-HUD-CoolDownManager-IconOverlay"] = true,
    ["UI-CooldownManager-OORshadow"] = true,
    ["UI-HUD-CoolDownManager-Bar"] = true,
    ["UI-HUD-CoolDownManager-Bar-BG"] = true,
    ["UI-HUD-CoolDownManager-Bar-Pip"] = true,
}
_G.__setAtlasesPresent = function(present)
    if present then return end
    for key in pairs(atlases) do atlases[key] = nil end
end

_G.C_Texture = {
    GetAtlasInfo = function(name) return atlases[name] and { width = 32, height = 32 } or nil end,
}

--------------------------------------------------------------------------------
-- Spell and aura data
--------------------------------------------------------------------------------

local SPELLS = {
    [187880] = { name = "Maelstrom Weapon", icon = "Interface\\Icons\\Spell_Shaman_MaelstromWeapon" },
    [324] = { name = "Lightning Shield", icon = "Interface\\Icons\\Spell_Nature_LightningShield" },
    [2645] = { name = "Ghost Wolf", icon = "Interface\\Icons\\Spell_Nature_SpiritWolf" },
    [686] = { name = "Shadow Bolt", icon = "Interface\\Icons\\Spell_Shadow_ShadowBolt", castTime = 3000 },
    -- A self-buff with no cooldown: its aura is the only thing to show.
    [5171] = { name = "Slice and Dice", icon = "Interface\\Icons\\Ability_Rogue_SliceDice" },
    -- Druid abilities for the form tags: one cat-only, one bear-only, one caster
    -- spell that must stay untagged, and one that belongs in every form.
    [1082] = { name = "Claw", icon = "Interface\\Icons\\Ability_Druid_Rake" },
    [6807] = { name = "Maul", icon = "Interface\\Icons\\Ability_Druid_Maul" },
    [5176] = { name = "Wrath", icon = "Interface\\Icons\\Spell_Nature_AbolishMagic" },
    [1126] = { name = "Mark of the Wild", icon = "Interface\\Icons\\Spell_Nature_Regeneration" },
}

_G.C_Spell = {
    GetSpellInfo = function(id)
        local spell = SPELLS[id]
        if not spell then return nil end
        return { name = spell.name, iconID = spell.icon, spellID = id, castTime = spell.castTime or 0 }
    end,
    GetSpellTexture = function(id) return SPELLS[id] and SPELLS[id].icon end,
    -- Driveable cooldown: __cd = { start=, duration= }. Empty means ready.
    GetSpellCooldown = function()
        local cd = _G.__cd or {}
        return { startTime = cd.start or 0, duration = cd.duration or 0, isEnabled = true, modRate = 1 }
    end,
    GetSpellCharges = function() return nil end,
    IsSpellUsable = function()
        local cd = _G.__cd or {}
        -- On a real (non-GCD) cooldown reads as unusable, as the live API does.
        if (cd.duration or 0) > 1.6 then return false, false end
        return true, false
    end,
    DoesSpellExist = function(id) return SPELLS[id] ~= nil end,
    IsSpellDataCached = function() return true end,
    RequestLoadSpellData = function() end,
}

_G.C_SpellBook = {
    GetNumSpellBookSkillLines = function() return 0 end,
    GetSpellBookSkillLineInfo = function() return nil end,
    GetSpellBookItemInfo = function() return nil end,
    GetSpellBookItemName = function() return nil end,
}

-- One stacking aura on the player, with a timer, so the bar has something to
-- draw. Stacks and remaining time are pokeable from the test.
_G.__aura = {
    spellId = 187880,
    name = "Maelstrom Weapon",
    icon = "Interface\\Icons\\Spell_Shaman_MaelstromWeapon",
    applications = 5,
    duration = 30,
    expirationTime = now + 12,
    timeMod = 1,
}

-- A harmful aura on the target, for DoT tracking. nil by default (no debuff);
-- tests set it, including sourceUnit to exercise the player-cast filter.
_G.__targetAura = nil

_G.C_UnitAuras = {
    GetAuraDataByIndex = function(unit, index, filter)
        if unit == "target" then
            if index == 1 and filter == "HARMFUL" then return _G.__targetAura end
            return nil
        end
        if index == 1 and filter ~= "HARMFUL" then return _G.__aura end
        return nil
    end,
    GetPlayerAuraBySpellID = function(id)
        if id == _G.__aura.spellId then return _G.__aura end
        return nil
    end,
    ForEachAura = function(unit, filter, max, fn)
        if filter ~= "HARMFUL" then fn(_G.__aura) end
    end,
}

_G.UnitAura = function(unit, index, filter)
    if index ~= 1 then return nil end
    local a
    if unit == "target" then
        if filter == "HARMFUL" then a = _G.__targetAura end
    elseif filter ~= "HARMFUL" then
        a = _G.__aura
    end
    if not a then return nil end
    return a.name, a.icon, a.applications, nil, a.duration, a.expirationTime,
        a.sourceUnit, nil, nil, a.spellId
end

_G.GetSpellInfo = function(id)
    local spell = SPELLS[id]
    if not spell then return nil end
    return spell.name, nil, spell.icon, spell.castTime or 0
end

-- Which spell is armed for the next swing. Set to a spellID to queue it.
_G.__queued = nil
_G.IsCurrentSpell = function(id) return _G.__queued == id end
_G.GetSpellCooldown = function() return 0, 0, 1 end
_G.GetSpellCharges = function() return nil end
_G.GetSpellTexture = function(id) return SPELLS[id] and SPELLS[id].icon end
_G.IsUsableSpell = function() return true, false end
