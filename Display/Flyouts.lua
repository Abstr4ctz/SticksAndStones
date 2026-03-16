-- SticksAndStones: Display/Flyouts.lua
-- Flyout behavior support module for the Display pod.
-- Owns canonical order resolution, flyout layout, open and close lifecycle,
-- flyout click routing, and deferred-close timing.
-- Exports flyout lifecycle helpers on DisplayInternal.
-- Side effects: creates one hidden timer frame for the shared close delay.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = DisplayInternal

local CreateFrame = CreateFrame
local GetTime     = GetTime

local ACTION_TYPES = SNS.ACTION_TYPES

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local FLYOUT_CLOSE_DELAY = 0.10
local EMPTY_LIST         = {}

local FLYOUT_ANCHOR = {
    top    = { point = "BOTTOM", relPoint = "TOP",    xSign =  0, ySign =  1 },
    bottom = { point = "TOP",    relPoint = "BOTTOM", xSign =  0, ySign = -1 },
    left   = { point = "RIGHT",  relPoint = "LEFT",   xSign = -1, ySign =  0 },
    right  = { point = "LEFT",   relPoint = "RIGHT",  xSign =  1, ySign =  0 },
}

local FLYOUT_CLICK_ACTIONS = {
    LeftButton  = { actionType = ACTION_TYPES.CAST_ELEMENT_FLYOUT,   includeElement = false },
    RightButton = { actionType = ACTION_TYPES.CHANGE_ELEMENT_FLYOUT, includeElement = true  },
}

------------------------------------------------------------------------
-- Owned state
------------------------------------------------------------------------

M.flyoutOpenElement    = nil
M.flyoutCloseStartedAt = nil

local closeTimerFrame = nil

local scratchCurrentByBaseName = {}
local scratchFilterBySpellId   = {}
local scratchSeenBaseNames     = {}
local scratchCanonicalOrder    = {}
local scratchVisibleOrder      = {}
local scratchCanonicalCount    = 0
local scratchVisibleCount      = 0

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function clearMap(map)
    local key
    for key in pairs(map) do
        map[key] = nil
    end
end

local function clearArray(array, count)
    local i
    for i = 1, count do
        array[i] = nil
    end
end

local function getCatalogList(element)
    local byElement = M.catalog and M.catalog.byElement
    if type(byElement) ~= "table" then return EMPTY_LIST end
    return byElement[element] or EMPTY_LIST
end

local function buildCurrentByBaseName(element)
    clearMap(scratchCurrentByBaseName)

    local list = getCatalogList(element)
    local i
    for i = 1, table.getn(list) do
        local record = list[i]
        if record and record.baseName then
            scratchCurrentByBaseName[record.baseName] = record
        end
    end

    return scratchCurrentByBaseName, list
end

local function resolveRecordForSpellId(element, spellId)
    local record = M.catalog and M.catalog.bySpellId and M.catalog.bySpellId[spellId]
    if not record or record.element ~= element then return nil end
    return record
end

local function canonicalizeFlyoutFilter(element, byBaseName)
    clearMap(scratchFilterBySpellId)

    local cfg = M.GetElementConfig(element)
    local raw = cfg and cfg.flyoutFilter or nil
    if type(raw) ~= "table" then
        return scratchFilterBySpellId
    end

    local spellId
    for spellId, enabled in pairs(raw) do
        if enabled then
            local record = resolveRecordForSpellId(element, spellId)
            if record and record.baseName then
                local current = byBaseName[record.baseName]
                if current then
                    scratchFilterBySpellId[current.spellId] = true
                end
            end
        end
    end

    return scratchFilterBySpellId
end

local function appendCanonicalRecord(record, count)
    if not record or not record.baseName then return count end
    if scratchSeenBaseNames[record.baseName] then return count end

    count = count + 1
    scratchCanonicalOrder[count]          = record.spellId
    scratchSeenBaseNames[record.baseName] = true
    return count
end

local function appendCanonicalFromRawSpellId(element, spellId, byBaseName, count)
    local record = resolveRecordForSpellId(element, spellId)
    if not record or not record.baseName then return count end
    return appendCanonicalRecord(byBaseName[record.baseName], count)
end

local function buildCanonicalOrder(element, byBaseName, catalogList)
    clearArray(scratchCanonicalOrder, scratchCanonicalCount)
    scratchCanonicalCount = 0
    clearMap(scratchSeenBaseNames)

    local cfg   = M.GetElementConfig(element)
    local raw   = cfg and cfg.flyoutOrder or nil
    local count = 0
    local i

    if type(raw) == "table" then
        for i = 1, table.getn(raw) do
            count = appendCanonicalFromRawSpellId(element, raw[i], byBaseName, count)
        end
    end

    for i = 1, table.getn(catalogList) do
        count = appendCanonicalRecord(catalogList[i], count)
    end

    scratchCanonicalCount = count
    return scratchCanonicalOrder, count
end

local function buildVisibleOrder(element, peekSpellId)
    clearArray(scratchVisibleOrder, scratchVisibleCount)
    scratchVisibleCount = 0

    local byBaseName, catalogList = buildCurrentByBaseName(element)
    local canonical, canonicalCount = buildCanonicalOrder(element, byBaseName, catalogList)
    local filter       = canonicalizeFlyoutFilter(element, byBaseName)
    local visibleCount = 0
    local i

    for i = 1, canonicalCount do
        local spellId = canonical[i]
        if spellId and not filter[spellId] and spellId ~= peekSpellId then
            visibleCount = visibleCount + 1
            scratchVisibleOrder[visibleCount] = spellId
        end
    end

    scratchVisibleCount = visibleCount
    return scratchVisibleOrder, visibleCount
end

local function resolveFlyoutOrigin(btn)
    local peekSpellId = M.GetPeekSpellId(btn.element)
    if peekSpellId and btn.peek:IsShown() then
        return btn.peek
    end
    return btn
end

local function applyEntryVisuals(entry, element, spellId)
    local record = M.catalog and M.catalog.bySpellId and M.catalog.bySpellId[spellId]
    local borderR, borderG, borderB = M.GetElementBorderColor(element)
    local icon   = (record and record.icon) or M.FALLBACK_ICON

    entry.element = element
    entry.spellId = spellId
    entry.icon:SetTexture(icon)
    entry.icon:SetVertexColor(1, 1, 1)
    entry.dimOverlay:SetAlpha(0)
    entry.dimOverlay:Hide()
    entry.border:SetVertexColor(borderR, borderG, borderB)
    entry:SetAlpha(1.0)

    entry.inputFrame.element    = element
    entry.inputFrame.entryIndex = entry.entryIndex

    if M.ApplyCooldownFrame then
        M.ApplyCooldownFrame(entry, spellId, false)
    end
end

local function hideEntry(entry)
    if not entry then return end

    if M.ClearCooldownFrame then
        M.ClearCooldownFrame(entry)
    end

    entry.spellId = nil
    entry:Hide()
    if entry.inputFrame then
        entry.inputFrame:Hide()
        entry.inputFrame:EnableMouse(false)
    end
end

local function layoutEntries(btn, element, order, count)
    local root = btn.flyout
    if not root then return nil end
    if table.getn(root.entries) < count then return nil end

    local cfg    = M.GetElementConfig(element)
    local dir    = cfg and cfg.flyoutDir or "top"
    local anchor = FLYOUT_ANCHOR[dir] or FLYOUT_ANCHOR.top
    local origin = resolveFlyoutOrigin(btn)
    local prev
    local i

    for i = 1, count do
        local entry = root.entries[i]
        if not entry then return nil end
        applyEntryVisuals(entry, element, order[i])
        entry:ClearAllPoints()

        if prev then
            entry:SetPoint(anchor.point, prev,   anchor.relPoint, anchor.xSign * M.FLYOUT_GAP, anchor.ySign * M.FLYOUT_GAP)
        else
            entry:SetPoint(anchor.point, origin, anchor.relPoint, anchor.xSign * M.FLYOUT_GAP, anchor.ySign * M.FLYOUT_GAP)
        end

        entry:Show()
        prev = entry
    end

    for i = count + 1, table.getn(root.entries) do
        hideEntry(root.entries[i])
    end

    root.visibleCount = count
    if M.SyncCooldownUpdateFrame then
        M.SyncCooldownUpdateFrame()
    end
    return true
end

local function cancelFlyoutClose()
    M.flyoutCloseStartedAt = nil
    if closeTimerFrame then
        closeTimerFrame:Hide()
    end
end

local function isFlyoutAllowed(element)
    if not element then return false end
    if type(SNSConfig) ~= "table" then return false end
    if not SNSConfig.locked then return false end
    if SNSConfig.flyoutMode == "closed" then return false end
    if SNSConfig.flyoutMode == "dynamic" then
        return M.flyoutModifierActive and true or false
    end
    return true
end

local function closeFlyout(element)
    element = element or M.flyoutOpenElement
    if not element then return end

    local btn  = M.buttons and M.buttons[element]
    local root = btn and btn.flyout
    local i

    if root then
        for i = 1, table.getn(root.entries) do
            hideEntry(root.entries[i])
        end
        root.visibleCount = 0
        root:Hide()
    end

    if M.flyoutOpenElement == element then
        M.flyoutOpenElement = nil
    end

    if M.SyncCooldownUpdateFrame then
        M.SyncCooldownUpdateFrame()
    end
    M.NotifyFlyoutStateChanged(element, true)
end

local function closeAllFlyouts()
    local openElement = M.flyoutOpenElement
    cancelFlyoutClose()
    if openElement then
        closeFlyout(openElement)
    end
end

local function openFlyout(element)
    local btn = M.buttons and M.buttons[element]
    if not btn or not btn.flyout then return end

    if M.flyoutOpenElement and M.flyoutOpenElement ~= element then
        closeFlyout(M.flyoutOpenElement)
    end

    local order, count = buildVisibleOrder(element, M.GetPeekSpellId(element))
    if count <= 0 then
        closeFlyout(element)
        return
    end

    if not layoutEntries(btn, element, order, count) then
        closeFlyout(element)
        return
    end
    btn.flyout:Show()
    M.flyoutOpenElement = element
    cancelFlyoutClose()
    if M.SyncCooldownUpdateFrame then
        M.SyncCooldownUpdateFrame()
    end
    M.NotifyFlyoutStateChanged(element, nil)
end

local function refreshOpenFlyout()
    local element = M.flyoutOpenElement
    if not element then return end
    if not isFlyoutAllowed(element) then
        closeFlyout(element)
        return
    end

    local btn = M.buttons and M.buttons[element]
    if not btn or not btn.flyout or not btn:IsShown() then
        closeFlyout(element)
        return
    end

    local order, count = buildVisibleOrder(element, M.GetPeekSpellId(element))
    if count <= 0 then
        closeFlyout(element)
        return
    end

    if not layoutEntries(btn, element, order, count) then
        closeFlyout(element)
        return
    end
    btn.flyout:Show()
    M.NotifyFlyoutStateChanged(element, nil)
end

local function onFlyoutCloseTimerUpdate()
    local startedAt = M.flyoutCloseStartedAt
    if not startedAt then
        if closeTimerFrame then
            closeTimerFrame:Hide()
        end
        return
    end

    if (GetTime() - startedAt) < FLYOUT_CLOSE_DELAY then return end

    M.flyoutCloseStartedAt = nil
    if closeTimerFrame then
        closeTimerFrame:Hide()
    end
    closeAllFlyouts()
end

local function ensureCloseTimerFrame()
    if closeTimerFrame then return closeTimerFrame end

    closeTimerFrame = CreateFrame("Frame", nil, UIParent)
    closeTimerFrame:SetScript("OnUpdate", onFlyoutCloseTimerUpdate)
    closeTimerFrame:Hide()
    return closeTimerFrame
end

local function requestFlyoutClose()
    if not M.flyoutOpenElement then return end
    M.flyoutCloseStartedAt = GetTime()
    ensureCloseTimerFrame():Show()
end

local function requestFlyoutOpen(element)
    cancelFlyoutClose()
    if isFlyoutAllowed(element) then
        openFlyout(element)
    end
end

local function onEntryClick(element, entryIndex, mouseButton)
    local btn     = M.buttons and M.buttons[element]
    local root    = btn and btn.flyout
    local entry   = root and root.entries and root.entries[entryIndex]
    local spellId = entry and entry.spellId
    if not spellId then return end

    local route = FLYOUT_CLICK_ACTIONS[mouseButton]
    if not route then return end

    local actionElement = route.includeElement and element or nil
    M.EmitSpellAction(route.actionType, actionElement, spellId)
end

local function onEntryEnterScript()
    M.HandleFlyoutEntryEnter(this)
end

local function onEntryLeaveScript()
    M.HandleFlyoutEntryLeave()
end

local function onEntryClickScript()
    onEntryClick(this.element, this.entryIndex, arg1)
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------
M.IsFlyoutAllowed    = isFlyoutAllowed
M.OpenFlyout         = openFlyout
M.CloseFlyout        = closeFlyout
M.CloseAllFlyouts    = closeAllFlyouts
M.RefreshOpenFlyout  = refreshOpenFlyout
M.RequestFlyoutClose = requestFlyoutClose
M.CancelFlyoutClose  = cancelFlyoutClose
M.RequestFlyoutOpen  = requestFlyoutOpen
M.OnEntryEnterScript = onEntryEnterScript
M.OnEntryLeaveScript = onEntryLeaveScript
M.OnEntryClickScript = onEntryClickScript
