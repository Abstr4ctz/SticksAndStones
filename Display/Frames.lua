-- SticksAndStones: Display/Frames.lua
-- Frame construction support module for the Display pod.
-- Owns button, peek, flyout-root, and flyout-entry frame construction plus
-- saved-position restore and magnetic snap geometry helpers.
-- Exports frame-building and geometry helpers on DisplayInternal.
-- Side effects: creates WoW frames, textures, and fontstrings; reads
-- screen geometry; registers click and drag capability on hotspot frames.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = DisplayInternal

local CreateFrame = CreateFrame
local getglobal   = getglobal

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local SNAP_THRESHOLD = 15

local PEEK_ANCHORS = {
    top    = { point = "BOTTOM", relPoint = "TOP",    x =  0, y =  1 },
    bottom = { point = "TOP",    relPoint = "BOTTOM", x =  0, y = -1 },
    left   = { point = "RIGHT",  relPoint = "LEFT",   x = -1, y =  0 },
    right  = { point = "LEFT",   relPoint = "RIGHT",  x =  1, y =  0 },
}

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function getSafeEffectiveScale(frame)
    local scale = frame and frame:GetEffectiveScale() or nil
    if type(scale) ~= "number" or scale <= 0 then
        return 1
    end
    return scale
end

local function getParentEffectiveScale(frame)
    local parent = frame and frame:GetParent() or nil
    if not parent then
        return 1
    end
    return getSafeEffectiveScale(parent)
end

local function framePointToParent(frame, x, y)
    -- Saved anchors live in UIParent space; live frame APIs use frame space.
    local factor = getSafeEffectiveScale(frame) / getParentEffectiveScale(frame)
    return x * factor, y * factor
end

local function parentPointToFrame(frame, x, y)
    local factor = getParentEffectiveScale(frame) / getSafeEffectiveScale(frame)
    return x * factor, y * factor
end

local function getLayoutParentSize()
    local width = UIParent and UIParent:GetWidth() or nil
    local height = UIParent and UIParent:GetHeight() or nil

    if type(width) ~= "number" or width <= 0 then
        width = GetScreenWidth()
    end
    if type(height) ~= "number" or height <= 0 then
        height = GetScreenHeight()
    end

    return width, height
end

local function createInputFrame(parent, enableWheel)
    local input = CreateFrame("Button", nil, parent)
    input:SetAllPoints(parent)
    input:SetFrameStrata(parent:GetFrameStrata())
    input:SetFrameLevel(parent:GetFrameLevel() + 5)
    input:EnableMouse(false)
    input:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    if enableWheel then
        input:EnableMouseWheel(false)
    end
    input:Hide()
    return input
end

local function getCooldownLayout()
    local layout = M.COOLDOWN_LAYOUT
    if type(layout) ~= "table" then return nil end
    return layout
end

local function createCooldownRoot(parent)
    local root = CreateFrame("Frame", nil, parent)
    root:SetAllPoints(parent)
    root:SetFrameStrata(parent:GetFrameStrata())
    root:SetFrameLevel(parent:GetFrameLevel() + 1)
    return root
end

local function createCooldownModelAnchor(parent)
    local anchor = CreateFrame("Frame", nil, parent)
    anchor:SetAllPoints(parent)
    anchor:SetFrameStrata(parent:GetFrameStrata())
    anchor:SetFrameLevel(parent:GetFrameLevel())
    return anchor
end

local function createCooldownTextAnchor(parent)
    local anchor = CreateFrame("Frame", nil, parent)
    anchor:SetFrameStrata(parent:GetFrameStrata())
    anchor:SetFrameLevel(parent:GetFrameLevel() + 1)
    return anchor
end

local function createCooldownFrame(parent)
    local cooldown     = CreateFrame("Model", nil, parent, "CooldownFrameTemplate")
    cooldown:SetAllPoints(parent)
    cooldown.noCooldownCount = true
    cooldown.noOmniCC        = true
    cooldown:Hide()
    return cooldown
end

local function createCooldownText(parent)
    local text = parent:CreateFontString(nil, "OVERLAY")
    text:SetJustifyH("CENTER")
    text:SetJustifyV("MIDDLE")
    text:Hide()
    return text
end

local function createCooldownWidgets(parent)
    local root        = createCooldownRoot(parent)
    local modelAnchor = createCooldownModelAnchor(root)
    local textAnchor  = createCooldownTextAnchor(root)
    local cooldown    = createCooldownFrame(modelAnchor)
    local text        = createCooldownText(textAnchor)
    return root, modelAnchor, textAnchor, cooldown, text
end

local function applyCooldownLayout(frame)
    if not frame or not frame.cooldownRoot then return end

    local root        = frame.cooldownRoot
    local modelAnchor = frame.cooldownModelAnchor
    local textAnchor  = frame.cooldownTextAnchor
    local cooldown    = frame.cooldown
    local text        = frame.cooldownText
    local layout      = getCooldownLayout()
    if not modelAnchor or not textAnchor or not cooldown or not text or not layout then return end

    root:ClearAllPoints()
    root:SetAllPoints(frame)
    root:SetFrameStrata(frame:GetFrameStrata())
    root:SetFrameLevel(frame:GetFrameLevel() + 1)

    modelAnchor:ClearAllPoints()
    modelAnchor:SetPoint("TOPLEFT",     root, "TOPLEFT",     layout.modelOffsetX or 0,   layout.modelOffsetY or 0)
    modelAnchor:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -(layout.modelOffsetX or 0), -(layout.modelOffsetY or 0))
    modelAnchor:SetFrameStrata(root:GetFrameStrata())
    modelAnchor:SetFrameLevel(root:GetFrameLevel())

    textAnchor:ClearAllPoints()
    textAnchor:SetPoint("TOPLEFT",     root, "TOPLEFT",     layout.textOffsetX or 0,   layout.textOffsetY or 0)
    textAnchor:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -(layout.textOffsetX or 0), -(layout.textOffsetY or 0))
    textAnchor:SetFrameStrata(root:GetFrameStrata())
    textAnchor:SetFrameLevel(root:GetFrameLevel() + 2)

    cooldown:ClearAllPoints()
    cooldown:SetAllPoints(modelAnchor)
    cooldown:SetFrameStrata(modelAnchor:GetFrameStrata())
    cooldown:SetFrameLevel(modelAnchor:GetFrameLevel() + 1)
    local targetSize = frame:GetWidth()
    if type(targetSize) ~= "number" or targetSize <= 0 then
        targetSize = 36
    end
    cooldown:SetScale(targetSize / 36)

    text:ClearAllPoints()
    text:SetPoint("TOPLEFT",     textAnchor, "TOPLEFT",     0, 0)
    text:SetPoint("BOTTOMRIGHT", textAnchor, "BOTTOMRIGHT", 0, 0)
    text:SetShadowColor(0, 0, 0, 1)
    text:SetShadowOffset(layout.textShadowX or 0, layout.textShadowY or 0)

    local fontObject = layout.textFontObject and getglobal(layout.textFontObject) or nil
    if fontObject then
        text:SetFontObject(fontObject)
    end
end

local function applyBasicIconChrome(frame, frameSize, showBorder)
    local border     = M.ACTIVE_BORDER
    local borderPath = border.path
    local offset     = border.offset
    local cropInset  = M.ICON_CROP_INSET

    if showBorder then
        frame.icon:SetTexCoord(0, 1, 0, 1)
        frame.border:SetTexture(borderPath)
        frame.border:ClearAllPoints()
        frame.border:SetPoint("TOPLEFT",     frame, "TOPLEFT",     -offset,  offset)
        frame.border:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT",  offset, -offset)
        frame.border:Show()
        frame:SetHitRectInsets(-offset, -offset, -offset, -offset)
        if frame.inputFrame then
            frame.inputFrame:SetHitRectInsets(-offset, -offset, -offset, -offset)
        end

        local drawW = frameSize - (M.PILL_INSET_X * 2)
        if drawW < 1 then drawW = 1 end
        frame.tickDrawW = drawW
        return
    end

    frame.icon:SetTexCoord(cropInset, 1 - cropInset, cropInset, 1 - cropInset)
    frame.border:Hide()
    frame:SetHitRectInsets(0, 0, 0, 0)
    if frame.inputFrame then
        frame.inputFrame:SetHitRectInsets(0, 0, 0, 0)
    end
    frame.tickDrawW = frameSize
end

local function applyFlyoutEntryChrome(frame, frameSize, showBorder)
    applyBasicIconChrome(frame, frameSize, showBorder)
    applyCooldownLayout(frame)

    if showBorder then return end

    frame:SetHitRectInsets(-1, -1, -1, -1)
    if frame.inputFrame then
        frame.inputFrame:SetHitRectInsets(-1, -1, -1, -1)
    end
end

local function pickSnap(delta, bestDist, bestOffset)
    local dist = math.abs(delta)
    if dist < bestDist then
        return dist, delta
    end
    return bestDist, bestOffset
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function createButton(element)
    local btn = CreateFrame("Button", nil, UIParent)
    btn:SetWidth(M.BUTTON_SIZE)
    btn:SetHeight(M.BUTTON_SIZE)
    btn:SetFrameStrata("MEDIUM")
    btn:SetMovable(true)
    btn:SetClampedToScreen(true)
    btn:EnableMouse(false)

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetAllPoints(btn)

    local dimOverlay = btn:CreateTexture(nil, "ARTWORK")
    dimOverlay:SetAllPoints(btn)
    dimOverlay:SetTexture(0, 0, 0, 1)
    dimOverlay:SetAlpha(0)

    local border = btn:CreateTexture(nil, "ARTWORK")
    border:SetVertexColor(1, 1, 1)

    local editOverlay = btn:CreateTexture(nil, "OVERLAY")
    editOverlay:SetAllPoints(btn)
    editOverlay:SetTexture(0.15, 0.80, 0.25, M.EDIT_OVERLAY_ALPHA)
    editOverlay:Hide()

    local timerPill = btn:CreateTexture(nil, "OVERLAY")
    timerPill:SetTexture(0, 0, 0, 1)
    timerPill:SetAlpha(M.TIMER_PILL_ALPHA)
    timerPill:Hide()

    local tickBarBg = btn:CreateTexture(nil, "ARTWORK")
    tickBarBg:SetTexture(0, 0, 0, 1)
    tickBarBg:SetAlpha(M.TICK_BAR_BG_ALPHA)
    tickBarBg:Hide()

    local tickBarFill = btn:CreateTexture(nil, "OVERLAY")
    tickBarFill:SetTexture(1, 1, 1, 1)
    tickBarFill:SetBlendMode("ADD")
    tickBarFill:SetAlpha(M.TICK_BAR_FILL_ALPHA)
    tickBarFill:Hide()

    local timer = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timer:SetJustifyH("CENTER")
    timer:SetJustifyV("MIDDLE")
    timer:SetShadowOffset(0, 0)
    timer:Hide()

    local inputFrame   = createInputFrame(btn, true)
    local cooldownRoot, cooldownModelAnchor, cooldownTextAnchor, cooldown, cooldownText = createCooldownWidgets(btn)

    btn.element             = element
    btn.icon                = icon
    btn.cooldownRoot        = cooldownRoot
    btn.cooldownModelAnchor = cooldownModelAnchor
    btn.cooldownTextAnchor  = cooldownTextAnchor
    btn.cooldownLayoutKey   = "button"
    btn.cooldown            = cooldown
    btn.cooldownText        = cooldownText
    btn.dimOverlay          = dimOverlay
    btn.border              = border
    btn.editOverlay         = editOverlay
    btn.timerPill           = timerPill
    btn.tickBarBg           = tickBarBg
    btn.tickBarFill         = tickBarFill
    btn.timer               = timer
    btn.tickDrawW           = 0
    btn.inputFrame          = inputFrame
    btn.peek                = nil

    inputFrame.element      = element
    return btn
end

local function createPeekFrame(btn)
    local peek = CreateFrame("Button", nil, UIParent)
    peek:SetWidth(M.PEEK_SIZE)
    peek:SetHeight(M.PEEK_SIZE)
    peek:SetFrameStrata("MEDIUM")
    peek:EnableMouse(false)

    local icon = peek:CreateTexture(nil, "BACKGROUND")
    icon:SetAllPoints(peek)

    local dimOverlay = peek:CreateTexture(nil, "ARTWORK")
    dimOverlay:SetAllPoints(peek)
    dimOverlay:SetTexture(0, 0, 0, 1)
    dimOverlay:SetAlpha(0)

    local border = peek:CreateTexture(nil, "ARTWORK")
    border:SetVertexColor(1, 1, 1)

    local timerPill = peek:CreateTexture(nil, "OVERLAY")
    timerPill:SetTexture(0, 0, 0, 1)
    timerPill:SetAlpha(M.TIMER_PILL_ALPHA)
    timerPill:Hide()

    local tickBarBg = peek:CreateTexture(nil, "ARTWORK")
    tickBarBg:SetTexture(0, 0, 0, 1)
    tickBarBg:SetAlpha(M.TICK_BAR_BG_ALPHA)
    tickBarBg:Hide()

    local tickBarFill = peek:CreateTexture(nil, "OVERLAY")
    tickBarFill:SetTexture(1, 1, 1, 1)
    tickBarFill:SetBlendMode("ADD")
    tickBarFill:SetAlpha(M.TICK_BAR_FILL_ALPHA)
    tickBarFill:Hide()

    local timer = peek:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timer:SetJustifyH("CENTER")
    timer:SetJustifyV("MIDDLE")
    timer:SetShadowOffset(0, 0)
    timer:Hide()

    local inputFrame = createInputFrame(peek, false)
    local cooldownRoot, cooldownModelAnchor, cooldownTextAnchor, cooldown, cooldownText = createCooldownWidgets(peek)

    peek.element             = btn.element
    peek.icon                = icon
    peek.cooldownRoot        = cooldownRoot
    peek.cooldownModelAnchor = cooldownModelAnchor
    peek.cooldownTextAnchor  = cooldownTextAnchor
    peek.cooldownLayoutKey   = "peek"
    peek.cooldown            = cooldown
    peek.cooldownText        = cooldownText
    peek.dimOverlay          = dimOverlay
    peek.border              = border
    peek.timerPill           = timerPill
    peek.tickBarBg           = tickBarBg
    peek.tickBarFill         = tickBarFill
    peek.timer               = timer
    peek.tickDrawW           = 0
    peek.inputFrame          = inputFrame

    inputFrame.element       = btn.element

    peek:Hide()
    btn.peek = peek
end

local function createFlyoutFrame(btn)
    local root = CreateFrame("Frame", nil, UIParent)
    root:SetWidth(1)
    root:SetHeight(1)
    root:SetFrameStrata(btn:GetFrameStrata())
    root:SetFrameLevel(btn:GetFrameLevel() + 10)
    root:SetScale(M.GetScale())
    root.entries      = {}
    root.visibleCount = 0
    root.element      = btn.element
    root:Hide()
    btn.flyout = root
    return root
end

local function createFlyoutEntry(root, index)
    local entry = CreateFrame("Button", nil, root)
    entry:SetWidth(M.FLYOUT_SIZE)
    entry:SetHeight(M.FLYOUT_SIZE)
    entry:SetFrameStrata(root:GetFrameStrata())
    entry:SetFrameLevel(root:GetFrameLevel() + index)
    entry:EnableMouse(false)

    local icon = entry:CreateTexture(nil, "BACKGROUND")
    icon:SetAllPoints(entry)

    local dimOverlay = entry:CreateTexture(nil, "ARTWORK")
    dimOverlay:SetAllPoints(entry)
    dimOverlay:SetTexture(0, 0, 0, 1)
    dimOverlay:SetAlpha(0)
    dimOverlay:Hide()

    local border = entry:CreateTexture(nil, "ARTWORK")
    border:SetVertexColor(1, 1, 1)

    local inputFrame   = createInputFrame(entry, false)
    local cooldownRoot, cooldownModelAnchor, cooldownTextAnchor, cooldown, cooldownText = createCooldownWidgets(entry)

    entry.element             = root.element
    entry.entryIndex          = index
    entry.spellId             = nil
    entry.icon                = icon
    entry.cooldownRoot        = cooldownRoot
    entry.cooldownModelAnchor = cooldownModelAnchor
    entry.cooldownTextAnchor  = cooldownTextAnchor
    entry.cooldownLayoutKey   = "flyout"
    entry.cooldown            = cooldown
    entry.cooldownText        = cooldownText
    entry.dimOverlay          = dimOverlay
    entry.border              = border
    entry.inputFrame          = inputFrame
    entry.tickDrawW           = M.FLYOUT_SIZE

    inputFrame.element        = root.element
    inputFrame.entryIndex     = index

    entry:Hide()
    return entry
end

local function ensureFlyoutEntry(root, index)
    local entry = root.entries[index]
    if entry then
        return entry, nil
    end

    entry = createFlyoutEntry(root, index)
    root.entries[index] = entry
    return entry, true
end

local function anchorPeek(btn)
    local peek = btn.peek
    if not peek then return end

    local cfg    = M.GetElementConfig and M.GetElementConfig(btn.element) or nil
    local dir    = cfg and cfg.flyoutDir or "top"
    local anchor = PEEK_ANCHORS[dir]               or PEEK_ANCHORS.top
    local gap    = M.PEEK_ANCHOR_GAP

    peek:ClearAllPoints()
    peek:SetPoint(anchor.point, btn, anchor.relPoint, anchor.x * gap, anchor.y * gap)
end

local function applyIconChrome(frame, frameSize, showBorder)
    local isButton = (frameSize == M.BUTTON_SIZE)
    applyBasicIconChrome(frame, frameSize, showBorder)

    local insetX = showBorder and M.PILL_INSET_X or 0
    local insetY = showBorder and M.PILL_INSET_Y or 0

    local pillH = isButton and M.BUTTON_TIMER_PILL_HEIGHT or M.PEEK_TIMER_PILL_HEIGHT
    frame.timerPill:ClearAllPoints()
    frame.timerPill:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",   insetX,  insetY)
    frame.timerPill:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -insetX,  insetY)
    frame.timerPill:SetHeight(pillH)

    local tickH = isButton and M.BUTTON_TICK_BAR_HEIGHT or M.PEEK_TICK_BAR_HEIGHT
    frame.tickBarBg:ClearAllPoints()
    frame.tickBarBg:SetPoint("BOTTOMLEFT",  frame.timerPill, "TOPLEFT",  0, 0)
    frame.tickBarBg:SetPoint("BOTTOMRIGHT", frame.timerPill, "TOPRIGHT", 0, 0)
    frame.tickBarBg:SetHeight(tickH)

    frame.tickBarFill:ClearAllPoints()
    frame.tickBarFill:SetPoint("TOPLEFT",    frame.tickBarBg, "TOPLEFT",    0, 0)
    frame.tickBarFill:SetPoint("BOTTOMLEFT", frame.tickBarBg, "BOTTOMLEFT", 0, 0)
    frame.tickBarFill:SetWidth(0)

    if showBorder then
        local drawW = frameSize - (M.PILL_INSET_X * 2)
        if drawW < 1 then drawW = 1 end
        frame.tickDrawW = drawW
    else
        frame.tickDrawW = frameSize
    end

    local textOffY = isButton and M.BUTTON_TIMER_TEXT_OFFSET_Y or M.PEEK_TIMER_TEXT_OFFSET_Y
    frame.timer:ClearAllPoints()
    frame.timer:SetPoint("CENTER", frame.timerPill, "CENTER", 0, textOffY)
    applyCooldownLayout(frame)
end

local function computeDefaultPositions()
    -- Default auto-layout lives in the same UIParent space as persisted anchors.
    local parentW, parentH = getLayoutParentSize()
    local scale      = M.GetScale()
    local visualSize = M.BUTTON_SIZE * scale
    local gap        = M.BUTTON_GAP
    local total      = SNS.MAX_TOTEM_SLOTS
    local totalWidth = total * visualSize + (total - 1) * gap
    local startX     = (parentW - totalWidth) / 2
    local centerY    = parentH / 2
    local positions  = {}
    local centerX
    local element

    for element = 1, total do
        centerX = startX + (element - 1) * (visualSize + gap) + visualSize / 2
        positions[element] = { x = centerX, y = centerY }
    end

    return positions
end

local function restoreButtonPosition(btn)
    local cfg = M.GetElementConfig(btn.element)
    local centerX
    local centerY
    local defaults
    local layout

    if cfg and cfg.centerX ~= nil and cfg.centerY ~= nil then
        centerX = cfg.centerX
        centerY = cfg.centerY
    else
        defaults = computeDefaultPositions()
        layout = defaults and defaults[btn.element] or nil
        centerX = layout and layout.x or nil
        centerY = layout and layout.y or nil
    end

    if centerX == nil or centerY == nil then
        centerX = 0
        centerY = 0
    end

    centerX, centerY = parentPointToFrame(btn, centerX, centerY)

    btn:ClearAllPoints()
    btn:SetPoint("CENTER", UIParent, "BOTTOMLEFT", centerX, centerY)
end

local function getButtonAnchor(btn)
    local left   = btn:GetLeft()
    local right  = btn:GetRight()
    local top    = btn:GetTop()
    local bottom = btn:GetBottom()
    if not left or not right or not top or not bottom then return nil end
    return (left + right) / 2, (top + bottom) / 2
end

local function getFrameBounds(frame)
    if not frame then return nil end

    local left   = frame:GetLeft()
    local right  = frame:GetRight()
    local top    = frame:GetTop()
    local bottom = frame:GetBottom()
    if not left or not right or not top or not bottom then return nil end

    return left, right, top, bottom
end

local function getBoundsCenter(left, right, top, bottom)
    return (left + right) / 2, (top + bottom) / 2
end

local function compareSnapAgainstOther(
    other,
    element,
    gap,
    left,
    right,
    top,
    bottom,
    cx,
    cy,
    bestXDist,
    bestXOff,
    bestYDist,
    bestYOff
)
    if not other or other.element == element then
        return bestXDist, bestXOff, bestYDist, bestYOff
    end

    local otherLeft, otherRight, otherTop, otherBottom = getFrameBounds(other)
    if not otherLeft then
        return bestXDist, bestXOff, bestYDist, bestYOff
    end

    local otherCenterX, otherCenterY = getBoundsCenter(otherLeft, otherRight, otherTop, otherBottom)

    bestXDist, bestXOff = pickSnap(otherLeft           - left,      bestXDist, bestXOff)
    bestXDist, bestXOff = pickSnap(otherRight          - right,     bestXDist, bestXOff)
    bestXDist, bestXOff = pickSnap(otherRight + gap    - left,      bestXDist, bestXOff)
    bestXDist, bestXOff = pickSnap(otherLeft  - gap    - right,     bestXDist, bestXOff)
    bestXDist, bestXOff = pickSnap(otherCenterX        - cx,        bestXDist, bestXOff)

    bestYDist, bestYOff = pickSnap(otherTop            - top,       bestYDist, bestYOff)
    bestYDist, bestYOff = pickSnap(otherBottom         - bottom,    bestYDist, bestYOff)
    bestYDist, bestYOff = pickSnap(otherBottom - gap   - top,       bestYDist, bestYOff)
    bestYDist, bestYOff = pickSnap(otherTop    + gap   - bottom,    bestYDist, bestYOff)
    bestYDist, bestYOff = pickSnap(otherCenterY        - cy,        bestYDist, bestYOff)

    return bestXDist, bestXOff, bestYDist, bestYOff
end

local function runSnap(btn, buttons)
    if not SNSConfig.snapAlign then return end

    local left, right, top, bottom = getFrameBounds(btn)
    if not left then return end

    local cx, cy  = getBoundsCenter(left, right, top, bottom)
    local gap     = parentPointToFrame(btn, M.BUTTON_GAP, 0)
    local thresh  = parentPointToFrame(btn, SNAP_THRESHOLD, 0)
    local element = btn.element
    local bestXDist = thresh + 1
    local bestXOff
    local bestYDist = thresh + 1
    local bestYOff

    local screenCX, screenCY = parentPointToFrame(btn, GetScreenWidth() / 2, GetScreenHeight() / 2)
    bestXDist, bestXOff = pickSnap(screenCX - cx, bestXDist, bestXOff)
    bestYDist, bestYOff = pickSnap(screenCY - cy, bestYDist, bestYOff)

    if buttons then
        local i
        for i = 1, SNS.MAX_TOTEM_SLOTS do
            local other = buttons[i]
            bestXDist, bestXOff, bestYDist, bestYOff = compareSnapAgainstOther(
                other,
                element,
                gap,
                left,
                right,
                top,
                bottom,
                cx,
                cy,
                bestXDist,
                bestXOff,
                bestYDist,
                bestYOff
            )
        end
    end

    if not bestXOff and not bestYOff then return end

    local newCenterX = cx + (bestXOff or 0)
    local newCenterY = cy + (bestYOff or 0)
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", UIParent, "BOTTOMLEFT", newCenterX, newCenterY)
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.CreateButton           = createButton
M.CreatePeekFrame        = createPeekFrame
M.CreateFlyoutFrame      = createFlyoutFrame
M.EnsureFlyoutEntry      = ensureFlyoutEntry
M.AnchorPeek             = anchorPeek
M.ApplyIconChrome        = applyIconChrome
M.ApplyFlyoutEntryChrome = applyFlyoutEntryChrome
M.RestoreButtonPosition  = restoreButtonPosition
M.GetButtonAnchor        = getButtonAnchor
M.FramePointToParent     = framePointToParent
M.ParentPointToFrame     = parentPointToFrame
M.RunSnap                = runSnap
