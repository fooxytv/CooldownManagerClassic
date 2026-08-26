local addonName, ns = ...

local Const = ns.Constants

local EntryMenu = {}
ns.EntryMenu = EntryMenu

local menu

local function IsDruid()
    return select(2, UnitClass("player")) == "DRUID"
end

local function FormCount(forms)
    if type(forms) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(forms) do count = count + 1 end
    return count
end

-- "All forms" is stored as nil, so every box reads as checked. Clicking a form
-- from that state used to *remove* it, which is the opposite of what picking a
-- form means. Starting a fresh selection instead makes the first click do what
-- it looks like it does.
function EntryMenu.ToggleForm(entry, formKey)
    if not entry then return end

    local forms = entry.forms
    if type(forms) ~= "table" or not next(forms) then
        entry.forms = { [formKey] = true }
        return
    end

    local set = {}
    for key in pairs(forms) do set[key] = true end
    set[formKey] = not set[formKey] or nil

    if FormCount(set) == 0 or FormCount(set) == #Const.DRUID_FORMS then
        entry.forms = nil
    else
        entry.forms = set
    end
end

function EntryMenu.SetAllForms(entry)
    if entry then entry.forms = nil end
end

function EntryMenu.IsAllForms(entry)
    local forms = entry and entry.forms
    return type(forms) ~= "table" or not next(forms)
end

-- Feral abilities that work in cat and bear are common enough to earn a row of
-- their own; everything past these goes through "Choose forms".
EntryMenu.FORM_PRESETS = {
    { label = "All forms",        forms = nil },
    { label = "Cat only",         forms = { "cat" } },
    { label = "Bear only",        forms = { "bear" } },
    { label = "Cat and Bear",     forms = { "cat", "bear" } },
    { label = "Moonkin only",     forms = { "moonkin" } },
    { label = "Caster / No Form", forms = { "caster" } },
}

local function SetOf(list)
    if not list then return nil end
    local set = {}
    for _, key in ipairs(list) do set[key] = true end
    return set
end

function EntryMenu.MatchesPreset(entry, preset)
    local forms = entry and entry.forms
    local want = SetOf(preset.forms)

    if not want then return EntryMenu.IsAllForms(entry) end
    if EntryMenu.IsAllForms(entry) then return false end

    for key in pairs(want) do
        if forms[key] ~= true then return false end
    end
    return FormCount(forms) == FormCount(want)
end

function EntryMenu.ApplyPreset(entry, preset)
    if not entry then return end
    entry.forms = SetOf(preset.forms)
end

function EntryMenu.Close()
    if _G.CloseDropDownMenus then CloseDropDownMenus() end
end

local function Refresh()
    if menu and _G.UIDropDownMenu_Refresh then
        UIDropDownMenu_Refresh(menu, false, 1)
    end
end

local function AddTitle(text)
    local info = UIDropDownMenu_CreateInfo()
    info.text = text
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info)
end

local function ResolveEntry(context)
    local entry = context and context.entry
    if type(entry) == "function" then return entry() end
    return entry
end

-- context = { entry (table or getter), groupKey, onChanged, allowMove }
function EntryMenu.Build(context, level, menuList)
    local entry = ResolveEntry(context)
    if not entry then return end

    local function changed()
        if context.onChanged then context.onChanged() end
    end

    if menuList == "forms" then
        for _, opt in ipairs(Const.FORM_TAG_OPTIONS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.label
            info.isNotRadio = true
            info.keepShownOnClick = true
            info.checked = not EntryMenu.IsAllForms(entry)
                and Const.FormAllows(entry.forms, opt.value)
            info.func = function()
                EntryMenu.ToggleForm(ResolveEntry(context), opt.value)
                changed()
                Refresh()
            end
            UIDropDownMenu_AddButton(info, level)
        end
        return
    end

    local dot = UIDropDownMenu_CreateInfo()
    dot.text = "Track its aura (buff or DoT)"
    dot.isNotRadio = true
    dot.checked = entry.trackDebuff and true or false
    dot.func = function()
        local live = ResolveEntry(context)
        if not live then return end
        live.trackDebuff = not live.trackDebuff or nil
        changed()
        EntryMenu.Close()
    end
    UIDropDownMenu_AddButton(dot)

    local rank = UIDropDownMenu_CreateInfo()
    rank.text = "Follow the highest rank I know"
    rank.isNotRadio = true
    rank.checked = entry.rankIndependent ~= false
    rank.func = function()
        local live = ResolveEntry(context)
        if not live then return end
        live.rankIndependent = live.rankIndependent == false
        changed()
        EntryMenu.Close()
    end
    UIDropDownMenu_AddButton(rank)

    if IsDruid() then
        AddTitle("Track in forms")

        -- One click for the cases people actually want. Ticking four checkboxes
        -- to say "this is a cat ability" was the wrong shape for the job.
        for _, preset in ipairs(EntryMenu.FORM_PRESETS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = preset.label
            info.checked = EntryMenu.MatchesPreset(entry, preset)
            info.func = function()
                EntryMenu.ApplyPreset(ResolveEntry(context), preset)
                changed()
                EntryMenu.Close()
            end
            UIDropDownMenu_AddButton(info)
        end

        -- Anything the presets do not cover.
        local custom = UIDropDownMenu_CreateInfo()
        custom.text = "Choose forms"
        custom.notCheckable = true
        custom.hasArrow = true
        custom.menuList = "forms"
        custom.func = nil
        UIDropDownMenu_AddButton(custom)
    end

    if context.groupKey and context.allowMove then
        AddTitle("Move to")

        for _, key in ipairs(Const.GROUP_ORDER) do
            if key ~= context.groupKey then
                local info = UIDropDownMenu_CreateInfo()
                info.text = Const.GROUP_LABELS[key] or key
                info.notCheckable = true
                info.func = function()
                    ns.DB:RemoveSpell(context.groupKey, entry.spellID)
                    local target = ns.DB:GetGroup(key)
                    if target then
                        target.spells[#target.spells + 1] = ns.DeepCopy(entry)
                    end
                    changed()
                    EntryMenu.Close()
                end
                UIDropDownMenu_AddButton(info)
            end
        end

        local remove = UIDropDownMenu_CreateInfo()
        remove.text = "|cffff5555Remove from this group|r"
        remove.notCheckable = true
        remove.func = function()
            ns.DB:RemoveSpell(context.groupKey, entry.spellID)
            changed()
            EntryMenu.Close()
        end
        UIDropDownMenu_AddButton(remove)
    end
end

function EntryMenu.Show(anchor, context)
    if not _G.UIDropDownMenu_Initialize or not _G.ToggleDropDownMenu then return false end

    if not menu then
        menu = CreateFrame("Frame", "CDMCEntryMenu", UIParent, "UIDropDownMenuTemplate")
    end

    EntryMenu.Close()
    UIDropDownMenu_Initialize(menu, function(_, level, menuList)
        EntryMenu.Build(context, level, menuList)
    end, "MENU")
    ToggleDropDownMenu(1, nil, menu, anchor or "cursor", 0, 0)
    return true
end
