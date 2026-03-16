-- SticksAndStones: Settings/UIFlyouts.lua
-- Flyouts tab owner for the Settings pod.
-- Owns the Flyouts tab UI state, per-element flyout editor rendering, and
-- flyout-tab interaction handlers. User-triggered writes flow through the
-- public Settings facade only.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local SI = SettingsInternal

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local floor = math.floor
local getglobal = getglobal

local FLYOUT_CONTENT_WIDTH      = 332
local FLYOUT_MIN_CONTENT_HEIGHT = 360
local FLYOUT_MODE_DROPDOWN_NAME = "SNSSettingsFlyoutModeDropdown"
local FLYOUT_MOD_DROPDOWN_NAME  = "SNSSettingsFlyoutModDropdown"
local DROPDOWN_NAME_PREFIX      = "SNSSettingsFlyoutDirDropdown"

local BLOCK_TOP_OFFSET  = -160
local BLOCK_SIDE_INSET  = 12
local BLOCK_GAP         = 10
local BLOCK_BOTTOM_PAD  = 14
local BLOCK_MIN_HEIGHT  = 114
local ICON_AREA_TOP     = -52
local ICON_AREA_WIDTH   = 304
local ICON_SIZE         = 28
local ICON_GAP          = 4
local BUTTON_WIDTH      = 62
local BUTTON_GAP        = 6
local SELECT_TEXT_WIDTH = 156
local MOUSE_BUTTON_LEFT  = "LeftButton"
local MOUSE_BUTTON_RIGHT = "RightButton"

local DIRECTION_ORDER = {
    SI.FLYOUT_DIR_TOP,
    SI.FLYOUT_DIR_BOTTOM,
    SI.FLYOUT_DIR_LEFT,
    SI.FLYOUT_DIR_RIGHT,
}

local FLYOUT_MODE_ORDER = {
    SI.FLYOUT_MODE_FREE,
    SI.FLYOUT_MODE_DYNAMIC,
    SI.FLYOUT_MODE_CLOSED,
}

local FLYOUT_MOD_ORDER = {
    SI.MOD_SHIFT,
    SI.MOD_CTRL,
    SI.MOD_ALT,
}

local FLYOUT_MODE_LABELS = {
    [SI.FLYOUT_MODE_FREE]    = "Free",
    [SI.FLYOUT_MODE_DYNAMIC] = "Dynamic",
    [SI.FLYOUT_MODE_CLOSED]  = "Closed",
}

local FLYOUT_MOD_LABELS = {
    [SI.MOD_SHIFT] = "Shift",
    [SI.MOD_CTRL]  = "Ctrl",
    [SI.MOD_ALT]   = "Alt",
}

local DIRECTION_LABELS = {
    [SI.FLYOUT_DIR_TOP]    = "Top",
    [SI.FLYOUT_DIR_BOTTOM] = "Bottom",
    [SI.FLYOUT_DIR_LEFT]   = "Left",
    [SI.FLYOUT_DIR_RIGHT]  = "Right",
}

local BLOCK_BACKDROP = {
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    tile     = true,
    tileSize = 8,
    edgeSize = 1,
    insets   = { left = 1, right = 1, top = 1, bottom = 1 },
}

local ICON_CLICK_HANDLERS = {}

local state = {
    panel     = nil,
    isSyncing = false,
}

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function clearArray(array)
    local i

    if type(array) ~= "table" then return end

    for i = 1, table.getn(array) do
        array[i] = nil
    end
end

local function clearMap(map)
    local key

    if type(map) ~= "table" then return end

    for key in pairs(map) do
        map[key] = nil
    end
end

local function getCatalog()
    if not App or not App.GetCatalog then return nil end
    return App.GetCatalog()
end

local function getElementConfig(element)
    if type(SNSConfig) ~= "table" then return nil end
    if type(SNSConfig.elements) ~= "table" then return nil end
    return SNSConfig.elements[element]
end

local function getFlyoutModeLabel(mode)
    mode = SI.sanitizeFlyoutMode(mode)
    return FLYOUT_MODE_LABELS[mode] or FLYOUT_MODE_LABELS[SI.FLYOUT_MODE_FREE]
end

local function getFlyoutModLabel(mod)
    mod = SI.sanitizeFlyoutMod(mod)
    return FLYOUT_MOD_LABELS[mod] or FLYOUT_MOD_LABELS[SI.MOD_SHIFT]
end

local function getDirectionLabel(dir)
    return DIRECTION_LABELS[dir] or DIRECTION_LABELS.top
end

local function getDirectionDropdownName(element)
    return DROPDOWN_NAME_PREFIX .. tostring(element)
end

local function resolveDropdownFrame(ref)
    if type(ref) == "table" then return ref end
    if type(ref) == "string" and getglobal then
        return getglobal(ref)
    end
    return nil
end

local function syncFlyoutModeDropdown(dropdown, mode)
    if not dropdown then return end

    mode = SI.sanitizeFlyoutMode(mode)
    if UIDropDownMenu_SetSelectedValue then
        UIDropDownMenu_SetSelectedValue(dropdown, mode)
    end
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(getFlyoutModeLabel(mode), dropdown)
    end
end

local function syncFlyoutModDropdown(dropdown, mod)
    if not dropdown then return end

    mod = SI.sanitizeFlyoutMod(mod)
    if UIDropDownMenu_SetSelectedValue then
        UIDropDownMenu_SetSelectedValue(dropdown, mod)
    end
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(getFlyoutModLabel(mod), dropdown)
    end
end

local function syncDirectionDropdown(dropdown, dir)
    if not dropdown then return end

    dir = SI.sanitizeFlyoutDir(dir)
    if UIDropDownMenu_SetSelectedValue then
        UIDropDownMenu_SetSelectedValue(dropdown, dir)
    end
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(getDirectionLabel(dir), dropdown)
    end
end

local function getElementList(catalog, element)
    local byElement = catalog and catalog.byElement
    if type(byElement) ~= "table" then return nil end
    if type(byElement[element]) ~= "table" then return nil end
    return byElement[element]
end

local function getRecordForSpellId(catalog, spellId)
    local bySpellId = catalog and catalog.bySpellId
    if type(bySpellId) ~= "table" then return nil end
    return bySpellId[spellId]
end

local function buildCurrentByBaseName(catalog, element)
    local byBaseName = {}
    local list = getElementList(catalog, element)
    local i

    if type(list) ~= "table" then
        return byBaseName, nil
    end

    for i = 1, table.getn(list) do
        local record = list[i]
        if record and record.baseName then
            byBaseName[record.baseName] = record
        end
    end

    return byBaseName, list
end

local function buildCanonicalOrder(element, catalog, outOrder)
    local byBaseName, list = buildCurrentByBaseName(catalog, element)
    local seenBaseNames    = {}
    local cfg              = getElementConfig(element)
    local raw              = cfg and cfg.flyoutOrder or nil
    local count            = 0
    local i

    clearArray(outOrder)

    if type(raw) == "table" then
        for i = 1, table.getn(raw) do
            local record = getRecordForSpellId(catalog, raw[i])
            local current

            if record and record.element == element and record.baseName then
                current = byBaseName[record.baseName]
                if current and not seenBaseNames[current.baseName] then
                    count = count + 1
                    outOrder[count] = current.spellId
                    seenBaseNames[current.baseName] = true
                end
            end
        end
    end

    if type(list) == "table" then
        for i = 1, table.getn(list) do
            local record = list[i]

            if record and record.baseName and not seenBaseNames[record.baseName] then
                count = count + 1
                outOrder[count] = record.spellId
                seenBaseNames[record.baseName] = true
            end
        end
    end

    return byBaseName, count
end

local function buildHiddenBySpellId(element, catalog, byBaseName, outHidden)
    local cfg     = getElementConfig(element)
    local raw     = cfg and cfg.flyoutFilter or nil
    local spellId

    clearMap(outHidden)

    if type(raw) ~= "table" then return end

    for spellId, enabled in pairs(raw) do
        if enabled then
            local record = getRecordForSpellId(catalog, spellId)
            local current

            if record and record.element == element and record.baseName then
                current = byBaseName[record.baseName]
                if current then
                    outHidden[current.spellId] = true
                end
            end
        end
    end
end

local function findSpellIndex(order, count, spellId)
    local i

    if spellId == nil then return nil end

    for i = 1, count do
        if order[i] == spellId then
            return i
        end
    end

    return nil
end

local function getIconsPerRow(block)
    local width   = block and block.iconAreaWidth or ICON_AREA_WIDTH
    local spacing = ICON_SIZE + ICON_GAP
    local perRow

    if spacing <= 0 then return 1 end

    perRow = floor((width + ICON_GAP) / spacing)
    if perRow < 1 then
        perRow = 1
    end

    return perRow
end

local function getIconRowCount(iconCount, iconsPerRow)
    if iconCount and iconCount > 0 then
        return floor((iconCount - 1) / iconsPerRow) + 1
    end
    return 1
end

local function getIconAreaHeight(rowCount)
    return (rowCount * ICON_SIZE) + ((rowCount - 1) * ICON_GAP)
end

local function applyBlockSizing(block, iconCount)
    local iconsPerRow
    local rowCount
    local iconAreaHeight
    local blockHeight

    if not block then return end

    iconsPerRow = getIconsPerRow(block)
    rowCount = getIconRowCount(iconCount, iconsPerRow)
    iconAreaHeight = getIconAreaHeight(rowCount)
    blockHeight = 92 + iconAreaHeight + BLOCK_BOTTOM_PAD
    if blockHeight < BLOCK_MIN_HEIGHT then
        blockHeight = BLOCK_MIN_HEIGHT
    end

    block.iconsPerRow = iconsPerRow
    block.dynamicHeight = blockHeight
    block:SetHeight(blockHeight)
    if block.iconArea then
        block.iconArea:SetHeight(iconAreaHeight)
    end
end

local function relayoutBlocks(panel)
    local controls = panel and panel.controls or nil
    local content  = controls and controls.content or nil
    local blocks   = controls and controls.blocks or nil
    local y        = BLOCK_TOP_OFFSET
    local element

    if not content or type(blocks) ~= "table" then return end

    for element = 1, SI.MAX_ELEMENTS do
        local block = blocks[element]
        local height = block and block.dynamicHeight or BLOCK_MIN_HEIGHT

        if block then
            block:ClearAllPoints()
            block:SetPoint("TOPLEFT", content, "TOPLEFT", BLOCK_SIDE_INSET, y)
            block:SetPoint("TOPRIGHT", content, "TOPRIGHT", -BLOCK_SIDE_INSET, y)
            y = y - height - BLOCK_GAP
        end
    end

    local contentHeight = (-y) + 18
    if contentHeight < FLYOUT_MIN_CONTENT_HEIGHT then
        contentHeight = FLYOUT_MIN_CONTENT_HEIGHT
    end
    content:SetHeight(contentHeight)
end

local function resolveIconTexture(catalog, element, spellId)
    local record = getRecordForSpellId(catalog, spellId)
    if record and record.icon then
        return record.icon
    end
    return SI.FALLBACK_ICON
end

local function buildToggledFlyoutFilter(owner, spellId)
    local orderIndex
    local filter

    filter = {}
    for orderIndex = 1, owner.currentCount do
        local currentSpellId = owner.currentOrder[orderIndex]
        local shouldHide = owner.hiddenBySpellId[currentSpellId] and true or false

        if currentSpellId == spellId then
            shouldHide = not shouldHide
        end
        if shouldHide then
            filter[currentSpellId] = true
        end
    end

    return filter
end

local function onIconButtonClick()
    local owner   = this and this.block or nil
    local spellId = this and this.spellId or nil
    local handler = ICON_CLICK_HANDLERS[arg1]

    if not owner or not spellId or not handler then return end

    handler(owner, spellId)
end

local function ensureIconButton(block, index)
    local btn = block.iconButtons[index]

    if btn then return btn end

    btn = CreateFrame("Button", nil, block.iconArea)
    btn:SetWidth(ICON_SIZE)
    btn:SetHeight(ICON_SIZE)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetBackdrop(BLOCK_BACKDROP)
    btn:SetBackdropColor(0, 0, 0, 0.92)
    btn:SetBackdropBorderColor(0.20, 0.20, 0.20, 1.00)

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
    btn.icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)

    btn.dim = btn:CreateTexture(nil, "OVERLAY")
    btn.dim:SetAllPoints(btn.icon)
    btn.dim:SetTexture(0, 0, 0, 1)
    btn.dim:SetAlpha(0)

    btn.orderText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.orderText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    btn.orderText:SetTextColor(1, 1, 1, 1)

    btn.hiddenText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.hiddenText:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
    btn.hiddenText:SetTextColor(1, 0.40, 0.40, 1)
    btn.hiddenText:SetText("H")
    btn.hiddenText:Hide()

    btn.selectedOverlay = btn:CreateTexture(nil, "OVERLAY")
    btn.selectedOverlay:SetPoint("TOPLEFT", btn, "TOPLEFT", -1, 1)
    btn.selectedOverlay:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 1, -1)
    btn.selectedOverlay:SetTexture(0.20, 0.75, 1.00, 0.45)
    btn.selectedOverlay:Hide()

    btn.block = block
    btn:SetScript("OnClick", onIconButtonClick)

    block.iconButtons[index] = btn
    return btn
end

------------------------------------------------------------------------
-- Private handlers
------------------------------------------------------------------------

local function onFlyoutModeSelected()
    if state.isSyncing or not this then return end
    Settings.SetFlyoutMode(this.value)
end

local function initializeFlyoutModeDropdown()
    local selected
    local i

    if (UIDROPDOWNMENU_MENU_LEVEL or 1) ~= 1 then return end
    if not UIDropDownMenu_CreateInfo or not UIDropDownMenu_AddButton then return end

    selected = SI.sanitizeFlyoutMode(SNSConfig and SNSConfig.flyoutMode)
    for i = 1, table.getn(FLYOUT_MODE_ORDER) do
        local mode = FLYOUT_MODE_ORDER[i]
        local info = UIDropDownMenu_CreateInfo()

        info.text = getFlyoutModeLabel(mode)
        info.value = mode
        info.checked = (selected == mode) and 1 or nil
        info.func = onFlyoutModeSelected
        UIDropDownMenu_AddButton(info)
    end
end

local function onFlyoutModSelected()
    if state.isSyncing or not this then return end
    Settings.SetFlyoutModifier(this.value)
end

local function initializeFlyoutModDropdown()
    local selected
    local i

    if (UIDROPDOWNMENU_MENU_LEVEL or 1) ~= 1 then return end
    if not UIDropDownMenu_CreateInfo or not UIDropDownMenu_AddButton then return end

    selected = SI.sanitizeFlyoutMod(SNSConfig and SNSConfig.flyoutMod)
    for i = 1, table.getn(FLYOUT_MOD_ORDER) do
        local mod = FLYOUT_MOD_ORDER[i]
        local info = UIDropDownMenu_CreateInfo()

        info.text = getFlyoutModLabel(mod)
        info.value = mod
        info.checked = (selected == mod) and 1 or nil
        info.func = onFlyoutModSelected
        UIDropDownMenu_AddButton(info)
    end
end

local function refreshPanel(panel)
    local controls
    local catalog
    local element

    if panel then
        state.panel = panel
    end

    panel = state.panel
    controls = panel and panel.controls or nil
    if not controls then return end

    state.isSyncing = true
    syncFlyoutModeDropdown(controls.modeDropdown, SNSConfig and SNSConfig.flyoutMode)
    syncFlyoutModDropdown(controls.modDropdown, SNSConfig and SNSConfig.flyoutMod)

    catalog = getCatalog()
    if type(catalog) ~= "table" then
        state.isSyncing = false
        return
    end

    for element = 1, SI.MAX_ELEMENTS do
        local block = controls.blocks[element]
        local byBaseName
        local count
        local selectedIndex
        local i

        if block then
            byBaseName, count = buildCanonicalOrder(element, catalog, block.currentOrder)
            buildHiddenBySpellId(element, catalog, byBaseName, block.hiddenBySpellId)
            block.currentCount = count

            selectedIndex = findSpellIndex(block.currentOrder, count, block.selectedSpellId)
            if block.selectedSpellId and not selectedIndex then
                block.selectedSpellId = nil
            end

            syncDirectionDropdown(block.dirDropdown, getElementConfig(element) and getElementConfig(element).flyoutDir or nil)
            applyBlockSizing(block, count)

            for i = 1, count do
                local btn = ensureIconButton(block, i)
                local spellId = block.currentOrder[i]
                local col = math.mod(i - 1, block.iconsPerRow)
                local row = floor((i - 1) / block.iconsPerRow)
                local hidden = block.hiddenBySpellId[spellId] and true or false
                local selected = block.selectedSpellId == spellId

                btn.element = block.element
                btn.spellId = spellId
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", block.iconArea, "TOPLEFT", col * (ICON_SIZE + ICON_GAP), -row * (ICON_SIZE + ICON_GAP))
                btn.icon:SetTexture(resolveIconTexture(catalog, block.element, spellId))
                btn.orderText:SetText(tostring(i))

                if hidden then
                    btn.icon:SetAlpha(0.35)
                    btn.dim:SetAlpha(0.45)
                    btn.hiddenText:Show()
                else
                    btn.icon:SetAlpha(1.0)
                    btn.dim:SetAlpha(0)
                    btn.hiddenText:Hide()
                end

                if selected then
                    btn.selectedOverlay:Show()
                    btn:SetBackdropBorderColor(0.45, 0.85, 1.00, 1.00)
                else
                    btn.selectedOverlay:Hide()
                    btn:SetBackdropBorderColor(0.20, 0.20, 0.20, 1.00)
                end

                btn:Show()
            end

            for i = count + 1, table.getn(block.iconButtons) do
                local btn = block.iconButtons[i]

                if btn then
                    btn.spellId = nil
                    btn:Hide()
                end
            end

            selectedIndex = findSpellIndex(block.currentOrder, count, block.selectedSpellId)
            SI.setButtonEnabled(block.earlierButton, selectedIndex and selectedIndex > 1)
            SI.setButtonEnabled(block.laterButton, selectedIndex and selectedIndex < count)

            if block.selectionText then
                if count <= 0 then
                    block.selectionText:SetText("No totems learned for this element yet.")
                elseif selectedIndex then
                    block.selectionText:SetText("Selected: #" .. tostring(selectedIndex))
                else
                    block.selectionText:SetText("Select an icon to reorder it.")
                end
            end
        end
    end

    relayoutBlocks(panel)
    state.isSyncing = false
end

local function handleIconLeftClick(owner, spellId)
    owner.selectedSpellId = spellId
    refreshPanel(state.panel)
end

local function handleIconRightClick(owner, spellId)
    Settings.SetElementFlyoutFilter(owner.element, buildToggledFlyoutFilter(owner, spellId))
end

ICON_CLICK_HANDLERS[MOUSE_BUTTON_LEFT] = handleIconLeftClick
ICON_CLICK_HANDLERS[MOUSE_BUTTON_RIGHT] = handleIconRightClick

local function onDirectionSelected()
    local dropdown
    local element

    if state.isSyncing or not this then return end

    dropdown = resolveDropdownFrame(UIDROPDOWNMENU_INIT_MENU or UIDROPDOWNMENU_OPEN_MENU or this)
    element = this.element or this.arg1 or (dropdown and dropdown.element) or nil
    if not element then return end

    Settings.SetElementFlyoutDirection(element, this.value)
end

local function initializeDirectionDropdown()
    local dropdown
    local element
    local cfg
    local selected
    local i

    if (UIDROPDOWNMENU_MENU_LEVEL or 1) ~= 1 then return end
    if not UIDropDownMenu_CreateInfo or not UIDropDownMenu_AddButton then return end

    dropdown = resolveDropdownFrame(UIDROPDOWNMENU_INIT_MENU or this)
    element = dropdown and dropdown.element or nil
    if not element then return end

    cfg = getElementConfig(element)
    selected = cfg and SI.sanitizeFlyoutDir(cfg.flyoutDir) or SI.sanitizeFlyoutDir(nil)

    for i = 1, table.getn(DIRECTION_ORDER) do
        local dir = DIRECTION_ORDER[i]
        local info = UIDropDownMenu_CreateInfo()

        info.text = getDirectionLabel(dir)
        info.value = dir
        info.checked = (selected == dir) and 1 or nil
        info.func = onDirectionSelected
        info.element = element
        info.arg1 = element
        UIDropDownMenu_AddButton(info)
    end
end

local function onMoveButtonClick()
    local block       = this and this.block or nil
    local delta       = this and this.delta or nil
    local fromIndex
    local targetIndex
    local newOrder
    local i

    if not block or type(delta) ~= "number" then return end

    fromIndex = findSpellIndex(block.currentOrder, block.currentCount, block.selectedSpellId)
    if not fromIndex then
        block.selectedSpellId = nil
        refreshPanel(state.panel)
        return
    end

    targetIndex = fromIndex + delta
    if targetIndex < 1 or targetIndex > block.currentCount then return end

    newOrder = {}
    for i = 1, block.currentCount do
        newOrder[i] = block.currentOrder[i]
    end

    newOrder[fromIndex], newOrder[targetIndex] = newOrder[targetIndex], newOrder[fromIndex]
    Settings.SetElementFlyoutOrder(block.element, newOrder)
end

------------------------------------------------------------------------
-- Private builders
------------------------------------------------------------------------

local function createElementBlock(parent, element)
    local block          = CreateFrame("Frame", nil, parent)
    local title          = block:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local directionLabel = block:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    local dirDropdown    = SI.createDropdown(getDirectionDropdownName(element), block, 56, -21, 84, initializeDirectionDropdown)
    local iconArea       = CreateFrame("Frame", nil, block)
    local earlierButton
    local laterButton
    local selectionText
    local hintText

    block.element         = element
    block:SetBackdrop(BLOCK_BACKDROP)
    block:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
    block:SetBackdropBorderColor(0.20, 0.20, 0.20, 1.00)
    block.iconButtons     = {}
    block.currentOrder    = {}
    block.currentCount    = 0
    block.hiddenBySpellId = {}
    block.selectedSpellId = nil

    title:SetPoint("TOPLEFT", block, "TOPLEFT", 8, -8)
    title:SetTextColor(1.00, 0.82, 0.00, 1.00)
    title:SetText(SI.getElementName(element))
    block.title = title

    directionLabel:SetPoint("TOPLEFT", block, "TOPLEFT", 8, -28)
    directionLabel:SetTextColor(1.00, 0.82, 0.00, 1.00)
    directionLabel:SetText("Direction")
    block.directionLabel = directionLabel

    dirDropdown.element = element
    block.dirDropdown = dirDropdown

    iconArea:SetPoint("TOPLEFT", block, "TOPLEFT", 8, ICON_AREA_TOP)
    iconArea:SetWidth(ICON_AREA_WIDTH)
    iconArea:SetHeight(ICON_SIZE)
    block.iconArea = iconArea
    block.iconAreaWidth = ICON_AREA_WIDTH

    earlierButton = SI.createActionButton(block, BUTTON_WIDTH, 8, -1, "Earlier", onMoveButtonClick)
    earlierButton:ClearAllPoints()
    earlierButton:SetPoint("TOPLEFT", iconArea, "BOTTOMLEFT", 0, -8)
    earlierButton.block = block
    earlierButton.delta = -1
    block.earlierButton = earlierButton

    laterButton = SI.createActionButton(block, BUTTON_WIDTH, 8 + BUTTON_WIDTH + BUTTON_GAP, -1, "Later", onMoveButtonClick)
    laterButton:ClearAllPoints()
    laterButton:SetPoint("TOPLEFT", iconArea, "BOTTOMLEFT", BUTTON_WIDTH + BUTTON_GAP, -8)
    laterButton.block = block
    laterButton.delta = 1
    block.laterButton = laterButton

    selectionText = block:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    selectionText:SetPoint("TOPLEFT", iconArea, "BOTTOMLEFT", 140, -10)
    selectionText:SetWidth(SELECT_TEXT_WIDTH)
    selectionText:SetJustifyH("LEFT")
    selectionText:SetTextColor(1.00, 0.82, 0.00, 1.00)
    selectionText:SetText("")
    block.selectionText = selectionText

    hintText = block:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hintText:SetPoint("TOPLEFT", selectionText, "BOTTOMLEFT", 0, -2)
    hintText:SetWidth(SELECT_TEXT_WIDTH)
    hintText:SetJustifyH("LEFT")
    hintText:SetTextColor(0.82, 0.82, 0.82, 1.00)
    hintText:SetText("LMB selects. RMB hides or shows.")
    block.hintText = hintText

    applyBlockSizing(block, 0)
    return block
end

local function buildPanel(panel)
    local controls    = {}
    local content     = panel.contentFrame or panel
    local title       = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    local hint        = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    local modeLabel   = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    local modLabel    = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    local editorTitle = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    local editorHint  = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    local element

    state.panel = panel
    panel.controls = controls
    controls.content = content
    controls.blocks = {}

    title:SetPoint("TOPLEFT", content, "TOPLEFT", 18, -10)
    title:SetText("Flyout Behavior")
    controls.title = title

    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetWidth(296)
    hint:SetJustifyH("LEFT")
    hint:SetText("Free opens on hover. Dynamic opens only while its modifier is held. Closed suppresses flyouts entirely.")
    controls.hint = hint

    modeLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 18, -58)
    modeLabel:SetText("Mode")
    controls.modeLabel = modeLabel

    controls.modeDropdown = SI.createDropdown(
        FLYOUT_MODE_DROPDOWN_NAME,
        content,
        8,
        -72,
        98,
        initializeFlyoutModeDropdown
    )

    modLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 174, -58)
    modLabel:SetText("Dynamic Modifier")
    controls.modLabel = modLabel

    controls.modDropdown = SI.createDropdown(
        FLYOUT_MOD_DROPDOWN_NAME,
        content,
        156,
        -72,
        98,
        initializeFlyoutModDropdown
    )

    editorTitle:SetPoint("TOPLEFT", content, "TOPLEFT", 18, -110)
    editorTitle:SetText("Per-element Flyout Editor")
    controls.editorTitle = editorTitle

    editorHint:SetPoint("TOPLEFT", editorTitle, "BOTTOMLEFT", 0, -6)
    editorHint:SetWidth(296)
    editorHint:SetJustifyH("LEFT")
    editorHint:SetText("Choose where each flyout opens, then reorder or hide individual totems.")
    controls.editorHint = editorHint

    for element = 1, SI.MAX_ELEMENTS do
        controls.blocks[element] = createElementBlock(content, element)
    end

    relayoutBlocks(panel)
end

------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------

if SI.RegisterUITab then
    SI.RegisterUITab(SI.UI_TAB_FLYOUTS, {
        Build = buildPanel,
        Refresh = refreshPanel,
        Scrollable = true,
        ContentWidth = FLYOUT_CONTENT_WIDTH,
    })
end
