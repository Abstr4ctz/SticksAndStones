-- SticksAndStones: Settings/UI.lua
-- Settings window shell/orchestrator module for the Settings pod.
-- Owns SettingsInternal.UI plus the shell runtime state: root frame, tab
-- buttons, tab panels, same-session active-tab memory, and shared UI
-- primitives for Settings tab modules.
-- Side effects: creates WoW UI frames lazily on first open, registers the
-- settings frame for Escape-key closing, and exports internal tab-registration
-- helpers on SettingsInternal.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M  = {}
local SI = SettingsInternal

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local WINDOW_NAME           = "SNSSettingsFrame"
local WINDOW_WIDTH          = 432
local WINDOW_HEIGHT         = 488
local HEADER_HEIGHT         = 30
local TAB_WIDTH             = 92
local TAB_HEIGHT            = 24
local TAB_GAP               = 8
local CONTENT_TOP_GAP       = 96
local CONTENT_INSET         = 14
local SCROLL_RIGHT_INSET    = 26
local PLACEHOLDER_TEXT      = "This tab is not built yet."
local CHAT_PREFIX           = "SticksAndStones: "
local PROFILE_DIALOG_NAME   = "SNSSettingsProfileDialog"
local PROFILE_DIALOG_WIDTH  = 392
local PROFILE_DIALOG_HEIGHT = 300
local PROFILE_DIALOG_BUTTON_WIDTH = 86

local PROFILE_DIALOG_MODE_EXPORT = "export"
local PROFILE_DIALOG_MODE_IMPORT = "import"
local RESET_CONFIRMATION_POPUP_ID = "SNSSettingsResetConfirmation"
local RESET_MODE_GENERAL_UI       = "general_ui"
local RESET_MODE_ACTIVE_PROFILE   = "active_profile"

local TAB_GENERAL  = 1
local TAB_SETS     = 2
local TAB_FLYOUTS  = 3
local TAB_ADVANCED = 4

local DEFAULT_TAB_ID = TAB_GENERAL

local TAB_ORDER = {
    TAB_GENERAL,
    TAB_SETS,
    TAB_FLYOUTS,
    TAB_ADVANCED,
}

local TAB_LABELS = {
    [TAB_GENERAL]  = "General",
    [TAB_SETS]     = "Sets",
    [TAB_FLYOUTS]  = "Flyouts",
    [TAB_ADVANCED] = "Advanced",
}

local WINDOW_BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true,
    tileSize = 16,
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
}

local PANEL_BACKDROP = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true,
    tileSize = 16,
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
}

local PROFILE_DIALOG_EDIT_BACKDROP = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true,
    tileSize = 16,
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
}

local TAB_BACKDROP = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true,
    tileSize = 16,
    edgeSize = 10,
    insets   = { left = 2, right = 2, top = 2, bottom = 2 },
}

local TAB_VISUALS = {
    selected = {
        bgR = 0.18, bgG = 0.18, bgB = 0.18, bgA = 1.00,
        edgeR = 0.95, edgeG = 0.82, edgeB = 0.38, edgeA = 1.00,
        textR = 1.00, textG = 0.93, textB = 0.62,
    },
    normal = {
        bgR = 0.08, bgG = 0.08, bgB = 0.08, bgA = 0.95,
        edgeR = 0.35, edgeG = 0.35, edgeB = 0.35, edgeA = 1.00,
        textR = 0.82, textG = 0.82, textB = 0.82,
    },
}

local FALLBACK_ICON = "Interface\\Icons\\Spell_Totem_WardOfDraining"

local tabDefinitions = {}

local state = {
    frame                 = nil,
    tabs                  = {},
    panels                = {},
    activeTabId           = DEFAULT_TAB_ID,
    profileDialog         = nil,
    resetConfirmationMode = nil,
}

local PROFILE_DIALOG_MODE_CONFIGS = {
    [PROFILE_DIALOG_MODE_EXPORT] = {
        title            = "Export Profile",
        description      = "Copy this text and share it.",
        confirmText      = "Close",
        shouldShowCancel = nil,
        shouldHighlight  = true,
        useProvidedText  = true,
    },
    [PROFILE_DIALOG_MODE_IMPORT] = {
        title            = "Import Profile",
        description      = "Paste exported profile text below.",
        confirmText      = "Import",
        shouldShowCancel = true,
        shouldHighlight  = nil,
        defaultText      = "",
    },
}

local PROFILE_DIALOG_CONFIRM_HANDLERS = {}
local RESET_MODE_CONFIGS = {
    [RESET_MODE_GENERAL_UI] = {
        text        = "Reset General UI settings and button positions to defaults?",
        confirmText = "Reset",
        chatMessage = "General UI reset to defaults.",
    },
    [RESET_MODE_ACTIVE_PROFILE] = {
        text        = "Reset the full active profile to default settings?",
        confirmText = "Reset",
        chatMessage = "Full profile reset to defaults.",
    },
}
local RESET_MODE_HANDLERS = {}

------------------------------------------------------------------------
-- Shared UI primitives
------------------------------------------------------------------------

local function printChat(message)
    if DEFAULT_CHAT_FRAME and type(message) == "string" then
        DEFAULT_CHAT_FRAME:AddMessage(message)
    end
end

local function setChecked(button, value)
    if not button then return end
    button:SetChecked(value and 1 or nil)
end

local function setButtonEnabled(button, enabled)
    if not button then return end

    if enabled then
        button:Enable()
        button:SetAlpha(1)
        return
    end

    button:Disable()
    button:SetAlpha(0.55)
end

local function createActionButton(parent, width, xOffset, yOffset, label, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")

    button:SetWidth(width)
    button:SetHeight(22)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", xOffset, yOffset)
    button:SetText(label)
    button:SetScript("OnClick", onClick)
    return button
end

local function createCheckboxRow(parent, yOffset, labelText, onClick)
    local button = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    local label = button:CreateFontString(nil, "ARTWORK", "GameFontNormal")

    button:SetWidth(24)
    button:SetHeight(24)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yOffset)
    button:SetScript("OnClick", onClick)

    label:SetPoint("LEFT", button, "RIGHT", 2, 0)
    label:SetJustifyH("LEFT")
    label:SetText(labelText)

    button.label = label
    return button
end

local function createDropdown(name, parent, x, y, width, initializeFunc)
    local dropdown = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")

    dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    if UIDropDownMenu_Initialize then
        UIDropDownMenu_Initialize(dropdown, initializeFunc)
    end
    if UIDropDownMenu_SetWidth then
        UIDropDownMenu_SetWidth(width, dropdown)
    end
    if UIDropDownMenu_JustifyText then
        UIDropDownMenu_JustifyText("LEFT", dropdown)
    end
    return dropdown
end

local function getElementName(element)
    local name = SNS.ELEMENT_NAMES[element]
    if name then return name end
    return "Element " .. tostring(element)
end

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function ensureEscapeCloseRegistration()
    local frameList = UISpecialFrames
    local i

    if type(frameList) ~= "table" then return end

    for i = 1, table.getn(frameList) do
        if frameList[i] == WINDOW_NAME then
            return
        end
    end

    frameList[table.getn(frameList) + 1] = WINDOW_NAME
end

local function buildShellWidgetName(tabId, suffix)
    return WINDOW_NAME .. "Tab" .. tostring(tabId) .. suffix
end

local function resolveProfileDialogText(modeConfig, text)
    if modeConfig.useProvidedText then
        return text or ""
    end
    return modeConfig.defaultText or ""
end

local function clearResetConfirmationMode()
    state.resetConfirmationMode = nil
end

local function runResetMode(mode)
    local modeConfig = RESET_MODE_CONFIGS[mode]
    local handler = RESET_MODE_HANDLERS[mode]
    local ok

    clearResetConfirmationMode()
    if not modeConfig or not handler then return nil end

    if SI.DismissGeneralColorPicker then
        SI.DismissGeneralColorPicker()
    end

    ok = handler()
    if ok and modeConfig.chatMessage then
        printChat(CHAT_PREFIX .. modeConfig.chatMessage)
    end
    return ok
end

local function handleResetPopupAccept()
    local mode = state.resetConfirmationMode

    if type(StaticPopup_Hide) == "function" then
        StaticPopup_Hide(RESET_CONFIRMATION_POPUP_ID)
    end

    return runResetMode(mode)
end

local function handleResetPopupCancel()
    clearResetConfirmationMode()
end

local function ensureResetConfirmationPopup()
    if type(StaticPopupDialogs) ~= "table" then return nil end
    if StaticPopupDialogs[RESET_CONFIRMATION_POPUP_ID] then return true end

    StaticPopupDialogs[RESET_CONFIRMATION_POPUP_ID] = {
        text           = "",
        button1        = "Reset",
        button2        = "Cancel",
        OnAccept       = handleResetPopupAccept,
        OnCancel       = handleResetPopupCancel,
        timeout        = 0,
        whileDead      = 1,
        hideOnEscape   = 1,
        preferredIndex = 3,
    }
    return true
end

local function showResetConfirmation(mode)
    local modeConfig = RESET_MODE_CONFIGS[mode]
    local dialog

    if not modeConfig then return nil end

    state.resetConfirmationMode = mode

    if ensureResetConfirmationPopup() and type(StaticPopup_Show) == "function" then
        dialog = StaticPopupDialogs[RESET_CONFIRMATION_POPUP_ID]
        if dialog then
            dialog.text = modeConfig.text
            dialog.button1 = modeConfig.confirmText
            dialog.button2 = "Cancel"
        end

        StaticPopup_Show(RESET_CONFIRMATION_POPUP_ID)
        return true
    end

    return runResetMode(mode)
end

local function isKnownTabId(tabId)
    local i

    for i = 1, table.getn(TAB_ORDER) do
        if TAB_ORDER[i] == tabId then
            return true
        end
    end

    return nil
end

local function createScrollablePanel(panel, tabId, contentWidth)
    local scrollName = buildShellWidgetName(tabId, "ScrollFrame")
    local scroll = CreateFrame("ScrollFrame", scrollName, panel, "UIPanelScrollFrameTemplate")
    local content = CreateFrame("Frame", nil, scroll)

    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -SCROLL_RIGHT_INSET, 0)
    scroll:SetVerticalScroll(0)

    content:SetWidth(contentWidth)
    content:SetHeight(1)
    scroll:SetScrollChild(content)

    return scroll, content
end

local function getProfileDialogScrollBar()
    local dialog = state.profileDialog
    local scroll = dialog and dialog.scrollFrame or nil
    local name

    if not scroll then return nil end

    name = scroll:GetName()
    if not name then return nil end

    return getglobal(name .. "ScrollBar")
end

local function updateProfileDialogScroll(resetToTop)
    local dialog        = state.profileDialog
    local scroll        = dialog and dialog.scrollFrame or nil
    local edit          = dialog and dialog.editBox or nil
    local measure       = dialog and dialog.measureText or nil
    local viewWidth
    local viewHeight
    local contentHeight
    local maxValue
    local value
    local scrollBar
    local upButton
    local downButton

    if not scroll or not edit or not measure then return end

    viewWidth = scroll:GetWidth() or 0
    if viewWidth < 32 then viewWidth = 32 end
    edit:SetWidth(viewWidth)
    measure:SetWidth(viewWidth)
    measure:SetText(edit:GetText() or "")

    viewHeight = scroll:GetHeight() or 0
    if viewHeight < 1 then viewHeight = 1 end

    contentHeight = (measure:GetHeight() or 0) + 24
    if contentHeight < viewHeight then
        contentHeight = viewHeight
    end
    edit:SetHeight(contentHeight)

    if scroll.UpdateScrollChildRect then
        scroll:UpdateScrollChildRect()
    end

    maxValue = contentHeight - viewHeight
    if maxValue < 0 then maxValue = 0 end

    value = scroll:GetVerticalScroll() or 0
    if resetToTop then value = 0 end
    if value > maxValue then value = maxValue end
    if value < 0 then value = 0 end
    scroll:SetVerticalScroll(value)

    scrollBar = getProfileDialogScrollBar()
    if not scrollBar then return end

    scrollBar:SetMinMaxValues(0, maxValue)
    scrollBar:SetValue(value)

    if maxValue > 0 then
        scrollBar:Show()
    else
        scrollBar:Hide()
    end

    upButton = getglobal(scrollBar:GetName() .. "ScrollUpButton")
    downButton = getglobal(scrollBar:GetName() .. "ScrollDownButton")

    if upButton then
        if value <= 0 then
            upButton:Disable()
        else
            upButton:Enable()
        end
    end
    if downButton then
        if value >= maxValue then
            downButton:Disable()
        else
            downButton:Enable()
        end
    end
end

local function buildPlaceholderPanel(panel, definition)
    local parent = panel.contentFrame or panel
    local title  = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local text   = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local width  = WINDOW_WIDTH - 64

    if definition and type(definition.ContentWidth) == "number" then
        width = definition.ContentWidth - 24
    end
    if width < 120 then
        width = WINDOW_WIDTH - 64
    end

    title:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -16)
    title:SetText(TAB_LABELS[panel.tabId] or "")

    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    text:SetWidth(width)
    text:SetJustifyH("LEFT")
    text:SetTextColor(0.80, 0.80, 0.80)
    text:SetText((definition and definition.PlaceholderText) or PLACEHOLDER_TEXT)
end

local function refreshActivePanel()
    local panel = state.panels[state.activeTabId]
    local definition

    if not panel then return end

    definition = tabDefinitions[panel.tabId]
    if definition and definition.Refresh then
        definition.Refresh(panel)
    end
end

local function applyTabVisual(button, isSelected)
    local visual = TAB_VISUALS.normal

    if isSelected then
        visual = TAB_VISUALS.selected
    end

    button:SetBackdropColor(visual.bgR, visual.bgG, visual.bgB, visual.bgA)
    button:SetBackdropBorderColor(visual.edgeR, visual.edgeG, visual.edgeB, visual.edgeA)
    button.text:SetTextColor(visual.textR, visual.textG, visual.textB)
end

local function hideProfileDialog()
    local dialog = state.profileDialog
    local frame = dialog and dialog.frame or nil

    if not frame then return end

    dialog.mode = nil
    frame:Hide()
end

local function selectTab(tabId)
    local index
    local previousTabId

    if not state.frame then return end
    previousTabId = state.activeTabId
    if not state.panels[tabId] then
        tabId = DEFAULT_TAB_ID
    end
    if not state.panels[tabId] then return end
    if previousTabId and previousTabId ~= tabId then
        hideProfileDialog()
    end

    state.activeTabId = tabId

    for index = 1, table.getn(TAB_ORDER) do
        local currentId = TAB_ORDER[index]
        local isSelected = currentId == tabId
        local panel = state.panels[currentId]
        local button = state.tabs[currentId]

        if panel then
            if isSelected then
                panel:Show()
            else
                panel:Hide()
            end
        end

        if button then
            applyTabVisual(button, isSelected)
        end
    end

    refreshActivePanel()
end

local function registerUITab(tabId, definition)
    if not isKnownTabId(tabId) then return nil end
    if type(definition) ~= "table" then return nil end
    if tabDefinitions[tabId] then return nil end
    if definition.Build ~= nil and type(definition.Build) ~= "function" then return nil end
    if definition.Refresh ~= nil and type(definition.Refresh) ~= "function" then return nil end
    if definition.Scrollable ~= nil and type(definition.Scrollable) ~= "boolean" then return nil end
    if definition.Scrollable and type(definition.ContentWidth) ~= "number" then return nil end
    if definition.PlaceholderText ~= nil and type(definition.PlaceholderText) ~= "string" then return nil end

    tabDefinitions[tabId] = definition
    return definition
end

local function createRootFrame()
    local root = CreateFrame("Frame", WINDOW_NAME, UIParent)
    local titleBar = root:CreateTexture(nil, "ARTWORK")
    local title = root:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    local subtitle = root:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local closeButton = CreateFrame("Button", nil, root, "UIPanelCloseButton")

    root:SetWidth(WINDOW_WIDTH)
    root:SetHeight(WINDOW_HEIGHT)
    root:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    root:SetFrameStrata("DIALOG")
    root:SetMovable(true)
    root:SetClampedToScreen(true)
    root:EnableMouse(true)
    root:RegisterForDrag("LeftButton")
    root:SetBackdrop(WINDOW_BACKDROP)
    root:SetBackdropColor(0.05, 0.05, 0.05, 0.96)
    root:SetBackdropBorderColor(0.50, 0.50, 0.50, 1.00)

    titleBar:SetPoint("TOPLEFT", root, "TOPLEFT", 8, -8)
    titleBar:SetPoint("TOPRIGHT", root, "TOPRIGHT", -8, -8)
    titleBar:SetHeight(HEADER_HEIGHT)
    titleBar:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    titleBar:SetVertexColor(0.12, 0.12, 0.12, 0.90)

    title:SetPoint("TOPLEFT", root, "TOPLEFT", 18, -15)
    title:SetText("Sticks and Stones")

    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    subtitle:SetText("Settings")

    closeButton:SetPoint("TOPRIGHT", root, "TOPRIGHT", -6, -6)

    root.closeButton = closeButton
    return root
end

local function createTabButton(parent, tabId, xOffset)
    local button = CreateFrame("Button", nil, parent)
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

    button:SetWidth(TAB_WIDTH)
    button:SetHeight(TAB_HEIGHT)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", xOffset, -48)
    button:RegisterForClicks("LeftButtonUp")
    button:SetBackdrop(TAB_BACKDROP)

    text:SetPoint("CENTER", button, "CENTER", 0, 0)
    text:SetText(TAB_LABELS[tabId])

    button.text = text
    button.tabId = tabId
    return button
end

local function createContentFrame(parent)
    local content = CreateFrame("Frame", nil, parent)

    content:SetPoint("TOPLEFT", parent, "TOPLEFT", CONTENT_INSET, -CONTENT_TOP_GAP)
    content:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -CONTENT_INSET, CONTENT_INSET)
    content:SetBackdrop(PANEL_BACKDROP)
    content:SetBackdropColor(0.02, 0.02, 0.02, 0.92)
    content:SetBackdropBorderColor(0.35, 0.35, 0.35, 1.00)

    return content
end

local function createTabPanel(parent, tabId)
    local panel = CreateFrame("Frame", nil, parent)
    local definition = tabDefinitions[tabId]

    panel:SetAllPoints(parent)
    panel.tabId = tabId

    if definition and definition.Scrollable then
        panel.scrollFrame, panel.contentFrame = createScrollablePanel(panel, tabId, definition.ContentWidth)
    end

    if definition and definition.Build then
        definition.Build(panel)
    else
        buildPlaceholderPanel(panel, definition)
    end

    panel:Hide()
    return panel
end

------------------------------------------------------------------------
-- Private handlers
------------------------------------------------------------------------

local function onFrameDragStart()
    this:StartMoving()
end

local function onFrameDragStop()
    this:StopMovingOrSizing()
end

local function onCloseButtonClick()
    M.Hide()
end

local function onTabButtonClick()
    if not this or not this.tabId then return end
    selectTab(this.tabId)
end

local function onProfileDialogScrollSizeChanged()
    updateProfileDialogScroll(nil)
end

local function onProfileDialogEditTextChanged()
    updateProfileDialogScroll(nil)
end

local function onProfileDialogEditCursorChanged()
    local dialog       = state.profileDialog
    local scroll       = dialog and dialog.scrollFrame or nil
    local viewHeight
    local cursorY
    local cursorHeight
    local value
    local scrollBar

    if not scroll then return end

    viewHeight = scroll:GetHeight() or 0
    if viewHeight <= 0 then return end

    cursorY = tonumber(arg2) or 0
    cursorHeight = tonumber(arg4) or 0
    value = scroll:GetVerticalScroll() or 0

    if cursorY < value then
        value = cursorY
    elseif (cursorY + cursorHeight) > (value + viewHeight) then
        value = cursorY + cursorHeight - viewHeight
    else
        return
    end

    if value < 0 then value = 0 end
    scroll:SetVerticalScroll(value)

    scrollBar = getProfileDialogScrollBar()
    if scrollBar then
        scrollBar:SetValue(value)
    end
end

local function handleProfileDialogExportConfirm()
    hideProfileDialog()
end

local function handleProfileDialogImportConfirm()
    local dialog = state.profileDialog
    local edit = dialog and dialog.editBox or nil
    local text
    local newKey
    local err

    if not edit or not Settings.ImportProfile then
        hideProfileDialog()
        return
    end

    text = edit:GetText()
    newKey, err = Settings.ImportProfile(text)
    if not newKey then
        printChat(CHAT_PREFIX .. "import failed (" .. tostring(err or "?") .. ").")
        return
    end

    if SI.SetAdvancedSelectedProfileKey then
        SI.SetAdvancedSelectedProfileKey(newKey)
    end

    hideProfileDialog()
    printChat(CHAT_PREFIX .. "imported profile: " .. newKey)
end

local function handleGeneralResetConfirm()
    if not Settings or not Settings.ResetGeneralToDefaults then return nil end
    return Settings.ResetGeneralToDefaults()
end

local function handleActiveProfileResetConfirm()
    if not Settings or not Settings.ResetToDefaults then return nil end
    return Settings.ResetToDefaults()
end

PROFILE_DIALOG_CONFIRM_HANDLERS[PROFILE_DIALOG_MODE_EXPORT] = handleProfileDialogExportConfirm
PROFILE_DIALOG_CONFIRM_HANDLERS[PROFILE_DIALOG_MODE_IMPORT] = handleProfileDialogImportConfirm
RESET_MODE_HANDLERS[RESET_MODE_GENERAL_UI] = handleGeneralResetConfirm
RESET_MODE_HANDLERS[RESET_MODE_ACTIVE_PROFILE] = handleActiveProfileResetConfirm

local function onProfileDialogCancelClick()
    hideProfileDialog()
end

local function onProfileDialogConfirmClick()
    local dialog = state.profileDialog
    local mode = dialog and dialog.mode or nil
    local handler = PROFILE_DIALOG_CONFIRM_HANDLERS[mode]

    if not handler then
        hideProfileDialog()
        return
    end

    handler()
end

local function createProfileDialog(parent)
    local dialog = {}
    local frame = CreateFrame("Frame", PROFILE_DIALOG_NAME, parent)
    local content = CreateFrame("Frame", nil, frame)
    local title = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local description = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    local closeButton = CreateFrame("Button", nil, content, "UIPanelCloseButton")
    local editBackground = CreateFrame("Frame", nil, content)
    local scroll = CreateFrame("ScrollFrame", PROFILE_DIALOG_NAME .. "ScrollFrame", editBackground, "UIPanelScrollFrameTemplate")
    local edit = CreateFrame("EditBox", PROFILE_DIALOG_NAME .. "Edit", scroll)
    local measure = editBackground:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    local confirmButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    local cancelButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    local scrollBar

    frame:SetWidth(PROFILE_DIALOG_WIDTH)
    frame:SetHeight(PROFILE_DIALOG_HEIGHT)
    frame:SetPoint("CENTER", parent, "CENTER", 0, 0)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetToplevel(true)
    frame:EnableMouse(false)
    frame:SetBackdrop(WINDOW_BACKDROP)
    frame:SetBackdropColor(0.06, 0.06, 0.06, 0.98)

    content:SetAllPoints(frame)
    content:SetFrameLevel(frame:GetFrameLevel() + 2)

    title:SetPoint("TOPLEFT", content, "TOPLEFT", 16, -14)
    title:SetText("Profile")

    description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    description:SetText("Profile text")

    closeButton:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -4)

    editBackground:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -54)
    editBackground:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -14, 44)
    editBackground:SetBackdrop(PROFILE_DIALOG_EDIT_BACKDROP)
    editBackground:SetBackdropColor(0, 0, 0, 0.9)

    scroll:SetPoint("TOPLEFT", editBackground, "TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", editBackground, "BOTTOMRIGHT", -30, 8)
    scroll:SetVerticalScroll(0)

    edit:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    edit:SetAutoFocus(false)
    edit:SetMultiLine(true)
    edit:SetMaxLetters(0)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(240)
    edit:SetHeight(120)
    scroll:SetScrollChild(edit)

    measure:SetPoint("TOPLEFT", editBackground, "TOPLEFT", 8, -8)
    measure:SetJustifyH("LEFT")
    measure:SetJustifyV("TOP")
    measure:SetWidth(240)
    measure:SetText("")
    measure:SetAlpha(0)

    scrollBar = getglobal((scroll:GetName() or "") .. "ScrollBar")
    if scrollBar then
        scrollBar:SetMinMaxValues(0, 0)
        scrollBar:SetValue(0)
        scrollBar:Hide()
    end

    confirmButton:SetWidth(PROFILE_DIALOG_BUTTON_WIDTH)
    confirmButton:SetHeight(22)
    confirmButton:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -14, 14)
    confirmButton:SetText("OK")

    cancelButton:SetWidth(PROFILE_DIALOG_BUTTON_WIDTH)
    cancelButton:SetHeight(22)
    cancelButton:SetPoint("RIGHT", confirmButton, "LEFT", -6, 0)
    cancelButton:SetText("Cancel")

    dialog.frame         = frame
    dialog.contentFrame  = content
    dialog.mode          = nil
    dialog.title         = title
    dialog.description   = description
    dialog.scrollFrame   = scroll
    dialog.editBox       = edit
    dialog.measureText   = measure
    dialog.confirmButton = confirmButton
    dialog.cancelButton  = cancelButton

    scroll:SetScript("OnSizeChanged", onProfileDialogScrollSizeChanged)
    edit:SetScript("OnEscapePressed", onProfileDialogCancelClick)
    edit:SetScript("OnTextChanged", onProfileDialogEditTextChanged)
    edit:SetScript("OnCursorChanged", onProfileDialogEditCursorChanged)
    closeButton:SetScript("OnClick", onProfileDialogCancelClick)
    confirmButton:SetScript("OnClick", onProfileDialogConfirmClick)
    cancelButton:SetScript("OnClick", onProfileDialogCancelClick)

    frame:Hide()
    return dialog
end

local function wireRootScripts(root)
    root:SetScript("OnDragStart", onFrameDragStart)
    root:SetScript("OnDragStop", onFrameDragStop)
end

local function wireCloseButtonScripts(button)
    button:SetScript("OnClick", onCloseButtonClick)
end

local function wireTabButtonScripts(button)
    button:SetScript("OnClick", onTabButtonClick)
end

local function wireWindowScripts()
    local index

    if not state.frame then return end

    wireRootScripts(state.frame)
    wireCloseButtonScripts(state.frame.closeButton)

    for index = 1, table.getn(TAB_ORDER) do
        wireTabButtonScripts(state.tabs[TAB_ORDER[index]])
    end
end

local function ensureWindowBuilt()
    if state.frame then return true end

    local root = createRootFrame()
    local content = createContentFrame(root)
    local index
    local buttonX = CONTENT_INSET

    state.frame = root
    state.tabs = {}
    state.panels = {}

    for index = 1, table.getn(TAB_ORDER) do
        local tabId = TAB_ORDER[index]

        state.tabs[tabId] = createTabButton(root, tabId, buttonX)
        state.panels[tabId] = createTabPanel(content, tabId)

        buttonX = buttonX + TAB_WIDTH + TAB_GAP
    end

    state.profileDialog = createProfileDialog(root)

    ensureEscapeCloseRegistration()
    selectTab(state.activeTabId)
    root:Hide()

    wireWindowScripts()
    return true
end

local function showProfileDialog(mode, text)
    local modeConfig = PROFILE_DIALOG_MODE_CONFIGS[mode]
    local dialog
    local frame
    local edit
    local title
    local description
    local confirmButton
    local cancelButton

    if not modeConfig then return nil end

    ensureWindowBuilt()

    dialog        = state.profileDialog
    frame         = dialog and dialog.frame or nil
    edit          = dialog and dialog.editBox or nil
    title         = dialog and dialog.title or nil
    description   = dialog and dialog.description or nil
    confirmButton = dialog and dialog.confirmButton or nil
    cancelButton  = dialog and dialog.cancelButton or nil

    if not frame or not edit or not title or not description or not confirmButton or not cancelButton then
        return nil
    end

    dialog.mode = mode

    title:SetText(modeConfig.title)
    description:SetText(modeConfig.description)
    confirmButton:SetText(modeConfig.confirmText)
    edit:SetText(resolveProfileDialogText(modeConfig, text))

    if modeConfig.shouldShowCancel then
        cancelButton:Show()
    else
        cancelButton:Hide()
    end

    frame:Raise()
    frame:Show()
    updateProfileDialogScroll(true)
    edit:SetFocus()

    if modeConfig.shouldHighlight then
        edit:HighlightText()
    end

    return true
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function show()
    ensureWindowBuilt()
    selectTab(state.activeTabId)
    state.frame:Show()
end

local function hide()
    if not state.frame then return end
    hideProfileDialog()
    state.frame:Hide()
end

local function toggle()
    if M.IsVisible() then
        M.Hide()
    else
        M.Show()
    end
end

local function isVisible()
    return state.frame and state.frame:IsShown() and true or false
end

local function refresh()
    if not state.frame then return end
    refreshActivePanel()
end

local function showProfileExportDialog(text)
    return showProfileDialog(PROFILE_DIALOG_MODE_EXPORT, text)
end

local function showProfileImportDialog()
    return showProfileDialog(PROFILE_DIALOG_MODE_IMPORT, nil)
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.Show                          = show
M.Hide                          = hide
M.Toggle                        = toggle
M.IsVisible                     = isVisible
M.Refresh                       = refresh

SI.RegisterUITab                = registerUITab
SI.UI_TAB_GENERAL               = TAB_GENERAL
SI.UI_TAB_SETS                  = TAB_SETS
SI.UI_TAB_FLYOUTS               = TAB_FLYOUTS
SI.UI_TAB_ADVANCED              = TAB_ADVANCED
SI.CHAT_PREFIX                  = CHAT_PREFIX
SI.printChat                    = printChat
SI.setChecked                   = setChecked
SI.setButtonEnabled             = setButtonEnabled
SI.createActionButton           = createActionButton
SI.createCheckboxRow            = createCheckboxRow
SI.createDropdown               = createDropdown
SI.FALLBACK_ICON                = FALLBACK_ICON
SI.getElementName               = getElementName
SI.UI_RESET_MODE_GENERAL_UI     = RESET_MODE_GENERAL_UI
SI.UI_RESET_MODE_ACTIVE_PROFILE = RESET_MODE_ACTIVE_PROFILE
SI.ShowProfileExportDialog      = showProfileExportDialog
SI.ShowProfileImportDialog      = showProfileImportDialog
SI.ShowResetConfirmation        = showResetConfirmation

SI.UI                           = M
