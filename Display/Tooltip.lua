-- SticksAndStones: Display/Tooltip.lua
-- Tooltip support module for the Display pod.
-- Owns tooltip anchoring, content formatting, and tooltip refresh helpers for
-- button, peek, and flyout hover surfaces.
-- Exports tooltip helpers on DisplayInternal.
-- Side effects: shows and hides GameTooltip at runtime. Creates no frames.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = DisplayInternal

local GameTooltip = GameTooltip
local GetTime     = GetTime
local math_floor  = math.floor
local type        = type

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local TOOLTIP_ANCHOR_FRAME  = "frame"
local TOOLTIP_ANCHOR_CURSOR = "cursor"

local TOOLTIP_DIR_UP    = "up"
local TOOLTIP_DIR_DOWN  = "down"
local TOOLTIP_DIR_LEFT  = "left"
local TOOLTIP_DIR_RIGHT = "right"

local TOOLTIP_KIND_BUTTON = "button"
local TOOLTIP_KIND_PEEK   = "peek"
local TOOLTIP_KIND_FLYOUT = "flyout"

local FRAME_ANCHORS = {
    [TOOLTIP_DIR_UP]    = { point = "BOTTOM", relPoint = "TOP"    },
    [TOOLTIP_DIR_DOWN]  = { point = "TOP",    relPoint = "BOTTOM" },
    [TOOLTIP_DIR_LEFT]  = { point = "RIGHT",  relPoint = "LEFT"   },
    [TOOLTIP_DIR_RIGHT] = { point = "LEFT",   relPoint = "RIGHT"  },
}

local TOOLTIP_RENDERERS = {}

------------------------------------------------------------------------
-- Owned state
------------------------------------------------------------------------

M.tooltipOwner         = nil
M.tooltipKind          = nil
M.tooltipAnchorMode    = false
M.tooltipDirection     = false
M.tooltipOffsetX       = false
M.tooltipOffsetY       = false
M.tooltipElement       = false
M.tooltipSpellId       = false
M.tooltipActiveFlag    = false
M.tooltipRemainingMode = -1
M.tooltipRemainingSecs = -1
M.tooltipRangeFlag     = -1
M.tooltipCatalogRef    = nil

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function isTooltipEnabled()
    if not GameTooltip then return false end
    if type(SNSConfig) ~= "table" then return true end
    if SNSConfig.tooltipsEnabled == nil then return true end
    return SNSConfig.tooltipsEnabled ~= false
end

local function sanitizeAnchorMode(value)
    if value == TOOLTIP_ANCHOR_CURSOR then return TOOLTIP_ANCHOR_CURSOR end
    return TOOLTIP_ANCHOR_FRAME
end

local function sanitizeDirection(value)
    if FRAME_ANCHORS[value] then return value end
    return TOOLTIP_DIR_RIGHT
end

local function sanitizeOffset(value, fallback)
    if type(value) ~= "number" then
        value = fallback
    end
    if type(value) ~= "number" then return 0 end
    if value < -200 then return -200 end
    if value >  200 then return  200 end
    return value
end

local function getAnchorState()
    local anchorMode = sanitizeAnchorMode(SNSConfig and SNSConfig.tooltipAnchorMode)
    local direction  = sanitizeDirection(SNSConfig  and SNSConfig.tooltipDirection)
    local offsetX    = sanitizeOffset(SNSConfig     and SNSConfig.tooltipOffsetX, 10)
    local offsetY    = sanitizeOffset(SNSConfig     and SNSConfig.tooltipOffsetY,  0)
    return anchorMode, direction, offsetX, offsetY
end

local function anchorTooltip(frame, anchorMode, direction, offsetX, offsetY)
    if anchorMode == TOOLTIP_ANCHOR_CURSOR then
        GameTooltip:SetOwner(frame, "ANCHOR_CURSOR")
        return
    end

    local anchor = FRAME_ANCHORS[direction] or FRAME_ANCHORS[TOOLTIP_DIR_RIGHT]

    GameTooltip:SetOwner(frame, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint(anchor.point, frame, anchor.relPoint, offsetX, offsetY)
end

local function isOwnedBy(frame)
    if not frame or not GameTooltip then return false end
    if GameTooltip.IsOwned then
        return GameTooltip:IsOwned(frame)
    end
    return true
end

local function getSlot(element)
    if not M.snapshot then return nil end
    return M.snapshot[element]
end

local function getRecord(spellId)
    if not spellId or not M.catalog or not M.catalog.bySpellId then return nil end
    return M.catalog.bySpellId[spellId]
end

local function getRemainingSeconds(spawnedAt, duration)
    if duration == nil or duration <= 0 then return -1 end
    if not GetTime or not spawnedAt then return 0 end

    local remaining = (spawnedAt + duration) - GetTime()
    if remaining < 0 then remaining = 0 end

    local secs = math_floor(remaining)
    if secs < 0 then secs = 0 end
    return secs
end

local function addTitleLine(tip, element, record)
    if record then
        local title = record.unitName or record.baseName
        if title then
            tip:AddLine(title)
            return
        end
    end

    local elementNames = SNS and SNS.ELEMENT_NAMES
    local elementName  = elementNames and elementNames[element]
    if not elementName then
        if type(element) == "number" then
            elementName = "Element " .. element
        else
            elementName = "Totem"
        end
    end
    tip:AddLine(elementName .. " Totem")
end

local function addSpellInfoLines(tip, record)
    if not record then return end

    local mana
    if record.manaCost and record.manaCost > 0 then
        mana = record.manaCost .. "m"
    elseif record.manaCostPct and record.manaCostPct > 0 then
        mana = record.manaCostPct .. "% base"
    else
        mana = "0m"
    end

    local range = "--"
    if record.rangeYards then
        range = record.rangeYards .. " yd"
    end

    tip:AddLine("Mana: "  .. mana,  1, 1, 1)
    tip:AddLine("Range: " .. range, 1, 1, 1)
end

local function addLiveStatusLines(tip, slot, remainingMode, remainingSecs)
    if not slot then return end

    if slot.activeId then
        if remainingMode == 1 then
            tip:AddLine("Remaining: " .. M.FormatMinutesSeconds(remainingSecs), 1, 1, 1)
        else
            tip:AddLine("Remaining: Infinite", 1, 1, 1)
        end
    end

    if slot.isInRange == false then
        tip:AddLine("Out of range", 1, 0.35, 0.35)
    end
end

local function addButtonHints(tip)
    tip:AddLine("Left-click: Cast element",        0.85, 0.85, 0.85)
    tip:AddLine("Right-click: Juggle chosen/peek", 0.85, 0.85, 0.85)
end

local function addPeekHints(tip)
    tip:AddLine("Left-click: Cast peek",     0.85, 0.85, 0.85)
    tip:AddLine("Right-click: Promote/swap", 0.85, 0.85, 0.85)
end

local function addFlyoutHints(tip)
    tip:AddLine("Left-click: Cast this totem", 0.85, 0.85, 0.85)
    tip:AddLine("Right-click: Set as chosen",  0.85, 0.85, 0.85)
end

local function fillButtonTooltip(frame, tip, remainingMode, remainingSecs)
    local element = frame and frame.element
    local slot    = getSlot(element)
    local record  = getRecord(M.GetButtonSpellId(element))

    addTitleLine(tip, element, record)
    if record then
        addSpellInfoLines(tip, record)
    end
    addLiveStatusLines(tip, slot, remainingMode, remainingSecs)
    addButtonHints(tip)
end

local function fillPeekTooltip(frame, tip, remainingMode, remainingSecs)
    local element = frame and frame.element
    local slot    = getSlot(element)
    local record  = getRecord(M.GetPeekSpellId(element))

    addTitleLine(tip, element, record)
    if record then
        addSpellInfoLines(tip, record)
    end
    addLiveStatusLines(tip, slot, remainingMode, remainingSecs)
    addPeekHints(tip)
end

local function fillFlyoutTooltip(frame, tip)
    local entry   = frame and frame:GetParent()
    local element = entry and entry.element
    local record  = getRecord(entry and entry.spellId)

    addTitleLine(tip, element, record)
    addSpellInfoLines(tip, record)
    addFlyoutHints(tip)
end

TOOLTIP_RENDERERS[TOOLTIP_KIND_BUTTON] = fillButtonTooltip
TOOLTIP_RENDERERS[TOOLTIP_KIND_PEEK]   = fillPeekTooltip
TOOLTIP_RENDERERS[TOOLTIP_KIND_FLYOUT] = fillFlyoutTooltip

local function renderTooltip(kind, frame, tip, remainingMode, remainingSecs)
    local render = TOOLTIP_RENDERERS[kind]
    if not render then return false end

    render(frame, tip, remainingMode, remainingSecs)
    return true
end

local function clearTooltipRenderState()
    M.tooltipAnchorMode    = false
    M.tooltipDirection     = false
    M.tooltipOffsetX       = false
    M.tooltipOffsetY       = false
    M.tooltipElement       = false
    M.tooltipSpellId       = false
    M.tooltipActiveFlag    = false
    M.tooltipRemainingMode = -1
    M.tooltipRemainingSecs = -1
    M.tooltipRangeFlag     = -1
    M.tooltipCatalogRef    = nil
end

local function clearTooltipContext()
    M.tooltipOwner = nil
    M.tooltipKind  = nil
    clearTooltipRenderState()
end

local function getTooltipState(kind, frame)
    local anchorMode, direction, offsetX, offsetY = getAnchorState()
    local element       = false
    local spellId       = false
    local activeFlag    = false
    local remainingMode = 0
    local remainingSecs = -1
    local rangeFlag     = 1

    if kind == TOOLTIP_KIND_FLYOUT then
        local entry = frame and frame:GetParent()
        element = entry and entry.element or false
        spellId = entry and entry.spellId or false
        return anchorMode, direction, offsetX, offsetY,
               element, spellId, activeFlag, remainingMode, remainingSecs, rangeFlag, M.catalog
    end

    element = frame and frame.element or false
    local slot = getSlot(element)
    if kind == TOOLTIP_KIND_BUTTON then
        spellId = M.GetButtonSpellId(element) or false
    else
        spellId = M.GetPeekSpellId(element)   or false
    end

    if slot and slot.activeId then
        activeFlag = true
        if slot.duration and slot.duration > 0 then
            remainingMode = 1
            remainingSecs = getRemainingSeconds(slot.spawnedAt, slot.duration)
        else
            remainingMode = 2
        end
    end

    if slot and slot.isInRange == false then
        rangeFlag = 0
    end

    return anchorMode, direction, offsetX, offsetY,
           element, spellId, activeFlag, remainingMode, remainingSecs, rangeFlag, M.catalog
end

local function storeTooltipState(
    frame,
    kind,
    anchorMode,
    direction,
    offsetX,
    offsetY,
    element,
    spellId,
    activeFlag,
    remainingMode,
    remainingSecs,
    rangeFlag,
    catalogRef
)
    M.tooltipOwner         = frame
    M.tooltipKind          = kind
    M.tooltipAnchorMode    = anchorMode
    M.tooltipDirection     = direction
    M.tooltipOffsetX       = offsetX
    M.tooltipOffsetY       = offsetY
    M.tooltipElement       = element
    M.tooltipSpellId       = spellId
    M.tooltipActiveFlag    = activeFlag
    M.tooltipRemainingMode = remainingMode
    M.tooltipRemainingSecs = remainingSecs
    M.tooltipRangeFlag     = rangeFlag
    M.tooltipCatalogRef    = catalogRef
end

local function updateTooltip(kind, frame, force)
    local anchorMode, direction, offsetX, offsetY,
          element, spellId, activeFlag, remainingMode, remainingSecs, rangeFlag, catalogRef =
        getTooltipState(kind, frame)

    local anchorChanged = force
                       or frame      ~= M.tooltipOwner
                       or anchorMode ~= M.tooltipAnchorMode
                       or direction  ~= M.tooltipDirection
                       or offsetX    ~= M.tooltipOffsetX
                       or offsetY    ~= M.tooltipOffsetY

    local contentChanged = force
                        or frame         ~= M.tooltipOwner
                        or kind          ~= M.tooltipKind
                        or element       ~= M.tooltipElement
                        or spellId       ~= M.tooltipSpellId
                        or activeFlag    ~= M.tooltipActiveFlag
                        or remainingMode ~= M.tooltipRemainingMode
                        or remainingSecs ~= M.tooltipRemainingSecs
                        or rangeFlag     ~= M.tooltipRangeFlag
                        or catalogRef    ~= M.tooltipCatalogRef

    if anchorChanged then
        anchorTooltip(frame, anchorMode, direction, offsetX, offsetY)
    end

    if contentChanged then
        GameTooltip:ClearLines()
        if not renderTooltip(kind, frame, GameTooltip, remainingMode, remainingSecs) then
            clearTooltipContext()
            return nil
        end
    end

    if anchorChanged or contentChanged then
        GameTooltip:Show()
    end

    storeTooltipState(
        frame,
        kind,
        anchorMode,
        direction,
        offsetX,
        offsetY,
        element,
        spellId,
        activeFlag,
        remainingMode,
        remainingSecs,
        rangeFlag,
        catalogRef
    )
    return true
end

local function showTooltip(frame, kind)
    if not frame or not kind or not GameTooltip then return end
    if not isTooltipEnabled() then
        M.HideTooltip()
        return
    end

    if not updateTooltip(kind, frame, true) then
        GameTooltip:Hide()
    end
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function hideTooltip()
    local owner    = M.tooltipOwner
    M.tooltipOwner = nil
    M.tooltipKind  = nil
    clearTooltipRenderState()

    if not owner or not GameTooltip then return end
    if not GameTooltip:IsShown() then return end
    if not isOwnedBy(owner) then return end

    GameTooltip:Hide()
end

local function refreshTooltip()
    local owner = M.tooltipOwner
    local kind  = M.tooltipKind
    if not owner or not kind or not GameTooltip then return end
    if not GameTooltip:IsShown() then
        clearTooltipContext()
        return
    end
    if not isOwnedBy(owner) then
        clearTooltipContext()
        return
    end
    if owner.IsShown and not owner:IsShown() then
        M.HideTooltip()
        return
    end
    if not isTooltipEnabled() then
        M.HideTooltip()
        return
    end

    if not updateTooltip(kind, owner, nil) then
        M.HideTooltip()
    end
end

local function showButtonTooltip(frame)
    showTooltip(frame, TOOLTIP_KIND_BUTTON)
end

local function showPeekTooltip(frame)
    showTooltip(frame, TOOLTIP_KIND_PEEK)
end

local function showFlyoutEntryTooltip(frame)
    showTooltip(frame, TOOLTIP_KIND_FLYOUT)
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.HideTooltip            = hideTooltip
M.RefreshTooltip         = refreshTooltip
M.ShowButtonTooltip      = showButtonTooltip
M.ShowPeekTooltip        = showPeekTooltip
M.ShowFlyoutEntryTooltip = showFlyoutEntryTooltip
