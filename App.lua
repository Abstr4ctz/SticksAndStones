-- SticksAndStones: App.lua
-- Root wiring module for addon bootstrap, root entry surfaces, and callback routing.
-- Owns App (public facade), SNS (root namespace), and addon-wide root contracts.
-- Side effects: probes addon features, may publish App when runtime is enabled,
-- registers slash commands and PLAYER_LOGIN.

------------------------------------------------------------------------
-- Public facade
------------------------------------------------------------------------

local M = {}

------------------------------------------------------------------------
-- Root namespace
------------------------------------------------------------------------

SNS = {
    EARTH           = 1,
    FIRE            = 2,
    WATER           = 3,
    AIR             = 4,
    MAX_TOTEM_SLOTS = 4,
    ELEMENT_NAMES   = { "Earth", "Fire", "Water", "Air" },
    ACTION_TYPES    = {
        CAST_ELEMENT_BUTTON   = "CAST_ELEMENT_BUTTON",
        CHANGE_ELEMENT_BUTTON = "CHANGE_ELEMENT_BUTTON",
        CAST_ELEMENT_PEEK     = "CAST_ELEMENT_PEEK",
        CHANGE_ELEMENT_PEEK   = "CHANGE_ELEMENT_PEEK",
        CAST_ELEMENT_FLYOUT   = "CAST_ELEMENT_FLYOUT",
        CHANGE_ELEMENT_FLYOUT = "CHANGE_ELEMENT_FLYOUT",
        SAVE_ELEMENT_POSITION = "SAVE_ELEMENT_POSITION",
        CYCLE_SET_FORWARD     = "CYCLE_SET_FORWARD",
        CYCLE_SET_BACKWARD    = "CYCLE_SET_BACKWARD",
    },
}

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local ACTION_TYPES   = SNS.ACTION_TYPES
local ACTION_ROUTES  = {}
local ACTION_CHECKS  = {}
local SLASH_ROUTES   = {}
local HELP_LINES = {
    "SticksAndStones commands:",
    "  /sns            - toggle settings",
    "  /sns help       - show this help",
    "  /sns smart      - smart cast chosen totems",
    "  /sns force      - cast all chosen totems",
}

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function hasNampower()
    local ok, value = pcall(function() return GetNampowerVersion end)
    return ok and value ~= nil
end

local function hasUnitXP()
    local ok = pcall(UnitXP, "nop", "nop")
    return ok
end

local function parseSlashArgs(msg)
    local _, _, word, rest = string.find(msg or "", "^%s*(%S*)%s*(.*)$")
    word = string.lower(word or "")
    return word, rest or ""
end

local function printSlashHelp()
    local lineCount = table.getn(HELP_LINES)
    local i
    for i = 1, lineCount do
        DEFAULT_CHAT_FRAME:AddMessage(HELP_LINES[i])
    end
end

local function isIntegerValue(value)
    return type(value) == "number" and value == math.floor(value)
end

local function isElementIndex(value)
    return isIntegerValue(value)
       and value >= 1
       and value <= SNS.MAX_TOTEM_SLOTS
end

local function isPositiveInteger(value)
    return isIntegerValue(value) and value > 0
end

local function isNumberValue(value)
    return type(value) == "number"
end

local function isValidNoPayloadAction(action)
    return type(action) == "table"
end

local function isValidElementAction(action)
    return type(action) == "table" and isElementIndex(action.element)
end

local function isValidSpellAction(action)
    return type(action) == "table" and isPositiveInteger(action.spellId)
end

local function isValidElementSpellAction(action)
    return type(action) == "table"
       and isElementIndex(action.element)
       and isPositiveInteger(action.spellId)
end

local function isValidPositionAction(action)
    return type(action) == "table"
       and isElementIndex(action.element)
       and isNumberValue(action.x)
       and isNumberValue(action.y)
end

local function validateAction(action)
    if type(action) ~= "table" then return nil end

    local actionType = action.type
    if type(actionType) ~= "string" then return nil end

    local check = ACTION_CHECKS[actionType]
    if not check or not check(action) then return nil end

    return actionType
end

local function initializeMinimap()
    if SNS.Minimap and SNS.Minimap.Initialize then
        SNS.Minimap.Initialize()
    end
end

------------------------------------------------------------------------
-- Private handlers
------------------------------------------------------------------------

local function routeCastElementButton(action)
    Totems.CastElementButton(action.element)
end

local function routeChangeElementButton(action)
    Totems.ChangeElementButton(action.element)
end

local function routeCastElementPeek(action)
    Totems.CastElementPeek(action.element)
end

local function routeChangeElementPeek(action)
    Totems.ChangeElementPeek(action.element)
end

local function routeCastElementFlyout(action)
    Totems.CastFlyout(action.spellId)
end

local function routeChangeElementFlyout(action)
    Totems.SetChosenFromFlyout(action.element, action.spellId)
end

local function routeSaveElementPosition(action)
    Settings.SaveElementAnchor(action.element, action.x, action.y)
end

local function routeCycleSetForward()
    Settings.CycleSetForward()
end

local function routeCycleSetBackward()
    Settings.CycleSetBackward()
end

local function handleUserAction(action)
    local actionType = validateAction(action)
    if not actionType then return end

    local handler = ACTION_ROUTES[actionType]
    if handler then
        handler(action)
    end
end

local function handleSettingsSlash()
    Settings.ToggleUI()
end

local function handleSmartSlash()
    Totems.CastSmart()
end

local function handleForceSlash()
    Totems.CastForce()
end

local function handleSlash(msg)
    local word, rest = parseSlashArgs(msg)
    local handler = SLASH_ROUTES[word]
    if not handler then
        printSlashHelp()
        return
    end
    handler(rest)
end

local function handleTotemRender(snapshot)
    Display.Render(snapshot)
end

local function handleTotemCatalogChanged(catalog)
    Display.SetCatalog(catalog)
end

local function handleTotemLifecycleAlert(element, guid)
    Display.PlayLifecycleAlert(element, guid)
end

local function handleSettingsConfigChanged()
    Totems.ApplyConfig()
    Display.ApplyConfig()
    if SNS.Minimap and SNS.Minimap.ApplyConfig then
        SNS.Minimap.ApplyConfig()
    end
end

local function handleSettingsFlyoutConfigChanged()
    Display.ApplyFlyoutConfig()
end

local function wireCallbacks()
    Totems.OnStateChanged    = handleTotemRender
    Totems.OnVisualRefresh   = handleTotemRender
    Totems.OnCatalogChanged  = handleTotemCatalogChanged
    Totems.OnLifecycleAlert  = handleTotemLifecycleAlert
    Display.OnUserAction     = handleUserAction
    Settings.OnConfigChanged = handleSettingsConfigChanged
    Settings.OnFlyoutConfigChanged = handleSettingsFlyoutConfigChanged
end

local function handlePlayerLogin()
    Settings.Initialize()
    Totems.Initialize()
    Display.Initialize(Totems.GetCatalog(), Totems.States)
    initializeMinimap()
    wireCallbacks()
    Totems.SetPollingEnabled(true)
    Display.Render(Totems.GetSnapshot())
    DEFAULT_CHAT_FRAME:AddMessage("SticksAndStones loaded.")
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function BindCastElement(element)
    if not isElementIndex(element) then return end
    Totems.CastElementButton(element)
end

local function BindCastSmart()
    Totems.CastSmart()
end

local function BindCastForce()
    Totems.CastForce()
end

local function SaveMinimapAngle(angle)
    if not isNumberValue(angle) then return nil end
    return Settings.SaveMinimapAngle(angle)
end

local function ToggleBarVisible()
    return Settings.ToggleBarVisible()
end

local function ToggleSettings()
    return Settings.ToggleUI()
end

local function GetChosenSnapshot()
    return Totems.GetChosenSnapshot()
end

local function GetCatalog()
    return Totems.GetCatalog()
end

M.BindCastElement       = BindCastElement
M.BindCastSmart         = BindCastSmart
M.BindCastForce         = BindCastForce
M.SaveMinimapAngle      = SaveMinimapAngle
M.ToggleBarVisible      = ToggleBarVisible
M.ToggleSettings        = ToggleSettings
M.GetChosenSnapshot     = GetChosenSnapshot
M.GetCatalog            = GetCatalog

------------------------------------------------------------------------
-- Public exports
------------------------------------------------------------------------

App = M

------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------

SNS.features = {
    hasNampower = hasNampower(),
    hasUnitXP   = hasUnitXP(),
}

local _, playerClass = UnitClass("player")
if playerClass ~= "SHAMAN" then
    App = nil
    return
end

if not SNS.features.hasNampower then
    App = nil
    DEFAULT_CHAT_FRAME:AddMessage("|cffff6600SticksAndStones:|r Nampower is required but not loaded. Addon disabled.")
    return
end

ACTION_CHECKS[ACTION_TYPES.CAST_ELEMENT_BUTTON]   = isValidElementAction
ACTION_CHECKS[ACTION_TYPES.CHANGE_ELEMENT_BUTTON] = isValidElementAction
ACTION_CHECKS[ACTION_TYPES.CAST_ELEMENT_PEEK]     = isValidElementAction
ACTION_CHECKS[ACTION_TYPES.CHANGE_ELEMENT_PEEK]   = isValidElementAction
ACTION_CHECKS[ACTION_TYPES.CAST_ELEMENT_FLYOUT]   = isValidSpellAction
ACTION_CHECKS[ACTION_TYPES.CHANGE_ELEMENT_FLYOUT] = isValidElementSpellAction
ACTION_CHECKS[ACTION_TYPES.SAVE_ELEMENT_POSITION] = isValidPositionAction
ACTION_CHECKS[ACTION_TYPES.CYCLE_SET_FORWARD]     = isValidNoPayloadAction
ACTION_CHECKS[ACTION_TYPES.CYCLE_SET_BACKWARD]    = isValidNoPayloadAction

ACTION_ROUTES[ACTION_TYPES.CAST_ELEMENT_BUTTON]   = routeCastElementButton
ACTION_ROUTES[ACTION_TYPES.CHANGE_ELEMENT_BUTTON] = routeChangeElementButton
ACTION_ROUTES[ACTION_TYPES.CAST_ELEMENT_PEEK]     = routeCastElementPeek
ACTION_ROUTES[ACTION_TYPES.CHANGE_ELEMENT_PEEK]   = routeChangeElementPeek
ACTION_ROUTES[ACTION_TYPES.CAST_ELEMENT_FLYOUT]   = routeCastElementFlyout
ACTION_ROUTES[ACTION_TYPES.CHANGE_ELEMENT_FLYOUT] = routeChangeElementFlyout
ACTION_ROUTES[ACTION_TYPES.SAVE_ELEMENT_POSITION] = routeSaveElementPosition
ACTION_ROUTES[ACTION_TYPES.CYCLE_SET_FORWARD]     = routeCycleSetForward
ACTION_ROUTES[ACTION_TYPES.CYCLE_SET_BACKWARD]    = routeCycleSetBackward

SLASH_ROUTES[""]        = handleSettingsSlash
SLASH_ROUTES["help"]    = printSlashHelp
SLASH_ROUTES["smart"]   = handleSmartSlash
SLASH_ROUTES["force"]   = handleForceSlash

BINDING_HEADER_STICKSANDSTONESHEADER = "Sticks and Stones"
BINDING_NAME_SNS_CAST_EARTH          = "Cast Earth Totem"
BINDING_NAME_SNS_CAST_FIRE           = "Cast Fire Totem"
BINDING_NAME_SNS_CAST_WATER          = "Cast Water Totem"
BINDING_NAME_SNS_CAST_AIR            = "Cast Air Totem"
BINDING_NAME_SNS_CAST_SMART          = "Smart Cast Set"
BINDING_NAME_SNS_CAST_FORCE          = "Force Cast Set"

SLASH_SNS1 = "/sns"
SLASH_SNS2 = "/sticksandstones"
SlashCmdList["SNS"] = handleSlash

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", handlePlayerLogin)
