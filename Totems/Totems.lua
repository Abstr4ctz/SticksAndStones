-- SticksAndStones: Totems/Totems.lua
-- Owns runtime coordination for the Totems pod.
-- Owns TotemsInternal, Totems, TotemsInternal.slots, and the persistent
-- snapshot table used by the display layer.
-- Coordinates FSM transitions, catalog refresh sequencing, detect-driven
-- lifecycle events, world-entry teardown, poll-driven visual/range updates,
-- and lifecycle alert classification.
-- Exports facade methods on Totems.
-- Side effects: creates TotemsInternal and Totems globals at file scope so
-- support modules can reference them per TOC order, and creates hidden facade-
-- owned frames for catalog refresh and detect events.

------------------------------------------------------------------------
-- Pod shared table
------------------------------------------------------------------------

-- Must exist at file scope before pod internals load.
TotemsInternal       = {}
TotemsInternal.slots = {}

------------------------------------------------------------------------
-- Public facade
------------------------------------------------------------------------

Totems  = {}
local M  = Totems
local TI = TotemsInternal
local GetTime = GetTime

------------------------------------------------------------------------
-- Private state
------------------------------------------------------------------------

-- [1..4] are slot object references assigned in initialize() and kept for
-- the addon session. activeCount is recomputed when active-slot membership changes.
local snapshot            = { activeCount = 0 }

local catalogRefreshFrame = CreateFrame("Frame", nil, UIParent)
local detectFrame         = CreateFrame("Frame", nil, UIParent)
catalogRefreshFrame:Hide()
detectFrame:Hide()
local catalogRefreshWired = false
local detectWired         = false
local lifecycleAlertElements = {}
local lifecycleAlertGuids    = {}
local lastLifecycleAlertCount = 0

local CLEAR_SOURCE_VISUAL_EXPIRY   = 1
local CLEAR_SOURCE_UNIT_DIED       = 2
local CLEAR_SOURCE_UNITXP_MISSING  = 3
local CLEAR_SOURCE_RECALL          = 4
local CLEAR_SOURCE_PLAYER_DEAD     = 5
local CLEAR_SOURCE_ENTERING_WORLD  = 6

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function newSlot()
    return {
        state      = TI.IDLE,
        chosenId   = nil,
        activeId   = nil,
        activeGuid = nil,
        spawnedAt  = nil,
        duration   = nil,
        qaId       = nil,
        isInRange  = true,
    }
end

local function fireStateChanged()
    M.OnStateChanged(snapshot)
end

local function fireLifecycleAlert(element, guid)
    M.OnLifecycleAlert(element, guid)
end

local function fireVisualRefresh()
    M.OnVisualRefresh(snapshot)
end

local function fireCatalogChanged()
    M.OnCatalogChanged(TI.BuildCatalogSnapshot())
end

local function publishStateContract()
    M.States = {
        IDLE             = TI.IDLE,
        CHOSEN           = TI.CHOSEN,
        ACTIVE_CHOSEN    = TI.ACTIVE_CHOSEN,
        CHOSEN_ACTIVE    = TI.CHOSEN_ACTIVE,
        EMPTY_ACTIVE     = TI.EMPTY_ACTIVE,
        EMPTY_QA         = TI.EMPTY_QA,
        CHOSEN_QA        = TI.CHOSEN_QA,
        ACTIVE_CHOSEN_QA = TI.ACTIVE_CHOSEN_QA,
    }
end

local function isValidElementIndex(element)
    return type(element) == "number"
       and element == math.floor(element)
       and element >= 1
       and element <= SNS.MAX_TOTEM_SLOTS
end

-- Returns true when spellId is a valid positive integer present in bySpellId.
local function isValidSpellId(spellId)
    if type(spellId) ~= "number" then return false end
    if spellId <= 0 or spellId ~= math.floor(spellId) then return false end
    if not TI.bySpellId[spellId] then return false end
    return true
end

local function normalizeConfiguredSpellId(element, spellId)
    if spellId == nil then return true, nil end
    if not isValidSpellId(spellId) then return false, nil end

    local canonicalSpellId = TI.ResolveCanonicalSpellId(spellId)
    if canonicalSpellId == nil then return false, nil end

    local record = TI.bySpellId[canonicalSpellId]
    if not record or record.element ~= element then return false, nil end
    return true, canonicalSpellId
end

local function applyPolledRangeToSlot(slot, isInRange)
    if isInRange == nil then return end
    if slot.activeGuid == nil then return end
    slot.isInRange = (isInRange ~= false)
end

local function clearDisabledRangeFadeState()
    if SNSConfig.rangeFade ~= false then return false end

    local changed = false
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        local slot = TI.slots[element]
        if slot.activeGuid ~= nil and slot.isInRange == false then
            slot.isInRange = true
            changed = true
        end
    end
    return changed
end

local function recomputeActiveCount()
    local count = 0
    for i = 1, SNS.MAX_TOTEM_SLOTS do
        if TI.slots[i].activeGuid then
            count = count + 1
        end
    end
    snapshot.activeCount = count
end

local function fireStateChangedAfterRecompute()
    recomputeActiveCount()
    fireStateChanged()
end

local function clearLifecycleAlertBuffer()
    for i = 1, lastLifecycleAlertCount do
        lifecycleAlertElements[i] = nil
        lifecycleAlertGuids[i] = nil
    end
    lastLifecycleAlertCount = 0
end

local function fireLifecycleAlerts(alertCount)
    local i
    for i = 1, alertCount do
        fireLifecycleAlert(lifecycleAlertElements[i], lifecycleAlertGuids[i])
    end
end

local function isAlertingClearSource(source)
    return source == CLEAR_SOURCE_VISUAL_EXPIRY
       or source == CLEAR_SOURCE_UNIT_DIED
       or source == CLEAR_SOURCE_UNITXP_MISSING
end

-- Replacement casts are the only alert-worthy-looking clears that should stay
-- silent; the pending-cast query lives in Detect so the facade can keep the
-- alert policy centralized in one place.
local function shouldAlertForClear(element, source, now)
    if not isAlertingClearSource(source) then
        return false
    end
    if TI.HasPendingCastForElement and TI.HasPendingCastForElement(element, now) then
        return false
    end
    return true
end

local function recordLifecycleAlert(element, guid, nextAlertCount)
    if type(guid) ~= "string" or string.len(guid) == 0 then
        return nextAlertCount
    end

    nextAlertCount = nextAlertCount + 1
    lifecycleAlertElements[nextAlertCount] = element
    lifecycleAlertGuids[nextAlertCount] = guid
    if nextAlertCount > lastLifecycleAlertCount then
        lastLifecycleAlertCount = nextAlertCount
    end
    return nextAlertCount
end

local function finalizeStateMutation(changed, alertCount)
    if not changed then
        clearLifecycleAlertBuffer()
        return false
    end

    TI.SyncPollingRegistration()
    if alertCount ~= nil and alertCount > 0 then
        fireLifecycleAlerts(alertCount)
    end
    fireStateChangedAfterRecompute()
    clearLifecycleAlertBuffer()
    return true
end

local function clearActiveElement(element, source, now, nextAlertCount)
    local slot = TI.slots[element]
    if slot.activeGuid == nil then return false, nextAlertCount end

    local activeGuid   = slot.activeGuid
    local shouldAlert  = shouldAlertForClear(element, source, now)
    local changed = TI.DispatchEvent(slot, TI.E_DEATH) ~= nil
    if changed then
        slot.isInRange = true
        if shouldAlert then
            nextAlertCount = recordLifecycleAlert(element, activeGuid, nextAlertCount)
        end
    end
    return changed, nextAlertCount
end

-- Config set helpers validate persisted chosen spell IDs before any slot writes.
local function getConfiguredSet(setIndex)
    if type(setIndex) ~= "number" then return nil end
    local sets = SNSConfig.sets
    if type(sets) ~= "table" then return nil end
    local set = sets[setIndex]
    if type(set) ~= "table" then return nil end
    return set
end

-- Returns a dense [1..4] chosen-id array for a valid config row, canonicalized
-- to the highest live rank for each configured totem type.
local function validateConfiguredSet(set)
    local validated = {}
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        local spellId = set[element]
        local isValid, canonicalSpellId = normalizeConfiguredSpellId(element, spellId)
        if not isValid then return nil end
        validated[element] = canonicalSpellId
    end
    return validated
end

local function applyChosenSet(chosenIds)
    local changed = false
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        local slot = TI.slots[element]
        local spellId = chosenIds and chosenIds[element] or nil
        if slot.chosenId ~= spellId and TI.DispatchEvent(slot, TI.E_SET_LOAD, spellId) ~= nil then
            changed = true
        end
    end
    return changed
end

local function clearChosenSet()
    return applyChosenSet(nil)
end

-- Returns canonical chosen IDs for a valid config row, or nil when the active
-- set row is missing or invalid.
local function resolveConfiguredChosenSet(setIndex)
    local set = getConfiguredSet(setIndex)
    if type(set) ~= "table" then return nil end

    return validateConfiguredSet(set)
end

-- Keeps Totems chosen state aligned with the active config row on startup and
-- on every Settings change. Missing or invalid rows are authoritative empty
-- chosen state.
local function reconcileConfiguredChosenSet(setIndex)
    local chosenIds = resolveConfiguredChosenSet(setIndex)
    if type(chosenIds) == "table" then
        return applyChosenSet(chosenIds)
    end

    return clearChosenSet()
end

-- Applies the latest derived range states without reporting a logical state
-- mutation.
local function applyPolledRanges(rangeStates)
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        applyPolledRangeToSlot(TI.slots[element], rangeStates[element])
    end
end

local function handleElementClearBatch(elements, elementCount, source, now)
    local changed = false
    local nextAlertCount = 0
    local count = elementCount or table.getn(elements)
    local elementChanged
    for i = 1, count do
        elementChanged, nextAlertCount = clearActiveElement(elements[i], source, now, nextAlertCount)
        if elementChanged then
            changed = true
        end
    end

    return finalizeStateMutation(changed, nextAlertCount)
end

-- Routes a confirmed totem spawn through pod-owned duration resolution,
-- FSM dispatch, and callback sequencing.
local function handleDetectSpawn(element, guid, spellId, spawnedAt)
    local slot = TI.slots[element]
    local duration = TI.ResolveSpawnDuration(spellId)
    local changed = TI.DispatchEvent(slot, TI.E_SPAWN, spellId, guid, spawnedAt, duration) ~= nil
    if changed then
        slot.isInRange = true
    end
    finalizeStateMutation(changed, 0)
end

-- Scans all slots for a GUID match and applies the death transition once.
local function handleDetectGuidDeath(guid)
    if type(guid) ~= "string" or string.len(guid) == 0 then return end

    local now = GetTime()
    local changed, alertCount

    for i = 1, SNS.MAX_TOTEM_SLOTS do
        if TI.slots[i].activeGuid == guid then
            changed, alertCount = clearActiveElement(i, CLEAR_SOURCE_UNIT_DIED, now, 0)
            finalizeStateMutation(changed, alertCount)
            return
        end
    end
end

-- E_DEATH all active slots, preserving chosen per FSM death semantics.
-- Used for player death, Totemic Recall, and world-entry teardown.
local function handleDetectDismissAll(source)
    local changed = false
    local nextAlertCount = 0
    local now = GetTime()
    local elementChanged
    for i = 1, SNS.MAX_TOTEM_SLOTS do
        elementChanged, nextAlertCount = clearActiveElement(i, source, now, nextAlertCount)
        if elementChanged then
            changed = true
        end
    end
    finalizeStateMutation(changed, nextAlertCount)
end

------------------------------------------------------------------------
-- Private handlers
------------------------------------------------------------------------

-- levelOrNil is optional so startup wiring can query the current player level.
local function syncCatalogLevelRefreshRegistration(levelOrNil)
    if TI.ShouldTrackLevelRefresh(levelOrNil) then
        catalogRefreshFrame:RegisterEvent("PLAYER_LEVEL_UP")
        return
    end
    catalogRefreshFrame:UnregisterEvent("PLAYER_LEVEL_UP")
end

local function handleCatalogLearnedSpell()
    TI.RebuildCatalog()
    reconcileConfiguredChosenSet(SNSConfig.activeSetIndex)
    fireCatalogChanged()
end

local function handleCatalogLevelUp(newLevel)
    TI.RebuildCatalog()
    syncCatalogLevelRefreshRegistration(newLevel)
    reconcileConfiguredChosenSet(SNSConfig.activeSetIndex)
    fireCatalogChanged()
end

local CATALOG_EVENT_HANDLERS = {
    LEARNED_SPELL_IN_TAB = handleCatalogLearnedSpell,
    PLAYER_LEVEL_UP      = handleCatalogLevelUp,
}

local function onCatalogRefreshEvent()
    -- Vanilla 1.12 OnEvent handlers read event payload from implicit globals.
    local handler = CATALOG_EVENT_HANDLERS[event]
    if handler then
        handler(arg1)
    end
end

local function wireCatalogRefresh()
    if catalogRefreshWired then return end

    catalogRefreshFrame:SetScript("OnEvent", onCatalogRefreshEvent)
    catalogRefreshFrame:RegisterEvent("LEARNED_SPELL_IN_TAB")
    syncCatalogLevelRefreshRegistration()
    catalogRefreshWired = true
end

local function handlePollVisualResults(expiredElements, expiredCount)
    if expiredCount == nil or expiredCount <= 0 then
        fireVisualRefresh()
        return
    end

    if not handleElementClearBatch(expiredElements, expiredCount, CLEAR_SOURCE_VISUAL_EXPIRY, GetTime()) then
        fireVisualRefresh()
    end
end

local function handlePollRangeResults(rangeStates, hasRangeState, missingElements, missingCount)
    if hasRangeState then
        applyPolledRanges(rangeStates)
    end
    if missingCount ~= nil and missingCount > 0 then
        handleElementClearBatch(missingElements, missingCount, CLEAR_SOURCE_UNITXP_MISSING, GetTime())
    end
end

local function onDetectSpellCastEvent(castFlag, spellId)
    local now = GetTime()
    if TI.ObserveSpellCast(castFlag, spellId, now) then
        detectFrame:SetScript("OnUpdate", nil)
        handleDetectDismissAll(CLEAR_SOURCE_RECALL)
    end
end

local function onDetectDelayUpdate()
    local now = GetTime()
    local elements, guids, spellIds, spawnedAts, spawnCount = TI.DrainDelayedSpawns(now)
    for i = 1, spawnCount do
        handleDetectSpawn(elements[i], guids[i], spellIds[i], spawnedAts[i])
    end
    if not TI.HasPendingDelaySpawns() then
        detectFrame:SetScript("OnUpdate", nil)
    end
end

local function onDetectUnitModelChangedEvent(unitId)
    local now = GetTime()
    local element, guid, spellId, spawnedAt = TI.ResolveUnitModelChange(unitId, now)
    if TI.HasPendingDelaySpawns() then
        detectFrame:SetScript("OnUpdate", onDetectDelayUpdate)
    end
    if element ~= nil then
        handleDetectSpawn(element, guid, spellId, spawnedAt)
    end
end

local function onDetectPlayerDeadEvent()
    TI.ResetDetectState()
    detectFrame:SetScript("OnUpdate", nil)
    handleDetectDismissAll(CLEAR_SOURCE_PLAYER_DEAD)
end

local function onDetectPlayerEnteringWorldEvent()
    TI.ResetDetectState()
    detectFrame:SetScript("OnUpdate", nil)
    handleDetectDismissAll(CLEAR_SOURCE_ENTERING_WORLD)
end

local DETECT_EVENT_HANDLERS = {
    SPELL_CAST_EVENT     = onDetectSpellCastEvent,
    UNIT_MODEL_CHANGED   = onDetectUnitModelChangedEvent,
    UNIT_DIED            = handleDetectGuidDeath,
    PLAYER_DEAD          = onDetectPlayerDeadEvent,
    PLAYER_ENTERING_WORLD = onDetectPlayerEnteringWorldEvent,
}

local function onDetectEvent()
    -- Vanilla 1.12 OnEvent handlers read event payload from implicit globals.
    local handler = DETECT_EVENT_HANDLERS[event]
    if handler then
        handler(arg1, arg2)
    end
end

local function wireDetect()
    if detectWired then return end

    detectFrame:SetScript("OnEvent", onDetectEvent)
    for eventName in pairs(DETECT_EVENT_HANDLERS) do
        detectFrame:RegisterEvent(eventName)
    end
    detectWired = true
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function initialize()
    publishStateContract()
    TI.RebuildCatalog()

    for i = 1, SNS.MAX_TOTEM_SLOTS do
        TI.slots[i] = newSlot()
        snapshot[i] = TI.slots[i]
    end
    snapshot.activeCount = 0

    -- Reconcile chosen state silently; App performs the initial Render after
    -- callback wiring, so initialize intentionally ignores the change flag.
    reconcileConfiguredChosenSet(SNSConfig.activeSetIndex)

    wireCatalogRefresh()
    wireDetect()
    TI.hasUnitXP = SNS.features and SNS.features.hasUnitXP == true or false
    TI.InitializePolling(handlePollVisualResults, handlePollRangeResults)
end

local function getSnapshot()
    return snapshot
end

-- Called by App when Settings fires OnConfigChanged.
-- Reconciles chosen totems against the active config row on every config change.
local function applyConfig()
    local rangeChanged = clearDisabledRangeFadeState()
    local chosenChanged = reconcileConfiguredChosenSet(SNSConfig.activeSetIndex)
    if chosenChanged or rangeChanged then
        fireStateChangedAfterRecompute()
    end
end

-- Returns a fresh {[1..4] = chosenId} table for set seeding.
local function getChosenSnapshot()
    local result = {}
    for i = 1, SNS.MAX_TOTEM_SLOTS do
        result[i] = TI.slots[i].chosenId
    end
    return result
end

-- Returns a fresh catalog snapshot detached from Catalog.lua's internal indexes.
local function getCatalog()
    return TI.BuildCatalogSnapshot()
end

local function castElementButton(element)
    if not isValidElementIndex(element) then return end
    local _, castSpellId = TI.DispatchEvent(TI.slots[element], TI.E_LMB)
    if castSpellId then TI.CastTotem(castSpellId) end
end

local function changeElementButton(element)
    if not isValidElementIndex(element) then return end
    local newState = TI.DispatchEvent(TI.slots[element], TI.E_RMB)
    if newState ~= nil then
        -- RMB only reshuffles chosen/QA fields; active membership does not change.
        fireStateChanged()
    end
end

local function castElementPeek(element)
    if not isValidElementIndex(element) then return end
    local _, castSpellId = TI.DispatchEvent(TI.slots[element], TI.E_PEEK_LMB)
    if castSpellId then TI.CastTotem(castSpellId) end
end

local function changeElementPeek(element)
    if not isValidElementIndex(element) then return end
    local newState = TI.DispatchEvent(TI.slots[element], TI.E_PEEK_RMB)
    if newState ~= nil then
        -- Peek RMB preserves active membership; activeCount does not need recomputing.
        fireStateChanged()
    end
end

local function castFlyout(spellId)
    if not isValidSpellId(spellId) then return end
    TI.CastTotem(spellId)
end

local function setChosenFromFlyout(element, spellId)
    if not isValidElementIndex(element) then return end
    local isValid, canonicalSpellId = normalizeConfiguredSpellId(element, spellId)
    if not isValid or canonicalSpellId == nil then return end

    local newState = TI.DispatchEvent(TI.slots[element], TI.E_SET_LOAD, canonicalSpellId)
    if newState ~= nil then
        fireStateChanged()
    end
end

-- Casts chosen totems that are missing or out of range.
-- Healthy active chosen totems are skipped.
local function castSmart()
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        local slot = TI.slots[element]
        if TI.ShouldSmartCastChosen(slot) then
            TI.CastTotem(slot.chosenId)
        end
    end
end

-- Casts every chosen totem regardless of current active state.
local function castForce()
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        local chosenId = TI.slots[element].chosenId
        if chosenId ~= nil then
            TI.CastTotem(chosenId)
        end
    end
end

local function setPollingEnabled(enabled)
    if type(enabled) ~= "boolean" then return nil end
    TI.SetPollingEnabled(enabled)
end

------------------------------------------------------------------------
-- Public exports
------------------------------------------------------------------------

-- Outbound callbacks. App wires these after all Initialize() calls.
M.OnStateChanged   = function() end
M.OnVisualRefresh  = function() end
M.OnCatalogChanged = function() end
M.OnLifecycleAlert = function() end
M.States           = nil

M.Initialize          = initialize
M.GetSnapshot         = getSnapshot
M.ApplyConfig         = applyConfig
M.GetChosenSnapshot   = getChosenSnapshot
M.GetCatalog          = getCatalog
M.CastElementButton   = castElementButton
M.ChangeElementButton = changeElementButton
M.CastElementPeek     = castElementPeek
M.ChangeElementPeek   = changeElementPeek
M.CastFlyout          = castFlyout
M.SetChosenFromFlyout = setChosenFromFlyout
M.CastSmart           = castSmart
M.CastForce           = castForce
M.SetPollingEnabled   = setPollingEnabled
