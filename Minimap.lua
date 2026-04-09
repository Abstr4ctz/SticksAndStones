-- SticksAndStones: Minimap.lua
-- Standalone minimap entry surface for button creation, tooltip state, and drag positioning.
-- Owns SNS.Minimap, the singleton minimap button frame, and minimap-local click and drag state.
-- Side effects: attaches SNS.Minimap when the root facade is available. No config writes.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local MINIMAP_FRAME = Minimap

if not SNS
or not App
or not App.SaveMinimapAngle
or not App.ToggleBarVisible
or not App.ToggleSettings
or not MINIMAP_FRAME then
    return
end

SNS.Minimap = SNS.Minimap or {}
local M = SNS.Minimap
local math_deg  = math.deg
local math_atan = math.atan
local math_rad  = math.rad
local math_cos  = math.cos
local math_sin  = math.sin

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local BUTTON_RADIUS      = 78
local BUTTON_SIZE        = 32
local ICON_SIZE          = 20
local BORDER_SIZE        = 54
local ICON_OFFSET_X      = 1
local TOOLTIP_TITLE      = "SticksAndStones"
local TOOLTIP_BAR_SHOWN  = "Totem bar: shown"
local TOOLTIP_BAR_HIDDEN = "Totem bar: hidden"

------------------------------------------------------------------------
-- Private state
------------------------------------------------------------------------

local button
local isLeftClickArmed
local didLeftDrag

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function getConfig()
    if type(SNSConfig) ~= "table" then return nil end
    return SNSConfig
end

local function computeAngle(dx, dy)
    if dx == 0 then
        if dy >= 0 then return 90 end
        return 270
    end

    local angle = math_deg(math_atan(dy / dx))
    if dx < 0 then
        angle = angle + 180
    end
    if angle < 0 then
        angle = angle + 360
    end
    return angle
end

local function getCursorAngle()
    if not button then return nil end

    local left = MINIMAP_FRAME:GetLeft()
    local bottom = MINIMAP_FRAME:GetBottom()
    local width = MINIMAP_FRAME:GetWidth()
    local height = MINIMAP_FRAME:GetHeight()
    if not left or not bottom or not width or not height then return nil end

    local scale = UIParent:GetScale()
    if not scale or scale == 0 then return nil end

    local cursorX, cursorY = GetCursorPosition()
    if not cursorX or not cursorY then return nil end

    cursorX = cursorX / scale
    cursorY = cursorY / scale

    local centerX = left + (width / 2)
    local centerY = bottom + (height / 2)
    local dx = cursorX - centerX
    local dy = cursorY - centerY
    if dx == 0 and dy == 0 then return nil end

    return computeAngle(dx, dy)
end

local function applyButtonPosition(angle)
    if not button or type(angle) ~= "number" then return end

    local radians = math_rad(angle)
    local x = math_cos(radians) * BUTTON_RADIUS
    local y = math_sin(radians) * BUTTON_RADIUS

    button:ClearAllPoints()
    button:SetPoint("CENTER", MINIMAP_FRAME, "CENTER", x, y)
end

local function updateButtonFromCursor()
    local angle = getCursorAngle()
    if angle == nil then return end
    applyButtonPosition(angle)
end

local function persistButtonAngle()
    local angle = getCursorAngle()
    if angle == nil then return end

    local savedAngle = App.SaveMinimapAngle(angle)
    if savedAngle == nil then return end
    applyButtonPosition(savedAngle)
end

local function getBarStateText()
    local config = getConfig()
    if config and config.visible then
        return TOOLTIP_BAR_SHOWN
    end
    return TOOLTIP_BAR_HIDDEN
end

local function showTooltip(frame)
    if not frame then return end

    GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(TOOLTIP_TITLE)
    GameTooltip:AddLine(getBarStateText(), 1, 1, 1)
    GameTooltip:AddLine("Left-click: Show/Hide bar", 1, 1, 1)
    GameTooltip:AddLine("Right-click: Toggle settings", 1, 1, 1)
    GameTooltip:AddLine("Drag: Move button", 1, 1, 1)
    GameTooltip:Show()
end

local function hideTooltip()
    GameTooltip:Hide()
end

local function isTooltipOwned()
    if not button or not GameTooltip then return false end
    if type(GameTooltip.IsOwned) ~= "function" then return false end
    return GameTooltip:IsOwned(button) and true or false
end

local function refreshOwnedTooltip()
    if not isTooltipOwned() then return end
    if not button or not button:IsShown() then
        hideTooltip()
        return
    end
    showTooltip(button)
end

local function applyVisibility()
    if not button then return end
    button:Show()
end

------------------------------------------------------------------------
-- Private handlers
------------------------------------------------------------------------

local function handleEnter(frame)
    showTooltip(frame)
end

local function handleLeave()
    hideTooltip()
end

local function handleMouseDown(mouseButton)
    if mouseButton ~= "LeftButton" then return end
    isLeftClickArmed = true
    didLeftDrag = false
end

local function handleDragStart(frame)
    didLeftDrag = true
    hideTooltip()
    frame:SetScript("OnUpdate", updateButtonFromCursor)
end

local function handleDragStop(frame)
    frame:SetScript("OnUpdate", nil)
    persistButtonAngle()
end

local function handleLeftMouseUp()
    local shouldToggle = isLeftClickArmed and not didLeftDrag
    isLeftClickArmed = nil
    didLeftDrag = nil
    if shouldToggle then
        App.ToggleBarVisible()
    end
end

local function handleRightMouseUp()
    App.ToggleSettings()
end

local MOUSE_UP_ROUTES = {
    LeftButton = handleLeftMouseUp,
    RightButton = handleRightMouseUp,
}

local function handleMouseUp(mouseButton)
    local handler = MOUSE_UP_ROUTES[mouseButton]
    if not handler then return end
    handler()
end

local function onEnterScript()
    handleEnter(this)
end

local function onLeaveScript()
    handleLeave()
end

local function onMouseDownScript()
    handleMouseDown(arg1)
end

local function onMouseUpScript()
    handleMouseUp(arg1)
end

local function onDragStartScript()
    handleDragStart(this)
end

local function onDragStopScript()
    handleDragStop(this)
end

------------------------------------------------------------------------
-- Private builders
------------------------------------------------------------------------

local function createButtonFrame()
    local frame = CreateFrame("Button", "SNSMinimapButtonFrame", MINIMAP_FRAME)
    frame:SetWidth(BUTTON_SIZE)
    frame:SetHeight(BUTTON_SIZE)
    frame:SetFrameStrata("MEDIUM")
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    return frame
end

local function createButtonVisuals(frame)
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetWidth(ICON_SIZE)
    background:SetHeight(ICON_SIZE)
    background:SetPoint("CENTER", frame, "CENTER", 0, 0)
    background:SetVertexColor(0, 0, 0)

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\Spell_Nature_EarthBindTotem")
    icon:SetWidth(ICON_SIZE)
    icon:SetHeight(ICON_SIZE)
    icon:SetPoint("CENTER", frame, "CENTER", ICON_OFFSET_X, 0)

    local border = frame:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(BORDER_SIZE)
    border:SetHeight(BORDER_SIZE)
    border:SetPoint("TOPLEFT", frame, "TOPLEFT")
end

local function wireButtonScripts(frame)
    frame:SetScript("OnEnter", onEnterScript)
    frame:SetScript("OnLeave", onLeaveScript)
    frame:SetScript("OnMouseDown", onMouseDownScript)
    frame:SetScript("OnMouseUp", onMouseUpScript)
    frame:SetScript("OnDragStart", onDragStartScript)
    frame:SetScript("OnDragStop", onDragStopScript)
end

local function createButton()
    if button then return button end

    local frame = createButtonFrame()
    createButtonVisuals(frame)
    wireButtonScripts(frame)
    button = frame
    return button
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function ApplyConfig()
    local config = getConfig()
    if not button or not config then return end

    applyButtonPosition(config.minimapAngle)
    applyVisibility()

    refreshOwnedTooltip()
end

local function Initialize()
    createButton()
    ApplyConfig()
end

------------------------------------------------------------------------
-- Public exports
------------------------------------------------------------------------

M.Initialize = Initialize
M.ApplyConfig = ApplyConfig
