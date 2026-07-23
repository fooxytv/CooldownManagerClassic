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
-- Export
--------------------------------------------------------------------------------

function Serialization:Export(profile)
    profile = profile or ns.DB:GetProfile()
    if not profile then return nil, "No profile to export." end

    local lines = { ("v=%d"):format(Const.PROFILE_FORMAT_VERSION) }

    for _, key in ipairs(Const.GROUP_ORDER) do
        local group = profile.groups[key]
        if group then
            local appearance = group.appearance
            local position = group.position

            lines[#lines + 1] = ("G=%s|%d|%d|%s|%s|%d|%d|%d"):format(
                key,
                appearance.iconSize or 40,
                appearance.spacing or 4,
                appearance.growth or "CENTER",
                position.relativePoint or "CENTER",
                position.x or 0,
                position.y or 0,
                group.enabled == false and 0 or 1
            )

            for _, entry in ipairs(group.spells) do
                lines[#lines + 1] = ("S=%d|%d"):format(
                    entry.spellID,
                    entry.rankIndependent and 1 or 0
                )
            end
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

--- Returns profile, class, flavor on success, or nil plus an error message.
function Serialization:Import(text)
    if type(text) ~= "string" or text == "" then
        return nil, "Nothing to import."
    end

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

    local profile = { version = version, groups = {} }
    local currentGroup

    for line in blob:gmatch("[^\n]+") do
        local kind, body = line:match("^(%a)=(.+)$")

        if kind == "G" then
            local key, iconSize, spacing, growth, relativePoint, x, y, enabled =
                body:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")

            if key then
                currentGroup = {
                    enabled = enabled ~= "0",
                    spells = {},
                    position = {
                        point = "CENTER",
                        relativePoint = relativePoint,
                        x = tonumber(x) or 0,
                        y = tonumber(y) or 0,
                    },
                    appearance = ns.DeepCopy(Const.DEFAULT_APPEARANCE),
                }
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

    if not next(profile.groups) then
        return nil, "The profile string contained no groups."
    end

    return ns.DB:NormalizeProfile(profile), class, flavor
end
