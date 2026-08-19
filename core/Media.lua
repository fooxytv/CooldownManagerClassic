local addonName, ns = ...

local Media = {}
ns.Media = Media

local LSM = _G.LibStub and LibStub("LibSharedMedia-3.0", true)
Media.lib = LSM

function Media.Fetch(mediatype, key, fallback)
    if LSM and key and key ~= "" then
        local path = LSM:Fetch(mediatype, key, true)
        if path then return path end
    end
    return fallback
end

function Media.List(mediatype)
    if LSM then return LSM:List(mediatype) or {} end
    return {}
end

Media.BUILTIN = {
    border = {
        ["Blizzard Tooltip"] = "Interface\\Tooltips\\UI-Tooltip-Border",
        ["Blizzard Dialog"]  = "Interface\\DialogFrame\\UI-DialogBox-Border",
        ["Blizzard Achievement"] = "Interface\\AchievementFrame\\UI-Achievement-WoodBorder",
        ["Solid"]            = "Interface\\Buttons\\WHITE8X8",
    },
    statusbar = {
        ["Blizzard"]      = "Interface\\TargetingFrame\\UI-StatusBar",
        ["Blizzard Raid"] = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill",
        ["Solid"]         = "Interface\\Buttons\\WHITE8X8",
    },
}

function Media.RegisterBuiltins()
    if not LSM then return false end

    for mediatype, entries in pairs(Media.BUILTIN) do
        for name, path in pairs(entries) do
            LSM:Register(mediatype, name, path)
        end
    end

    return true
end

Media.RegisterBuiltins()
