--[[
Copyright (C) 2023 FooxyTV (simon@fooxy.tv)
All rights reserved.

Programming by: FooxyTV
]]

local addonName, ns = ...

local Const = ns.Constants
local Compat = ns.Compat

local Range = {}
ns.Range = Range

-- Whether the target is worth measuring against is the same answer for every
-- tracked spell in every group, so it is resolved once per update tick and the
-- per-spell results are memoised for that tick. Without this a full pass would
-- ask the client about the same target once per icon, several times a second.
local watching = false
local results = {}

-- Only groups that show castable abilities. Aura groups track what is already
-- on you, so how far away the target stands says nothing about them, and
-- Icon/BuffBar short-circuit them to white regardless.
--
-- Gated on the same setting that draws the colour: with usability tinting off
-- everywhere there is nothing for a poll to feed, and polling the client twice
-- a second to compute a colour no one renders is pure waste.
local function AnyGroupWantsRange()
    for _, key in ipairs(Const.GROUP_ORDER) do
        if not Const.AURA_GROUPS[key] then
            local settings = ns.DB:GetGroup(key)
            if settings and settings.enabled ~= false
                and settings.appearance
                and settings.appearance.colorByUsability ~= false
                and #settings.spells > 0
            then
                return true
            end
        end
    end
    return false
end

-- Call once at the top of an update pass, before any group reads a state.
function Range:Poll()
    wipe(results)
    watching = false

    if not (ns.DB and ns.DB.root) then return end
    if not UnitExists("target") then return end

    -- Hostile only. A friendly target makes the answer ambiguous -- an offensive
    -- spell reports out of range against an ally at any distance -- and turning
    -- half the bar red while healing a party member is worse than saying
    -- nothing.
    if not UnitCanAttack("player", "target") then return end

    if not AnyGroupWantsRange() then return end

    watching = true
end

-- True while there is something to measure, which is also the signal Core needs
-- to keep ticking: range changes with no event behind it, so an idle bar that
-- stopped its ticker would freeze on a stale colour.
function Range:IsWatching()
    return watching
end

function Range:IsOutOfRange(spellID)
    if not watching or not spellID then return false end

    local cached = results[spellID]
    if cached ~= nil then return cached end

    local inRange = Compat.IsSpellInRange(spellID, "target")

    -- nil means the client will not measure this pairing: a self buff, a spell
    -- with no range requirement, an entry that is not really a spell. Unknown is
    -- not the same as out of range, and conflating them turns every self buff
    -- red the moment a target is up.
    local outOfRange = (inRange == false)

    results[spellID] = outOfRange
    return outOfRange
end

function Range:Clear()
    wipe(results)
    watching = false
end
