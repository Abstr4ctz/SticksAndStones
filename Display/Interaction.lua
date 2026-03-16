-- SticksAndStones: Display/Interaction.lua
-- Input behavior support module for the Display pod.
-- Owns click, drag, hover, mouse-wheel, and modifier-capture handling for
-- button, peek, and flyout hotspot frames.
-- Exports interaction helpers and script wrappers on DisplayInternal.
-- Side effects: creates one hidden event frame for Nampower KEY_DOWN/KEY_UP.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = DisplayInternal

local CreateFrame      = CreateFrame
local IsAltKeyDown     = IsAltKeyDown
local IsControlKeyDown = IsControlKeyDown
local IsShiftKeyDown   = IsShiftKeyDown
local tonumber         = tonumber

local ACTION_TYPES = SNS.ACTION_TYPES

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local MODIFIER_STATE_READERS = {
    ctrl  = IsControlKeyDown,
    alt   = IsAltKeyDown,
    shift = IsShiftKeyDown,
}

local BUTTON_CLICK_ACTIONS = {
    LeftButton  = ACTION_TYPES.CAST_ELEMENT_BUTTON,
    RightButton = ACTION_TYPES.CHANGE_ELEMENT_BUTTON,
}

local PEEK_CLICK_ACTIONS = {
    LeftButton  = ACTION_TYPES.CAST_ELEMENT_PEEK,
    RightButton = ACTION_TYPES.CHANGE_ELEMENT_PEEK,
}

------------------------------------------------------------------------
-- Owned state
------------------------------------------------------------------------

M.modifierOverrideActive = false
M.flyoutModifierActive   = false
M.keyCaptureRegistered   = false
M.eventFrame             = nil

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function getClickThroughModifier()
    local mod = SNSConfig and SNSConfig.clickThroughMod
    if mod == "none" then return mod end
    if MODIFIER_STATE_READERS[mod] then return mod end
    return "ctrl"
end

local function getFlyoutMode()
    local mode = SNSConfig and SNSConfig.flyoutMode
    if mode == "dynamic" or mode == "closed" then return mode end
    return "free"
end

local function getFlyoutModifier()
    local mod = SNSConfig and SNSConfig.flyoutMod
    if MODIFIER_STATE_READERS[mod] then return mod end
    return "shift"
end

local function wantsClickThroughCapture()
    if type(SNSConfig) ~= "table" then return false end
    if not SNSConfig.locked then return false end
    if not SNSConfig.clickThrough then return false end
    return MODIFIER_STATE_READERS[getClickThroughModifier()] ~= nil
end

local function wantsFlyoutModifierCapture()
    if type(SNSConfig) ~= "table" then return false end
    if not SNSConfig.locked then return false end
    if getFlyoutMode() ~= "dynamic" then return false end
    return MODIFIER_STATE_READERS[getFlyoutModifier()] ~= nil
end

local function wantsModifierCapture()
    return wantsClickThroughCapture() or wantsFlyoutModifierCapture()
end

local function computeInputActive(overrideActive, flyoutActive)
    if type(SNSConfig) ~= "table" then return true end
    return (not SNSConfig.locked)
        or (not SNSConfig.clickThrough)
        or overrideActive
        or flyoutActive
end

local function isInputActive()
    return computeInputActive(M.modifierOverrideActive, M.flyoutModifierActive)
end

local function computeModifierOverrideState()
    if not wantsClickThroughCapture() then return false end

    local reader = MODIFIER_STATE_READERS[getClickThroughModifier()]
    if not reader then return false end
    return reader() and true or false
end

local function computeFlyoutModifierState()
    if not wantsFlyoutModifierCapture() then return false end

    local reader = MODIFIER_STATE_READERS[getFlyoutModifier()]
    if not reader then return false end
    return reader() and true or false
end

local function ensureEventFrame()
    if M.eventFrame then return M.eventFrame end

    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetScript("OnEvent", M.OnModifierKeyEventScript)
    M.eventFrame = frame
    return frame
end

local function setHotspotState(frame, active, allowWheel)
    if not frame then return end

    if active then
        frame:EnableMouse(true)
        if allowWheel then
            frame:EnableMouseWheel(true)
        end
        frame:Show()
        return
    end

    frame:Hide()
    frame:EnableMouse(false)
    if allowWheel then
        frame:EnableMouseWheel(false)
    end
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function onClick(element, button)
    local actionType = BUTTON_CLICK_ACTIONS[button]
    if not actionType then return end
    M.EmitElementAction(actionType, element)
end

local function onPeekClick(element, button)
    local actionType = PEEK_CLICK_ACTIONS[button]
    if not actionType then return end
    M.EmitElementAction(actionType, element)
end

local function onDragStart(element)
    if SNSConfig.locked then return end

    local btn = M.buttons and M.buttons[element]
    if not btn then return end
    btn:StartMoving()
end

local function onDragStop(element)
    local btn = M.buttons and M.buttons[element]
    if not btn then return end

    btn:StopMovingOrSizing()
    M.CommitDraggedButtonPosition(element)
end

local function applyFlyoutEntryHotspots(root, inputOn)
    if not root or not root.entries then return end

    local canShowEntries = inputOn and root:IsShown()
    local i
    for i = 1, table.getn(root.entries) do
        local entry = root.entries[i]
        setHotspotState(entry.inputFrame, canShowEntries and entry:IsShown(), false)
    end
end

local function applyButtonInteractionState(element)
    local btn = M.buttons and M.buttons[element]
    if not btn then return end

    local inputOn = isInputActive()
    if SNSConfig.locked then
        btn.inputFrame:RegisterForDrag()
        btn.editOverlay:Hide()
    else
        btn.inputFrame:RegisterForDrag("LeftButton")
        btn.editOverlay:Show()
    end

    btn:EnableMouse(false)
    btn:EnableMouseWheel(false)
    btn.peek:EnableMouse(false)

    setHotspotState(btn.inputFrame, inputOn, true)
    setHotspotState(btn.peek.inputFrame, inputOn and btn.peek:IsShown(), false)
    applyFlyoutEntryHotspots(btn.flyout, inputOn)
end

local function applyAllButtonInteractionState()
    if not M.buttons then return end

    local i
    for i = 1, SNS.MAX_TOTEM_SLOTS do
        applyButtonInteractionState(i)
    end
end

local function updateModifierEventCapture()
    local wants = wantsModifierCapture()
    if (not wants) and (not M.keyCaptureRegistered) then
        M.modifierOverrideActive = false
        M.flyoutModifierActive   = false
        return
    end

    local frame = ensureEventFrame()
    if wants and not M.keyCaptureRegistered then
        frame:RegisterEvent("KEY_DOWN")
        frame:RegisterEvent("KEY_UP")
        M.keyCaptureRegistered = true
    elseif (not wants) and M.keyCaptureRegistered then
        frame:UnregisterEvent("KEY_DOWN")
        frame:UnregisterEvent("KEY_UP")
        M.keyCaptureRegistered = false
    end

    M.modifierOverrideActive = computeModifierOverrideState()
    M.flyoutModifierActive   = computeFlyoutModifierState()
end

local function onModifierKeyEvent()
    local prevInputState   = isInputActive()
    local prevFlyoutState  = M.flyoutModifierActive
    local newOverrideState = computeModifierOverrideState()
    local newFlyoutState   = computeFlyoutModifierState()
    local newInputState    = computeInputActive(newOverrideState, newFlyoutState)
    local overrideChanged  = (newOverrideState ~= M.modifierOverrideActive)
    local flyoutChanged    = (newFlyoutState ~= M.flyoutModifierActive)

    if not overrideChanged and not flyoutChanged then return end

    M.modifierOverrideActive = newOverrideState
    M.flyoutModifierActive   = newFlyoutState
    M.HandleModifierStateChange(prevInputState, newInputState, prevFlyoutState, newFlyoutState)
end

local function onClickScript()
    onClick(this.element, arg1)
end

local function onPeekClickScript()
    onPeekClick(this.element, arg1)
end

local function onDragStartScript()
    onDragStart(this.element)
end

local function onDragStopScript()
    onDragStop(this.element)
end

local function onMouseWheelScript()
    local delta = tonumber(arg1)
    if not delta then return end
    if delta > 0 then
        M.EmitAction(ACTION_TYPES.CYCLE_SET_BACKWARD)
        return
    end
    M.EmitAction(ACTION_TYPES.CYCLE_SET_FORWARD)
end

local function onModifierKeyEventScript()
    onModifierKeyEvent()
end

local function onHotspotEnterScript()
    M.HandleHotspotEnter(this)
end

local function onHotspotLeaveScript()
    M.HandleHotspotLeave()
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.ApplyButtonInteractionState    = applyButtonInteractionState
M.ApplyAllButtonInteractionState = applyAllButtonInteractionState
M.UpdateModifierEventCapture     = updateModifierEventCapture
M.OnClickScript                  = onClickScript
M.OnPeekClickScript              = onPeekClickScript
M.OnDragStartScript              = onDragStartScript
M.OnDragStopScript               = onDragStopScript
M.OnMouseWheelScript             = onMouseWheelScript
M.OnModifierKeyEventScript       = onModifierKeyEventScript
M.OnHotspotEnterScript           = onHotspotEnterScript
M.OnHotspotLeaveScript           = onHotspotLeaveScript
