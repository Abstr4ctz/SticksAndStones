-- SticksAndStones: Settings/Rules.lua
-- Pure schema, defaults, and sanitization module for the Settings pod.
-- Owns SettingsInternal's schema constants, default profile template, and
-- sanitizeProfile. Zero WoW API calls. Side effects: load-time writes onto
-- SettingsInternal during export.
-- Constants and sanitizers for additional fields arrive with their
-- respective features.
-- All exports on SettingsInternal. No other globals created.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = SettingsInternal  -- created by Settings.lua, loaded first per TOC order

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local STORE_SCHEMA_VERSION     = 1
local ACTIVE_SET_NONE          = 0
local SCALE_MIN                = 0.5
local SCALE_MAX                = 3.0
local POLL_MIN                 = 0.1
local POLL_MAX                 = 5.0
local RANGE_OFFSET_MIN         = -10
local RANGE_OFFSET_MAX         = 10
local EXPIRY_THRESHOLD_MIN     = 0
local EXPIRY_THRESHOLD_MAX     = 600
local TOOLTIP_OFFSET_MIN       = -200
local TOOLTIP_OFFSET_MAX       = 200
local COLOR_MIN                = 0
local COLOR_MAX                = 1
local MINIMAP_ANGLE_MAX        = 360
local MINIMAP_ANGLE_DEFAULT    = 220

local MAX_ELEMENTS             = SNS.MAX_TOTEM_SLOTS
local MAX_SETS                 = 20

local DIR_TOP                  = "top"
local DIR_BOTTOM               = "bottom"
local DIR_LEFT                 = "left"
local DIR_RIGHT                = "right"
local DIR_UP                   = "up"
local DIR_DOWN                 = "down"
local MOD_NONE                 = "none"
local MOD_CTRL                 = "ctrl"
local MOD_ALT                  = "alt"
local MOD_SHIFT                = "shift"
local MODE_FREE                = "free"
local MODE_DYNAMIC             = "dynamic"
local MODE_CLOSED              = "closed"
local ANCHOR_MODE_FRAME        = "frame"
local ANCHOR_MODE_CURSOR       = "cursor"

local VALID_CLICK_THROUGH_MODS   = { [MOD_NONE] = true, [MOD_CTRL] = true, [MOD_ALT] = true, [MOD_SHIFT] = true }
local VALID_FLYOUT_MODES         = { [MODE_FREE] = true, [MODE_DYNAMIC] = true, [MODE_CLOSED] = true }
local VALID_FLYOUT_MODS          = { [MOD_CTRL] = true, [MOD_ALT] = true, [MOD_SHIFT] = true }
local VALID_FLYOUT_DIRS          = { [DIR_TOP] = true, [DIR_BOTTOM] = true, [DIR_LEFT] = true, [DIR_RIGHT] = true }
local VALID_TOOLTIP_ANCHOR_MODES = { [ANCHOR_MODE_FRAME] = true, [ANCHOR_MODE_CURSOR] = true }
local VALID_TOOLTIP_DIRS         = { [DIR_UP] = true, [DIR_DOWN] = true, [DIR_LEFT] = true, [DIR_RIGHT] = true }

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function deepCopy(src)
    if type(src) ~= "table" then return src end
    local copy = {}
    for key, value in pairs(src) do
        copy[deepCopy(key)] = deepCopy(value)
    end
    return copy
end

local function clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function isBoolean(value)
    return type(value) == "boolean"
end

local function sanitizeMinimapAngle(value)
    if type(value) ~= "number" then return MINIMAP_ANGLE_DEFAULT end
    value = math.mod(value, MINIMAP_ANGLE_MAX)
    if value < 0 then value = value + MINIMAP_ANGLE_MAX end
    return value
end

-- Returns clamped [0, 1] channel value; defaults to COLOR_MAX for non-numbers.
local function sanitizeColorChannel(value)
    if type(value) ~= "number" then return COLOR_MAX end
    return clamp(value, COLOR_MIN, COLOR_MAX)
end

local function sanitizeClickThroughMod(value)
    if type(value) ~= "string" then return MOD_CTRL end
    if VALID_CLICK_THROUGH_MODS[value] then return value end
    return MOD_CTRL
end

local function sanitizeFlyoutMode(value)
    if type(value) ~= "string" then return MODE_FREE end
    if VALID_FLYOUT_MODES[value] then return value end
    return MODE_FREE
end

local function sanitizeFlyoutMod(value)
    if type(value) ~= "string" then return MOD_SHIFT end
    if VALID_FLYOUT_MODS[value] then return value end
    return MOD_SHIFT
end

local function sanitizeFlyoutDir(value)
    if type(value) ~= "string" then return DIR_TOP end
    if VALID_FLYOUT_DIRS[value] then return value end
    return DIR_TOP
end

local function sanitizeTooltipAnchorMode(value)
    if type(value) ~= "string" then return ANCHOR_MODE_FRAME end
    if VALID_TOOLTIP_ANCHOR_MODES[value] then return value end
    return ANCHOR_MODE_FRAME
end

local function sanitizeTooltipDirection(value)
    if type(value) ~= "string" then return DIR_RIGHT end
    if VALID_TOOLTIP_DIRS[value] then return value end
    return DIR_RIGHT
end

local function sanitizeTooltipOffset(value, fallback)
    if type(value) ~= "number" then
        value = fallback
    end
    if type(value) ~= "number" then
        value = 0
    end
    return clamp(value, TOOLTIP_OFFSET_MIN, TOOLTIP_OFFSET_MAX)
end

local function sanitizeRangeOffsetYards(value, fallback)
    if type(value) ~= "number" then
        value = fallback
    end
    if type(value) ~= "number" then
        value = 0
    end
    return clamp(value, RANGE_OFFSET_MIN, RANGE_OFFSET_MAX)
end

local function sanitizePollInterval(value, fallback)
    if type(value) ~= "number" then
        value = fallback
    end
    if type(value) ~= "number" then
        value = POLL_MIN
    end
    return clamp(value, POLL_MIN, POLL_MAX)
end

local function sanitizeExpiryThresholdSecs(value, fallback)
    if type(value) ~= "number" then
        value = fallback
    end
    if type(value) ~= "number" then
        value = EXPIRY_THRESHOLD_MIN
    end

    value = math.floor(value)
    return clamp(value, EXPIRY_THRESHOLD_MIN, EXPIRY_THRESHOLD_MAX)
end

local function sanitizeFlyoutOrder(raw)
    local out  = {}
    local seen = {}
    if type(raw) ~= "table" then return out end

    local count = 0
    for i = 1, table.getn(raw) do
        local spellId = raw[i]
        if type(spellId) == "number"
        and spellId > 0
        and spellId == math.floor(spellId)
        and not seen[spellId] then
            count = count + 1
            out[count] = spellId
            seen[spellId] = true
        end
    end
    return out
end

local function sanitizeFlyoutFilter(raw)
    local out = {}
    if type(raw) ~= "table" then return out end

    for key, value in pairs(raw) do
        local spellId = nil
        if type(key) == "number" and value then
            spellId = key
        elseif type(value) == "number" then
            spellId = value
        end
        if type(spellId) == "number"
        and spellId > 0
        and spellId == math.floor(spellId) then
            out[spellId] = true
        end
    end
    return out
end

local function buildDefaultElementConfig()
    return {
        centerX       = nil,
        centerY       = nil,
        borderColorR  = COLOR_MAX,
        borderColorG  = COLOR_MAX,
        borderColorB  = COLOR_MAX,
        elementColorR = COLOR_MAX,
        elementColorG = COLOR_MAX,
        elementColorB = COLOR_MAX,
        flyoutDir     = DIR_TOP,
        flyoutOrder   = {},
        flyoutFilter  = {},
    }
end

-- Constructs fresh per-element config tables with all current field defaults.
-- No shared sub-table references between element slots.
local function buildDefaultElementConfigs()
    local elements = {}
    for i = 1, MAX_ELEMENTS do
        elements[i] = buildDefaultElementConfig()
    end
    return elements
end

------------------------------------------------------------------------
-- Schema defaults
-- DEFAULTS is deep-copied on each use and treated as immutable.
-- Fields for future features arrive with their step.
------------------------------------------------------------------------

local DEFAULTS = {
    visible             = true,
    minimapAngle        = MINIMAP_ANGLE_DEFAULT,
    scale               = 1.0,
    locked              = true,
    clickThrough        = false,
    clickThroughMod     = MOD_SHIFT,
    flyoutMode          = MODE_FREE,
    flyoutMod           = MOD_SHIFT,
    showBorder          = true,
    tooltipsEnabled     = true,
    tooltipAnchorMode   = ANCHOR_MODE_FRAME,
    tooltipDirection    = DIR_RIGHT,
    tooltipOffsetX      = 10,
    tooltipOffsetY      = 0,
    snapAlign           = true,
    rangeFade           = true,
    rangeOffsetYards    = -1.3,
    pollInterval        = 0.3,
    timerShowMinutes    = false,
    expiryThresholdSecs = 5,
    expirySoundEnabled  = false,
    elements            = buildDefaultElementConfigs(),
    sets                = {},
    activeSetIndex      = ACTIVE_SET_NONE,
    setsCycleWrap       = false,
}

------------------------------------------------------------------------
-- Private sanitizers
------------------------------------------------------------------------

-- Builds one sanitized element entry from arbitrary raw input.
local function sanitizeElementConfig(src)
    local entry = buildDefaultElementConfig()
    if type(src) ~= "table" then return entry end

    if type(src.centerX) == "number" then entry.centerX = src.centerX end
    if type(src.centerY) == "number" then entry.centerY = src.centerY end
    entry.borderColorR  = sanitizeColorChannel(src.borderColorR)
    entry.borderColorG  = sanitizeColorChannel(src.borderColorG)
    entry.borderColorB  = sanitizeColorChannel(src.borderColorB)
    entry.elementColorR = sanitizeColorChannel(src.elementColorR)
    entry.elementColorG = sanitizeColorChannel(src.elementColorG)
    entry.elementColorB = sanitizeColorChannel(src.elementColorB)
    entry.flyoutDir     = sanitizeFlyoutDir(src.flyoutDir)
    entry.flyoutOrder   = sanitizeFlyoutOrder(src.flyoutOrder)
    entry.flyoutFilter  = sanitizeFlyoutFilter(src.flyoutFilter)
    return entry
end

-- Returns a sanitized elements table from raw input.
-- Always produces MAX_ELEMENTS full entries; position fields nil when unset.
local function sanitizeElements(raw)
    local out = {}
    local rawElements = type(raw) == "table" and raw or nil
    for el = 1, MAX_ELEMENTS do
        out[el] = sanitizeElementConfig(rawElements and rawElements[el] or nil)
    end
    return out
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function sanitizeProfileKey(key)
    if type(key) ~= "string" then return nil end
    local _, _, trimmed = string.find(key, "^%s*(.-)%s*$")
    if not trimmed or string.len(trimmed) == 0 then return nil end
    return trimmed
end

local function sanitizeSetRow(raw)
    if type(raw) ~= "table" then return nil end
    local row = {}
    for i = 1, MAX_ELEMENTS do
        local id = raw[i]
        if type(id) == "number" and id > 0 and id == math.floor(id) then
            row[i] = id
        end
    end
    return row
end

-- Returns a fully valid profile from arbitrarily corrupt input.
-- Only recognized fields are read from raw; unrecognized keys are ignored.
local function sanitizeProfile(raw)
    local config = deepCopy(DEFAULTS)
    if type(raw) ~= "table" then return config end

    if isBoolean(raw.visible)       then config.visible         = raw.visible end
    if isBoolean(raw.locked)        then config.locked          = raw.locked end
    if isBoolean(raw.clickThrough)  then config.clickThrough    = raw.clickThrough end
    if isBoolean(raw.snapAlign)     then config.snapAlign       = raw.snapAlign end
    config.minimapAngle        = sanitizeMinimapAngle(raw.minimapAngle)
    config.clickThroughMod     = sanitizeClickThroughMod(raw.clickThroughMod)
    config.flyoutMode          = sanitizeFlyoutMode(raw.flyoutMode)
    config.flyoutMod           = sanitizeFlyoutMod(raw.flyoutMod)
    if isBoolean(raw.tooltipsEnabled) then config.tooltipsEnabled = raw.tooltipsEnabled end
    config.tooltipAnchorMode   = sanitizeTooltipAnchorMode(raw.tooltipAnchorMode)
    config.tooltipDirection    = sanitizeTooltipDirection(raw.tooltipDirection)
    config.tooltipOffsetX      = sanitizeTooltipOffset(raw.tooltipOffsetX, DEFAULTS.tooltipOffsetX)
    config.tooltipOffsetY      = sanitizeTooltipOffset(raw.tooltipOffsetY, DEFAULTS.tooltipOffsetY)
    if type(raw.scale) == "number" then
        config.scale           = clamp(raw.scale, SCALE_MIN, SCALE_MAX)
    end
    if isBoolean(raw.showBorder) then config.showBorder         = raw.showBorder end
    if isBoolean(raw.rangeFade)  then config.rangeFade          = raw.rangeFade end
    config.rangeOffsetYards    = sanitizeRangeOffsetYards(raw.rangeOffsetYards, DEFAULTS.rangeOffsetYards)
    config.pollInterval        = sanitizePollInterval(raw.pollInterval, DEFAULTS.pollInterval)
    if isBoolean(raw.timerShowMinutes) then config.timerShowMinutes = raw.timerShowMinutes end
    config.expiryThresholdSecs = sanitizeExpiryThresholdSecs(raw.expiryThresholdSecs, DEFAULTS.expiryThresholdSecs)
    if isBoolean(raw.expirySoundEnabled) then config.expirySoundEnabled = raw.expirySoundEnabled end
    config.elements            = sanitizeElements(raw.elements)

    if isBoolean(raw.setsCycleWrap) then config.setsCycleWrap = raw.setsCycleWrap end
    if type(raw.sets) == "table" then
        local count = 0
        for i = 1, MAX_SETS do
            local row = type(raw.sets[i]) == "table" and sanitizeSetRow(raw.sets[i]) or nil
            if row then
                count = count + 1
                config.sets[count] = row
            end
        end
    end
    if type(raw.activeSetIndex) == "number" then
        local idx   = math.floor(raw.activeSetIndex)
        local count = table.getn(config.sets)
        config.activeSetIndex = (idx >= 1 and idx <= count) and idx or ACTIVE_SET_NONE
    end

    return config
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.STORE_SCHEMA_VERSION        = STORE_SCHEMA_VERSION
M.ACTIVE_SET_NONE             = ACTIVE_SET_NONE
M.SCALE_MIN                   = SCALE_MIN
M.SCALE_MAX                   = SCALE_MAX
M.POLL_MIN                    = POLL_MIN
M.POLL_MAX                    = POLL_MAX
M.RANGE_OFFSET_MIN            = RANGE_OFFSET_MIN
M.RANGE_OFFSET_MAX            = RANGE_OFFSET_MAX
M.EXPIRY_THRESHOLD_MIN        = EXPIRY_THRESHOLD_MIN
M.EXPIRY_THRESHOLD_MAX        = EXPIRY_THRESHOLD_MAX
M.TOOLTIP_OFFSET_MIN          = TOOLTIP_OFFSET_MIN
M.TOOLTIP_OFFSET_MAX          = TOOLTIP_OFFSET_MAX
M.FLYOUT_DIR_TOP              = DIR_TOP
M.FLYOUT_DIR_BOTTOM           = DIR_BOTTOM
M.FLYOUT_DIR_LEFT             = DIR_LEFT
M.FLYOUT_DIR_RIGHT            = DIR_RIGHT
M.MOD_NONE                    = MOD_NONE
M.MOD_CTRL                    = MOD_CTRL
M.MOD_ALT                     = MOD_ALT
M.MOD_SHIFT                   = MOD_SHIFT
M.FLYOUT_MODE_FREE            = MODE_FREE
M.FLYOUT_MODE_DYNAMIC         = MODE_DYNAMIC
M.FLYOUT_MODE_CLOSED          = MODE_CLOSED
M.TOOLTIP_DIR_UP              = DIR_UP
M.TOOLTIP_DIR_DOWN            = DIR_DOWN
M.TOOLTIP_DIR_LEFT            = DIR_LEFT
M.TOOLTIP_DIR_RIGHT           = DIR_RIGHT
M.TOOLTIP_ANCHOR_MODE_FRAME   = ANCHOR_MODE_FRAME
M.TOOLTIP_ANCHOR_MODE_CURSOR  = ANCHOR_MODE_CURSOR
M.DEFAULTS                    = DEFAULTS

M.clamp                       = clamp
M.isBoolean                   = isBoolean
M.sanitizeProfile             = sanitizeProfile
M.sanitizeMinimapAngle        = sanitizeMinimapAngle
M.sanitizeColorChannel        = sanitizeColorChannel
M.sanitizeClickThroughMod     = sanitizeClickThroughMod
M.sanitizeFlyoutMode          = sanitizeFlyoutMode
M.sanitizeFlyoutMod           = sanitizeFlyoutMod
M.sanitizeFlyoutDir           = sanitizeFlyoutDir
M.sanitizeFlyoutOrder         = sanitizeFlyoutOrder
M.sanitizeFlyoutFilter        = sanitizeFlyoutFilter
M.sanitizeTooltipAnchorMode   = sanitizeTooltipAnchorMode
M.sanitizeTooltipDirection    = sanitizeTooltipDirection
M.sanitizeTooltipOffset       = sanitizeTooltipOffset
M.sanitizeRangeOffsetYards    = sanitizeRangeOffsetYards
M.sanitizePollInterval        = sanitizePollInterval
M.sanitizeExpiryThresholdSecs = sanitizeExpiryThresholdSecs

M.MAX_ELEMENTS                = MAX_ELEMENTS
M.MAX_SETS                    = MAX_SETS
M.sanitizeSetRow              = sanitizeSetRow
M.sanitizeProfileKey          = sanitizeProfileKey
