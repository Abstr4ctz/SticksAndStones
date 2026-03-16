-- SticksAndStones: Totems/FSM.lua
-- Pure finite-state transition engine for totem slot management.
-- Owns TotemsInternal's state enums, event enums, transition table, and
-- smart-cast policy helper.
-- Exports pure transition and policy helpers on TotemsInternal.
-- Side effects: load-time writes onto TotemsInternal only. Zero WoW API
-- calls. Zero globals beyond the shared pod table.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = TotemsInternal  -- created by Totems facade, loaded first per TOC order

------------------------------------------------------------------------
-- State enums
------------------------------------------------------------------------

-- QA: secondary spell remembered when the active totem displaces the chosen one.
M.IDLE             = 1  -- Situation 1: Empty
M.CHOSEN           = 2  -- Situation 2: Chosen only
M.ACTIVE_CHOSEN    = 3  -- Situation 3: Active equals Chosen
M.CHOSEN_ACTIVE    = 4  -- Situation 4: Chosen + different Active
M.EMPTY_ACTIVE     = 5  -- Situation 5: Active only
M.EMPTY_QA         = 6  -- Situation 6: QA only
M.CHOSEN_QA        = 7  -- Situation 7: Chosen + QA
M.ACTIVE_CHOSEN_QA = 8  -- Situation 8: Active equals Chosen + QA

------------------------------------------------------------------------
-- Event enums
------------------------------------------------------------------------

M.E_LMB      = 1
M.E_RMB      = 2
M.E_SPAWN    = 3
M.E_DEATH    = 4
M.E_SET_LOAD = 5
M.E_PEEK_LMB = 6
M.E_PEEK_RMB = 7

------------------------------------------------------------------------
-- State classification tables
------------------------------------------------------------------------

-- States where qaId is a valid occupied field.
local QA_STATES = {
    [M.EMPTY_QA]         = true,
    [M.CHOSEN_QA]        = true,
    [M.ACTIVE_CHOSEN_QA] = true,
}

-- States where death saves the active totem into QA before clearing.
local DEATH_SAVES_QA = {
    [M.CHOSEN_ACTIVE] = true,   -- Situation 4: active saved to QA
    [M.EMPTY_ACTIVE]  = true,   -- Situation 5: active saved to QA
}

-- Explicit next-state after E_DEATH. Only states with an active totem appear.
local DEATH_NEXT = {
    [M.ACTIVE_CHOSEN]    = M.CHOSEN,    -- Situation 3 -> 2
    [M.CHOSEN_ACTIVE]    = M.CHOSEN_QA, -- Situation 4 -> 7
    [M.EMPTY_ACTIVE]     = M.EMPTY_QA,  -- Situation 5 -> 6
    [M.ACTIVE_CHOSEN_QA] = M.CHOSEN_QA, -- Situation 8 -> 7
}

local SMART_CAST_SKIP_STATES = {
    [M.ACTIVE_CHOSEN]    = true,
    [M.ACTIVE_CHOSEN_QA] = true,
}

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

-- QA field manipulation.
local function hasDistinctQA(slot)
    return slot.qaId ~= nil and slot.qaId ~= slot.chosenId
end

local function ejectChosenToQA(slot)
    slot.qaId = slot.chosenId
    slot.chosenId = nil
end

local function promoteQA(slot)
    slot.chosenId = slot.qaId
    slot.qaId = nil
end

-- Unified state resolver covering all 8 Situations.
-- Branches on (chosenId, activeGuid, chosenId==activeId, hasDistinctQA).
-- Pure query: returns the canonical state without mutating the slot.
local function resolveState(slot)
    local hasChosen = slot.chosenId ~= nil
    local hasActive = slot.activeGuid ~= nil

    if not hasChosen then
        if hasActive then return M.EMPTY_ACTIVE end              -- Situation 5
        if slot.qaId ~= nil then return M.EMPTY_QA end           -- Situation 6
        return M.IDLE                                             -- Situation 1
    end
    if not hasActive then
        if hasDistinctQA(slot) then return M.CHOSEN_QA end        -- Situation 7
        return M.CHOSEN                                           -- Situation 2
    end
    if slot.chosenId == slot.activeId then
        if hasDistinctQA(slot) then return M.ACTIVE_CHOSEN_QA end -- Situation 8
        return M.ACTIVE_CHOSEN                                    -- Situation 3
    end
    return M.CHOSEN_ACTIVE                                        -- Situation 4
end

-- Enforces the invariant that qaId is nil in non-QA states.
-- Called after resolveState in handleSpawn and handleSetLoad.
-- NOT called in handleDeath (death uses explicit DEATH_SAVES_QA / DEATH_NEXT).
local function cleanupQA(slot, state)
    if not QA_STATES[state] then
        slot.qaId = nil
    end
end

------------------------------------------------------------------------
-- Private handlers
------------------------------------------------------------------------

-- Spawn, death, and set-load transition handlers.
local function handleSpawn(slot, spellId, guid, spawnedAt, duration)
    -- Save the displaced active spell before activeId is overwritten.
    if slot.activeGuid ~= nil and slot.activeId ~= slot.chosenId then
        slot.qaId = slot.activeId
    end

    slot.activeId   = spellId
    slot.activeGuid = guid
    slot.spawnedAt  = spawnedAt
    slot.duration   = duration

    local state = resolveState(slot)
    cleanupQA(slot, state)
    return state, nil
end

-- Death transitions use explicit lookup tables (DEATH_SAVES_QA / DEATH_NEXT)
-- rather than resolveState/cleanupQA, keeping them simple and verifiable.
local function handleDeath(slot)
    local nextState = DEATH_NEXT[slot.state]
    if not nextState then return nil, nil end

    if DEATH_SAVES_QA[slot.state] then
        slot.qaId = slot.activeId
    end

    slot.activeId   = nil
    slot.activeGuid = nil
    slot.spawnedAt  = nil
    slot.duration   = nil

    return nextState, nil
end

local function handleSetLoad(slot, spellId)
    slot.chosenId = spellId
    local state = resolveState(slot)
    cleanupQA(slot, state)
    return state, nil
end

------------------------------------------------------------------------
-- Transition helpers
-- Each returns (newState, castSpellId).
------------------------------------------------------------------------

local function castChosen(slot) return slot.state, slot.chosenId end
local function castActive(slot) return slot.state, slot.activeId end
local function castQA(slot)     return slot.state, slot.qaId end

-- RMB on EMPTY_ACTIVE / PEEK_RMB on EMPTY_ACTIVE: adopt active as chosen.
local function adoptActive(slot)
    slot.chosenId = slot.activeId
    slot.qaId = nil
    return M.ACTIVE_CHOSEN, nil
end

-- RMB on ACTIVE_CHOSEN / CHOSEN_ACTIVE / ACTIVE_CHOSEN_QA:
-- clear chosen and QA, active stays.
local function clearChosenAndQA(slot)
    slot.chosenId = nil
    slot.qaId = nil
    return M.EMPTY_ACTIVE, nil
end

-- RMB on CHOSEN / CHOSEN_QA: eject chosen to QA (replaces existing QA).
local function ejectToQAState(slot)
    ejectChosenToQA(slot)
    return M.EMPTY_QA, nil
end

-- RMB on EMPTY_QA / PEEK_RMB on EMPTY_QA: promote QA to chosen.
local function promoteQAToChosen(slot)
    promoteQA(slot)
    return M.CHOSEN, nil
end

-- PEEK_RMB on ACTIVE_CHOSEN_QA: promote QA to chosen, active stays.
local function promoteQAKeepActive(slot)
    promoteQA(slot)
    return M.CHOSEN_ACTIVE, nil
end

-- PEEK_RMB on CHOSEN_ACTIVE: active becomes chosen, old chosen → QA.
local function replaceChosenWithActive(slot)
    local oldChosenId = slot.chosenId
    slot.chosenId = slot.activeId
    slot.qaId = oldChosenId
    return M.ACTIVE_CHOSEN_QA, nil
end

-- PEEK_RMB on CHOSEN_QA: swap chosen and QA positions.
local function swapChosenAndQA(slot)
    local oldChosenId = slot.chosenId
    slot.chosenId = slot.qaId
    slot.qaId = oldChosenId
    return M.CHOSEN_QA, nil
end

------------------------------------------------------------------------
-- Transition table
-- TRANSITIONS[state][event] = handler(slot, a, b, c, d) -> (newState, castSpellId)
------------------------------------------------------------------------

local TRANSITIONS = {
    -- Situation 1: Empty
    [M.IDLE] = {
        [M.E_SPAWN]    = handleSpawn,
        [M.E_SET_LOAD] = handleSetLoad,
    },
    -- Situation 2: Chosen only
    [M.CHOSEN] = {
        [M.E_LMB]      = castChosen,
        [M.E_RMB]      = ejectToQAState,
        [M.E_SPAWN]    = handleSpawn,
        [M.E_SET_LOAD] = handleSetLoad,
    },
    -- Situation 3: Active equals Chosen
    [M.ACTIVE_CHOSEN] = {
        [M.E_LMB]      = castChosen,
        [M.E_RMB]      = clearChosenAndQA,
        [M.E_SPAWN]    = handleSpawn,
        [M.E_DEATH]    = handleDeath,
        [M.E_SET_LOAD] = handleSetLoad,
    },
    -- Situation 4: Chosen + different Active
    [M.CHOSEN_ACTIVE] = {
        [M.E_LMB]      = castChosen,
        [M.E_RMB]      = clearChosenAndQA,
        [M.E_SPAWN]    = handleSpawn,
        [M.E_DEATH]    = handleDeath,
        [M.E_SET_LOAD] = handleSetLoad,
        [M.E_PEEK_LMB] = castActive,
        [M.E_PEEK_RMB] = replaceChosenWithActive,
    },
    -- Situation 5: Active only
    [M.EMPTY_ACTIVE] = {
        [M.E_LMB]      = castActive,
        [M.E_RMB]      = adoptActive,
        [M.E_SPAWN]    = handleSpawn,
        [M.E_DEATH]    = handleDeath,
        [M.E_SET_LOAD] = handleSetLoad,
        [M.E_PEEK_LMB] = castActive,
        [M.E_PEEK_RMB] = adoptActive,
    },
    -- Situation 6: QA only
    [M.EMPTY_QA] = {
        [M.E_LMB]      = castQA,
        [M.E_RMB]      = promoteQAToChosen,
        [M.E_SPAWN]    = handleSpawn,
        [M.E_SET_LOAD] = handleSetLoad,
        [M.E_PEEK_LMB] = castQA,
        [M.E_PEEK_RMB] = promoteQAToChosen,
    },
    -- Situation 7: Chosen + QA
    [M.CHOSEN_QA] = {
        [M.E_LMB]      = castChosen,
        [M.E_RMB]      = ejectToQAState,
        [M.E_SPAWN]    = handleSpawn,
        [M.E_SET_LOAD] = handleSetLoad,
        [M.E_PEEK_LMB] = castQA,
        [M.E_PEEK_RMB] = swapChosenAndQA,
    },
    -- Situation 8: Active equals Chosen + QA
    [M.ACTIVE_CHOSEN_QA] = {
        [M.E_LMB]      = castChosen,
        [M.E_RMB]      = clearChosenAndQA,
        [M.E_SPAWN]    = handleSpawn,
        [M.E_DEATH]    = handleDeath,
        [M.E_SET_LOAD] = handleSetLoad,
        [M.E_PEEK_LMB] = castQA,
        [M.E_PEEK_RMB] = promoteQAKeepActive,
    },
}

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function shouldSmartCastChosen(slot)
    if slot.chosenId == nil then return false end

    if not SMART_CAST_SKIP_STATES[slot.state] then
        return true
    end

    if slot.isInRange == false then
        return true
    end
    return false
end

-- DispatchEvent(slot, event, a, b, c, d) -> (newState, castSpellId)
-- Returns (nil, nil) for missing slot or unhandled (state, event) pair.
-- Explicit args instead of varargs for Lua 5.0 compatibility.
local function dispatchEvent(slot, event, a, b, c, d)
    if not slot then return nil, nil end

    local eventHandlers = TRANSITIONS[slot.state]
    local handler = eventHandlers and eventHandlers[event]
    if not handler then return nil, nil end

    local newState, castSpellId = handler(slot, a, b, c, d)
    if newState ~= nil then
        slot.state = newState
    end
    return newState, castSpellId
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.DispatchEvent         = dispatchEvent
M.ShouldSmartCastChosen = shouldSmartCastChosen
