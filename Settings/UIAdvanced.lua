-- SticksAndStones: Settings/UIAdvanced.lua
-- Advanced settings tab owner for the Settings pod.
-- Owns the Advanced tab UI state, profile-management controls, and advanced
-- tuning handlers for range, polling, duration expiry, and tooltip placement.
-- User-triggered writes flow through the public Settings facade only.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local SI = SettingsInternal

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local ADVANCED_CONTENT_WIDTH      = 332
local ADVANCED_MIN_CONTENT_HEIGHT = 672
local BUTTON_GAP                  = 6
local NUMERIC_EDIT_WIDTH          = 52
local PROFILE_RESET_BUTTON_WIDTH  = 156

local PROFILE_DROPDOWN_NAME         = "SNSSettingsAdvancedProfileDropdown"
local TOOLTIP_ANCHOR_DROPDOWN_NAME  = "SNSSettingsAdvancedTooltipAnchorDropdown"
local TOOLTIP_DIRECTION_DROPDOWN_NAME = "SNSSettingsAdvancedTooltipDirectionDropdown"
local PROFILE_NAME_EDIT_NAME        = "SNSProfileNameEdit"
local POLL_INTERVAL_EDIT_NAME       = "SNSPollingFrequencyEdit"
local RANGE_OFFSET_EDIT_NAME        = "SNSRangeOffsetEdit"
local EXPIRY_THRESHOLD_EDIT_NAME    = "SNSExpiryThresholdEdit"
local TOOLTIP_OFFSET_X_EDIT_NAME    = "SNSTooltipOffsetXEdit"
local TOOLTIP_OFFSET_Y_EDIT_NAME    = "SNSTooltipOffsetYEdit"

local TOOLTIP_ANCHOR_ORDER = {
    SI.TOOLTIP_ANCHOR_MODE_FRAME,
    SI.TOOLTIP_ANCHOR_MODE_CURSOR,
}

local TOOLTIP_ANCHOR_LABELS = {
    [SI.TOOLTIP_ANCHOR_MODE_FRAME]  = "Frame",
    [SI.TOOLTIP_ANCHOR_MODE_CURSOR] = "Cursor",
}

local TOOLTIP_DIRECTION_ORDER = {
    SI.TOOLTIP_DIR_UP,
    SI.TOOLTIP_DIR_DOWN,
    SI.TOOLTIP_DIR_LEFT,
    SI.TOOLTIP_DIR_RIGHT,
}

local TOOLTIP_DIRECTION_LABELS = {
    [SI.TOOLTIP_DIR_UP]    = "Up",
    [SI.TOOLTIP_DIR_DOWN]  = "Down",
    [SI.TOOLTIP_DIR_LEFT]  = "Left",
    [SI.TOOLTIP_DIR_RIGHT] = "Right",
}

local PROFILE_ERROR_MESSAGE_FALLBACK = "profile change failed."
local PROFILE_ERROR_MESSAGES = {
    profile_exists   = "that profile name is already in use.",
    profile_missing  = "that profile no longer exists.",
    profile_active   = "you cannot delete the active profile.",
    same_profile_key = "choose a different profile name.",
}

local state = {
    panel                = nil,
    isSyncing            = false,
    selectedProfileKey   = nil,
    nameEditSelectionKey = nil,
}

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function formatNumber(value)
    local text

    if type(value) ~= "number" then return "" end

    text = string.format("%.2f", value)
    text = string.gsub(text, "(%.%d-)0+$", "%1")
    text = string.gsub(text, "%.$", "")
    return text
end

local function formatInteger(value)
    if type(value) ~= "number" then return "" end
    return tostring(math.floor(value))
end

local function normalizeProfileKey(text)
    if not SI.sanitizeProfileKey then return nil end
    return SI.sanitizeProfileKey(text)
end

local function parseNumericEdit(edit)
    if not edit then return nil end
    return tonumber(edit:GetText())
end

local function getProfileKeys()
    local keys = Settings.ListProfiles and Settings.ListProfiles() or nil
    if type(keys) ~= "table" then
        return {}
    end
    return keys
end

local function getActiveProfileKey()
    if not Settings.GetActiveProfileKey then return nil end
    return Settings.GetActiveProfileKey()
end

local function hasProfileKey(keys, key)
    local i

    if not key then return nil end

    for i = 1, table.getn(keys) do
        if keys[i] == key then
            return true
        end
    end

    return nil
end

local function resolveSelectedProfileKey(keys, activeKey)
    if table.getn(keys) <= 0 then
        return nil
    end
    if hasProfileKey(keys, state.selectedProfileKey) then
        return state.selectedProfileKey
    end
    if hasProfileKey(keys, activeKey) then
        return activeKey
    end
    return keys[1]
end

local function getProfileLabel(key, activeKey)
    if not key then return "(none)" end
    if key == activeKey then
        return key .. " (active)"
    end
    return key
end

local function getTooltipAnchorLabel(value)
    return TOOLTIP_ANCHOR_LABELS[value] or TOOLTIP_ANCHOR_LABELS[SI.TOOLTIP_ANCHOR_MODE_FRAME]
end

local function getTooltipDirectionLabel(value)
    return TOOLTIP_DIRECTION_LABELS[value] or TOOLTIP_DIRECTION_LABELS[SI.TOOLTIP_DIR_RIGHT]
end

local function syncProfileDropdown(dropdown, selectedKey, activeKey)
    if not dropdown then return end

    if UIDropDownMenu_SetSelectedValue then
        UIDropDownMenu_SetSelectedValue(dropdown, selectedKey)
    end
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(getProfileLabel(selectedKey, activeKey), dropdown)
    end
end

local function syncTooltipAnchorDropdown(dropdown, value)
    if not dropdown then return end

    value = SI.sanitizeTooltipAnchorMode(value)
    if UIDropDownMenu_SetSelectedValue then
        UIDropDownMenu_SetSelectedValue(dropdown, value)
    end
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(getTooltipAnchorLabel(value), dropdown)
    end
end

local function syncTooltipDirectionDropdown(dropdown, value)
    if not dropdown then return end

    value = SI.sanitizeTooltipDirection(value)
    if UIDropDownMenu_SetSelectedValue then
        UIDropDownMenu_SetSelectedValue(dropdown, value)
    end
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(getTooltipDirectionLabel(value), dropdown)
    end
end

local function getProfileErrorMessage(err)
    return PROFILE_ERROR_MESSAGES[err] or PROFILE_ERROR_MESSAGE_FALLBACK
end

local function syncProfileNameEdit(controls)
    local edit

    if not controls then return end

    edit = controls.profileNameEdit
    if not edit then return end
    if state.nameEditSelectionKey == state.selectedProfileKey then return end

    edit:SetText(state.selectedProfileKey or "")
    state.nameEditSelectionKey = state.selectedProfileKey
end

local function refreshPanel(panel)
    local controls
    local profileKeys
    local activeKey
    local selectedKey
    local canSwitch
    local canDelete

    if panel then
        state.panel = panel
    end

    panel = state.panel
    controls = panel and panel.controls or nil
    if type(SNSConfig) ~= "table" or not controls then return end

    profileKeys = getProfileKeys()
    activeKey = getActiveProfileKey()
    selectedKey = resolveSelectedProfileKey(profileKeys, activeKey)
    state.selectedProfileKey = selectedKey

    state.isSyncing = true

    if controls.activeValue then
        controls.activeValue:SetText(activeKey or "(none)")
    end

    syncProfileDropdown(controls.profileDropdown, selectedKey, activeKey)
    syncProfileNameEdit(controls)

    canSwitch = selectedKey and selectedKey ~= activeKey
    canDelete = selectedKey and selectedKey ~= activeKey

    SI.setButtonEnabled(controls.profileCreateButton, true)
    SI.setButtonEnabled(controls.profileResetButton, activeKey and true or nil)
    SI.setButtonEnabled(controls.profileRenameButton, selectedKey and true or nil)
    SI.setButtonEnabled(controls.profileSwitchButton, canSwitch and true or nil)
    SI.setButtonEnabled(controls.profileDeleteButton, canDelete and true or nil)
    SI.setButtonEnabled(controls.profileExportButton, selectedKey and true or nil)
    SI.setButtonEnabled(controls.profileImportButton, true)

    if controls.pollIntervalEdit then
        controls.pollIntervalEdit:SetText(formatNumber(SI.sanitizePollInterval(SNSConfig.pollInterval, SI.DEFAULTS.pollInterval)))
    end
    SI.setChecked(controls.rangeFadeCheck, SNSConfig.rangeFade ~= false)
    if controls.rangeOffsetEdit then
        controls.rangeOffsetEdit:SetText(formatNumber(SI.sanitizeRangeOffsetYards(SNSConfig.rangeOffsetYards, SI.DEFAULTS.rangeOffsetYards)))
    end
    if controls.expiryThresholdEdit then
        controls.expiryThresholdEdit:SetText(formatInteger(SI.sanitizeExpiryThresholdSecs(SNSConfig.expiryThresholdSecs, SI.DEFAULTS.expiryThresholdSecs)))
    end
    if controls.tooltipOffsetXEdit then
        controls.tooltipOffsetXEdit:SetText(formatNumber(SI.sanitizeTooltipOffset(SNSConfig.tooltipOffsetX, SI.DEFAULTS.tooltipOffsetX)))
    end
    if controls.tooltipOffsetYEdit then
        controls.tooltipOffsetYEdit:SetText(formatNumber(SI.sanitizeTooltipOffset(SNSConfig.tooltipOffsetY, SI.DEFAULTS.tooltipOffsetY)))
    end

    SI.setChecked(controls.timerShowMinutesCheck, SNSConfig.timerShowMinutes)
    SI.setChecked(controls.expirySoundCheck, SNSConfig.expirySoundEnabled)
    SI.setChecked(controls.tooltipsEnabledCheck, SNSConfig.tooltipsEnabled ~= false)
    syncTooltipAnchorDropdown(controls.tooltipAnchorDropdown, SNSConfig.tooltipAnchorMode)
    syncTooltipDirectionDropdown(controls.tooltipDirectionDropdown, SNSConfig.tooltipDirection)

    state.isSyncing = false
end

local function setSelectedProfileKey(key)
    state.selectedProfileKey = normalizeProfileKey(key)
    state.nameEditSelectionKey = nil

    if state.panel then
        refreshPanel(state.panel)
    end
end

local function commitRangeOffsetFromEdit()
    local controls = state.panel and state.panel.controls or nil
    local edit     = controls and controls.rangeOffsetEdit or nil
    local value    = parseNumericEdit(edit)

    if not edit then return end
    if type(value) ~= "number" then
        SI.printChat(SI.CHAT_PREFIX .. "enter a valid range offset.")
        refreshPanel(state.panel)
        return
    end

    Settings.SetRangeOffsetYards(value)
end

local function commitPollIntervalFromEdit()
    local controls = state.panel and state.panel.controls or nil
    local edit     = controls and controls.pollIntervalEdit or nil
    local value    = parseNumericEdit(edit)

    if not edit then return end
    if type(value) ~= "number" then
        SI.printChat(SI.CHAT_PREFIX .. "enter a valid poll interval.")
        refreshPanel(state.panel)
        return
    end

    Settings.SetPollInterval(value)
end

local function commitTooltipOffsetXFromEdit()
    local controls = state.panel and state.panel.controls or nil
    local edit     = controls and controls.tooltipOffsetXEdit or nil
    local value    = parseNumericEdit(edit)

    if not edit then return end
    if type(value) ~= "number" then
        SI.printChat(SI.CHAT_PREFIX .. "enter a valid tooltip X offset.")
        refreshPanel(state.panel)
        return
    end

    Settings.SetTooltipOffsetX(value)
end

local function commitTooltipOffsetYFromEdit()
    local controls = state.panel and state.panel.controls or nil
    local edit     = controls and controls.tooltipOffsetYEdit or nil
    local value    = parseNumericEdit(edit)

    if not edit then return end
    if type(value) ~= "number" then
        SI.printChat(SI.CHAT_PREFIX .. "enter a valid tooltip Y offset.")
        refreshPanel(state.panel)
        return
    end

    Settings.SetTooltipOffsetY(value)
end

local function commitExpiryThresholdFromEdit()
    local controls = state.panel and state.panel.controls or nil
    local edit     = controls and controls.expiryThresholdEdit or nil
    local value    = parseNumericEdit(edit)

    if not edit then return end
    if type(value) ~= "number" then
        SI.printChat(SI.CHAT_PREFIX .. "enter a valid expiry threshold.")
        refreshPanel(state.panel)
        return
    end

    Settings.SetExpiryThresholdSecs(value)
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

local function onProfileSelected()
    if state.isSyncing or not this then return end

    state.selectedProfileKey = this.value
    state.nameEditSelectionKey = nil
    refreshPanel(state.panel)
end

local function initializeProfileDropdown()
    local keys
    local activeKey
    local selectedKey
    local i

    if (UIDROPDOWNMENU_MENU_LEVEL or 1) ~= 1 then return end
    if not UIDropDownMenu_CreateInfo or not UIDropDownMenu_AddButton then return end

    keys = getProfileKeys()
    activeKey = getActiveProfileKey()
    selectedKey = resolveSelectedProfileKey(keys, activeKey)

    for i = 1, table.getn(keys) do
        local key = keys[i]
        local info = UIDropDownMenu_CreateInfo()

        info.text = getProfileLabel(key, activeKey)
        info.value = key
        info.checked = (selectedKey == key) and 1 or nil
        info.func = onProfileSelected
        UIDropDownMenu_AddButton(info)
    end
end

local function onTooltipAnchorSelected()
    if state.isSyncing or not this then return end
    Settings.SetTooltipAnchorMode(this.value)
end

local function initializeTooltipAnchorDropdown()
    local selected
    local i

    if (UIDROPDOWNMENU_MENU_LEVEL or 1) ~= 1 then return end
    if not UIDropDownMenu_CreateInfo or not UIDropDownMenu_AddButton then return end

    selected = SI.sanitizeTooltipAnchorMode(SNSConfig and SNSConfig.tooltipAnchorMode)

    for i = 1, table.getn(TOOLTIP_ANCHOR_ORDER) do
        local value = TOOLTIP_ANCHOR_ORDER[i]
        local info = UIDropDownMenu_CreateInfo()

        info.text = getTooltipAnchorLabel(value)
        info.value = value
        info.checked = (selected == value) and 1 or nil
        info.func = onTooltipAnchorSelected
        UIDropDownMenu_AddButton(info)
    end
end

local function onTooltipDirectionSelected()
    if state.isSyncing or not this then return end
    Settings.SetTooltipDirection(this.value)
end

local function initializeTooltipDirectionDropdown()
    local selected
    local i

    if (UIDROPDOWNMENU_MENU_LEVEL or 1) ~= 1 then return end
    if not UIDropDownMenu_CreateInfo or not UIDropDownMenu_AddButton then return end

    selected = SI.sanitizeTooltipDirection(SNSConfig and SNSConfig.tooltipDirection)

    for i = 1, table.getn(TOOLTIP_DIRECTION_ORDER) do
        local value = TOOLTIP_DIRECTION_ORDER[i]
        local info = UIDropDownMenu_CreateInfo()

        info.text = getTooltipDirectionLabel(value)
        info.value = value
        info.checked = (selected == value) and 1 or nil
        info.func = onTooltipDirectionSelected
        UIDropDownMenu_AddButton(info)
    end
end

local function onProfileCreateClick()
    local controls = state.panel and state.panel.controls or nil
    local edit     = controls and controls.profileNameEdit or nil
    local newKey
    local ok
    local err

    if not edit then return end

    newKey = normalizeProfileKey(edit:GetText())
    if not newKey then
        SI.printChat(SI.CHAT_PREFIX .. "enter a profile name.")
        return
    end

    ok, err = Settings.CreateProfile(newKey, state.selectedProfileKey)
    if not ok then
        SI.printChat(SI.CHAT_PREFIX .. getProfileErrorMessage(err))
        return
    end

    state.selectedProfileKey = newKey
    state.nameEditSelectionKey = nil
    SI.printChat(SI.CHAT_PREFIX .. "profile created: " .. newKey)
    refreshPanel(state.panel)
end

local function onProfileNameEnterPressed()
    onProfileCreateClick()
    if this then this:ClearFocus() end
end

local function onProfileNameEscapePressed()
    state.nameEditSelectionKey = nil
    refreshPanel(state.panel)
    if this then this:ClearFocus() end
end

local function onProfileRenameClick()
    local controls = state.panel and state.panel.controls or nil
    local edit     = controls and controls.profileNameEdit or nil
    local newKey
    local ok
    local err

    if not state.selectedProfileKey then return end
    if not edit then return end

    newKey = normalizeProfileKey(edit:GetText())
    if not newKey then
        SI.printChat(SI.CHAT_PREFIX .. "enter a profile name.")
        return
    end

    ok, err = Settings.RenameProfile(state.selectedProfileKey, newKey)
    if not ok then
        SI.printChat(SI.CHAT_PREFIX .. getProfileErrorMessage(err))
        return
    end

    state.selectedProfileKey = newKey
    state.nameEditSelectionKey = nil
    SI.printChat(SI.CHAT_PREFIX .. "profile renamed to " .. newKey)
    refreshPanel(state.panel)
end

local function onProfileDeleteClick()
    local deletedKey = state.selectedProfileKey
    local ok
    local err

    if not deletedKey then return end

    ok, err = Settings.DeleteProfile(deletedKey)
    if not ok then
        SI.printChat(SI.CHAT_PREFIX .. getProfileErrorMessage(err))
        return
    end

    state.selectedProfileKey = nil
    state.nameEditSelectionKey = nil
    SI.printChat(SI.CHAT_PREFIX .. "profile deleted: " .. deletedKey)
    refreshPanel(state.panel)
end

local function onProfileSwitchClick()
    local key = state.selectedProfileKey
    local ok
    local err

    if not key then return end

    ok, err = Settings.SetActiveProfile(key)
    if not ok then
        SI.printChat(SI.CHAT_PREFIX .. getProfileErrorMessage(err))
        return
    end

    SI.printChat(SI.CHAT_PREFIX .. "active profile set to " .. key)
end

local function onProfileExportClick()
    local key  = state.selectedProfileKey
    local text
    local err

    if not key then return end
    if not Settings.ExportProfile then return end

    text, err = Settings.ExportProfile(key)
    if not text then
        SI.printChat(SI.CHAT_PREFIX .. "export failed (" .. tostring(err or "?") .. ").")
        return
    end
    if SI.ShowProfileExportDialog then
        SI.ShowProfileExportDialog(text)
    end
end

local function onProfileImportClick()
    if SI.ShowProfileImportDialog then
        SI.ShowProfileImportDialog()
    end
end

local function onProfileResetClick()
    if not SI.ShowResetConfirmation then return end
    SI.ShowResetConfirmation(SI.UI_RESET_MODE_ACTIVE_PROFILE)
end

local function onRangeOffsetEnterPressed()
    commitRangeOffsetFromEdit()
    if this then this:ClearFocus() end
end

local function onRangeOffsetFocusLost()
    commitRangeOffsetFromEdit()
end

local function onRangeOffsetEscapePressed()
    refreshPanel(state.panel)
    if this then this:ClearFocus() end
end

local function onPollIntervalEnterPressed()
    commitPollIntervalFromEdit()
    if this then this:ClearFocus() end
end

local function onPollIntervalFocusLost()
    commitPollIntervalFromEdit()
end

local function onPollIntervalEscapePressed()
    refreshPanel(state.panel)
    if this then this:ClearFocus() end
end

local function onTooltipOffsetXEnterPressed()
    commitTooltipOffsetXFromEdit()
    if this then this:ClearFocus() end
end

local function onTooltipOffsetXFocusLost()
    commitTooltipOffsetXFromEdit()
end

local function onTooltipOffsetXEscapePressed()
    refreshPanel(state.panel)
    if this then this:ClearFocus() end
end

local function onTooltipOffsetYEnterPressed()
    commitTooltipOffsetYFromEdit()
    if this then this:ClearFocus() end
end

local function onTooltipOffsetYFocusLost()
    commitTooltipOffsetYFromEdit()
end

local function onTooltipOffsetYEscapePressed()
    refreshPanel(state.panel)
    if this then this:ClearFocus() end
end

local function onExpiryThresholdEnterPressed()
    commitExpiryThresholdFromEdit()
    if this then this:ClearFocus() end
end

local function onExpiryThresholdFocusLost()
    commitExpiryThresholdFromEdit()
end

local function onExpiryThresholdEscapePressed()
    refreshPanel(state.panel)
    if this then this:ClearFocus() end
end

------------------------------------------------------------------------
-- Private builders
------------------------------------------------------------------------

local function createTextLabel(parent, x, y, text, fontObject)
    local label = parent:CreateFontString(nil, "ARTWORK", fontObject or "GameFontNormal")

    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetText(text)
    return label
end

local function createEditBox(name, parent, width, anchor, relTo, relPoint, x, y)
    local edit = CreateFrame("EditBox", name, parent, "InputBoxTemplate")

    edit:SetWidth(width)
    edit:SetHeight(22)
    edit:SetPoint(anchor, relTo, relPoint, x, y)
    edit:SetAutoFocus(false)
    return edit
end

local function buildProfileSection(parent, controls, y)
    local activeLabel
    local nameLabel
    local hint

    controls.profileHeader = createTextLabel(parent, 18, y, "Profiles", "GameFontHighlight")

    y = y - 28
    activeLabel = createTextLabel(parent, 18, y, "Active Profile")
    controls.activeLabel = activeLabel

    controls.activeValue = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    controls.activeValue:SetPoint("TOPLEFT", activeLabel, "BOTTOMLEFT", 0, -4)
    controls.activeValue:SetWidth(280)
    controls.activeValue:SetJustifyH("LEFT")
    controls.activeValue:SetText("(none)")

    y = y - 46
    controls.profileResetButton = SI.createActionButton(parent, PROFILE_RESET_BUTTON_WIDTH, 18, y, "Reset Full Profile", onProfileResetClick)

    y = y - 40
    controls.selectedLabel = createTextLabel(parent, 18, y, "Saved Profiles")
    controls.profileDropdown = SI.createDropdown(
        PROFILE_DROPDOWN_NAME,
        parent,
        4,
        y - 14,
        200,
        initializeProfileDropdown
    )

    y = y - 52
    nameLabel = createTextLabel(parent, 18, y, "Profile Name")
    controls.nameLabel = nameLabel

    controls.profileNameEdit = createEditBox(
        PROFILE_NAME_EDIT_NAME,
        parent,
        188,
        "LEFT",
        nameLabel,
        "RIGHT",
        12,
        0
    )
    controls.profileNameEdit:SetMaxLetters(64)
    controls.profileNameEdit:SetScript("OnEnterPressed", onProfileNameEnterPressed)
    controls.profileNameEdit:SetScript("OnEscapePressed", onProfileNameEscapePressed)

    y = y - 30
    controls.profileCreateButton = SI.createActionButton(parent, 72, 18, y, "Create", onProfileCreateClick)
    controls.profileRenameButton = SI.createActionButton(parent, 72, 18 + 72 + BUTTON_GAP, y, "Rename", onProfileRenameClick)
    controls.profileSwitchButton = SI.createActionButton(parent, 72, 18 + (72 + BUTTON_GAP) * 2, y, "Switch", onProfileSwitchClick)
    controls.profileDeleteButton = SI.createActionButton(parent, 72, 18 + (72 + BUTTON_GAP) * 3, y, "Delete", onProfileDeleteClick)

    y = y - 28
    controls.profileExportButton = SI.createActionButton(parent, 72, 18, y, "Export", onProfileExportClick)
    controls.profileImportButton = SI.createActionButton(parent, 72, 18 + 72 + BUTTON_GAP, y, "Import", onProfileImportClick)

    hint = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, y - 32)
    hint:SetWidth(292)
    hint:SetJustifyH("LEFT")
    hint:SetText("New profiles are copied from the currently selected profile.")
    controls.profileHint = hint

    return y - 70
end

local function buildTuningSection(parent, controls, y)
    local pollLabel
    local rangeLabel

    controls.tuningHeader = createTextLabel(parent, 18, y, "Polling and Range", "GameFontHighlight")

    y = y - 30
    controls.rangeFadeCheck = SI.createCheckboxRow(parent, y, "Fade Out-of-Range Totems", onCheckboxClick)
    controls.rangeFadeCheck.onValueChanged = Settings.SetRangeFade

    y = y - 38
    pollLabel = createTextLabel(parent, 18, y, "Poll Interval")
    controls.pollLabel = pollLabel

    controls.pollIntervalEdit = createEditBox(
        POLL_INTERVAL_EDIT_NAME,
        parent,
        NUMERIC_EDIT_WIDTH,
        "LEFT",
        pollLabel,
        "RIGHT",
        10,
        0
    )
    controls.pollIntervalEdit:SetScript("OnEnterPressed",  onPollIntervalEnterPressed)
    controls.pollIntervalEdit:SetScript("OnEditFocusLost", onPollIntervalFocusLost)
    controls.pollIntervalEdit:SetScript("OnEscapePressed", onPollIntervalEscapePressed)

    rangeLabel = createTextLabel(parent, 174, y, "Range Offset")
    controls.rangeLabel = rangeLabel

    controls.rangeOffsetEdit = createEditBox(
        RANGE_OFFSET_EDIT_NAME,
        parent,
        NUMERIC_EDIT_WIDTH,
        "LEFT",
        rangeLabel,
        "RIGHT",
        10,
        0
    )
    controls.rangeOffsetEdit:SetScript("OnEnterPressed",  onRangeOffsetEnterPressed)
    controls.rangeOffsetEdit:SetScript("OnEditFocusLost", onRangeOffsetFocusLost)
    controls.rangeOffsetEdit:SetScript("OnEscapePressed", onRangeOffsetEscapePressed)

    return y - 40
end

local function buildDurationSection(parent, controls, y)
    local thresholdLabel
    local hint

    controls.durationHeader = createTextLabel(parent, 18, y, "Duration and Expiry", "GameFontHighlight")

    y = y - 30
    controls.timerShowMinutesCheck = SI.createCheckboxRow(parent, y, "Show Minutes In Timer", onCheckboxClick)
    controls.timerShowMinutesCheck.onValueChanged = Settings.SetTimerShowMinutes

    y = y - 28
    controls.expirySoundCheck = SI.createCheckboxRow(parent, y, "Play Totem Alert Sound", onCheckboxClick)
    controls.expirySoundCheck.onValueChanged = Settings.SetExpirySoundEnabled

    y = y - 38
    thresholdLabel = createTextLabel(parent, 18, y, "Expiry Threshold")
    controls.expiryThresholdLabel = thresholdLabel

    controls.expiryThresholdEdit = createEditBox(
        EXPIRY_THRESHOLD_EDIT_NAME,
        parent,
        NUMERIC_EDIT_WIDTH,
        "LEFT",
        thresholdLabel,
        "RIGHT",
        12,
        0
    )
    controls.expiryThresholdEdit:SetScript("OnEnterPressed", onExpiryThresholdEnterPressed)
    controls.expiryThresholdEdit:SetScript("OnEditFocusLost", onExpiryThresholdFocusLost)
    controls.expiryThresholdEdit:SetScript("OnEscapePressed", onExpiryThresholdEscapePressed)

    controls.expiryThresholdUnit = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    controls.expiryThresholdUnit:SetPoint("LEFT", controls.expiryThresholdEdit, "RIGHT", 8, 0)
    controls.expiryThresholdUnit:SetText("sec")

    hint = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, y - 26)
    hint:SetWidth(292)
    hint:SetJustifyH("LEFT")
    hint:SetText("0 disables only the threshold warning. Each active totem alerts at most once: at threshold, or on expiry/destruction if it never alerted earlier.")
    controls.durationHint = hint

    return y - 54
end

local function buildTooltipSection(parent, controls, y)
    local offsetXLabel
    local offsetYLabel

    controls.tooltipsHeader = createTextLabel(parent, 18, y, "Tooltips", "GameFontHighlight")

    y = y - 30
    controls.tooltipsEnabledCheck = SI.createCheckboxRow(parent, y, "Enable Tooltips", onCheckboxClick)
    controls.tooltipsEnabledCheck.onValueChanged = Settings.SetTooltipsEnabled

    y = y - 36
    controls.anchorLabel = createTextLabel(parent, 18, y, "Anchor")
    controls.tooltipAnchorDropdown = SI.createDropdown(
        TOOLTIP_ANCHOR_DROPDOWN_NAME,
        parent,
        4,
        y - 14,
        120,
        initializeTooltipAnchorDropdown
    )

    controls.directionLabel = createTextLabel(parent, 176, y, "Direction")
    controls.tooltipDirectionDropdown = SI.createDropdown(
        TOOLTIP_DIRECTION_DROPDOWN_NAME,
        parent,
        162,
        y - 14,
        120,
        initializeTooltipDirectionDropdown
    )

    y = y - 58
    offsetXLabel = createTextLabel(parent, 18, y, "Offset X")
    controls.offsetXLabel = offsetXLabel

    controls.tooltipOffsetXEdit = createEditBox(
        TOOLTIP_OFFSET_X_EDIT_NAME,
        parent,
        NUMERIC_EDIT_WIDTH,
        "LEFT",
        offsetXLabel,
        "RIGHT",
        12,
        0
    )
    controls.tooltipOffsetXEdit:SetScript("OnEnterPressed", onTooltipOffsetXEnterPressed)
    controls.tooltipOffsetXEdit:SetScript("OnEditFocusLost", onTooltipOffsetXFocusLost)
    controls.tooltipOffsetXEdit:SetScript("OnEscapePressed", onTooltipOffsetXEscapePressed)

    offsetYLabel = createTextLabel(parent, 174, y, "Offset Y")
    controls.offsetYLabel = offsetYLabel

    controls.tooltipOffsetYEdit = createEditBox(
        TOOLTIP_OFFSET_Y_EDIT_NAME,
        parent,
        NUMERIC_EDIT_WIDTH,
        "LEFT",
        offsetYLabel,
        "RIGHT",
        12,
        0
    )
    controls.tooltipOffsetYEdit:SetScript("OnEnterPressed", onTooltipOffsetYEnterPressed)
    controls.tooltipOffsetYEdit:SetScript("OnEditFocusLost", onTooltipOffsetYFocusLost)
    controls.tooltipOffsetYEdit:SetScript("OnEscapePressed", onTooltipOffsetYEscapePressed)

    return y
end

local function buildPanel(panel)
    local controls = {}
    local content = panel.contentFrame or panel
    local y = -8

    state.panel = panel
    panel.controls = controls

    y = buildProfileSection(content, controls, y)
    y = buildTuningSection(content, controls, y)
    y = buildDurationSection(content, controls, y)
    buildTooltipSection(content, controls, y)

    content:SetHeight(ADVANCED_MIN_CONTENT_HEIGHT)
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

SI.SetAdvancedSelectedProfileKey = setSelectedProfileKey

------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------

if SI.RegisterUITab then
    SI.RegisterUITab(SI.UI_TAB_ADVANCED, {
        Build = buildPanel,
        Refresh = refreshPanel,
        Scrollable = true,
        ContentWidth = ADVANCED_CONTENT_WIDTH,
    })
end
