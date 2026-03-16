-- SticksAndStones: Totems/Poll.lua
-- Support module for poll-loop timing, expiry/range/existence collection, and spawn-
-- duration resolution in the Totems pod.
-- Owns the hidden poll frame, reusable buffers, timer state, and facade-wired
-- poll handlers.
-- Exports poll initialization/control and spawn-duration resolution on
-- TotemsInternal.
-- Side effects: creates a hidden private frame, reads TotemsInternal.slots,
-- TotemsInternal.bySpellId, TotemsInternal.hasUnitXP, and SNSConfig, and calls
-- GetTime(), GetSpellDuration(), and UnitXP() at runtime.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = TotemsInternal  -- created by Totems facade, loaded first per TOC order

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local VISUAL_TICK_INTERVAL = 0.1

local GetTime          = GetTime
local GetSpellDuration = GetSpellDuration
local UnitXP           = UnitXP

------------------------------------------------------------------------
-- Private state
------------------------------------------------------------------------

local pollFrame = CreateFrame("Frame", nil, UIParent)
pollFrame:Hide()

local pollingEnabled        = false
local pollFrameWired        = false
local lastVisualTick        = 0
local lastRangeTick         = 0
local expiredElements       = {}
local missingElements       = {}
local rangeStates           = {}
local expiredCount          = 0
local missingCount          = 0
local visualResultsCallback = nil
local rangeResultsCallback  = nil

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function resetTickState()
    lastVisualTick = 0
    lastRangeTick  = 0
end

local function hasActiveSlots()
    local slots = M.slots
    local slotCount = table.getn(slots)
    for i = 1, slotCount do
        local slot = slots[i]
        if slot and slot.activeGuid ~= nil then
            return true
        end
    end
    return false
end

local function clearElementBuffer(buffer, count)
    for i = 1, count do
        buffer[i] = nil
    end
end

local function clearRangeStates()
    local slotCount = table.getn(M.slots)
    for element = 1, slotCount do
        rangeStates[element] = nil
    end
end

local function isSlotExpired(slot, now)
    if slot.activeGuid == nil then return false end
    if slot.duration == nil then return false end
    if slot.duration <= 0 then return false end
    return now - (slot.spawnedAt or now) >= slot.duration
end

local function collectSlotRangeState(element, slot, collectRangeState, rangeOffset, nextMissingCount)
    if slot.activeGuid == nil then
        return nextMissingCount, false
    end

    local distance = UnitXP("distanceBetween", "player", slot.activeGuid)
    if distance == nil then
        -- UnitXP nil: totem no longer exists. Free death signal.
        nextMissingCount = nextMissingCount + 1
        missingElements[nextMissingCount] = element
        return nextMissingCount, false
    end

    if not collectRangeState then
        return nextMissingCount, false
    end

    local record = M.bySpellId[slot.activeId]
    if not record or not record.rangeYards then
        rangeStates[element] = true
        return nextMissingCount, true
    end

    local effectiveDist = distance - rangeOffset
    if effectiveDist < 0 then effectiveDist = 0 end
    rangeStates[element] = (effectiveDist <= record.rangeYards)
    return nextMissingCount, true
end

local function collectExpiredElements(now)
    clearElementBuffer(expiredElements, expiredCount)

    local nextExpiredCount = 0
    local slots = M.slots
    local slotCount = table.getn(slots)

    for i = 1, slotCount do
        local slot = slots[i]
        if isSlotExpired(slot, now) then
            nextExpiredCount = nextExpiredCount + 1
            expiredElements[nextExpiredCount] = i
        end
    end

    expiredCount = nextExpiredCount
    return expiredElements, nextExpiredCount
end

local function collectRangeTickState()
    clearRangeStates()
    clearElementBuffer(missingElements, missingCount)

    local collectRangeState = SNSConfig.rangeFade == true
    local rangeOffset = SNSConfig.rangeOffsetYards
    local hasRangeState = false
    local nextMissingCount = 0
    local slots = M.slots
    local slotCount = table.getn(slots)

    for i = 1, slotCount do
        local hadRangeState
        nextMissingCount, hadRangeState = collectSlotRangeState(
            i,
            slots[i],
            collectRangeState,
            rangeOffset,
            nextMissingCount
        )
        if hadRangeState then
            hasRangeState = true
        end
    end

    missingCount = nextMissingCount
    return rangeStates, hasRangeState, missingElements, nextMissingCount
end

local function shouldRunVisualTick(now)
    if now - lastVisualTick < VISUAL_TICK_INTERVAL then
        return false
    end

    lastVisualTick = now
    return true
end

local function shouldRunRangeTick(now)
    if not M.hasUnitXP then
        return false
    end
    if not SNSConfig.rangeFade and not SNSConfig.expirySoundEnabled then
        return false
    end
    if now - lastRangeTick < SNSConfig.pollInterval then
        return false
    end

    lastRangeTick = now
    return true
end

local function runVisualTick(now)
    local callback = visualResultsCallback
    if not callback then return end
    local elements, elementCount = collectExpiredElements(now)
    callback(elements, elementCount)
end

local function runRangeTick()
    local callback = rangeResultsCallback
    if not callback then return end
    local states, hasRangeState, elements, elementCount = collectRangeTickState()
    callback(states, hasRangeState, elements, elementCount)
end

------------------------------------------------------------------------
-- Private handlers
------------------------------------------------------------------------

local function onPollUpdate()
    local now = GetTime()

    if shouldRunVisualTick(now) then
        runVisualTick(now)
    end

    if shouldRunRangeTick(now) then
        runRangeTick()
    end
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

-- GetSpellDuration returns milliseconds or nil; convert to seconds.
-- Called at spawn time so talent-modified durations are captured.
-- Falls back to catalog record.duration. Returns 0 on total failure.
local function resolveSpawnDuration(spellId)
    local ms = GetSpellDuration(spellId)
    if ms ~= nil and ms > 0 then return ms / 1000 end
    local record = M.bySpellId[spellId]
    if record and type(record.duration) == "number" then
        return record.duration
    end
    return 0
end

local function syncPollingRegistration()
    if not pollFrameWired then return end

    if hasActiveSlots() and pollingEnabled then
        if not pollFrame:IsShown() then
            resetTickState()
            pollFrame:Show()
        end
        return
    end

    if pollFrame:IsShown() then
        pollFrame:Hide()
        resetTickState()
    end
end

-- Facade wiring stores the two poll-result callbacks before polling starts.
-- Later calls only replace those callbacks and resync frame visibility.
local function initializePolling(onVisualResults, onRangeResults)
    visualResultsCallback = onVisualResults
    rangeResultsCallback  = onRangeResults

    if not pollFrameWired then
        pollFrame:SetScript("OnUpdate", onPollUpdate)
        pollFrameWired = true
    end

    syncPollingRegistration()
end

local function setPollingEnabled(enabled)
    pollingEnabled = enabled
    syncPollingRegistration()
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.InitializePolling       = initializePolling
M.SyncPollingRegistration = syncPollingRegistration
M.SetPollingEnabled       = setPollingEnabled
M.ResolveSpawnDuration    = resolveSpawnDuration
