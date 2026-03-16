-- SticksAndStones: Totems/Detect.lua
-- Support module: correlates combat observations to identify totem summons and
-- deaths.
-- Owns pending cast state, delayed WDB-name resolution, and the WDB delay-slot
-- pool.
-- Exports raw combat-correlation helpers on TotemsInternal for the facade to
-- consume, including pending-cast replacement queries for the facade.
-- Side effects: reads unit APIs during model/correlation helpers. No frames or
-- globals are created here.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = TotemsInternal  -- created by Totems facade, loaded first per TOC order

local UnitName   = UnitName
local UnitExists = UnitExists
local UnitIsUnit = UnitIsUnit

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local SCAN_WINDOW       = 1.0   -- max seconds between cast event and model match
local MODEL_DELAY       = 0.2   -- seconds between WDB cache miss re-checks
local MODEL_RECHECKS    = 2     -- max re-check attempts for Unknown name
local MAX_DELAY_SLOTS   = 8     -- pool size for concurrent WDB cache misses
local CAST_FLAG_SUCCESS = 1     -- SPELL_CAST_EVENT arg1 success sentinel
local RECALL_ID         = 45513 -- Totemic Recall spell ID
local UNKNOWN_NAME      = "Unknown"

------------------------------------------------------------------------
-- Private state
------------------------------------------------------------------------

local pendingCasts = {} -- [unitName] = reusable { spellId, element }
local pendingCount = 0
local windowEnd    = 0

local delaySlots = {}
for i = 1, MAX_DELAY_SLOTS do
    delaySlots[i] = { guid = false, expiry = 0, checks = 0, firstSeen = 0 }
end
local delayCount        = 0
local drainedElements   = {}
local drainedGuids      = {}
local drainedSpellIds   = {}
local drainedSpawnAts   = {}
local lastDrainedCount  = 0

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function wipePendingCasts()
    for _, entry in pairs(pendingCasts) do
        entry.spellId = nil
        entry.element = nil
    end
    pendingCount = 0
    windowEnd    = 0
end

local function claimPendingCastEntry(unitName)
    local entry = pendingCasts[unitName]
    if entry then
        if entry.spellId == nil then
            pendingCount = pendingCount + 1
        end
        return entry
    end

    entry = { spellId = nil, element = nil }
    pendingCasts[unitName] = entry
    pendingCount = pendingCount + 1
    return entry
end

-- Returns (slotIndex, isExisting). Single pass: finds GUID match or first empty.
local function findDelaySlot(guid)
    local emptySlot
    for i = 1, MAX_DELAY_SLOTS do
        local slotGuid = delaySlots[i].guid
        if slotGuid == guid then
            return i, true
        end
        if not emptySlot and not slotGuid then
            emptySlot = i
        end
    end
    return emptySlot, false
end

local function clearDelaySlot(i)
    delaySlots[i].guid      = false
    delaySlots[i].expiry    = 0
    delaySlots[i].checks    = 0
    delaySlots[i].firstSeen = 0
end

local function wipeDelaySlots()
    for i = 1, MAX_DELAY_SLOTS do
        clearDelaySlot(i)
    end
    delayCount = 0
end

-- The correlation window owns both pending casts and delayed WDB-name slots.
-- Once the scan window expires, all of that state is stale and must retire
-- together before any new cast or delayed resolution can reuse it.
local function expireCorrelationWindow(now)
    if type(now) ~= "number" then return false end
    if windowEnd <= 0 or now <= windowEnd then return false end

    wipePendingCasts()
    wipeDelaySlots()
    return true
end

local function clearDrainedTail(nextCount)
    for i = nextCount + 1, lastDrainedCount do
        drainedElements[i] = nil
        drainedGuids[i] = nil
        drainedSpellIds[i] = nil
        drainedSpawnAts[i] = nil
    end
    lastDrainedCount = nextCount
end

local function queueDelayedModelMatch(unitId, now)
    local _, guid = UnitExists(unitId)
    if not guid then return false end

    local slotIndex, isExisting = findDelaySlot(guid)
    if not slotIndex then return false end
    local slot = delaySlots[slotIndex]

    if not isExisting then
        slot.guid = guid
        delayCount = delayCount + 1
    end

    -- Keep the earliest model-appearance timestamp for accurate spawn timing.
    if slot.firstSeen == 0 or now < slot.firstSeen then
        slot.firstSeen = now
    end
    slot.expiry = now + MODEL_DELAY
    slot.checks = 0

    return
end

local function resolveQueuedSpawnAt(guid, fallbackSpawnAt)
    local spawnAt = fallbackSpawnAt
    local slotIndex, isExisting = findDelaySlot(guid)
    if not isExisting then
        return spawnAt
    end

    local slot = delaySlots[slotIndex]
    if slot.firstSeen and slot.firstSeen > 0 and slot.firstSeen < spawnAt then
        spawnAt = slot.firstSeen
    end
    clearDelaySlot(slotIndex)
    delayCount = delayCount - 1
    return spawnAt
end

local function consumePendingCast(guid, entry, spawnAt)
    if not entry or entry.spellId == nil then return end

    local spellId = entry.spellId
    local element = entry.element

    entry.spellId = nil
    entry.element = nil
    pendingCount = pendingCount - 1

    return element, guid, spellId, spawnAt
end

local function handleResolvedModelMatch(unitId, name, now)
    local entry = pendingCasts[name]
    if not entry or entry.spellId == nil then return end

    local _, guid = UnitExists(unitId)
    if not guid then return end

    local spawnAt = resolveQueuedSpawnAt(guid, now)
    return consumePendingCast(guid, entry, spawnAt)
end

local function resolveDelayedSpawnAt(slot)
    local spawnAt = slot.firstSeen
    if not spawnAt or spawnAt <= 0 then
        return nil
    end
    return spawnAt
end

-- Re-checks one delayed WDB-name slot until the unit name resolves or the
-- retry budget expires, then returns a completed spawn if one is found.
local function processDelaySlot(i, now)
    local slot = delaySlots[i]
    if not slot.guid or now < slot.expiry then return end

    local name = UnitName(slot.guid)
    if name and name ~= UNKNOWN_NAME then
        local element, guid, spellId, spawnAt = consumePendingCast(slot.guid, pendingCasts[name], resolveDelayedSpawnAt(slot))
        clearDelaySlot(i)
        delayCount = delayCount - 1
        return element, guid, spellId, spawnAt
    end

    local nextCheck = slot.checks + 1
    if nextCheck < MODEL_RECHECKS then
        slot.checks = nextCheck
        slot.expiry = now + MODEL_DELAY
        return
    end

    clearDelaySlot(i)
    delayCount = delayCount - 1
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

-- Tracks a pending cast window from SPELL_CAST_EVENT.
-- Returns true only for Totemic Recall so the facade can dismiss active totems.
local function observeSpellCast(castFlag, spellId, now)
    if castFlag ~= CAST_FLAG_SUCCESS then return false end

    expireCorrelationWindow(now)

    if spellId == RECALL_ID then
        wipePendingCasts()
        wipeDelaySlots()
        return true
    end

    local record = M.bySpellId and M.bySpellId[spellId]
    if not record then return false end

    local unitName = record.unitName
    local element  = record.element

    local entry = claimPendingCastEntry(unitName)
    entry.spellId = spellId
    entry.element = element

    windowEnd = now + SCAN_WINDOW
    return false
end

local function drainDelayedSpawns(now)
    if expireCorrelationWindow(now) then
        clearDrainedTail(0)
        return drainedElements, drainedGuids, drainedSpellIds, drainedSpawnAts, 0
    end

    local drainedCount = 0
    for i = 1, MAX_DELAY_SLOTS do
        local element, guid, spellId, spawnAt = processDelaySlot(i, now)
        if element ~= nil then
            drainedCount = drainedCount + 1
            drainedElements[drainedCount] = element
            drainedGuids[drainedCount] = guid
            drainedSpellIds[drainedCount] = spellId
            drainedSpawnAts[drainedCount] = spawnAt
        end
    end

    clearDrainedTail(drainedCount)
    return drainedElements, drainedGuids, drainedSpellIds, drainedSpawnAts, drainedCount
end

local function resolveUnitModelChange(unitId, now)
    if expireCorrelationWindow(now) then return end
    if pendingCount == 0 then return end

    if not unitId then return end

    -- Ownership check: totem must belong to the player.
    if not UnitIsUnit(unitId .. "owner", "player") then return end

    -- Name resolution.
    local name = UnitName(unitId)

    if not name or name == UNKNOWN_NAME then
        queueDelayedModelMatch(unitId, now)
        return
    end

    return handleResolvedModelMatch(unitId, name, now)
end

local function resetDetectState()
    wipePendingCasts()
    wipeDelaySlots()
end

local function hasPendingDelaySpawns()
    return delayCount > 0
end

local function hasPendingCastForElement(element, now)
    local _, entry

    expireCorrelationWindow(now)
    if pendingCount <= 0 then return false end

    for _, entry in pairs(pendingCasts) do
        if entry.spellId ~= nil and entry.element == element then
            return true
        end
    end

    return false
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.ObserveSpellCast       = observeSpellCast
M.ResolveUnitModelChange = resolveUnitModelChange
M.DrainDelayedSpawns     = drainDelayedSpawns
M.ResetDetectState       = resetDetectState
M.HasPendingDelaySpawns  = hasPendingDelaySpawns
M.HasPendingCastForElement = hasPendingCastForElement
