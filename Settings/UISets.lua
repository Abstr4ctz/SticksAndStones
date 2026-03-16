-- SticksAndStones: Settings/UISets.lua
-- Sets tab owner for the Settings pod.
-- Owns the Sets tab UI state, row rendering, and set-list controls.
-- User-triggered writes flow through the public Settings facade only.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local SI = SettingsInternal

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local SETS_LIST_SCROLL_GLOBAL_NAME = "SNSSettingsSetsListScrollFrame"

local BUTTON_GAP         = 6
local LIST_TOP_OFFSET    = 100
local LIST_SIDE_INSET    = 14
local LIST_BOTTOM_INSET  = 14
local SET_ROW_HEIGHT     = 34
local SET_ROW_GAP        = 4
local SET_ICON_SIZE      = 24
local LIST_SCROLL_STEP   = SET_ROW_HEIGHT + SET_ROW_GAP
local MOVE_DIRECTION_UP   = -1
local MOVE_DIRECTION_DOWN = 1

local LIST_BACKDROP = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true,
    tileSize = 16,
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
}

local ROW_BACKDROP = {
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    tile     = true,
    tileSize = 8,
    edgeSize = 1,
    insets   = { left = 1, right = 1, top = 1, bottom = 1 },
}

local state = {
    panel           = nil,
    isSyncing       = false,
    lastActiveIndex = nil,
}

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function getSetCount()
    if type(SNSConfig) ~= "table" or type(SNSConfig.sets) ~= "table" then return 0 end
    return table.getn(SNSConfig.sets)
end

local function getSet(index)
    local count
    local set

    if type(index) ~= "number" or index ~= math.floor(index) then return nil end

    count = getSetCount()
    if index < 1 or index > count then return nil end

    set = SNSConfig.sets[index]
    if type(set) ~= "table" then return nil end
    return set
end

local function getActiveSetIndex(count)
    local index = SNSConfig and SNSConfig.activeSetIndex or nil

    if type(count) ~= "number" then
        count = getSetCount()
    end
    if type(index) ~= "number" or index ~= math.floor(index) then
        return SI.ACTIVE_SET_NONE
    end
    if index < 1 or index > count then
        return SI.ACTIVE_SET_NONE
    end
    return index
end

local function resolveSpellIconTexture(spellId)
    local iconId
    local id     = tonumber(spellId)

    if not id then return nil end

    id = math.floor(id)
    if id < 1 then return nil end
    if type(GetSpellRecField) ~= "function" or type(GetSpellIconTexture) ~= "function" then
        return nil
    end

    iconId = GetSpellRecField(id, "spellIconID")
    if not iconId then return nil end
    return GetSpellIconTexture(iconId)
end

local function resolveSetSlotIcon(set, element)
    local spellId = type(set) == "table" and set[element] or nil
    local icon    = resolveSpellIconTexture(spellId)

    if icon then
        return icon, true
    end
    return SI.FALLBACK_ICON, nil
end

local function applyRowSelectedVisual(row, isSelected)
    if not row or not row.bg then return end

    if isSelected then
        if row.highlight then row.highlight:Show() end
        row.bg:SetBackdropColor(0.14, 0.24, 0.44, 0.98)
        row.bg:SetBackdropBorderColor(0.42, 0.78, 1.00, 1.00)
        return
    end

    if row.highlight then row.highlight:Hide() end
    row.bg:SetBackdropColor(0.05, 0.05, 0.05, 0.90)
    row.bg:SetBackdropBorderColor(0.20, 0.20, 0.20, 1.00)
end

local function getListContentHeight(count)
    if count <= 0 then return 1 end
    return (count * SET_ROW_HEIGHT) + ((count - 1) * SET_ROW_GAP)
end

local function clampListScroll(scroll, contentHeight)
    local maxScroll
    local currentScroll

    if not scroll then return end

    maxScroll = contentHeight - (scroll:GetHeight() or 0)
    if maxScroll < 0 then maxScroll = 0 end

    currentScroll = scroll:GetVerticalScroll() or 0
    if currentScroll < 0 then
        currentScroll = 0
    elseif currentScroll > maxScroll then
        currentScroll = maxScroll
    end

    scroll:SetVerticalScroll(currentScroll)
end

local function syncListMetrics(panel, count)
    local controls      = panel and panel.controls or nil
    local scroll        = controls and controls.listScroll or nil
    local content       = controls and controls.listContent or nil
    local contentHeight
    local viewWidth

    if not scroll or not content then return end

    contentHeight = getListContentHeight(count)
    viewWidth = scroll:GetWidth() or 0
    if viewWidth < 1 then viewWidth = 1 end

    content:SetWidth(viewWidth)
    content:SetHeight(contentHeight)
    clampListScroll(scroll, contentHeight)
end

local function ensureRowVisible(index)
    local panel           = state.panel
    local controls        = panel and panel.controls or nil
    local rows            = controls and controls.rows or nil
    local row             = type(rows) == "table" and rows[index] or nil
    local scroll          = controls and controls.listScroll or nil
    local content         = controls and controls.listContent or nil
    local rowTop
    local rowBottom
    local contentTop
    local scrollTop
    local scrollBottom
    local rowTopOffset
    local rowBottomOffset
    local targetScroll
    local maxScroll

    if not row or not scroll or not content then return end

    rowTop = row:GetTop()
    rowBottom = row:GetBottom()
    contentTop = content:GetTop()
    if not rowTop or not rowBottom or not contentTop then return end

    scrollTop = scroll:GetVerticalScroll() or 0
    scrollBottom = scrollTop + (scroll:GetHeight() or 0)
    rowTopOffset = contentTop - rowTop
    rowBottomOffset = contentTop - rowBottom
    targetScroll = scrollTop

    if rowTopOffset < scrollTop then
        targetScroll = rowTopOffset
    elseif rowBottomOffset > scrollBottom then
        targetScroll = rowBottomOffset - (scroll:GetHeight() or 0)
    end

    maxScroll = (content:GetHeight() or 0) - (scroll:GetHeight() or 0)
    if maxScroll < 0 then maxScroll = 0 end
    if targetScroll < 0 then targetScroll = 0 end
    if targetScroll > maxScroll then targetScroll = maxScroll end

    scroll:SetVerticalScroll(targetScroll)
end

local function refreshPanel(panel)
    local controls
    local count
    local activeIndex
    local hasSelection
    local selectedChanged
    local i

    if panel then
        if panel ~= state.panel then
            state.lastActiveIndex = nil
        end
        state.panel = panel
    end

    panel = state.panel
    controls = panel and panel.controls or nil
    if type(SNSConfig) ~= "table" or not controls then return end

    state.isSyncing = true

    count = getSetCount()
    activeIndex = getActiveSetIndex(count)
    selectedChanged = activeIndex ~= state.lastActiveIndex

    SI.setChecked(controls.wrapCheck, SNSConfig.setsCycleWrap and true or nil)

    for i = 1, count do
        local row = controls.rows[i]
        local set = getSet(i)
        local element

        if not row then
            row = controls.ensureSetRow(i)
        end

        row.setIndex = i
        row:Show()
        applyRowSelectedVisual(row, activeIndex == i)

        for element = 1, SI.MAX_ELEMENTS do
            local iconTexture, hasAssigned = resolveSetSlotIcon(set, element)
            local icon = row.icons[element]

            if icon then
                icon:SetTexture(iconTexture or SI.FALLBACK_ICON)
                icon:SetAlpha(hasAssigned and 1 or 0.35)
            end
        end
    end

    for i = count + 1, table.getn(controls.rows) do
        local row = controls.rows[i]

        if row then
            row.setIndex = nil
            applyRowSelectedVisual(row, nil)
            row:Hide()
        end
    end

    syncListMetrics(panel, count)

    hasSelection = activeIndex ~= SI.ACTIVE_SET_NONE
    SI.setButtonEnabled(controls.addButton, count < SI.MAX_SETS)
    SI.setButtonEnabled(controls.deleteButton, hasSelection)
    SI.setButtonEnabled(controls.moveUpButton, hasSelection and activeIndex > 1)
    SI.setButtonEnabled(controls.moveDownButton, hasSelection and activeIndex < count)

    state.isSyncing = false

    if selectedChanged and activeIndex ~= SI.ACTIVE_SET_NONE then
        ensureRowVisible(activeIndex)
    end
    state.lastActiveIndex = activeIndex
end

------------------------------------------------------------------------
-- Private handlers
------------------------------------------------------------------------

local function onCheckboxClick()
    local onValueChanged
    local checked

    if not this then return end

    onValueChanged = this.onValueChanged
    if not onValueChanged or state.isSyncing then return end

    checked = this:GetChecked() and true or false
    onValueChanged(checked)
end

local function onSetRowClick()
    local row = this

    if not row or type(row.setIndex) ~= "number" then return end

    Settings.SetActiveSet(row.setIndex)
end

local function onAddButtonClick()
    local newIndex
    local err

    newIndex, err = Settings.CreateSet()
    if newIndex then
        ensureRowVisible(newIndex)
        return
    end

    if err == "max_sets_reached" then
        SI.printChat(SI.CHAT_PREFIX .. "you can save up to " .. tostring(SI.MAX_SETS) .. " sets.")
        return
    end
    SI.printChat(SI.CHAT_PREFIX .. "failed to create a set.")
end

local function onDeleteButtonClick()
    local activeIndex = getActiveSetIndex()

    if activeIndex == SI.ACTIVE_SET_NONE then return end
    Settings.RemoveSet(activeIndex)
end

local function reorderActiveSet(direction)
    local activeIndex = getActiveSetIndex()

    if activeIndex == SI.ACTIVE_SET_NONE then return end
    Settings.ReorderSet(activeIndex, direction)
end

local function onMoveUpButtonClick()
    reorderActiveSet(MOVE_DIRECTION_UP)
end

local function onMoveDownButtonClick()
    reorderActiveSet(MOVE_DIRECTION_DOWN)
end

local function onListScrollSizeChanged()
    if not this then return end
    if not state.panel or not state.panel.controls then return end
    if this ~= state.panel.controls.listScroll then return end

    syncListMetrics(state.panel, getSetCount())
end

local function onListScrollMouseWheel()
    local controls     = state.panel and state.panel.controls or nil
    local scroll       = controls and controls.listScroll or nil
    local content      = controls and controls.listContent or nil
    local delta        = tonumber(arg1)
    local targetScroll
    local maxScroll

    if not scroll or not content or not delta then return end

    targetScroll = (scroll:GetVerticalScroll() or 0) - (delta * LIST_SCROLL_STEP)
    maxScroll = (content:GetHeight() or 0) - (scroll:GetHeight() or 0)
    if maxScroll < 0 then maxScroll = 0 end
    if targetScroll < 0 then targetScroll = 0 end
    if targetScroll > maxScroll then targetScroll = maxScroll end

    scroll:SetVerticalScroll(targetScroll)
end

------------------------------------------------------------------------
-- Private builders
------------------------------------------------------------------------

local function buildSetRow(parent, index)
    local row       = CreateFrame("Button", nil, parent)
    local bg        = CreateFrame("Frame", nil, row)
    local highlight = row:CreateTexture(nil, "BORDER")
    local iconX     = 12
    local element

    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * (SET_ROW_HEIGHT + SET_ROW_GAP)))
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * (SET_ROW_HEIGHT + SET_ROW_GAP)))
    row:SetHeight(SET_ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", onSetRowClick)

    bg:SetAllPoints(row)
    bg:SetBackdrop(ROW_BACKDROP)
    bg:SetBackdropColor(0.05, 0.05, 0.05, 0.90)
    bg:SetBackdropBorderColor(0.20, 0.20, 0.20, 1.00)
    row.bg = bg

    highlight:SetAllPoints(row)
    highlight:SetTexture(0.20, 0.55, 0.95, 0.30)
    highlight:Hide()
    row.highlight = highlight

    row.icons = {}
    row.iconFrames = {}
    for element = 1, SI.MAX_ELEMENTS do
        local iconFrame = CreateFrame("Frame", nil, row)
        local icon = iconFrame:CreateTexture(nil, "ARTWORK")

        iconFrame:SetWidth(SET_ICON_SIZE + 2)
        iconFrame:SetHeight(SET_ICON_SIZE + 2)
        iconFrame:SetPoint("LEFT", row, "LEFT", iconX, 0)
        iconFrame:SetBackdrop(ROW_BACKDROP)
        iconFrame:SetBackdropColor(0, 0, 0, 0.92)
        iconFrame:SetBackdropBorderColor(0.20, 0.20, 0.20, 1.00)

        icon:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -1, 1)

        row.iconFrames[element] = iconFrame
        row.icons[element] = icon
        iconX = iconX + SET_ICON_SIZE + 8
    end

    return row
end

local function buildPanel(panel)
    local controls     = {}
    local content      = panel
    local listBg
    local listScroll
    local listContent
    local hint

    state.panel = panel
    state.lastActiveIndex = nil
    panel.controls = controls

    controls.addButton = SI.createActionButton(content, 68, 18, -8, "Add", onAddButtonClick)
    controls.deleteButton = SI.createActionButton(content, 68, 18 + 68 + BUTTON_GAP, -8, "Remove", onDeleteButtonClick)
    controls.moveUpButton = SI.createActionButton(content, 50, 18 + 68 + BUTTON_GAP + 68 + BUTTON_GAP, -8, "Up", onMoveUpButtonClick)
    controls.moveDownButton = SI.createActionButton(content, 62, 18 + 68 + BUTTON_GAP + 68 + BUTTON_GAP + 50 + BUTTON_GAP, -8, "Down", onMoveDownButtonClick)

    controls.wrapCheck = SI.createCheckboxRow(content, -42, "Cycle Wrap", onCheckboxClick)
    controls.wrapCheck.onValueChanged = Settings.SetSetCycleWrap

    hint = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", content, "TOPLEFT", 40, -72)
    hint:SetWidth(280)
    hint:SetJustifyH("LEFT")
    hint:SetText("Mouse wheel over the totem bar cycles saved sets.")
    controls.hint = hint

    listBg = CreateFrame("Frame", nil, content)
    listBg:SetPoint("TOPLEFT", content, "TOPLEFT", LIST_SIDE_INSET, -LIST_TOP_OFFSET)
    listBg:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -LIST_SIDE_INSET, LIST_BOTTOM_INSET)
    listBg:SetBackdrop(LIST_BACKDROP)
    listBg:SetBackdropColor(0, 0, 0, 0.90)
    listBg:SetBackdropBorderColor(0.35, 0.35, 0.35, 1.00)
    controls.listBg = listBg

    listScroll = CreateFrame("ScrollFrame", SETS_LIST_SCROLL_GLOBAL_NAME, listBg, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", listBg, "TOPLEFT", 8, -8)
    listScroll:SetPoint("BOTTOMRIGHT", listBg, "BOTTOMRIGHT", -30, 8)
    listScroll:SetVerticalScroll(0)
    listScroll:SetScript("OnSizeChanged", onListScrollSizeChanged)
    if listScroll.EnableMouseWheel then
        listScroll:EnableMouseWheel(true)
    end
    listScroll:SetScript("OnMouseWheel", onListScrollMouseWheel)
    controls.listScroll = listScroll

    listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetHeight(1)
    listContent:SetWidth(1)
    listScroll:SetScrollChild(listContent)
    controls.listContent = listContent

    controls.rows = {}
    local function ensureSetRow(index)
        local row = controls.rows[index]

        if row then return row end

        row = buildSetRow(listContent, index)
        controls.rows[index] = row
        return row
    end
    controls.ensureSetRow = ensureSetRow
end

------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------

if SI.RegisterUITab then
    SI.RegisterUITab(SI.UI_TAB_SETS, {
        Build = buildPanel,
        Refresh = refreshPanel,
    })
end
