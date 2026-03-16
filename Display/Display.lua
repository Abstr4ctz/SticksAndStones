-- SticksAndStones: Display/Display.lua
-- Public facade for the Display pod.
-- Owns DisplayInternal (pod shared table), Display (public facade), and the
-- facade-owned render/action coordination helpers shared with support modules.
-- Exports the Display lifecycle methods, ApplyFlyoutConfig helper, and
-- OnUserAction callback slot.
-- Side effects: creates DisplayInternal and Display globals at file scope so
-- later Display support modules can attach their exports per TOC order.
-- Reads SNSConfig and SNS.ACTION_TYPES, and may play one
-- local lifecycle alert sound at runtime. Does not write SNSConfig. Does not call
-- Totems, Settings, or Minimap facades.

------------------------------------------------------------------------
-- Pod shared table
------------------------------------------------------------------------

DisplayInternal = {}

------------------------------------------------------------------------
-- Public facade
------------------------------------------------------------------------

Display = {}
local M  = Display
local DI = DisplayInternal

local GetTime       = GetTime
local MouseIsOver   = MouseIsOver
local PlaySoundFile = PlaySoundFile
local math_floor    = math.floor
local math_mod      = math.mod

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local ACTION_TYPES = SNS.ACTION_TYPES

local RANGE_FADE_FACTOR     = 0.50
local EXPIRY_SOUND_THROTTLE = 1.0
local EXPIRY_SOUND_PATH     = "Interface\\AddOns\\SticksAndStones\\Sounds\\sound1.ogg"

local ACTIVE_BORDER = { path = "Interface\\AddOns\\SticksAndStones\\Textures\\border1", offset = 4 }

local TIMER_TEXT_COLORS = {
    normal = { r = 1.00, g = 1.00, b = 1.00 },
    expiry = { r = 0.95, g = 0.74, b = 0.74 },
}

local MODES = {
    empty  = { alpha = 0.30, r = -1.0, g = -1.0, b = -1.0, dimAlpha = 0.00, timerOn = false },
    chosen = { alpha = 0.70, r =  1.0, g =  1.0, b =  1.0, dimAlpha = 0.30, timerOn = false },
    active = { alpha = 1.00, r =  1.0, g =  1.0, b =  1.0, dimAlpha = 0.00, timerOn = true  },
    faded  = { alpha = 0.40, r = 0.60, g = 0.60, b = 0.60, dimAlpha = 0.40, timerOn = false },
}

local EMPTY_VISUAL  = { spellIdField = false,      modeKey = "empty"  }
local CHOSEN_VISUAL = { spellIdField = "chosenId", modeKey = "chosen" }
local ACTIVE_VISUAL = { spellIdField = "activeId", modeKey = "active" }
local QA_VISUAL     = { spellIdField = "qaId",     modeKey = "faded"  }
local HIDDEN_VISUAL = { spellIdField = false,      modeKey = "hidden" }

local BUTTON_VISUALS = nil
local PEEK_VISUALS   = nil
local IDLE_STATE     = nil

------------------------------------------------------------------------
-- Owned state
------------------------------------------------------------------------

DI.BUTTON_SIZE     = 40
DI.PEEK_SIZE       = 30
DI.FLYOUT_SIZE     = 30
DI.BUTTON_GAP      = 2
DI.FLYOUT_GAP      = 2
DI.PEEK_ANCHOR_GAP = 2
DI.ACTIVE_BORDER   = ACTIVE_BORDER
DI.COOLDOWN_LAYOUT = {
    modelOffsetX   =  0,
    modelOffsetY   =  0,
    textOffsetX    =  0,
    textOffsetY    =  0,
    textFontObject = "GameFontNormalSmall",
    textShadowX    =  1,
    textShadowY    = -1,
}

DI.PILL_INSET_X = 1
DI.PILL_INSET_Y = 1

DI.BUTTON_TIMER_PILL_HEIGHT   = 12
DI.PEEK_TIMER_PILL_HEIGHT     = 11
DI.BUTTON_TICK_BAR_HEIGHT     = 3
DI.PEEK_TICK_BAR_HEIGHT       = 3
DI.BUTTON_TIMER_TEXT_OFFSET_Y = 1
DI.PEEK_TIMER_TEXT_OFFSET_Y   = 1

DI.TIMER_PILL_ALPHA    = 0.65
DI.TICK_BAR_BG_ALPHA   = 0.65
DI.TICK_BAR_FILL_ALPHA = 1.00
DI.EDIT_OVERLAY_ALPHA  = 0.45

DI.ICON_CROP_INSET = 0.07

DI.FALLBACK_ICON = "Interface\\Icons\\Spell_Totem_WardOfDraining"

DI.buttons                  = nil
DI.buttonState              = nil
DI.catalog                  = nil
DI.snapshot                 = nil
DI.expirySoundThrottleUntil = 0

local peekInteractionDirty = {}

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function onUserActionNoop()
end

local function isPositiveInteger(value)
    return type(value) == "number"
       and value > 0
       and value == math_floor(value)
end

local function isElementIndex(value)
    return type(value) == "number"
       and value == math_floor(value)
       and value >= 1
       and value <= SNS.MAX_TOTEM_SLOTS
end

local function isNumberOrNil(value)
    return value == nil or type(value) == "number"
end

local function isStringOrNil(value)
    return value == nil or type(value) == "string"
end

local function isNonEmptyString(value)
    return type(value) == "string" and string.len(value) > 0
end

local function isBooleanOrNil(value)
    return value == nil or type(value) == "boolean"
end

local function getScale()
    local value = SNSConfig and SNSConfig.scale
    if type(value) ~= "number" then return 1 end
    return value
end

local function shouldShowBorder()
    if type(SNSConfig) ~= "table" then return true end
    if SNSConfig.showBorder == nil then return true end
    return SNSConfig.showBorder ~= false
end

local function getElementConfig(element)
    if type(SNSConfig) ~= "table" then return nil end

    local elements = SNSConfig.elements
    if type(elements) ~= "table" then return nil end
    return elements[element]
end

local function getElementTintColor(element)
    local cfg = getElementConfig(element)
    if not cfg then return 1, 1, 1 end

    local r = type(cfg.elementColorR) == "number" and cfg.elementColorR or 1
    local g = type(cfg.elementColorG) == "number" and cfg.elementColorG or 1
    local b = type(cfg.elementColorB) == "number" and cfg.elementColorB or 1
    return r, g, b
end

local function getElementBorderColor(element)
    local cfg = getElementConfig(element)
    if not cfg then return 1, 1, 1 end

    local r = type(cfg.borderColorR) == "number" and cfg.borderColorR or 1
    local g = type(cfg.borderColorG) == "number" and cfg.borderColorG or 1
    local b = type(cfg.borderColorB) == "number" and cfg.borderColorB or 1
    return r, g, b
end

local function shouldShowTimerMinutes()
    return SNSConfig and SNSConfig.timerShowMinutes == true
end

local function getExpiryThresholdSecs()
    local value = SNSConfig and SNSConfig.expiryThresholdSecs
    if type(value) ~= "number" then return 5 end

    value = math_floor(value)
    if value <   0 then return   0 end
    if value > 600 then return 600 end
    return value
end

local function isLifecycleAlertEnabled()
    return SNSConfig and SNSConfig.expirySoundEnabled == true
end

local function computeRemainingSeconds(spawnedAt, duration, now)
    if duration == nil or duration <= 0 then return nil end
    if spawnedAt == nil then return nil end

    local remaining = (spawnedAt + duration) - now
    local secs      = math_floor(remaining)
    if secs <    0 then secs =    0 end
    if secs > 3600 then secs = 3600 end
    return secs
end

local function formatTimerMinutesSeconds(secs)
    local mins = math_floor(secs / 60)
    secs       = secs - (mins * 60)

    if secs < 10 then
        return mins .. ":0" .. secs
    end
    return mins .. ":" .. secs
end

local function formatTimerText(secs)
    if secs == nil then return false end
    if shouldShowTimerMinutes() and secs > 60 then
        return formatTimerMinutesSeconds(secs)
    end
    return tostring(secs)
end

local function isSlotAtExpiryThreshold(slot, now)
    if not slot then return nil, nil end
    if slot.activeId == nil then return nil, nil end

    local remainingSecs = computeRemainingSeconds(slot.spawnedAt, slot.duration, now)
    local threshold     = getExpiryThresholdSecs()
    if remainingSecs == nil or threshold <= 0 then
        return remainingSecs, false
    end

    return remainingSecs, remainingSecs <= threshold
end

local function setTimerTextColor(frame, cache, isPeek, colorKey)
    local color = TIMER_TEXT_COLORS[colorKey] or TIMER_TEXT_COLORS.normal

    if not isPeek then
        if color.r ~= cache.timerR or color.g ~= cache.timerG or color.b ~= cache.timerB then
            frame.timer:SetTextColor(color.r, color.g, color.b)
            cache.timerR = color.r
            cache.timerG = color.g
            cache.timerB = color.b
        end
        return
    end

    if color.r ~= cache.peekTimerR or color.g ~= cache.peekTimerG or color.b ~= cache.peekTimerB then
        frame.timer:SetTextColor(color.r, color.g, color.b)
        cache.peekTimerR = color.r
        cache.peekTimerG = color.g
        cache.peekTimerB = color.b
    end
end

local function resetThresholdAlertState(cache)
    cache.thresholdAlertGuid  = false
    cache.thresholdAlertUnder = false
end

local function canEmitLifecycleAlert()
    if not isLifecycleAlertEnabled() then return false end
    if type(SNSConfig) ~= "table" or not SNSConfig.visible then return false end
    if type(EXPIRY_SOUND_PATH) ~= "string" or string.len(EXPIRY_SOUND_PATH) == 0 then return false end
    if type(PlaySoundFile) ~= "function" then return false end
    return true
end

local function tryPlayLifecycleAlert(now)
    if now < DI.expirySoundThrottleUntil then return false end

    pcall(PlaySoundFile, EXPIRY_SOUND_PATH)
    DI.expirySoundThrottleUntil = now + EXPIRY_SOUND_THROTTLE
    return true
end

-- Threshold crossing and death callbacks both route through the same
-- per-element GUID dedupe so one active totem lifecycle can only alert once.
local function registerLifecycleAlert(cache, guid, now)
    if not cache or not isNonEmptyString(guid) then return false end
    if not canEmitLifecycleAlert() then return false end
    if cache.lastAlertedGuid == guid then return false end

    cache.lastAlertedGuid = guid
    tryPlayLifecycleAlert(now)
    return true
end

local function syncThresholdAlertState(cache, slot, isExpiring, now)
    local activeGuid = slot and slot.activeGuid or nil

    if not isNonEmptyString(activeGuid) then
        resetThresholdAlertState(cache)
        return
    end

    if activeGuid ~= cache.thresholdAlertGuid then
        cache.thresholdAlertGuid  = activeGuid
        cache.thresholdAlertUnder = false
    end

    if not isExpiring then
        cache.thresholdAlertUnder = false
        return
    end

    if cache.thresholdAlertUnder then return end

    cache.thresholdAlertUnder = true
    registerLifecycleAlert(cache, activeGuid, now)
end

local function isValidPublishedStateValue(stateValue, seen)
    if type(stateValue) ~= "number" then return false end
    if stateValue ~= math_floor(stateValue) or stateValue <= 0 then return false end
    if seen[stateValue] then return false end
    seen[stateValue] = true
    return true
end

local function isValidStateContract(states)
    if type(states) ~= "table" then return false end

    local seen = {}
    return isValidPublishedStateValue(states.IDLE,             seen)
       and isValidPublishedStateValue(states.CHOSEN,           seen)
       and isValidPublishedStateValue(states.ACTIVE_CHOSEN,    seen)
       and isValidPublishedStateValue(states.CHOSEN_ACTIVE,    seen)
       and isValidPublishedStateValue(states.EMPTY_ACTIVE,     seen)
       and isValidPublishedStateValue(states.EMPTY_QA,         seen)
       and isValidPublishedStateValue(states.CHOSEN_QA,        seen)
       and isValidPublishedStateValue(states.ACTIVE_CHOSEN_QA, seen)
end

local function bindStateVisual(buttonVisuals, peekVisuals, stateValue, buttonVisual, peekVisual)
    buttonVisuals[stateValue] = buttonVisual
    peekVisuals[stateValue]   = peekVisual
end

local function buildStateVisualTables(states)
    local buttonVisuals = {}
    local peekVisuals   = {}

    bindStateVisual(buttonVisuals, peekVisuals, states.IDLE,             EMPTY_VISUAL,  HIDDEN_VISUAL)
    bindStateVisual(buttonVisuals, peekVisuals, states.CHOSEN,           CHOSEN_VISUAL, HIDDEN_VISUAL)
    bindStateVisual(buttonVisuals, peekVisuals, states.ACTIVE_CHOSEN,    ACTIVE_VISUAL, HIDDEN_VISUAL)
    bindStateVisual(buttonVisuals, peekVisuals, states.CHOSEN_ACTIVE,    CHOSEN_VISUAL, ACTIVE_VISUAL)
    bindStateVisual(buttonVisuals, peekVisuals, states.EMPTY_ACTIVE,     EMPTY_VISUAL,  ACTIVE_VISUAL)
    bindStateVisual(buttonVisuals, peekVisuals, states.EMPTY_QA,         EMPTY_VISUAL,  QA_VISUAL)
    bindStateVisual(buttonVisuals, peekVisuals, states.CHOSEN_QA,        CHOSEN_VISUAL, QA_VISUAL)
    bindStateVisual(buttonVisuals, peekVisuals, states.ACTIVE_CHOSEN_QA, ACTIVE_VISUAL, QA_VISUAL)

    return buttonVisuals, peekVisuals, states.IDLE
end

local function isValidCatalogRecord(record, element)
    if type(record) ~= "table" then return false end
    if not isPositiveInteger(record.spellId) then return false end
    if not isElementIndex(record.element) then return false end
    if element ~= nil and record.element ~= element then return false end
    if not isStringOrNil(record.baseName) then return false end
    if not isStringOrNil(record.unitName) then return false end
    if not isStringOrNil(record.icon) then return false end
    if record.rank ~= nil and not isPositiveInteger(record.rank) then return false end
    if not isNumberOrNil(record.duration) then return false end
    if not isNumberOrNil(record.rangeYards) then return false end
    if not isNumberOrNil(record.manaCost) then return false end
    if not isNumberOrNil(record.manaCostPct) then return false end
    if not isNumberOrNil(record.tickInterval) then return false end
    return true
end

local function isValidCatalogElementList(catalog, element)
    local list = catalog.byElement[element]
    local i
    if type(list) ~= "table" then return false end

    for i = 1, table.getn(list) do
        if not isValidCatalogRecord(list[i], element) then return false end
    end

    return true
end

local function isValidCatalog(catalog)
    if type(catalog) ~= "table" then return false end
    if type(catalog.bySpellId) ~= "table" then return false end
    if type(catalog.byElement) ~= "table" then return false end

    local element
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        if not isValidCatalogElementList(catalog, element) then return false end
    end

    local spellId
    for spellId, record in pairs(catalog.bySpellId) do
        if not isPositiveInteger(spellId) then return false end
        if not isValidCatalogRecord(record) then return false end
        if record.spellId ~= spellId then return false end
    end

    return true
end

local function isValidSnapshotSlot(slot)
    if type(slot) ~= "table" then return false end
    if type(slot.state) ~= "number" then return false end
    if not BUTTON_VISUALS or not BUTTON_VISUALS[slot.state] then return false end
    if slot.chosenId ~= nil and not isPositiveInteger(slot.chosenId) then return false end
    if slot.activeId ~= nil and not isPositiveInteger(slot.activeId) then return false end
    if slot.qaId     ~= nil and not isPositiveInteger(slot.qaId) then return false end
    if slot.activeGuid ~= nil and not isNonEmptyString(slot.activeGuid) then
        return false
    end
    if not isNumberOrNil(slot.spawnedAt) then return false end
    if not isNumberOrNil(slot.duration) then return false end
    if not isBooleanOrNil(slot.isInRange) then return false end
    return true
end

local function isValidSnapshot(snapshot)
    if type(snapshot) ~= "table" then return false end
    if type(snapshot.activeCount) ~= "number" then return false end
    if snapshot.activeCount ~= math_floor(snapshot.activeCount) then return false end
    if snapshot.activeCount < 0 or snapshot.activeCount > SNS.MAX_TOTEM_SLOTS then return false end

    local element
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        if not isValidSnapshotSlot(snapshot[element]) then return false end
    end

    return true
end

local function getVisualSpellId(slot, visuals)
    if not slot or not visuals then return nil end

    local entry = visuals[slot.state] or visuals[IDLE_STATE]
    if not entry or not entry.spellIdField then return nil end
    return slot[entry.spellIdField]
end

local function getButtonSpellId(element)
    local slot = DI.snapshot and DI.snapshot[element]
    return getVisualSpellId(slot, BUTTON_VISUALS)
end

local function getPeekSpellId(element)
    local slot = DI.snapshot and DI.snapshot[element]
    return getVisualSpellId(slot, PEEK_VISUALS)
end

local function wireFlyoutEntryScripts(entry)
    if not entry or entry.snsScriptsWired then return end
    if not entry.inputFrame then return end

    entry.inputFrame:SetScript("OnEnter", DI.OnEntryEnterScript)
    entry.inputFrame:SetScript("OnLeave", DI.OnEntryLeaveScript)
    entry.inputFrame:SetScript("OnClick", DI.OnEntryClickScript)
    entry.snsScriptsWired = true
end

local function syncFlyoutPoolForButton(btn, requiredCount, showBorder)
    if not btn then return end

    local root = btn.flyout
    if not root then
        root = DI.CreateFlyoutFrame(btn)
    end
    if not root then return end
    if requiredCount <= 0 then return end

    local i
    for i = 1, requiredCount do
        local entry, created = DI.EnsureFlyoutEntry(root, i)
        if created then
            DI.ApplyFlyoutEntryChrome(entry, DI.FLYOUT_SIZE, showBorder)
            wireFlyoutEntryScripts(entry)
        end
    end
end

local function syncFlyoutPools(buttons, catalog)
    if not buttons or not catalog then return end

    local showBorder = shouldShowBorder()
    local element
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        local list = catalog.byElement[element]
        syncFlyoutPoolForButton(buttons[element], table.getn(list), showBorder)
    end
end

local function applyFlyoutFrameConfig(btn, scale, showBorder)
    local root = btn and btn.flyout
    if not root then return end

    root:SetFrameStrata(btn:GetFrameStrata())
    root:SetFrameLevel(btn:GetFrameLevel() + 10)
    root:SetScale(scale)

    local i
    for i = 1, table.getn(root.entries) do
        DI.ApplyFlyoutEntryChrome(root.entries[i], DI.FLYOUT_SIZE, showBorder)
    end
end

local function newCacheRow()
    return {
        icon             = false,
        alpha            = -1,
        r                = -1,
        g                = -1,
        b                = -1,
        dimAlpha         = -1,
        borderR          = -1,
        borderG          = -1,
        borderB          = -1,
        timerStr         = false,
        timerR           = -1,
        timerG           = -1,
        timerB           = -1,
        timerPillOn      = false,
        timerShown       = false,
        tickShown        = false,
        tickFillW        = -1,
        peekIcon         = false,
        peekAlpha        = -1,
        peekR            = -1,
        peekG            = -1,
        peekB            = -1,
        peekDimAlpha     = -1,
        peekBorderR      = -1,
        peekBorderG      = -1,
        peekBorderB      = -1,
        peekTimerStr     = false,
        peekTimerR       = -1,
        peekTimerG       = -1,
        peekTimerB       = -1,
        peekTimerPillOn  = false,
        peekTimerShown   = false,
        peekVisible      = false,
        peekTickShown    = false,
        peekTickFillW    = -1,
        thresholdAlertGuid  = false,
        thresholdAlertUnder = false,
        lastAlertedGuid     = false,
    }
end

local function resetPeekCache(cache)
    cache.peekIcon        = false
    cache.peekAlpha       = -1
    cache.peekR           = -1
    cache.peekG           = -1
    cache.peekB           = -1
    cache.peekDimAlpha    = -1
    cache.peekBorderR     = -1
    cache.peekBorderG     = -1
    cache.peekBorderB     = -1
    cache.peekTimerStr    = false
    cache.peekTimerR      = -1
    cache.peekTimerG      = -1
    cache.peekTimerB      = -1
    cache.peekTimerPillOn = false
    cache.peekTimerShown  = false
    cache.peekVisible     = false
    cache.peekTickShown   = false
    cache.peekTickFillW   = -1
end

local function clearFrameTimer(frame, cache, isPeek)
    frame.timerPill:Hide()
    frame.timer:Hide()
    frame.timer:SetText("")

    if not isPeek then
        cache.timerStr    = false
        cache.timerR      = -1
        cache.timerG      = -1
        cache.timerB      = -1
        cache.timerPillOn = false
        cache.timerShown  = false
        return
    end

    cache.peekTimerStr    = false
    cache.peekTimerR      = -1
    cache.peekTimerG      = -1
    cache.peekTimerB      = -1
    cache.peekTimerPillOn = false
    cache.peekTimerShown  = false
end

local function clearFrameTickBar(frame, cache, isPeek)
    frame.tickBarBg:Hide()
    frame.tickBarFill:Hide()
    frame.tickBarFill:SetWidth(0)

    if not isPeek then
        cache.tickShown = false
        cache.tickFillW = -1
        return
    end

    cache.peekTickShown = false
    cache.peekTickFillW = -1
end

local function clearFrameTimingVisuals(frame, cache, isPeek)
    clearFrameTimer(frame, cache, isPeek)
    clearFrameTickBar(frame, cache, isPeek)
    if DI.ClearCooldownFrame then
        DI.ClearCooldownFrame(frame)
    end
end

local function ownsActiveTiming(slot, spellId)
    return slot ~= nil
       and spellId ~= nil
       and slot.activeId ~= nil
       and spellId == slot.activeId
       and slot.spawnedAt ~= nil
end

local function resolveIcon(spellId, element)
    if spellId and DI.catalog and DI.catalog.bySpellId then
        local record = DI.catalog.bySpellId[spellId]
        if record and record.icon then return record.icon end
    end
    return DI.FALLBACK_ICON
end

local function getTickInterval(spellId)
    if not spellId or not DI.catalog or not DI.catalog.bySpellId then return 0 end

    local record = DI.catalog.bySpellId[spellId]
    if not record then return 0 end
    return record.tickInterval or 0
end

local function computeTickProgress(spawnedAt, tickInterval)
    if not spawnedAt or tickInterval <= 0 then return 0 end

    local elapsed = GetTime() - spawnedAt
    if elapsed < 0 then elapsed = 0 end

    local progress = math_mod(elapsed, tickInterval) / tickInterval
    if progress < 0 then progress = 0 end
    if progress > 1 then progress = 1 end
    return progress
end

local function applyTickBar(frame, cache, spellId, slot, isPeek)
    if not ownsActiveTiming(slot, spellId) then
        clearFrameTickBar(frame, cache, isPeek)
        return
    end

    local tickInterval = getTickInterval(spellId)
    if tickInterval <= 0 then
        clearFrameTickBar(frame, cache, isPeek)
        return
    end

    if not isPeek then
        if not cache.tickShown then
            frame.tickBarBg:Show()
            frame.tickBarFill:Show()
            cache.tickShown = true
        end

        local progress = computeTickProgress(slot.spawnedAt, tickInterval)
        local fillW    = progress * (frame.tickDrawW or 0)
        if fillW ~= cache.tickFillW then
            frame.tickBarFill:SetWidth(fillW)
            cache.tickFillW = fillW
        end
        return
    end

    if not cache.peekTickShown then
        frame.tickBarBg:Show()
        frame.tickBarFill:Show()
        cache.peekTickShown = true
    end

    local progress = computeTickProgress(slot.spawnedAt, tickInterval)
    local fillW    = progress * (frame.tickDrawW or 0)
    if fillW ~= cache.peekTickFillW then
        frame.tickBarFill:SetWidth(fillW)
        cache.peekTickFillW = fillW
    end
end

local function applyFrameTimer(frame, cache, mode, spellId, slot, isPeek, remainingSecs, isExpiring)
    if not mode.timerOn
    or not ownsActiveTiming(slot, spellId)
    or slot.duration == nil
    or slot.duration <= 0 then
        clearFrameTimer(frame, cache, isPeek)
        return
    end

    local timerStr   = false
    local timerShown = false

    timerStr   = formatTimerText(remainingSecs)
    timerShown = true

    if not isPeek then
        if timerShown ~= cache.timerPillOn then
            if timerShown then frame.timerPill:Show() else frame.timerPill:Hide() end
            cache.timerPillOn = timerShown
        end
        if timerShown ~= cache.timerShown then
            if timerShown then frame.timer:Show() else frame.timer:Hide() end
            cache.timerShown = timerShown
        end
        if timerStr ~= cache.timerStr then
            if timerStr then frame.timer:SetText(timerStr) end
            cache.timerStr = timerStr
        end
        setTimerTextColor(frame, cache, false, isExpiring and "expiry" or "normal")
        return
    end

    if timerShown ~= cache.peekTimerPillOn then
        if timerShown then frame.timerPill:Show() else frame.timerPill:Hide() end
        cache.peekTimerPillOn = timerShown
    end
    if timerShown ~= cache.peekTimerShown then
        if timerShown then frame.timer:Show() else frame.timer:Hide() end
        cache.peekTimerShown = timerShown
    end
    if timerStr ~= cache.peekTimerStr then
        if timerStr then frame.timer:SetText(timerStr) end
        cache.peekTimerStr = timerStr
    end
    setTimerTextColor(frame, cache, true, isExpiring and "expiry" or "normal")
end

local function renderElement(element, btn, slot, cache, now)
    local peekVisibilityChanged     = false
    local tintR, tintG, tintB       = getElementTintColor(element)
    local borderR, borderG, borderB = getElementBorderColor(element)
    local remainingSecs, isExpiring = isSlotAtExpiryThreshold(slot, now)

    local buttonEntry   = BUTTON_VISUALS[slot.state] or BUTTON_VISUALS[IDLE_STATE]
    local buttonSpellId = getVisualSpellId(slot, BUTTON_VISUALS)
    local buttonMode    = MODES[buttonEntry.modeKey] or MODES.empty
    local buttonIcon    = resolveIcon(buttonSpellId, element)

    syncThresholdAlertState(cache, slot, isExpiring, now)

    if buttonIcon ~= cache.icon then
        btn.icon:SetTexture(buttonIcon)
        cache.icon = buttonIcon
    end

    local buttonAlpha = buttonMode.alpha
    if slot.isInRange == false
    and SNSConfig
    and SNSConfig.rangeFade
    and buttonSpellId == slot.activeId then
        buttonAlpha = buttonAlpha * RANGE_FADE_FACTOR
    end

    if buttonAlpha ~= cache.alpha then
        btn:SetAlpha(buttonAlpha)
        cache.alpha = buttonAlpha
    end

    local buttonR = (buttonMode.r == -1) and tintR or buttonMode.r
    local buttonG = (buttonMode.g == -1) and tintG or buttonMode.g
    local buttonB = (buttonMode.b == -1) and tintB or buttonMode.b

    if buttonR ~= cache.r or buttonG ~= cache.g or buttonB ~= cache.b then
        btn.icon:SetVertexColor(buttonR, buttonG, buttonB)
        cache.r = buttonR
        cache.g = buttonG
        cache.b = buttonB
    end

    if buttonMode.dimAlpha ~= cache.dimAlpha then
        btn.dimOverlay:SetAlpha(buttonMode.dimAlpha)
        if buttonMode.dimAlpha > 0 then btn.dimOverlay:Show() else btn.dimOverlay:Hide() end
        cache.dimAlpha = buttonMode.dimAlpha
    end

    if borderR ~= cache.borderR or borderG ~= cache.borderG or borderB ~= cache.borderB then
        btn.border:SetVertexColor(borderR, borderG, borderB)
        cache.borderR = borderR
        cache.borderG = borderG
        cache.borderB = borderB
    end

    applyFrameTimer(btn, cache, buttonMode, buttonSpellId, slot, false, remainingSecs, isExpiring)
    applyTickBar(btn, cache, buttonSpellId, slot, false)
    if DI.ApplyCooldownFrame then
        DI.ApplyCooldownFrame(btn, buttonSpellId, buttonMode.timerOn and ownsActiveTiming(slot, buttonSpellId))
    end

    local peek      = btn.peek
    local peekEntry = PEEK_VISUALS[slot.state] or PEEK_VISUALS[IDLE_STATE]
    if peekEntry.modeKey == "hidden" then
        if cache.peekVisible then
            clearFrameTimingVisuals(peek, cache, true)
            peek:Hide()
            resetPeekCache(cache)
            peekVisibilityChanged = true
        end
        return peekVisibilityChanged
    end

    if not cache.peekVisible then
        peek:Show()
        cache.peekVisible     = true
        peekVisibilityChanged = true
    end

    local peekSpellId = getVisualSpellId(slot, PEEK_VISUALS)
    local peekMode    = MODES[peekEntry.modeKey] or MODES.faded
    local peekIcon    = resolveIcon(peekSpellId, element)

    if peekIcon ~= cache.peekIcon then
        peek.icon:SetTexture(peekIcon)
        cache.peekIcon = peekIcon
    end

    local peekAlpha = peekMode.alpha
    if slot.isInRange == false
    and SNSConfig
    and SNSConfig.rangeFade
    and peekSpellId == slot.activeId then
        peekAlpha = peekAlpha * RANGE_FADE_FACTOR
    end

    if peekAlpha ~= cache.peekAlpha then
        peek:SetAlpha(peekAlpha)
        cache.peekAlpha = peekAlpha
    end

    local peekR = (peekMode.r == -1) and tintR or peekMode.r
    local peekG = (peekMode.g == -1) and tintG or peekMode.g
    local peekB = (peekMode.b == -1) and tintB or peekMode.b

    if peekR ~= cache.peekR or peekG ~= cache.peekG or peekB ~= cache.peekB then
        peek.icon:SetVertexColor(peekR, peekG, peekB)
        cache.peekR = peekR
        cache.peekG = peekG
        cache.peekB = peekB
    end

    if peekMode.dimAlpha ~= cache.peekDimAlpha then
        peek.dimOverlay:SetAlpha(peekMode.dimAlpha)
        if peekMode.dimAlpha > 0 then peek.dimOverlay:Show() else peek.dimOverlay:Hide() end
        cache.peekDimAlpha = peekMode.dimAlpha
    end

    if borderR ~= cache.peekBorderR or borderG ~= cache.peekBorderG or borderB ~= cache.peekBorderB then
        peek.border:SetVertexColor(borderR, borderG, borderB)
        cache.peekBorderR = borderR
        cache.peekBorderG = borderG
        cache.peekBorderB = borderB
    end

    applyFrameTimer(peek, cache, peekMode, peekSpellId, slot, true, remainingSecs, isExpiring)
    applyTickBar(peek, cache, peekSpellId, slot, true)
    if DI.ApplyCooldownFrame then
        DI.ApplyCooldownFrame(peek, peekSpellId, peekMode.timerOn and ownsActiveTiming(slot, peekSpellId))
    end
    return peekVisibilityChanged
end

local function reconcilePeekInteractionState(dirtyElements, dirtyCount)
    local i
    for i = 1, dirtyCount do
        DI.ApplyButtonInteractionState(dirtyElements[i])
        dirtyElements[i] = nil
    end
end

local function fireUserAction(action)
    M.OnUserAction(action)
end

local function emitAction(actionType)
    if not actionType then return end
    fireUserAction({ type = actionType })
end

local function emitElementAction(actionType, element)
    if not actionType then return end
    fireUserAction({ type = actionType, element = element })
end

local function emitSpellAction(actionType, element, spellId)
    if not actionType then return end

    local action = { type = actionType, spellId = spellId }
    if element ~= nil then
        action.element = element
    end
    fireUserAction(action)
end

local function emitPositionAction(element, x, y)
    fireUserAction({
        type    = ACTION_TYPES.SAVE_ELEMENT_POSITION,
        element = element,
        x       = x,
        y       = y,
    })
end

local function syncFlyoutDerivedState()
    if DI.RefreshOpenFlyout then
        DI.RefreshOpenFlyout()
    end
    if DI.RefreshTooltip then
        DI.RefreshTooltip()
    end
    if DI.SyncCooldownUpdateFrame then
        DI.SyncCooldownUpdateFrame()
    end
end

local function commitDraggedButtonPosition(element)
    if not isElementIndex(element) then return end

    local btn = DI.buttons and DI.buttons[element]
    if not btn then return end

    DI.RunSnap(btn, DI.buttons)

    local x, y = DI.GetButtonAnchor(btn)
    if x == nil then return end

    btn:ClearAllPoints()
    btn:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    x, y = DI.FramePointToParent(btn, x, y)
    emitPositionAction(element, x, y)
end

------------------------------------------------------------------------
-- Private handlers
------------------------------------------------------------------------

local function handleHotspotEnter(frame)
    if not frame then return end

    DI.CancelFlyoutClose()
    DI.RequestFlyoutOpen(frame.element)

    local btn = DI.buttons and DI.buttons[frame.element]
    if btn and btn.peek and frame == btn.peek.inputFrame then
        if DI.ShowPeekTooltip then DI.ShowPeekTooltip(frame) end
        return
    end

    if DI.ShowButtonTooltip then
        DI.ShowButtonTooltip(frame)
    end
end

local function handleHotspotLeave()
    if DI.HideTooltip then
        DI.HideTooltip()
    end
    DI.RequestFlyoutClose()
end

local function handleFlyoutEntryEnter(frame)
    DI.CancelFlyoutClose()
    if DI.ShowFlyoutEntryTooltip then
        DI.ShowFlyoutEntryTooltip(frame)
    end
end

local function handleFlyoutEntryLeave()
    if DI.HideTooltip then
        DI.HideTooltip()
    end
    DI.RequestFlyoutClose()
end

local function bootstrapFlyoutFromMouseIsOver()
    if not DI.buttons then return end

    local element
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        local btn = DI.buttons[element]
        if btn and btn.inputFrame and btn.inputFrame:IsShown() and MouseIsOver(btn.inputFrame) then
            DI.HandleHotspotEnter(btn.inputFrame)
            return
        end
        if btn and btn.peek and btn.peek.inputFrame
       and btn.peek.inputFrame:IsShown()
       and MouseIsOver(btn.peek.inputFrame) then
            DI.HandleHotspotEnter(btn.peek.inputFrame)
            return
        end
    end
end

local function handleModifierStateChange(prevInputActive, inputActive, prevFlyoutState, newFlyoutState)
    local shouldBootstrap = (inputActive and not prevInputActive)
                         or (newFlyoutState and not prevFlyoutState)

    DI.ApplyAllButtonInteractionState()

    if not inputActive then
        if DI.HideTooltip then
            DI.HideTooltip()
        end
        DI.CloseAllFlyouts()
        return
    end

    if SNSConfig and SNSConfig.flyoutMode == "dynamic" and not newFlyoutState then
        DI.CloseAllFlyouts()
    end

    if shouldBootstrap then
        bootstrapFlyoutFromMouseIsOver()
    end
end

local function notifyFlyoutStateChanged(element, hideTooltip)
    if hideTooltip and DI.HideTooltip then
        DI.HideTooltip()
    end

    if element ~= nil and DI.ApplyButtonInteractionState then
        DI.ApplyButtonInteractionState(element)
    end
end

local function setVisible(show)
    if not DI.buttons then return end

    local i
    if show then
        for i = 1, SNS.MAX_TOTEM_SLOTS do
            DI.buttons[i]:Show()
        end
        M.Render()
        return
    end

    if DI.HideTooltip then
        DI.HideTooltip()
    end
    DI.CloseAllFlyouts()

    for i = 1, SNS.MAX_TOTEM_SLOTS do
        local btn = DI.buttons[i]
        clearFrameTimingVisuals(btn, DI.buttonState[i], false)
        clearFrameTimingVisuals(btn.peek, DI.buttonState[i], true)
        btn:Hide()
        btn.peek:Hide()
        resetPeekCache(DI.buttonState[i])
    end
    if DI.SyncCooldownUpdateFrame then
        DI.SyncCooldownUpdateFrame()
    end
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function initialize(catalog, states)
    if DI.buttons then return nil end
    if not isValidCatalog(catalog) then return nil end
    if not isValidStateContract(states) then return nil end

    local buttonVisuals, peekVisuals, idleState = buildStateVisualTables(states)

    local buttons     = {}
    local buttonState = {}
    local element
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        buttonState[element] = newCacheRow()

        local btn        = DI.CreateButton(element)
        buttons[element] = btn
        DI.CreatePeekFrame(btn)
        DI.CreateFlyoutFrame(btn)

        btn.inputFrame:SetScript("OnClick",      DI.OnClickScript)
        btn.inputFrame:SetScript("OnDragStart",  DI.OnDragStartScript)
        btn.inputFrame:SetScript("OnDragStop",   DI.OnDragStopScript)
        btn.inputFrame:SetScript("OnMouseWheel", DI.OnMouseWheelScript)
        btn.inputFrame:SetScript("OnEnter",      DI.OnHotspotEnterScript)
        btn.inputFrame:SetScript("OnLeave",      DI.OnHotspotLeaveScript)

        btn.peek.inputFrame:SetScript("OnClick", DI.OnPeekClickScript)
        btn.peek.inputFrame:SetScript("OnEnter", DI.OnHotspotEnterScript)
        btn.peek.inputFrame:SetScript("OnLeave", DI.OnHotspotLeaveScript)
    end

    syncFlyoutPools(buttons, catalog)

    BUTTON_VISUALS = buttonVisuals
    PEEK_VISUALS   = peekVisuals
    IDLE_STATE     = idleState

    DI.catalog     = catalog
    DI.buttons     = buttons
    DI.buttonState = buttonState

    M.ApplyConfig()
end

local function setCatalog(catalog)
    if not isValidCatalog(catalog) then return nil end
    if not DI.buttons then return nil end

    DI.catalog = catalog
    syncFlyoutPools(DI.buttons, catalog)
    if DI.snapshot then
        M.Render()
    end
end

local function render(snapshot)
    if snapshot ~= nil and not isValidSnapshot(snapshot) then
        return nil
    end

    if not DI.buttons then return nil end

    if snapshot ~= nil then
        DI.snapshot = snapshot
    end

    if type(SNSConfig) ~= "table" or not SNSConfig.visible then return end

    local snap = DI.snapshot
    if not snap then return end

    local dirtyElements = peekInteractionDirty
    local dirtyCount    = 0
    local now           = GetTime()
    local element
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        if renderElement(element, DI.buttons[element], snap[element], DI.buttonState[element], now) then
            dirtyCount = dirtyCount + 1
            dirtyElements[dirtyCount] = element
        end
    end

    if dirtyCount > 0 then
        reconcilePeekInteractionState(dirtyElements, dirtyCount)
    end

    syncFlyoutDerivedState()
end

local function applyConfig()
    if not DI.buttons then return end

    local scale      = getScale()
    local showBorder = shouldShowBorder()
    local element

    for element = 1, SNS.MAX_TOTEM_SLOTS do
        local btn = DI.buttons[element]
        btn:SetScale(scale)
        btn.peek:SetScale(scale)
        applyFlyoutFrameConfig(btn, scale, showBorder)
        DI.ApplyIconChrome(btn, DI.BUTTON_SIZE, showBorder)
        DI.ApplyIconChrome(btn.peek, DI.PEEK_SIZE, showBorder)
        DI.RestoreButtonPosition(btn)
        DI.AnchorPeek(btn)
    end

    DI.CloseAllFlyouts()
    DI.UpdateModifierEventCapture()
    DI.ApplyAllButtonInteractionState()
    if DI.HideTooltip then
        DI.HideTooltip()
    end
    setVisible(type(SNSConfig) == "table" and SNSConfig.visible ~= false)
end

local function applyFlyoutConfig()
    if not DI.buttons then return end

    local element
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        DI.AnchorPeek(DI.buttons[element])
    end

    syncFlyoutDerivedState()
end

local function playLifecycleAlert(element, guid)
    local cache

    if not isElementIndex(element) then return nil end
    if not isNonEmptyString(guid) then return nil end

    cache = DI.buttonState and DI.buttonState[element] or nil
    if not cache then return nil end

    return registerLifecycleAlert(cache, guid, GetTime())
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

DI.GetScale                    = getScale
DI.ShouldShowBorder            = shouldShowBorder
DI.GetElementConfig            = getElementConfig
DI.GetElementTintColor         = getElementTintColor
DI.GetElementBorderColor       = getElementBorderColor
DI.GetButtonSpellId            = getButtonSpellId
DI.GetPeekSpellId              = getPeekSpellId
DI.FormatTimerText             = formatTimerText
DI.FormatMinutesSeconds        = formatTimerMinutesSeconds
DI.EmitAction                  = emitAction
DI.EmitElementAction           = emitElementAction
DI.EmitSpellAction             = emitSpellAction
DI.CommitDraggedButtonPosition = commitDraggedButtonPosition
DI.HandleHotspotEnter          = handleHotspotEnter
DI.HandleHotspotLeave          = handleHotspotLeave
DI.HandleFlyoutEntryEnter      = handleFlyoutEntryEnter
DI.HandleFlyoutEntryLeave      = handleFlyoutEntryLeave
DI.HandleModifierStateChange   = handleModifierStateChange
DI.NotifyFlyoutStateChanged    = notifyFlyoutStateChanged

------------------------------------------------------------------------
-- Public exports
------------------------------------------------------------------------

M.OnUserAction      = onUserActionNoop
M.Initialize        = initialize
M.SetCatalog        = setCatalog
M.Render            = render
M.PlayLifecycleAlert = playLifecycleAlert
M.ApplyConfig       = applyConfig
M.ApplyFlyoutConfig = applyFlyoutConfig
