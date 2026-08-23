local addonName, ns = ...

local Const = ns.Constants

-- Reactive spell highlighting -- Retail's Cooldown Manager glows an icon when
-- the spell becomes the thing to press. Classic has no curated activation
-- database, so the trigger is a curated, data-driven rule table: while an aura
-- holds (optionally at a minimum stack count), the spells it names light up.
--
-- Rules match tracked entries by name, so they cover every rank without knowing
-- any spell ID, at the cost of being locale-sensitive (the same trade-off the
-- rest of the addon's name matching makes).

local Highlights = {}
ns.Highlights = Highlights

-- Keyed by class token. `sod = true` gates a rule to Season of Discovery.
--   aura       the buff whose presence arms the rule
--   minStacks  optional; the aura must be at or above this many applications
--   glow       spell names to light up while the rule is active
local RULES = {
    SHAMAN = {
        -- Maelstrom Weapon at max stacks: the next Lightning Bolt / Chain
        -- Lightning / heal is instant, so those are the payoff casts.
        {
            aura = "Maelstrom Weapon",
            minStacks = Const.MAELSTROM_MAX_STACKS,
            sod = true,
            glow = {
                "Lightning Bolt", "Chain Lightning",
                "Healing Wave", "Lesser Healing Wave", "Chain Heal",
            },
        },
    },
    WARLOCK = {
        -- Nightfall procs Shadow Trance, making the next Shadow Bolt instant.
        {
            aura = "Shadow Trance",
            glow = { "Shadow Bolt" },
        },
    },
}

-- Reactive abilities that light up from combat events rather than an aura or the
-- activation overlay. In Classic these become castable off a dodge / parry /
-- block and, unlike Retail, do not reliably fire the activation overlay, so they
-- are read straight from the combat log.
--   spell    tracked entry name to glow
--   window   seconds the ability stays castable after the trigger
--   trigger  which combat outcome arms it (see TRIGGERS)
local COMBAT_RULES = {
    WARRIOR = {
        -- Overpower: castable for a few seconds after the target dodges you.
        { spell = "Overpower", window = 5, trigger = "target_dodged" },
        -- Revenge: castable after you dodge, parry or fully block an attack.
        { spell = "Revenge", window = 5, trigger = "player_avoided" },
    },
    ROGUE = {
        -- Riposte: castable after you parry an attack.
        { spell = "Riposte", window = 5, trigger = "player_parried" },
    },
}

-- Maps a combat rule's trigger to the miss it arms on.
--   miss       the missType string ("DODGE" / "PARRY" / "BLOCK")
--   byPlayer   the player dealt the attack that was avoided (source)
--   onPlayer   the player avoided an incoming attack (dest)
local TRIGGERS = {
    target_dodged  = function(miss, byPlayer) return byPlayer and miss == "DODGE" end,
    player_avoided = function(miss, _, onPlayer)
        return onPlayer and (miss == "DODGE" or miss == "PARRY" or miss == "BLOCK")
    end,
    player_parried = function(miss, _, onPlayer) return onPlayer and miss == "PARRY" end,
}

-- Resolved once per class; class does not change within a session.
local activeRules
local activeCombatRules

-- Reused between passes so a refresh allocates nothing.
local glowNames = {}

-- Spell IDs the game itself has flagged as procced, via the Blizzard activation
-- overlay (SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/_HIDE). Kept as a set of live IDs
-- and folded into glowNames each pass by resolving each to its spell name, so it
-- matches tracked entries the same by-name way the rule table does -- covering
-- every rank of the spell the game glowed. Any is set means the overlay is
-- contributing this pass. This source is additive: Era's overlay coverage is
-- patchy, so it layers on top of the curated rules rather than replacing them.
local overlaySpells = {}
local overlayAny = false

-- Reactive combat abilities inside their post-dodge/parry window: spell name ->
-- GetTime() expiry. Folded into glowNames by name like the other sources.
local reactiveUntil = {}
local reactiveAny = false

-- Picks the rules that apply to the current character, dropping SoD-only rules
-- off Season of Discovery. Combat rules are resolved here too, so a class with
-- only reactive abilities (Warrior) and no aura rules is still covered.
function Highlights:ResolveRules()
    activeRules = {}
    activeCombatRules = {}

    local _, classToken = UnitClass("player")

    local classRules = RULES[classToken or ""]
    if classRules then
        for _, rule in ipairs(classRules) do
            if not rule.sod or ns.Compat.isSoD then
                activeRules[#activeRules + 1] = rule
            end
        end
    end

    local combatRules = COMBAT_RULES[classToken or ""]
    if combatRules then
        for _, rule in ipairs(combatRules) do
            activeCombatRules[#activeCombatRules + 1] = rule
        end
    end
end

-- Whether this character has any reactive combat abilities. Core uses it to
-- decide whether to register the (high-traffic) combat-log event at all.
function Highlights:HasCombatRules()
    if not activeCombatRules then self:ResolveRules() end
    return #activeCombatRules > 0
end

-- Whether a rule's aura condition is currently met.
function Highlights:RuleActive(rule)
    local data = ns.Auras:LookupByName(rule.aura)
    if not data then return false end

    if rule.minStacks then
        local stacks = data.applications or data.count or 0
        if stacks < rule.minStacks then return false end
    end

    return true
end

-- The game fired an activation-overlay glow for a spell. Record it; the next
-- Apply lights the matching tracked icon or bar. Called from the event handler.
function Highlights:OnOverlayShow(spellID)
    if not spellID then return end
    overlaySpells[spellID] = true
    overlayAny = true
end

-- The overlay glow for a spell ended.
function Highlights:OnOverlayHide(spellID)
    if not spellID then return end
    overlaySpells[spellID] = nil
    overlayAny = next(overlaySpells) ~= nil
end

-- Reads one combat-log event and arms any reactive rule it satisfies. This fires
-- on every swing in combat, so it exits fast when highlighting is off or the
-- event is not an avoided attack, and captures the payload without allocating.
function Highlights:OnCombatLogEvent()
    if not activeCombatRules or #activeCombatRules == 0 then return end
    if not (ns.DB and ns.DB:AreHighlightsEnabled()) then return end

    -- SWING_MISSED carries missType at position 12; the spell/range variants push
    -- it to 15 (three extra spell fields). SPELL_CAST_SUCCESS carries the spell
    -- name at 13. Everything else is neither an avoid nor a cast we care about.
    local _, subevent, _, sourceGUID, _, _, _, destGUID,
          _, _, _, arg12, arg13, _, arg15 = CombatLogGetCurrentEventInfo()

    local playerGUID = UnitGUID("player")

    -- Using a reactive ability clears its glow immediately, matching the action
    -- bar; otherwise the window would keep it lit for its remaining seconds.
    if subevent == "SPELL_CAST_SUCCESS" then
        if sourceGUID == playerGUID and arg13 and reactiveUntil[arg13] then
            reactiveUntil[arg13] = nil
            reactiveAny = next(reactiveUntil) ~= nil
            self:Apply()
        end
        return
    end

    local miss
    if subevent == "SWING_MISSED" then
        miss = arg12
    elseif subevent == "SPELL_MISSED" or subevent == "RANGE_MISSED" then
        miss = arg15
    else
        return
    end
    if not miss then return end

    local byPlayer = sourceGUID == playerGUID
    local onPlayer = destGUID == playerGUID
    if not (byPlayer or onPlayer) then return end

    local now = GetTime()
    local armed, longest = false, 0
    for _, rule in ipairs(activeCombatRules) do
        local predicate = TRIGGERS[rule.trigger]
        if predicate and predicate(miss, byPlayer, onPlayer) then
            reactiveUntil[rule.spell] = now + rule.window
            reactiveAny = true
            armed = true
            if rule.window > longest then longest = rule.window end
        end
    end

    if armed then
        self:Apply()
        -- Combat events alone would not fire again if the player stops taking
        -- swings, so schedule the clear when the window lapses.
        C_Timer.After(longest + 0.1, function() ns.Highlights:Apply() end)
    end
end

-- Recomputes which tracked icons should glow and applies it. Called from the
-- refresh pass, so it rides UNIT_AURA and every other update without its own
-- event registration. Highlighting is opt-in; when it is off, every icon is
-- cleared so turning it off takes effect immediately.
function Highlights:Apply()
    if not activeRules then self:ResolveRules() end

    wipe(glowNames)

    -- Building the candidate set does aura lookups and spell-name resolves, so it
    -- is skipped entirely when no group opts in; the per-group loop below still
    -- runs and clears any lingering glow.
    local anyEnabled = ns.DB and ns.DB:AreHighlightsEnabled()
    if anyEnabled then
        for _, rule in ipairs(activeRules) do
            if self:RuleActive(rule) then
                for _, name in ipairs(rule.glow) do
                    glowNames[name] = true
                end
            end
        end

        -- Fold the game's own activation-overlay procs into the same by-name set.
        -- Resolving each live spell ID to its name means a proc on any rank lights
        -- the tracked entry, and the match is spelling-for-spelling with the rules.
        if overlayAny then
            for spellID in pairs(overlaySpells) do
                local name = ns.Spellbook:GetName(spellID)
                if name then glowNames[name] = true end
            end
        end

        -- Reactive combat abilities still inside their post-dodge/parry window.
        -- Expired entries are pruned here, so a lapsed window stops contributing.
        if reactiveAny then
            local now = GetTime()
            local stillAny = false
            for name, expiry in pairs(reactiveUntil) do
                if expiry > now then
                    glowNames[name] = true
                    stillAny = true
                else
                    reactiveUntil[name] = nil
                end
            end
            reactiveAny = stillAny
        end
    end

    -- Cooldown groups, whether drawn as icons or as bars. Aura groups are skipped:
    -- a buff icon or bar is only on screen while its own aura is up, so a proc glow
    -- there is meaningless. Highlighting is per group, so each group is gated on
    -- its own toggle. Each glows through its own widget -- ButtonGlow for square
    -- icons, PixelGlow's animated border for rectangular bars.
    for _, key in ipairs(Const.GROUP_ORDER) do
        if not Const.AURA_GROUPS[key] then
            local group = ns.groups[key]
            if group then
                local on = anyEnabled and ns.DB:IsGroupHighlightEnabled(key)
                local widget = group.widget == ns.BuffBar and ns.BuffBar or ns.Icon
                for _, item in ipairs(group.icons) do
                    local name = item.entry and item.entry.name
                    widget:SetGlow(item, on and name ~= nil and glowNames[name] == true)
                end
            end
        end
    end
end

-- The active rule sets depend only on class, but a profile switch may change the
-- enable state; dropping both caches is cheap insurance and re-resolves them.
function Highlights:OnProfileChanged()
    activeRules = nil
    activeCombatRules = nil
end
