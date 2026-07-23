local addonName, ns = ...

local Const = ns.Constants

-- Profile import/export.
--
-- Deliberately not a general Lua serialiser: WoW addons cannot loadstring, so
-- a generic format would need a generic parser. Instead the profile is written
-- as a small line-based format whose grammar is fixed, which keeps the reader
-- short and makes a malformed string a parse error rather than a surprise.
--
--   CDMC1:<CLASS>:<flavor>:<base64 payload>
--
-- Payload lines:
--   v=<formatVersion>
--   G=<groupKey>|<iconSize>|<spacing>|<growth>|<relativePoint>|<x>|<y>|<enabled>
--   S=<spellID>|<rankIndependent>      (applies to the most recent G)

local Serialization = {}
ns.Serialization = Serialization

--------------------------------------------------------------------------------
-- Base64
--------------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_LOOKUP = {}
for i = 1, #B64 do
    B64_LOOKUP[B64:sub(i, i)] = i - 1
end

local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local function B64Char(sextet)
    local index = band(sextet, 63) + 1
    return B64:sub(index, index)
end

local function Base64Encode(input)
    local out = {}

    for i = 1, #input, 3 do
        local b1 = input:byte(i)
        local b2 = input:byte(i + 1)
        local b3 = input:byte(i + 2)

        local n = lshift(b1, 16) + lshift(b2 or 0, 8) + (b3 or 0)

        out[#out + 1] = B64Char(rshift(n, 18))
        out[#out + 1] = B64Char(rshift(n, 12))
        out[#out + 1] = b2 and B64Char(rshift(n, 6)) or "="
        out[#out + 1] = b3 and B64Char(n) or "="
    end

    return table.concat(out)
end

local function Base64Decode(input)
    input = input:gsub("[^A-Za-z0-9+/=]", "")
    local out = {}

    for i = 1, #input, 4 do
        local c1 = B64_LOOKUP[input:sub(i, i)]
        local c2 = B64_LOOKUP[input:sub(i + 1, i + 1)]
        if not c1 or not c2 then return nil end

        local c3 = B64_LOOKUP[input:sub(i + 2, i + 2)]
        local c4 = B64_LOOKUP[input:sub(i + 3, i + 3)]

        local n = lshift(c1, 18) + lshift(c2, 12) + lshift(c3 or 0, 6) + (c4 or 0)

        out[#out + 1] = string.char(band(rshift(n, 16), 255))
        if c3 then out[#out + 1] = string.char(band(rshift(n, 8), 255)) end
        if c4 then out[#out + 1] = string.char(band(n, 255)) end
    end

    return table.concat(out)
end

--------------------------------------------------------------------------------
-- Scalars
--------------------------------------------------------------------------------

-- Appearance tables are flat maps of scalars, so rather than a fixed field order
-- that silently drops anything added later, each value carries a one-character
-- type tag. A profile written by a build that knows more settings than this one
-- still imports; the unknown keys simply ride along.
local function EncodeScalar(value)
    local kind = type(value)
    if kind == "boolean" then
        return value and "b1" or "b0"
    elseif kind == "number" then
        return "n" .. tostring(value)
    elseif kind == "string" then
        return "s" .. value
    end
    return nil
end

local function DecodeScalar(text)
    if not text or text == "" then return nil end

    local tag, rest = text:sub(1, 1), text:sub(2)
    if tag == "b" then
        return rest == "1"
    elseif tag == "n" then
        return tonumber(rest)
    elseif tag == "s" then
        return rest
    end
    return nil
end

local function WritePosition(lines, prefix, position)
    position = position or {}
    lines[#lines + 1] = ("%s=%s|%s|%d|%d"):format(
        prefix,
        position.point or "CENTER",
        position.relativePoint or "CENTER",
        math.floor((position.x or 0) + 0.5),
        math.floor((position.y or 0) + 0.5)
    )
end

--- Keys are sorted so the same profile always produces the same string, which
--- makes two exports comparable by eye.
local function WriteAppearance(lines, prefix, appearance)
    if type(appearance) ~= "table" then return end

    local keys = {}
    for key in pairs(appearance) do
        if type(key) == "string" then keys[#keys + 1] = key end
    end
    table.sort(keys)

    for _, key in ipairs(keys) do
        local encoded = EncodeScalar(appearance[key])
        if encoded then
            lines[#lines + 1] = ("%s=%s=%s"):format(prefix, key, encoded)
        end
    end
end

--------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------

function Serialization:Export(profile)
    profile = profile or ns.DB:GetProfile()
    if not profile then return nil, "No profile to export." end

    local lines = { ("v=%d"):format(Const.PROFILE_FORMAT_VERSION) }

    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = profile.groups[key]
        if group then
            lines[#lines + 1] = "G=" .. key
            lines[#lines + 1] = "Ge=" .. (group.enabled == false and "0" or "1")
            WritePosition(lines, "Gp", group.position)
            WriteAppearance(lines, "Ga", group.appearance)

            for _, entry in ipairs(group.spells) do
                -- The name is carried so a rank-independent entry can resolve on
                -- a character that knows a different rank, or none yet.
                lines[#lines + 1] = ("S=%d|%d|%s"):format(
                    entry.spellID,
                    entry.rankIndependent and 1 or 0,
                    entry.name or ""
                )
            end
        end
    end

    for _, key in ipairs(Const.BAR_ORDER) do
        local bar = profile.bars and profile.bars[key]
        if bar then
            lines[#lines + 1] = "B=" .. key
            lines[#lines + 1] = "Be=" .. (bar.enabled and "1" or "0")
            WritePosition(lines, "Bp", bar.position)
            WriteAppearance(lines, "Ba", bar.appearance)
        end
    end

    local _, class = UnitClass("player")
    return ("CDMC%d:%s:%s:%s"):format(
        Const.PROFILE_FORMAT_VERSION,
        class or "UNKNOWN",
        ns.Compat.GetProfileFlavor(),
        Base64Encode(table.concat(lines, "\n"))
    )
end

--------------------------------------------------------------------------------
-- Import
--------------------------------------------------------------------------------

--- A group seeded with this build's defaults, so a field the incoming string
--- does not mention lands on something sane rather than nil.
local function NewGroupShell(key)
    local appearance = ns.DeepCopy(Const.DEFAULT_APPEARANCE)
    for option, value in pairs(Const.GROUP_APPEARANCE[key] or {}) do
        appearance[option] = value
    end

    return {
        enabled = true,
        spells = {},
        position = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 0 },
        appearance = appearance,
    }
end

local function NewBarShell()
    return {
        enabled = false,
        position = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 0 },
        appearance = ns.DeepCopy(Const.DEFAULT_BAR_APPEARANCE),
    }
end

local function ParsePosition(body)
    local point, relativePoint, x, y = body:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    if not point then return nil end

    return {
        point = point ~= "" and point or "CENTER",
        relativePoint = relativePoint ~= "" and relativePoint or "CENTER",
        x = tonumber(x) or 0,
        y = tonumber(y) or 0,
    }
end

--- Format 2: every appearance field, positions, spell names and the bars.
local function ParseV2(blob)
    local profile = { version = 2, groups = {}, bars = {} }
    local current, currentIsGroup

    for line in blob:gmatch("[^\n]+") do
        local tag, body = line:match("^(%a+)=(.*)$")

        if tag == "G" then
            current, currentIsGroup = NewGroupShell(body), true
            profile.groups[body] = current

        elseif tag == "B" then
            current, currentIsGroup = NewBarShell(), false
            profile.bars[body] = current

        elseif current and (tag == "Ge" or tag == "Be") then
            current.enabled = body == "1"

        elseif current and (tag == "Gp" or tag == "Bp") then
            current.position = ParsePosition(body) or current.position

        elseif current and (tag == "Ga" or tag == "Ba") then
            local key, encoded = body:match("^(.-)=(.*)$")
            if key and key ~= "" then
                local value = DecodeScalar(encoded)
                if value ~= nil then current.appearance[key] = value end
            end

        elseif current and currentIsGroup and tag == "S" then
            -- Negative IDs are the weapon-enchant pseudo-spells, so the sign is
            -- part of the pattern. The name is whatever remains on the line.
            local spellID, rankIndependent, name = body:match("^(%-?%d+)|([01])|(.*)$")
            spellID = tonumber(spellID)
            if spellID then
                current.spells[#current.spells + 1] = {
                    spellID = spellID,
                    rankIndependent = rankIndependent ~= "0",
                    name = name ~= "" and name or nil,
                }
            end
        end
    end

    return profile
end

--- Format 1: the original, which carried only the spell list plus icon size,
--- spacing, growth and position. Kept so strings shared before v2 still import.
local function ParseV1(blob)
    local profile = { version = 1, groups = {} }
    local currentGroup

    for line in blob:gmatch("[^\n]+") do
        local kind, body = line:match("^(%a)=(.+)$")

        if kind == "G" then
            local key, iconSize, spacing, growth, relativePoint, x, y, enabled =
                body:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")

            if key then
                currentGroup = NewGroupShell(key)
                currentGroup.enabled = enabled ~= "0"
                currentGroup.position.relativePoint = relativePoint
                currentGroup.position.x = tonumber(x) or 0
                currentGroup.position.y = tonumber(y) or 0
                currentGroup.appearance.iconSize = tonumber(iconSize) or currentGroup.appearance.iconSize
                currentGroup.appearance.spacing = tonumber(spacing) or currentGroup.appearance.spacing
                currentGroup.appearance.growth = growth
                profile.groups[key] = currentGroup
            end

        elseif kind == "S" and currentGroup then
            local spellID, rankIndependent = body:match("^([^|]+)|([^|]+)$")
            spellID = tonumber(spellID)
            if spellID then
                currentGroup.spells[#currentGroup.spells + 1] = {
                    spellID = spellID,
                    rankIndependent = rankIndependent ~= "0",
                }
            end
        end
    end

    return profile
end

--- Returns profile, class, flavor on success, or nil plus an error message.
function Serialization:Import(text)
    if type(text) ~= "string" or text == "" then
        return nil, "Nothing to import."
    end

    -- Whitespace is stripped wholesale: the string is one line as exported, but
    -- pasting it through chat or a wrapped edit box can fold newlines into it.
    text = text:gsub("%s+", "")

    local version, class, flavor, payload = text:match("^CDMC(%d+):([^:]+):([^:]+):(.+)$")
    if not version then
        return nil, "That does not look like a Cooldown Manager Classic string."
    end

    version = tonumber(version)
    if version > Const.PROFILE_FORMAT_VERSION then
        return nil, ("That profile was exported by a newer version (format %d)."):format(version)
    end

    local blob = Base64Decode(payload)
    if not blob then
        return nil, "The profile string is corrupt."
    end

    local profile = (version >= 2) and ParseV2(blob) or ParseV1(blob)

    if not profile or not next(profile.groups) then
        return nil, "The profile string contained no groups."
    end

    return ns.DB:NormalizeProfile(profile), class, flavor
end
