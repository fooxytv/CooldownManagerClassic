-- Luacheck configuration for Cooldown Manager Classic

std = "lua51"
max_line_length = false

exclude_files = {
    "ci/**",
}

globals = {
    -- API namespaces
    "C_Spell",
    "C_SpellBook",
    "C_UnitAuras",
    "C_Engraving",
    "C_Timer",
    "C_TooltipInfo",
    "Enum",
    "EventRegistry",
    "EditModeManagerFrame",
    "TooltipUtil",

    -- API functions
    "CreateFrame",
    "GetTime",
    "GetBuildInfo",
    "GetRealmName",
    "UnitName",
    "UnitClass",
    "UnitAura",
    "GetSpellInfo",
    "GetSpellCooldown",
    "GetSpellCharges",
    "GetSpellBookItemInfo",
    "GetSpellBookItemName",
    "GetNumSpellTabs",
    "GetSpellTabInfo",
    "IsPassiveSpell",
    "IsSpellKnown",
    "IsPlayerSpell",
    "PickupSpellBookItem",
    "hooksecurefunc",
    "wipe",
    "tinsert",
    "bit",

    -- UI globals
    "UIParent",
    "GameTooltip",
    "DEFAULT_CHAT_FRAME",
    "UISpecialFrames",
    "StaticPopupDialogs",
    "StaticPopup_Show",
    "FauxScrollFrame_Update",
    "FauxScrollFrame_GetOffset",
    "FauxScrollFrame_OnVerticalScroll",
    "SlashCmdList",
    "SLASH_CDMC1",
    "SLASH_CDMC2",
    "BOOKTYPE_SPELL",
    "ACCEPT",
    "CANCEL",
    "CLOSE",

    -- Project globals
    "WOW_PROJECT_ID",
    "WOW_PROJECT_MAINLINE",
    "WOW_PROJECT_CLASSIC",
    "WOW_PROJECT_BURNING_CRUSADE_CLASSIC",
    "WOW_PROJECT_WRATH_CLASSIC",
    "WOW_PROJECT_CATACLYSM_CLASSIC",
    "WOW_PROJECT_MISTS_CLASSIC",

    -- SavedVariables
    "CooldownManagerClassicDB",
}

read_globals = {
    "print",
    "pairs",
    "ipairs",
    "type",
    "tostring",
    "tonumber",
    "string",
    "table",
    "math",
    "select",
    "unpack",
    "next",
    "setmetatable",
    "getmetatable",
    "pcall",
    "error",
    "assert",
}
