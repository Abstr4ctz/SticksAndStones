-- SticksAndStones: Settings/UIGeneral.lua
-- General settings tab owner for the Settings pod.
-- Registers the General tab with the Settings UI shell and keeps all
-- General-only UI state, parsing, and control handlers local to this module.
-- User-triggered writes flow through the public Settings facade only.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local SI = SettingsInternal

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local GENERAL_CONTENT_WIDTH      = 332
local GENERAL_MIN_CONTENT_HEIGHT = 360
local SCALE_SLIDER_NAME          = "SNSSettingsGeneralScaleSlider"
local CLICK_THROUGH_MOD_DROPDOWN_NAME = "SNSSettingsGeneralClickThroughModDropdown"
local RESET_BUTTON_WIDTH         = 144

local COLOR_KIND_BORDER = "border"
local COLOR_KIND_TINT   = "tint"

local COLOR_FIELD_PREFIXES = {
    [COLOR_KIND_BORDER] = "borderColor",
    [COLOR_KIND_TINT]   = "elementColor",
}

local COLOR_SETTERS = {
    [COLOR_KIND_BORDER] = Settings.SetElementBorderColor,
    [COLOR_KIND_TINT]   = Settings.SetElementTintColor,
}

local COLOR_ROW_TABLE_KEYS = {
    [COLOR_KIND_BORDER] = "borderRows",
    [COLOR_KIND_TINT]   = "tintRows",
}

local COLOR_SECTION_TITLES = {
    [COLOR_KIND_BORDER] = "Border Colors",
    [COLOR_KIND_TINT]   = "Element Tint Colors",
}

local COLOR_SECTION_DESCRIPTIONS = {
    [COLOR_KIND_BORDER] = "Pick colors visually or paste normalized RGB values directly.",
    [COLOR_KIND_TINT]   = "Controls empty-state icon tint. Default is native icon color (1, 1, 1).",
}

local COLOR_SECTION_HINTS = {
    [COLOR_KIND_BORDER] = "Format: R G B (0-1), e.g. 0.650 0.300 0.900",
    [COLOR_KIND_TINT]   = "Format: R G B (0-1), e.g. 1.000 1.000 1.000",
}

local COLOR_INVALID_LABELS = {
    [COLOR_KIND_BORDER] = "border color",
    [COLOR_KIND_TINT]   = "element tint color",
}

local EDIT_BACKDROP = {
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    tile     = true,
    tileSize = 8,
    edgeSize = 1,
    insets   = { left = 1, right = 1, top = 1, bottom = 1 },
}

local CLICK_THROUGH_MOD_ORDER = {
    SI.MOD_NONE,
    SI.MOD_CTRL,
    SI.MOD_ALT,
    SI.MOD_SHIFT,
}

local CLICK_THROUGH_MOD_LABELS = {
    [SI.MOD_NONE]  = "None",
    [SI.MOD_CTRL]  = "Ctrl",
    [SI.MOD_ALT]   = "Alt",
    [SI.MOD_SHIFT] = "Shift",
}

local state = {
    panel        = nil,
    isSyncing    = false,
    pendingScale = nil,
    colorPickerButtonsWired = nil,
    colorPickerOkayOriginal = nil,
    colorPickerCancelOriginal = nil,
    colorPicker  = {
        controlKind = nil,
        element     = nil,
        previousR   = nil,
        previousG   = nil,
        previousB   = nil,
        pendingR    = nil,
        pendingG    = nil,
        pendingB    = nil,
    },
}

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function formatScaleText(value)
    if type(value) ~= "number" then value = 1 end
    return string.format("%.2f", SI.clamp(value, SI.SCALE_MIN, SI.SCALE_MAX))
end

local function formatColorTriplet(r, g, b)
    return string.format(
        "%.3f %.3f %.3f",
        SI.sanitizeColorChannel(r),
        SI.sanitizeColorChannel(g),
        SI.sanitizeColorChannel(b)
    )
end

local function parseColorTriplet(text)
    local normalized
    local values = {}
    local token
    local index
    local r
    local g
    local b

    if type(text) ~= "string" then return nil end

    normalized = string.gsub(text, ",", " ")
    for token in string.gfind(normalized, "[-+]?%d*%.?%d+") do
        index = table.getn(values) + 1
        if index > 3 then return nil end
        values[index] = tonumber(token)
    end

    if table.getn(values) ~= 3 then return nil end

    r = values[1]
    g = values[2]
    b = values[3]
    if not r or not g or not b then return nil end
    if r < 0 or r > 1 then return nil end
    if g < 0 or g > 1 then return nil end
    if b < 0 or b > 1 then return nil end

    return r, g, b
end

local function getClickThroughModLabel(value)
    value = SI.sanitizeClickThroughMod(value)
    return CLICK_THROUGH_MOD_LABELS[value] or CLICK_THROUGH_MOD_LABELS[SI.MOD_CTRL]
end

local function syncClickThroughModifierDropdown(dropdown, value)
    if not dropdown then return end

    value = SI.sanitizeClickThroughMod(value)
    if UIDropDownMenu_SetSelectedValue then
        UIDropDownMenu_SetSelectedValue(dropdown, value)
    end
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(getClickThroughModLabel(value), dropdown)
    end
end

local function getElementColorTriplet(controlKind, element)
    local prefix = COLOR_FIELD_PREFIXES[controlKind]
    local cfg    = SNSConfig and SNSConfig.elements and SNSConfig.elements[element]
    local r
    local g
    local b

    if not prefix or not cfg then return 1, 1, 1 end

    r = cfg[prefix .. "R"]
    g = cfg[prefix .. "G"]
    b = cfg[prefix .. "B"]
    if type(r) ~= "number" then r = 1 end
    if type(g) ~= "number" then g = 1 end
    if type(b) ~= "number" then b = 1 end
    return r, g, b
end

local function applyElementColorTriplet(controlKind, element, r, g, b)
    local setter = COLOR_SETTERS[controlKind]

    if not setter then return nil end
    return setter(element, r, g, b)
end

local function getColorRows(panel, controlKind)
    local controls = panel and panel.controls or nil
    local rowKey   = COLOR_ROW_TABLE_KEYS[controlKind]

    if not controls or not rowKey then return nil end
    return controls[rowKey]
end

local function getColorRow(panel, controlKind, element)
    local rows = getColorRows(panel, controlKind)

    if type(rows) ~= "table" then return nil end
    return rows[element]
end

local function previewColorRow(panel, controlKind, element, r, g, b)
    local row = getColorRow(panel, controlKind, element)

    if not row then return end

    r = SI.sanitizeColorChannel(r)
    g = SI.sanitizeColorChannel(g)
    b = SI.sanitizeColorChannel(b)

    if row.swatchFill then
        row.swatchFill:SetVertexColor(r, g, b)
    end
    if row.edit then
        row.edit:SetText(formatColorTriplet(r, g, b))
    end
end

local function refreshColorRow(panel, controlKind, element)
    local r
    local g
    local b

    r, g, b = getElementColorTriplet(controlKind, element)
    previewColorRow(panel, controlKind, element, r, g, b)
end

local function refreshColorRows(panel, controlKind)
    local element

    for element = 1, SI.MAX_ELEMENTS do
        refreshColorRow(panel, controlKind, element)
    end
end

local function clearColorPickerState()
    state.colorPicker.controlKind = nil
    state.colorPicker.element = nil
    state.colorPicker.previousR = nil
    state.colorPicker.previousG = nil
    state.colorPicker.previousB = nil
    state.colorPicker.pendingR = nil
    state.colorPicker.pendingG = nil
    state.colorPicker.pendingB = nil
end

local function clearColorPickerBindings()
    if not ColorPickerFrame then return end

    ColorPickerFrame.func = nil
    ColorPickerFrame.opacityFunc = nil
    ColorPickerFrame.cancelFunc = nil
    ColorPickerFrame.previousValues = nil
end

local function finalizeColorPicker(shouldCancel)
    local picker = state.colorPicker
    local r
    local g
    local b

    if not picker.controlKind or not picker.element then
        clearColorPickerBindings()
        clearColorPickerState()
        return
    end

    if shouldCancel then
        refreshColorRow(state.panel, picker.controlKind, picker.element)
        clearColorPickerBindings()
        clearColorPickerState()
        return
    end

    r = (type(picker.pendingR) == "number") and picker.pendingR or picker.previousR
    g = (type(picker.pendingG) == "number") and picker.pendingG or picker.previousG
    b = (type(picker.pendingB) == "number") and picker.pendingB or picker.previousB

    if r == picker.previousR and g == picker.previousG and b == picker.previousB then
        clearColorPickerBindings()
        clearColorPickerState()
        return
    end

    applyElementColorTriplet(picker.controlKind, picker.element, r, g, b)
    clearColorPickerBindings()
    clearColorPickerState()
end

local function onColorPickerOkayClick()
    local original = state.colorPickerOkayOriginal
    if original then
        original()
    end
    finalizeColorPicker(nil)
end

local function onColorPickerCancelClick()
    local original = state.colorPickerCancelOriginal
    if original then
        original()
    end
    finalizeColorPicker(true)
end

local function ensureColorPickerButtonScripts()
    local okayButton
    local cancelButton

    if state.colorPickerButtonsWired then return true end
    if not ColorPickerFrame then return nil end

    okayButton = ColorPickerOkayButton or getglobal("ColorPickerOkayButton")
    cancelButton = ColorPickerCancelButton or getglobal("ColorPickerCancelButton")
    if not okayButton or not cancelButton then return nil end

    state.colorPickerOkayOriginal = okayButton:GetScript("OnClick")
    state.colorPickerCancelOriginal = cancelButton:GetScript("OnClick")
    okayButton:SetScript("OnClick", onColorPickerOkayClick)
    cancelButton:SetScript("OnClick", onColorPickerCancelClick)
    state.colorPickerButtonsWired = true
    return true
end

local function dismissColorPicker()
    local picker = state.colorPicker

    if picker.controlKind and picker.element then
        refreshColorRow(state.panel, picker.controlKind, picker.element)
    end

    if not ColorPickerFrame then
        clearColorPickerState()
        return
    end

    clearColorPickerBindings()
    if ColorPickerFrame:IsShown() then
        if HideUIPanel then
            HideUIPanel(ColorPickerFrame)
        else
            ColorPickerFrame:Hide()
        end
    end
    clearColorPickerState()
end

local function clearPendingScale()
    state.pendingScale = nil
end

local function commitPendingScale()
    local scale = state.pendingScale
    local currentScale

    if type(scale) ~= "number" then return end

    currentScale = SNSConfig and SNSConfig.scale or nil
    if type(currentScale) ~= "number" then currentScale = 1 end
    currentScale = SI.clamp(currentScale, SI.SCALE_MIN, SI.SCALE_MAX)

    clearPendingScale()
    if scale == currentScale then return end

    Settings.SetScale(scale)
end

local function onColorPickerChanged()
    local picker = state.colorPicker
    local r
    local g
    local b

    if not picker.controlKind or not picker.element or not ColorPickerFrame then return end

    r, g, b = ColorPickerFrame:GetColorRGB()
    picker.pendingR = SI.sanitizeColorChannel(r)
    picker.pendingG = SI.sanitizeColorChannel(g)
    picker.pendingB = SI.sanitizeColorChannel(b)
    previewColorRow(state.panel, picker.controlKind, picker.element, picker.pendingR, picker.pendingG, picker.pendingB)
end

local function onColorPickerCancelled(previousValues)
    local picker = state.colorPicker
    local r
    local g
    local b

    if not picker.controlKind or not picker.element then return end

    r = picker.previousR
    g = picker.previousG
    b = picker.previousB

    if type(previousValues) == "table" then
        r = tonumber(previousValues.r) or tonumber(previousValues[1]) or r
        g = tonumber(previousValues.g) or tonumber(previousValues[2]) or g
        b = tonumber(previousValues.b) or tonumber(previousValues[3]) or b
    end

    picker.pendingR = SI.sanitizeColorChannel(r)
    picker.pendingG = SI.sanitizeColorChannel(g)
    picker.pendingB = SI.sanitizeColorChannel(b)
    previewColorRow(state.panel, picker.controlKind, picker.element, picker.pendingR, picker.pendingG, picker.pendingB)
end

local function openColorPicker(controlKind, element)
    local r
    local g
    local b

    if not ColorPickerFrame then
        SI.printChat(SI.CHAT_PREFIX .. "color picker is unavailable.")
        return
    end

    dismissColorPicker()
    ensureColorPickerButtonScripts()

    r, g, b = getElementColorTriplet(controlKind, element)
    state.colorPicker.controlKind = controlKind
    state.colorPicker.element = element
    state.colorPicker.previousR = r
    state.colorPicker.previousG = g
    state.colorPicker.previousB = b
    state.colorPicker.pendingR = r
    state.colorPicker.pendingG = g
    state.colorPicker.pendingB = b

    ColorPickerFrame.func = onColorPickerChanged
    ColorPickerFrame.opacityFunc = nil
    ColorPickerFrame.cancelFunc = onColorPickerCancelled
    ColorPickerFrame.hasOpacity = nil
    ColorPickerFrame:SetColorRGB(r, g, b)
    ColorPickerFrame.previousValues = { r, g, b }

    if ShowUIPanel then
        ShowUIPanel(ColorPickerFrame)
    else
        ColorPickerFrame:Show()
    end

    ColorPickerFrame:SetFrameStrata("DIALOG")
    if ColorPickerFrame.SetToplevel then
        ColorPickerFrame:SetToplevel(true)
    end
    if ColorPickerFrame.Raise then
        ColorPickerFrame:Raise()
    end
end

local function commitColorFromEdit(controlKind, element)
    local row = getColorRow(state.panel, controlKind, element)
    local r
    local g
    local b

    if not row or not row.edit then return end

    r, g, b = parseColorTriplet(row.edit:GetText())
    if not r then
        SI.printChat(SI.CHAT_PREFIX .. "invalid " .. SI.getElementName(element) .. " " .. COLOR_INVALID_LABELS[controlKind] .. ". Use: R G B (0-1).")
        refreshColorRow(state.panel, controlKind, element)
        return
    end

    applyElementColorTriplet(controlKind, element, r, g, b)
end

local function refreshPanel(panel)
    local controls
    local scale

    if panel then
        state.panel = panel
    end

    panel = state.panel
    controls = panel and panel.controls or nil
    if type(SNSConfig) ~= "table" or not controls then return end

    state.isSyncing = true

    SI.setChecked(controls.lockedCheck, SNSConfig.locked)
    SI.setChecked(controls.clickThroughCheck, SNSConfig.clickThrough)
    SI.setChecked(controls.snapAlignCheck, SNSConfig.snapAlign ~= false)
    SI.setChecked(controls.showBorderCheck, SNSConfig.showBorder ~= false)
    syncClickThroughModifierDropdown(controls.clickThroughModDropdown, SNSConfig.clickThroughMod)

    scale = SNSConfig.scale
    if type(scale) ~= "number" then scale = 1 end
    scale = SI.clamp(scale, SI.SCALE_MIN, SI.SCALE_MAX)
    if controls.scaleSlider then
        controls.scaleSlider:SetValue(scale)
    end
    if controls.scaleValue then
        controls.scaleValue:SetText(formatScaleText(scale))
    end
    clearPendingScale()

    refreshColorRows(panel, COLOR_KIND_BORDER)
    refreshColorRows(panel, COLOR_KIND_TINT)

    state.isSyncing = false
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

local function onScaleSliderChanged()
    local controls = state.panel and state.panel.controls or nil
    local scale

    if not this or not controls or this ~= controls.scaleSlider then return end

    scale = this:GetValue()
    if controls.scaleValue then
        controls.scaleValue:SetText(formatScaleText(scale))
    end
    if state.isSyncing then return end

    state.pendingScale = SI.clamp(scale, SI.SCALE_MIN, SI.SCALE_MAX)
end

local function onScaleSliderCommitRequested()
    local controls = state.panel and state.panel.controls or nil

    if not this or not controls or this ~= controls.scaleSlider then return end
    if state.isSyncing then return end

    commitPendingScale()
end

local function onClickThroughModSelected()
    if state.isSyncing or not this then return end
    Settings.SetClickThroughModifier(this.value)
end

local function initializeClickThroughModDropdown()
    local selected
    local i

    if (UIDROPDOWNMENU_MENU_LEVEL or 1) ~= 1 then return end
    if not UIDropDownMenu_CreateInfo or not UIDropDownMenu_AddButton then return end

    selected = SI.sanitizeClickThroughMod(SNSConfig and SNSConfig.clickThroughMod)
    for i = 1, table.getn(CLICK_THROUGH_MOD_ORDER) do
        local value = CLICK_THROUGH_MOD_ORDER[i]
        local info = UIDropDownMenu_CreateInfo()

        info.text = getClickThroughModLabel(value)
        info.value = value
        info.checked = (selected == value) and 1 or nil
        info.func = onClickThroughModSelected
        UIDropDownMenu_AddButton(info)
    end
end

local function onColorSwatchClick()
    if not this or not this.controlKind or not this.element then return end
    openColorPicker(this.controlKind, this.element)
end

local function onColorEditEnterPressed()
    if this and this.controlKind and this.element then
        commitColorFromEdit(this.controlKind, this.element)
    end
    if this then
        this:ClearFocus()
    end
end

local function onColorEditFocusLost()
    if not this or not this.controlKind or not this.element then return end
    commitColorFromEdit(this.controlKind, this.element)
end

local function onColorEditEscapePressed()
    if not this then return end

    if this.controlKind and this.element then
        refreshColorRow(state.panel, this.controlKind, this.element)
    end
    this:ClearFocus()
end

local function onResetUIButtonClick()
    if not SI.ShowResetConfirmation then return end
    SI.ShowResetConfirmation(SI.UI_RESET_MODE_GENERAL_UI)
end

------------------------------------------------------------------------
-- Private builders
------------------------------------------------------------------------

local function createScaleSliderControls(parent, controls, yOffset)
    local sliderLabel = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    local slider = CreateFrame("Slider", SCALE_SLIDER_NAME, parent, "OptionsSliderTemplate")
    local sliderText
    local sliderLow
    local sliderHigh
    local scaleValue

    sliderLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, yOffset - 24)
    sliderLabel:SetText("Display Scale")
    controls.scaleLabel = sliderLabel

    slider:SetPoint("TOPLEFT", sliderLabel, "BOTTOMLEFT", -4, -10)
    slider:SetWidth(220)
    slider:SetHeight(18)
    slider:SetMinMaxValues(SI.SCALE_MIN, SI.SCALE_MAX)
    slider:SetValueStep(0.05)
    slider:SetScript("OnValueChanged", onScaleSliderChanged)
    slider:SetScript("OnMouseUp", onScaleSliderCommitRequested)
    slider:SetScript("OnHide", onScaleSliderCommitRequested)
    controls.scaleSlider = slider

    sliderText = getglobal(SCALE_SLIDER_NAME .. "Text")
    sliderLow = getglobal(SCALE_SLIDER_NAME .. "Low")
    sliderHigh = getglobal(SCALE_SLIDER_NAME .. "High")
    if sliderText then sliderText:SetText("") end
    if sliderLow then sliderLow:SetText(string.format("%.1f", SI.SCALE_MIN)) end
    if sliderHigh then sliderHigh:SetText(string.format("%.1f", SI.SCALE_MAX)) end

    scaleValue = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    scaleValue:SetPoint("LEFT", slider, "RIGHT", 10, 0)
    scaleValue:SetText("1.00")
    controls.scaleValue = scaleValue
end

local function createClickThroughModifierControls(parent, controls, yOffset)
    local label = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    local dropdown = CreateFrame("Frame", CLICK_THROUGH_MOD_DROPDOWN_NAME, parent, "UIDropDownMenuTemplate")
    local hint = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")

    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 40, yOffset - 4)
    label:SetJustifyH("LEFT")
    label:SetText("Click-Through Modifier")
    controls.clickThroughModLabel = label

    dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, yOffset - 18)
    if UIDropDownMenu_Initialize then
        UIDropDownMenu_Initialize(dropdown, initializeClickThroughModDropdown)
    end
    if UIDropDownMenu_SetWidth then
        UIDropDownMenu_SetWidth(108, dropdown)
    end
    if UIDropDownMenu_JustifyText then
        UIDropDownMenu_JustifyText("LEFT", dropdown)
    end
    controls.clickThroughModDropdown = dropdown

    hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 40, yOffset - 48)
    hint:SetWidth(286)
    hint:SetJustifyH("LEFT")
    hint:SetText("Choose which modifier temporarily restores hover and mouse input while locked. Pick None to keep the bar fully click-through.")
    controls.clickThroughModHint = hint

    return yOffset - 88
end

local function createColorControlRow(parent, yOffset, controlKind, element)
    local row        = {}
    local label      = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    local swatch     = CreateFrame("Button", nil, parent)
    local swatchFill = swatch:CreateTexture(nil, "BACKGROUND")
    local editBg     = CreateFrame("Frame", nil, parent)
    local edit       = CreateFrame("EditBox", nil, editBg)

    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yOffset)
    label:SetWidth(44)
    label:SetJustifyH("LEFT")
    label:SetText(SI.getElementName(element) .. ":")
    row.label = label

    swatch:SetWidth(20)
    swatch:SetHeight(20)
    swatch:SetPoint("LEFT", label, "RIGHT", 8, 0)
    swatch.controlKind = controlKind
    swatch.element = element
    swatch:SetScript("OnClick", onColorSwatchClick)
    row.swatch = swatch

    swatchFill:SetAllPoints(swatch)
    swatchFill:SetTexture(1, 1, 1, 1)
    row.swatchFill = swatchFill

    row.swatchBorderTop = swatch:CreateTexture(nil, "BORDER")
    row.swatchBorderTop:SetPoint("TOPLEFT", swatch, "TOPLEFT", 0, 0)
    row.swatchBorderTop:SetPoint("TOPRIGHT", swatch, "TOPRIGHT", 0, 0)
    row.swatchBorderTop:SetHeight(1)
    row.swatchBorderTop:SetTexture(0.05, 0.05, 0.05, 1)

    row.swatchBorderBottom = swatch:CreateTexture(nil, "BORDER")
    row.swatchBorderBottom:SetPoint("BOTTOMLEFT", swatch, "BOTTOMLEFT", 0, 0)
    row.swatchBorderBottom:SetPoint("BOTTOMRIGHT", swatch, "BOTTOMRIGHT", 0, 0)
    row.swatchBorderBottom:SetHeight(1)
    row.swatchBorderBottom:SetTexture(0.05, 0.05, 0.05, 1)

    row.swatchBorderLeft = swatch:CreateTexture(nil, "BORDER")
    row.swatchBorderLeft:SetPoint("TOPLEFT", swatch, "TOPLEFT", 0, 0)
    row.swatchBorderLeft:SetPoint("BOTTOMLEFT", swatch, "BOTTOMLEFT", 0, 0)
    row.swatchBorderLeft:SetWidth(1)
    row.swatchBorderLeft:SetTexture(0.05, 0.05, 0.05, 1)

    row.swatchBorderRight = swatch:CreateTexture(nil, "BORDER")
    row.swatchBorderRight:SetPoint("TOPRIGHT", swatch, "TOPRIGHT", 0, 0)
    row.swatchBorderRight:SetPoint("BOTTOMRIGHT", swatch, "BOTTOMRIGHT", 0, 0)
    row.swatchBorderRight:SetWidth(1)
    row.swatchBorderRight:SetTexture(0.05, 0.05, 0.05, 1)

    editBg:SetWidth(176)
    editBg:SetHeight(22)
    editBg:SetPoint("LEFT", swatch, "RIGHT", 8, 0)
    editBg:SetBackdrop(EDIT_BACKDROP)
    editBg:SetBackdropColor(0, 0, 0, 0.92)
    editBg:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    row.editBg = editBg

    edit:SetPoint("TOPLEFT", editBg, "TOPLEFT", 5, -4)
    edit:SetPoint("BOTTOMRIGHT", editBg, "BOTTOMRIGHT", -5, 4)
    edit:SetFontObject(ChatFontNormal)
    edit:SetJustifyH("LEFT")
    edit:SetJustifyV("MIDDLE")
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(24)
    edit.controlKind = controlKind
    edit.element = element
    edit:SetScript("OnEnterPressed", onColorEditEnterPressed)
    edit:SetScript("OnEditFocusLost", onColorEditFocusLost)
    edit:SetScript("OnEscapePressed", onColorEditEscapePressed)
    if edit.EnableMouse then edit:EnableMouse(true) end
    if edit.EnableKeyboard then edit:EnableKeyboard(true) end
    row.edit = edit

    return row
end

local function buildColorSection(panel, parent, yOffset, controlKind)
    local controls    = panel.controls
    local rows        = {}
    local header      = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    local description = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    local hint        = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    local element

    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yOffset)
    header:SetText(COLOR_SECTION_TITLES[controlKind])

    description:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
    description:SetWidth(308)
    description:SetJustifyH("LEFT")
    description:SetText(COLOR_SECTION_DESCRIPTIONS[controlKind])

    yOffset = yOffset - 44
    for element = 1, SI.MAX_ELEMENTS do
        local row = createColorControlRow(parent, yOffset, controlKind, element)
        rows[element] = row
        yOffset = yOffset - 28
    end

    hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yOffset - 4)
    hint:SetText(COLOR_SECTION_HINTS[controlKind])

    controls[COLOR_ROW_TABLE_KEYS[controlKind]] = rows
    return yOffset - 34
end

local function buildPanel(panel)
    local controls = {}
    local content  = panel.contentFrame or panel
    local contentHeight
    local y        = -8

    state.panel = panel
    panel.controls = controls

    controls.lockedCheck = SI.createCheckboxRow(content, y, "Lock Buttons", onCheckboxClick)
    controls.lockedCheck.onValueChanged = Settings.SetLocked
    y = y - 24

    controls.clickThroughCheck = SI.createCheckboxRow(content, y, "Click-Through", onCheckboxClick)
    controls.clickThroughCheck.onValueChanged = Settings.SetClickThrough
    y = y - 24

    y = createClickThroughModifierControls(content, controls, y)

    controls.snapAlignCheck = SI.createCheckboxRow(content, y, "Snap Align", onCheckboxClick)
    controls.snapAlignCheck.onValueChanged = Settings.SetSnapAlign
    y = y - 24

    controls.showBorderCheck = SI.createCheckboxRow(content, y, "Show Border", onCheckboxClick)
    controls.showBorderCheck.onValueChanged = Settings.SetBorderVisible

    createScaleSliderControls(content, controls, y)

    y = y - 84
    controls.resetButton = SI.createActionButton(content, RESET_BUTTON_WIDTH, 18, y, "Reset General UI", onResetUIButtonClick)

    y = y - 42
    y = buildColorSection(panel, content, y, COLOR_KIND_BORDER)
    y = buildColorSection(panel, content, y, COLOR_KIND_TINT)

    contentHeight = (-y) + 48
    if contentHeight < GENERAL_MIN_CONTENT_HEIGHT then
        contentHeight = GENERAL_MIN_CONTENT_HEIGHT
    end
    content:SetHeight(contentHeight)
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

SI.DismissGeneralColorPicker = dismissColorPicker

------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------

if SI.RegisterUITab then
    SI.RegisterUITab(SI.UI_TAB_GENERAL, {
        Build = buildPanel,
        Refresh = refreshPanel,
        Scrollable = true,
        ContentWidth = GENERAL_CONTENT_WIDTH,
    })
end
