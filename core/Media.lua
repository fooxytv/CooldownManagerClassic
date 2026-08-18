local addonName, ns = ...

-- Thin wrapper over LibSharedMedia so the rest of the addon can ask for a font
-- or bar texture by name and get a usable path, with a graceful fallback when
-- the library is absent (the headless test does not load libs) or the name is
-- not registered.
--
-- Media types used here: "font", "statusbar" and "border". A border is an edge
-- file, which only the backdrop API can draw -- see Compat.SetBorderTexture for
-- the client without one.

local Media = {}
ns.Media = Media

local LSM = _G.LibStub and LibStub("LibSharedMedia-3.0", true)
Media.lib = LSM

-- The path for a registered medium, or `fallback` when the library is absent or
-- the key is empty/unknown. An empty key -- the "Default" choice in the picker
-- -- always falls back, which is how "use the built-in look" is expressed.
function Media.Fetch(mediatype, key, fallback)
    if LSM and key and key ~= "" then
        -- The trailing true returns nil for an unknown key rather than LSM's own
        -- default, so a bad name falls back to ours.
        local path = LSM:Fetch(mediatype, key, true)
        if path then return path end
    end
    return fallback
end

-- Registered names of a media type, for the settings dropdowns. Empty without
-- the library.
function Media.List(mediatype)
    if LSM then return LSM:List(mediatype) or {} end
    return {}
end

-- LibSharedMedia ships no media of its own -- its lists hold whatever *other*
-- addons register. On a client with none of them the Border and Bar Texture
-- pickers offer nothing but "Default", which reads as a broken feature rather
-- than an empty library, so the client's own art is registered here.
--
-- Paths must live under Interface\ or LSM silently refuses them, and these all
-- exist on Classic Era. Register keeps the first claim on a name, so an addon
-- that registered the same name first is left alone.
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
