-- SticksAndStones: Settings/Settings.lua
-- Facade and lifecycle controller for the Settings pod.
-- Owns SettingsInternal (pod shared table), Settings (public facade), and the
-- outbound OnConfigChanged / OnFlyoutConfigChanged callback slots.
-- Delegates SavedVariables and binding work to Store.lua and exposes public
-- config-mutation entrypoints on Settings.
-- No direct WoW API calls. No globals created beyond SettingsInternal and Settings.

------------------------------------------------------------------------
-- Pod shared table
------------------------------------------------------------------------

SettingsInternal = {}

------------------------------------------------------------------------
-- Public facade
------------------------------------------------------------------------

Settings = {}
local M  = Settings
local SI = SettingsInternal  -- sibling modules add fields onto the same table

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local SET_DIRECTION_FORWARD  = 1
local SET_DIRECTION_BACKWARD = -1
local CONFIG_SCOPE_DISPLAY   = "display"
local CONFIG_SCOPE_RANGE     = "range"
local CONFIG_SCOPE_SETS      = "sets"
local CONFIG_SCOPE_PROFILE   = "profile"

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

-- Refreshes the Settings UI when visible. No-op until SI.UI is assigned.
local function refreshVisibleUI()
    local UI = SI.UI
    if UI and UI.IsVisible and UI.IsVisible() then UI.Refresh() end
end

-- Notifies Settings UI then broadcasts the config scope to dependent pods.
local function broadcastConfigChanged(scope)
    refreshVisibleUI()
    M.OnConfigChanged(scope or CONFIG_SCOPE_DISPLAY)
end

local function broadcastDisplayConfigChanged()
    broadcastConfigChanged(CONFIG_SCOPE_DISPLAY)
end

local function broadcastRangeConfigChanged()
    broadcastConfigChanged(CONFIG_SCOPE_RANGE)
end

local function broadcastSetConfigChanged()
    broadcastConfigChanged(CONFIG_SCOPE_SETS)
end

local function broadcastProfileConfigChanged()
    broadcastConfigChanged(CONFIG_SCOPE_PROFILE)
end

-- Notifies the Flyouts tab, then asks App to refresh any open live flyout.
local function broadcastFlyoutConfigChanged()
    refreshVisibleUI()
    M.OnFlyoutConfigChanged()
end

local function getSetCount()
    if type(SNSConfig.sets) ~= "table" then return 0 end
    return table.getn(SNSConfig.sets)
end

local function isValidSetIndex(index, count)
    return  type(index) == "number"
        and index == math.floor(index)
        and index >= 1
        and index <= count
end

local function isValidElementIndex(element)
    return  type(element) == "number"
        and element == math.floor(element)
        and element >= 1
        and element <= SI.MAX_ELEMENTS
end

local function isValidClickThroughModifier(value)
    return type(value) == "string"
       and SI.sanitizeClickThroughMod
       and SI.sanitizeClickThroughMod(value) == value
end

local function isValidFlyoutMode(value)
    return type(value) == "string"
       and SI.sanitizeFlyoutMode
       and SI.sanitizeFlyoutMode(value) == value
end

local function isValidFlyoutModifier(value)
    return type(value) == "string"
       and SI.sanitizeFlyoutMod
       and SI.sanitizeFlyoutMod(value) == value
end

local function isValidFlyoutDirection(value)
    return type(value) == "string"
       and SI.sanitizeFlyoutDir
       and SI.sanitizeFlyoutDir(value) == value
end

local function isValidTooltipAnchorMode(value)
    return type(value) == "string"
       and SI.sanitizeTooltipAnchorMode
       and SI.sanitizeTooltipAnchorMode(value) == value
end

local function isValidTooltipDirection(value)
    return type(value) == "string"
       and SI.sanitizeTooltipDirection
       and SI.sanitizeTooltipDirection(value) == value
end

local function normalizeProfileKey(key)
    if not SI.sanitizeProfileKey then return nil end
    return SI.sanitizeProfileKey(key)
end

local function isValidFlyoutOrder(rawOrder)
    local sanitized = SI.sanitizeFlyoutOrder and SI.sanitizeFlyoutOrder(rawOrder) or nil
    local rawCount
    local i

    if type(rawOrder) ~= "table" or type(sanitized) ~= "table" then
        return nil
    end

    rawCount = table.getn(rawOrder)
    if rawCount ~= table.getn(sanitized) then
        return nil
    end

    for i = 1, rawCount do
        if rawOrder[i] ~= sanitized[i] then
            return nil
        end
    end

    return sanitized
end

local function isValidFlyoutFilter(rawFilter)
    local sanitized = SI.sanitizeFlyoutFilter and SI.sanitizeFlyoutFilter(rawFilter) or nil
    local rawCount       = 0
    local sanitizedCount = 0
    local spellId
    local hidden

    if type(rawFilter) ~= "table" or type(sanitized) ~= "table" then
        return nil
    end

    for spellId, hidden in pairs(rawFilter) do
        if type(spellId) ~= "number"
        or spellId ~= math.floor(spellId)
        or spellId <= 0
        or hidden ~= true
        or not sanitized[spellId] then
            return nil
        end
        rawCount = rawCount + 1
    end

    for spellId in pairs(sanitized) do
        sanitizedCount = sanitizedCount + 1
    end

    if rawCount ~= sanitizedCount then
        return nil
    end

    return sanitized
end

-- Seeds a raw set row from the current chosen snapshot, then lets Rules own
-- the final set-row shape and validation.
local function buildChosenSetRow(chosen)
    local rawSet = {}
    local chosenTable = type(chosen) == "table" and chosen or nil
    for slot = 1, SI.MAX_ELEMENTS do
        rawSet[slot] = chosenTable and chosenTable[slot] or nil
    end
    return SI.sanitizeSetRow(rawSet)
end

local function resetGeneralElementDefaults(config, defaults)
    local element

    for element = 1, SI.MAX_ELEMENTS do
        local cfg = config.elements[element]
        local defaultCfg = defaults.elements[element]

        cfg.centerX       = defaultCfg.centerX
        cfg.centerY       = defaultCfg.centerY
        cfg.borderColorR  = defaultCfg.borderColorR
        cfg.borderColorG  = defaultCfg.borderColorG
        cfg.borderColorB  = defaultCfg.borderColorB
        cfg.elementColorR = defaultCfg.elementColorR
        cfg.elementColorG = defaultCfg.elementColorG
        cfg.elementColorB = defaultCfg.elementColorB
    end
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

-- Bootstraps SNSProfiles and binds SNSConfig to the current character's
-- resolved active profile. Must run before other pods read config.
local function initialize()
    SI.ensureStore()
    SI.bindCharacterProfile(SI.characterKey())
end

-- Toggle the Settings UI when it exists. Returns nil when no Settings UI is wired.
local function toggleUI()
    local UI = SI.UI
    if not UI or not UI.Toggle then return nil end
    UI.Toggle()
    return true
end

-- Flip the saved bar visibility flag and notify dependent pods to refresh.
local function toggleBarVisible()
    SNSConfig.visible = not SNSConfig.visible
    broadcastDisplayConfigChanged()
    return SNSConfig.visible
end

-- Reset the current character's resolved active profile through Store so
-- defaults remain owned by Rules/Store helpers.
local function resetToDefaults()
    SI.ensureStore()
    SI.resetCharacterProfile(SI.characterKey())
    broadcastProfileConfigChanged()
    return true
end

local function resetGeneralToDefaults()
    local defaults = SI.DEFAULTS

    if type(SNSConfig) ~= "table" then return nil end
    if type(defaults) ~= "table" then return nil end
    if type(SNSConfig.elements) ~= "table" then return nil end
    if type(defaults.elements) ~= "table" then return nil end

    SNSConfig.scale           = defaults.scale
    SNSConfig.locked          = defaults.locked
    SNSConfig.clickThrough    = defaults.clickThrough
    SNSConfig.clickThroughMod = defaults.clickThroughMod
    SNSConfig.snapAlign       = defaults.snapAlign
    SNSConfig.showBorder      = defaults.showBorder

    resetGeneralElementDefaults(SNSConfig, defaults)
    broadcastDisplayConfigChanged()
    return true
end

local function listProfiles()
    local list = SI.ListProfilesInternal and SI.ListProfilesInternal() or nil
    if type(list) ~= "table" then
        return {}
    end
    return list
end

local function getActiveProfileKey()
    if not SI.GetActiveProfileKeyInternal then return nil end
    return SI.GetActiveProfileKeyInternal()
end

local function setActiveProfile(key)
    local normalized = normalizeProfileKey(key)
    local ok
    local err

    if not normalized then return nil, "invalid_profile_key" end
    if not SI.SetActiveProfileInternal then return nil end
    if normalized == getActiveProfileKey() then return true end

    ok, err = SI.SetActiveProfileInternal(normalized)
    if not ok then return nil, err end

    broadcastProfileConfigChanged()
    return true
end

local function createProfile(key, sourceKey)
    local normalizedKey    = normalizeProfileKey(key)
    local normalizedSource = nil
    local ok
    local err

    if not normalizedKey then return nil, "invalid_profile_key" end
    if sourceKey ~= nil then
        normalizedSource = normalizeProfileKey(sourceKey)
        if not normalizedSource then return nil, "invalid_profile_key" end
    end
    if not SI.CreateProfileInternal then return nil end

    ok, err = SI.CreateProfileInternal(normalizedKey, normalizedSource)
    if not ok then return nil, err end

    refreshVisibleUI()
    return true
end

local function renameProfile(oldKey, newKey)
    local normalizedOld = normalizeProfileKey(oldKey)
    local normalizedNew = normalizeProfileKey(newKey)
    local ok
    local err

    if not normalizedOld or not normalizedNew then
        return nil, "invalid_profile_key"
    end
    if normalizedOld == normalizedNew then
        return nil, "same_profile_key"
    end
    if not SI.RenameProfileInternal then return nil end

    ok, err = SI.RenameProfileInternal(normalizedOld, normalizedNew)
    if not ok then return nil, err end

    refreshVisibleUI()
    return true
end

local function deleteProfile(key)
    local normalized = normalizeProfileKey(key)
    local ok
    local err

    if not normalized then return nil, "invalid_profile_key" end
    if not SI.DeleteProfileInternal then return nil end

    ok, err = SI.DeleteProfileInternal(normalized)
    if not ok then return nil, err end

    refreshVisibleUI()
    return true
end

-- Export one saved profile as deterministic share text. Nil key means the
-- active profile.
local function exportProfile(key)
    local normalized = nil

    if key ~= nil then
        normalized = normalizeProfileKey(key)
        if not normalized then return nil, "invalid_profile_key" end
    end
    if not SI.ExportProfileInternal then return nil end

    return SI.ExportProfileInternal(normalized)
end

-- Import shared profile text into SavedVariables without changing the active
-- profile binding.
local function importProfile(text)
    local newKey
    local err

    if type(text) ~= "string" then return nil, "invalid_text" end
    if not SI.ImportProfileInternal then return nil end

    newKey, err = SI.ImportProfileInternal(text)
    if not newKey then return nil, err end

    refreshVisibleUI()
    return newKey
end

-- Set the locked state. Fires OnConfigChanged so Display refreshes
-- edit overlays and drag registration.
local function setLocked(value)
    if not SI.isBoolean(value) then return end
    if SNSConfig.locked == value then return end
    SNSConfig.locked = value
    broadcastDisplayConfigChanged()
end

local function setClickThrough(enabled)
    if not SI.isBoolean(enabled) then return nil end
    if SNSConfig.clickThrough == enabled then return true end

    SNSConfig.clickThrough = enabled
    broadcastDisplayConfigChanged()
    return true
end

local function setClickThroughModifier(value)
    if not isValidClickThroughModifier(value) then return nil end
    if SNSConfig.clickThroughMod == value then return true end

    SNSConfig.clickThroughMod = value
    broadcastDisplayConfigChanged()
    return true
end

local function setFlyoutMode(value)
    if not isValidFlyoutMode(value) then return nil end
    if SNSConfig.flyoutMode == value then return true end

    SNSConfig.flyoutMode = value
    broadcastDisplayConfigChanged()
    return true
end

local function setFlyoutModifier(value)
    if not isValidFlyoutModifier(value) then return nil end
    if SNSConfig.flyoutMod == value then return true end

    SNSConfig.flyoutMod = value
    broadcastDisplayConfigChanged()
    return true
end

local function onConfigChangedNoop()
end

local function onFlyoutConfigChangedNoop()
end

-- Persist a button's center position after drag. Does NOT fire
-- OnConfigChanged - the button is already visually in place and no
-- other pod reacts to position changes.
local function saveElementAnchor(element, x, y)
    if not isValidElementIndex(element) then return end
    if type(x) ~= "number" or type(y) ~= "number" then return end
    local cfg = SNSConfig.elements[element]
    if not cfg then return end
    cfg.centerX = x
    cfg.centerY = y
end

-- Persist the minimap button angle after drag. Does NOT fire
-- OnConfigChanged - the button is already visually in place and no
-- other pod reacts to minimap angle changes.
local function saveMinimapAngle(angle)
    if type(angle) ~= "number" then return nil end
    local sanitized = SI.sanitizeMinimapAngle(angle)
    SNSConfig.minimapAngle = sanitized
    return sanitized
end

local function setScale(value)
    if type(value) ~= "number" then return end
    local clamped = SI.clamp(value, SI.SCALE_MIN, SI.SCALE_MAX)
    if SNSConfig.scale == clamped then return end
    SNSConfig.scale = clamped
    broadcastDisplayConfigChanged()
end

local function setBorderVisible(show)
    if not SI.isBoolean(show) then return end
    if SNSConfig.showBorder == show then return end
    SNSConfig.showBorder = show
    broadcastDisplayConfigChanged()
end

local function setSnapAlign(enabled)
    if not SI.isBoolean(enabled) then return end
    SNSConfig.snapAlign = enabled
    refreshVisibleUI()
end

local function setRangeOffsetYards(value)
    if type(value) ~= "number" or not SI.sanitizeRangeOffsetYards then return nil end

    value = SI.sanitizeRangeOffsetYards(value, SNSConfig.rangeOffsetYards)
    SNSConfig.rangeOffsetYards = value
    refreshVisibleUI()
    return value
end

local function setPollInterval(value)
    if type(value) ~= "number" or not SI.sanitizePollInterval then return nil end

    value = SI.sanitizePollInterval(value, SNSConfig.pollInterval)
    SNSConfig.pollInterval = value
    refreshVisibleUI()
    return value
end

local function setRangeFade(enabled)
    if not SI.isBoolean(enabled) then return nil end
    if SNSConfig.rangeFade == enabled then return true end

    SNSConfig.rangeFade = enabled
    broadcastRangeConfigChanged()
    return true
end

local function setTimerShowMinutes(enabled)
    if not SI.isBoolean(enabled) then return nil end
    if SNSConfig.timerShowMinutes == enabled then return true end

    SNSConfig.timerShowMinutes = enabled
    broadcastDisplayConfigChanged()
    return true
end

local function setExpiryThresholdSecs(value)
    if type(value) ~= "number" or not SI.sanitizeExpiryThresholdSecs then return nil end

    value = SI.sanitizeExpiryThresholdSecs(value, SNSConfig.expiryThresholdSecs)
    if SNSConfig.expiryThresholdSecs == value then return value end

    SNSConfig.expiryThresholdSecs = value
    broadcastDisplayConfigChanged()
    return value
end

local function setExpirySoundEnabled(enabled)
    if not SI.isBoolean(enabled) then return nil end
    if SNSConfig.expirySoundEnabled == enabled then return true end

    SNSConfig.expirySoundEnabled = enabled
    broadcastDisplayConfigChanged()
    return true
end

local function setTooltipsEnabled(enabled)
    if not SI.isBoolean(enabled) then return nil end
    if SNSConfig.tooltipsEnabled == enabled then return true end

    SNSConfig.tooltipsEnabled = enabled
    broadcastDisplayConfigChanged()
    return true
end

local function setTooltipAnchorMode(value)
    if not isValidTooltipAnchorMode(value) then return nil end
    if SNSConfig.tooltipAnchorMode == value then return true end

    SNSConfig.tooltipAnchorMode = value
    broadcastDisplayConfigChanged()
    return true
end

local function setTooltipDirection(value)
    if not isValidTooltipDirection(value) then return nil end
    if SNSConfig.tooltipDirection == value then return true end

    SNSConfig.tooltipDirection = value
    broadcastDisplayConfigChanged()
    return true
end

local function setTooltipOffsetX(value)
    if type(value) ~= "number" or not SI.sanitizeTooltipOffset then return nil end

    value = SI.sanitizeTooltipOffset(value, SNSConfig.tooltipOffsetX)
    if SNSConfig.tooltipOffsetX == value then return value end
    SNSConfig.tooltipOffsetX = value
    broadcastDisplayConfigChanged()
    return value
end

local function setTooltipOffsetY(value)
    if type(value) ~= "number" or not SI.sanitizeTooltipOffset then return nil end

    value = SI.sanitizeTooltipOffset(value, SNSConfig.tooltipOffsetY)
    if SNSConfig.tooltipOffsetY == value then return value end
    SNSConfig.tooltipOffsetY = value
    broadcastDisplayConfigChanged()
    return value
end

local function setElementColorTriplet(element, r, g, b, rKey, gKey, bKey)
    if not isValidElementIndex(element) then return end
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return end

    local cfg = SNSConfig.elements[element]
    if not cfg then return end

    cfg[rKey] = SI.sanitizeColorChannel(r)
    cfg[gKey] = SI.sanitizeColorChannel(g)
    cfg[bKey] = SI.sanitizeColorChannel(b)
    broadcastDisplayConfigChanged()
    return true
end

local function setElementBorderColor(element, r, g, b)
    return setElementColorTriplet(element, r, g, b, "borderColorR", "borderColorG", "borderColorB")
end

local function setElementTintColor(element, r, g, b)
    return setElementColorTriplet(element, r, g, b, "elementColorR", "elementColorG", "elementColorB")
end

local function setElementFlyoutDirection(element, dir)
    if not isValidElementIndex(element) then return nil end
    if not isValidFlyoutDirection(dir) then return nil end

    local cfg = SNSConfig.elements[element]
    if not cfg then return nil end
    if cfg.flyoutDir == dir then return true end

    cfg.flyoutDir = dir
    broadcastFlyoutConfigChanged()
    return true
end

local function setElementFlyoutOrder(element, rawOrder)
    local sanitized

    if not isValidElementIndex(element) then return nil end
    sanitized = isValidFlyoutOrder(rawOrder)
    if not sanitized then return nil end

    local cfg = SNSConfig.elements[element]
    if not cfg then return nil end

    cfg.flyoutOrder = sanitized
    broadcastFlyoutConfigChanged()
    return true
end

local function setElementFlyoutFilter(element, rawFilter)
    local sanitized

    if not isValidElementIndex(element) then return nil end
    sanitized = isValidFlyoutFilter(rawFilter)
    if not sanitized then return nil end

    local cfg = SNSConfig.elements[element]
    if not cfg then return nil end

    cfg.flyoutFilter = sanitized
    broadcastFlyoutConfigChanged()
    return true
end

-- Set management public API.
-- Set whether keyboard/mouse-wheel set cycling wraps across the ends.
local function setSetCycleWrap(enabled)
    if not SI.isBoolean(enabled) then return end
    SNSConfig.setsCycleWrap = enabled
    refreshVisibleUI()
end

-- Select a set by index (or ACTIVE_SET_NONE = 0) and notify dependents.
local function setActiveSet(index)
    local count = getSetCount()
    if index ~= SI.ACTIVE_SET_NONE and not isValidSetIndex(index, count) then
        return nil, "invalid_index"
    end
    SNSConfig.activeSetIndex = index
    broadcastSetConfigChanged()
    return true
end

-- Step the active set by the requested direction. Wraps when setsCycleWrap is true.
local function cycleSet(direction)
    if direction ~= SET_DIRECTION_FORWARD and direction ~= SET_DIRECTION_BACKWARD then
        return nil, "invalid_direction"
    end
    local count = getSetCount()
    if count == 0 then
        SNSConfig.activeSetIndex = SI.ACTIVE_SET_NONE
        return
    end
    local currentIndex = SNSConfig.activeSetIndex
    if not isValidSetIndex(currentIndex, count) then
        currentIndex = SI.ACTIVE_SET_NONE
    end
    local nextIndex
    if SNSConfig.setsCycleWrap then
        if currentIndex == SI.ACTIVE_SET_NONE then
            nextIndex = (direction == SET_DIRECTION_FORWARD) and 1 or count
        else
            nextIndex = math.mod(currentIndex - 1 + direction + count, count) + 1
        end
    else
        nextIndex = currentIndex + direction
        if nextIndex < 1 then nextIndex = 1 end
        if nextIndex > count then nextIndex = count end
    end
    if nextIndex == SNSConfig.activeSetIndex then return end
    SNSConfig.activeSetIndex = nextIndex
    broadcastSetConfigChanged()
end

local function cycleSetForward()
    return cycleSet(SET_DIRECTION_FORWARD)
end

local function cycleSetBackward()
    return cycleSet(SET_DIRECTION_BACKWARD)
end

-- Create a set seeded from current chosen totems. Auto-selects the new set.
local function createSet()
    local count    = getSetCount()
    if count >= SI.MAX_SETS then return nil, "max_sets_reached" end
    local newIndex = count + 1
    local newSet   = buildChosenSetRow(App.GetChosenSnapshot())
    SNSConfig.sets[newIndex] = newSet
    SNSConfig.activeSetIndex = newIndex
    broadcastSetConfigChanged()
    return newIndex
end

-- Remove a set row and remap activeSetIndex to the nearest surviving row.
local function removeSet(index)
    local count               = getSetCount()
    if not isValidSetIndex(index, count) then return nil, "invalid_index" end
    local prevActive          = SNSConfig.activeSetIndex
    local activeRowWasRemoved = prevActive == index
    for i = index, count - 1 do
        SNSConfig.sets[i] = SNSConfig.sets[i + 1]
    end
    SNSConfig.sets[count] = nil
    local newCount  = count - 1
    local newActive
    if newCount == 0 then
        newActive = SI.ACTIVE_SET_NONE
    elseif prevActive == SI.ACTIVE_SET_NONE then
        newActive = SI.ACTIVE_SET_NONE
    elseif prevActive < index then
        newActive = prevActive
    elseif prevActive == index then
        newActive = (index <= newCount) and index or newCount
    else
        newActive = prevActive - 1
    end
    SNSConfig.activeSetIndex = newActive
    if newActive ~= prevActive or activeRowWasRemoved then
        broadcastSetConfigChanged()
    else
        refreshVisibleUI()
    end
    return newActive
end

-- Swap a set with its neighbor in the requested direction, tracking activeSetIndex.
local function reorderSet(index, direction)
    if direction ~= SET_DIRECTION_FORWARD and direction ~= SET_DIRECTION_BACKWARD then
        return nil, "invalid_direction"
    end
    local count    = getSetCount()
    if not isValidSetIndex(index, count) then return nil, "invalid_index" end
    local newIndex = index + direction
    if newIndex < 1 or newIndex > count then return nil, "out_of_bounds" end
    local prevActive         = SNSConfig.activeSetIndex
    local tempSet            = SNSConfig.sets[index]
    SNSConfig.sets[index]    = SNSConfig.sets[newIndex]
    SNSConfig.sets[newIndex] = tempSet
    local newActive          = prevActive
    if prevActive == index then
        newActive = newIndex
    elseif prevActive == newIndex then
        newActive = index
    end
    SNSConfig.activeSetIndex = newActive
    if newActive ~= prevActive then
        broadcastSetConfigChanged()
    else
        refreshVisibleUI()
    end
    return newIndex
end

------------------------------------------------------------------------
-- Public exports
------------------------------------------------------------------------

-- Outbound callback slot. App wires this after initialization. Default is noop.
M.OnConfigChanged           = onConfigChangedNoop
M.OnFlyoutConfigChanged     = onFlyoutConfigChangedNoop

M.Initialize                = initialize
M.ToggleUI                  = toggleUI
M.ToggleBarVisible          = toggleBarVisible
M.ResetToDefaults           = resetToDefaults
M.ResetGeneralToDefaults    = resetGeneralToDefaults
M.ListProfiles              = listProfiles
M.GetActiveProfileKey       = getActiveProfileKey
M.SetActiveProfile          = setActiveProfile
M.CreateProfile             = createProfile
M.RenameProfile             = renameProfile
M.DeleteProfile             = deleteProfile
M.ExportProfile             = exportProfile
M.ImportProfile             = importProfile
M.SetLocked                 = setLocked
M.SetClickThrough           = setClickThrough
M.SetClickThroughModifier   = setClickThroughModifier
M.SaveElementAnchor         = saveElementAnchor
M.SaveMinimapAngle          = saveMinimapAngle
M.SetScale                  = setScale
M.SetBorderVisible          = setBorderVisible
M.SetSnapAlign              = setSnapAlign
M.SetFlyoutMode             = setFlyoutMode
M.SetFlyoutModifier         = setFlyoutModifier
M.SetRangeFade              = setRangeFade
M.SetRangeOffsetYards       = setRangeOffsetYards
M.SetPollInterval           = setPollInterval
M.SetTimerShowMinutes       = setTimerShowMinutes
M.SetExpiryThresholdSecs    = setExpiryThresholdSecs
M.SetExpirySoundEnabled     = setExpirySoundEnabled
M.SetTooltipsEnabled        = setTooltipsEnabled
M.SetTooltipAnchorMode      = setTooltipAnchorMode
M.SetTooltipDirection       = setTooltipDirection
M.SetTooltipOffsetX         = setTooltipOffsetX
M.SetTooltipOffsetY         = setTooltipOffsetY
M.SetElementBorderColor     = setElementBorderColor
M.SetElementTintColor       = setElementTintColor
M.SetElementFlyoutDirection = setElementFlyoutDirection
M.SetElementFlyoutOrder     = setElementFlyoutOrder
M.SetElementFlyoutFilter    = setElementFlyoutFilter
M.SetSetCycleWrap           = setSetCycleWrap
M.SetActiveSet              = setActiveSet
M.CycleSetForward           = cycleSetForward
M.CycleSetBackward          = cycleSetBackward
M.CreateSet                 = createSet
M.RemoveSet                 = removeSet
M.ReorderSet                = reorderSet
