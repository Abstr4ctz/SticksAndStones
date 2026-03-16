-- SticksAndStones: Settings/ImportExport.lua
-- Deterministic profile text export and strict text import support.
-- Owns share-string serialization, non-executing parse/validation, and
-- imported-profile key collision handling for the Settings pod.
-- Side effects: reads and writes SNSProfiles profile rows through
-- SettingsInternal and never calls WoW UI or game APIs directly.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = SettingsInternal

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local EXPORT_HEADER        = "SNS_PROFILE_V1"
local IMPORT_SUFFIX_LABEL  = "Imported"
local MAX_IMPORT_TEXT_SIZE = 131072

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function trimString(value)
    if type(value) ~= "string" then return nil end

    local _, _, trimmed = string.find(value, "^%s*(.-)%s*$")
    return trimmed
end

local function sortedNumericKeys(src)
    local keys = {}
    local count = 0
    local key
    local value

    for key, value in pairs(src) do
        if type(key) == "number" and value ~= nil then
            count = count + 1
            keys[count] = key
        end
    end

    table.sort(keys)
    return keys
end

local function quoteString(value)
    local text = value or ""

    text = string.gsub(text, "\\", "\\\\")
    text = string.gsub(text, "\"", "\\\"")
    text = string.gsub(text, "\r", "\\r")
    text = string.gsub(text, "\n", "\\n")

    return "\"" .. text .. "\""
end

local function emitScalarFields(out, config)
    out[table.getn(out) + 1] = "    visible             = " .. tostring(config.visible and true or false) .. ","
    out[table.getn(out) + 1] = "    minimapAngle        = " .. tostring(M.sanitizeMinimapAngle(config.minimapAngle)) .. ","
    out[table.getn(out) + 1] = "    scale               = " .. tostring(M.clamp(config.scale, M.SCALE_MIN, M.SCALE_MAX)) .. ","
    out[table.getn(out) + 1] = "    locked              = " .. tostring(config.locked and true or false) .. ","
    out[table.getn(out) + 1] = "    clickThrough        = " .. tostring(config.clickThrough and true or false) .. ","
    out[table.getn(out) + 1] = "    clickThroughMod     = " .. quoteString(M.sanitizeClickThroughMod(config.clickThroughMod)) .. ","
    out[table.getn(out) + 1] = "    flyoutMode          = " .. quoteString(M.sanitizeFlyoutMode(config.flyoutMode)) .. ","
    out[table.getn(out) + 1] = "    flyoutMod           = " .. quoteString(M.sanitizeFlyoutMod(config.flyoutMod)) .. ","
    out[table.getn(out) + 1] = "    showBorder          = " .. tostring(config.showBorder and true or false) .. ","
    out[table.getn(out) + 1] = "    tooltipsEnabled     = " .. tostring(config.tooltipsEnabled and true or false) .. ","
    out[table.getn(out) + 1] = "    tooltipAnchorMode   = " .. quoteString(config.tooltipAnchorMode) .. ","
    out[table.getn(out) + 1] = "    tooltipDirection    = " .. quoteString(config.tooltipDirection) .. ","
    out[table.getn(out) + 1] = "    tooltipOffsetX      = " .. tostring(M.sanitizeTooltipOffset(config.tooltipOffsetX, M.DEFAULTS.tooltipOffsetX)) .. ","
    out[table.getn(out) + 1] = "    tooltipOffsetY      = " .. tostring(M.sanitizeTooltipOffset(config.tooltipOffsetY, M.DEFAULTS.tooltipOffsetY)) .. ","
    out[table.getn(out) + 1] = "    snapAlign           = " .. tostring(config.snapAlign and true or false) .. ","
    out[table.getn(out) + 1] = "    rangeFade           = " .. tostring(config.rangeFade and true or false) .. ","
    out[table.getn(out) + 1] = "    rangeOffsetYards    = " .. tostring(M.sanitizeRangeOffsetYards(config.rangeOffsetYards, M.DEFAULTS.rangeOffsetYards)) .. ","
    out[table.getn(out) + 1] = "    pollInterval        = " .. tostring(M.sanitizePollInterval(config.pollInterval, M.DEFAULTS.pollInterval)) .. ","
    out[table.getn(out) + 1] = "    timerShowMinutes    = " .. tostring(config.timerShowMinutes and true or false) .. ","
    out[table.getn(out) + 1] = "    expiryThresholdSecs = " .. tostring(M.sanitizeExpiryThresholdSecs(config.expiryThresholdSecs, M.DEFAULTS.expiryThresholdSecs)) .. ","
    out[table.getn(out) + 1] = "    expirySoundEnabled  = " .. tostring(config.expirySoundEnabled and true or false) .. ","
    out[table.getn(out) + 1] = "    activeSetIndex      = " .. tostring(config.activeSetIndex) .. ","
    out[table.getn(out) + 1] = "    setsCycleWrap       = " .. tostring(config.setsCycleWrap and true or false) .. ","
end

local function emitSets(out, sets)
    local index
    local slot
    local setRow
    local row

    out[table.getn(out) + 1] = "    sets = {"

    for index = 1, table.getn(sets) do
        setRow = sets[index]
        if type(setRow) == "table" then
            out[table.getn(out) + 1] = "      [" .. index .. "] = {"

            for slot = 1, M.MAX_ELEMENTS do
                row = setRow[slot]
                if type(row) == "number" then
                    out[table.getn(out) + 1] = "        [" .. slot .. "] = " .. tostring(math.floor(row)) .. ","
                end
            end

            out[table.getn(out) + 1] = "      },"
        end
    end

    out[table.getn(out) + 1] = "    },"
end

local function emitElements(out, elements)
    local index
    local element
    local order
    local filter
    local filterKeys
    local filterIndex
    local spellId

    out[table.getn(out) + 1] = "    elements = {"

    for index = 1, M.MAX_ELEMENTS do
        element = elements[index] or {}
        out[table.getn(out) + 1] = "      [" .. index .. "] = {"

        if type(element.centerX) == "number" then
            out[table.getn(out) + 1] = "        centerX = " .. tostring(element.centerX) .. ","
        end
        if type(element.centerY) == "number" then
            out[table.getn(out) + 1] = "        centerY = " .. tostring(element.centerY) .. ","
        end

        out[table.getn(out) + 1] = "        borderColorR  = " .. tostring(M.sanitizeColorChannel(element.borderColorR)) .. ","
        out[table.getn(out) + 1] = "        borderColorG  = " .. tostring(M.sanitizeColorChannel(element.borderColorG)) .. ","
        out[table.getn(out) + 1] = "        borderColorB  = " .. tostring(M.sanitizeColorChannel(element.borderColorB)) .. ","
        out[table.getn(out) + 1] = "        elementColorR = " .. tostring(M.sanitizeColorChannel(element.elementColorR)) .. ","
        out[table.getn(out) + 1] = "        elementColorG = " .. tostring(M.sanitizeColorChannel(element.elementColorG)) .. ","
        out[table.getn(out) + 1] = "        elementColorB = " .. tostring(M.sanitizeColorChannel(element.elementColorB)) .. ","
        out[table.getn(out) + 1] = "        flyoutDir     = " .. quoteString(M.sanitizeFlyoutDir(element.flyoutDir)) .. ","
        out[table.getn(out) + 1] = "        flyoutOrder   = {"

        order = M.sanitizeFlyoutOrder(element.flyoutOrder)
        for filterIndex = 1, table.getn(order) do
            out[table.getn(out) + 1] = "          [" .. filterIndex .. "] = " .. tostring(order[filterIndex]) .. ","
        end

        out[table.getn(out) + 1] = "        },"
        out[table.getn(out) + 1] = "        flyoutFilter = {"

        filter = M.sanitizeFlyoutFilter(element.flyoutFilter)
        filterKeys = sortedNumericKeys(filter)
        for filterIndex = 1, table.getn(filterKeys) do
            spellId = filterKeys[filterIndex]
            out[table.getn(out) + 1] = "          [" .. spellId .. "] = true,"
        end

        out[table.getn(out) + 1] = "        },"
        out[table.getn(out) + 1] = "      },"
    end

    out[table.getn(out) + 1] = "    },"
end

local function serializeProfile(key, profile)
    local config = M.sanitizeProfile(profile)
    local out = {}

    out[table.getn(out) + 1] = EXPORT_HEADER
    out[table.getn(out) + 1] = "{"
    out[table.getn(out) + 1] = "  profileKey = " .. quoteString(key) .. ","
    out[table.getn(out) + 1] = "  config = {"

    emitScalarFields(out, config)
    emitSets(out, config.sets or {})
    emitElements(out, config.elements or {})

    out[table.getn(out) + 1] = "  },"
    out[table.getn(out) + 1] = "}"

    return table.concat(out, "\n")
end

local function tokenize(text)
    local tokens = {}
    local index = 1
    local limit = string.len(text)

    while index <= limit do
        local ch = string.sub(text, index, index)

        if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
            index = index + 1

        elseif ch == "{" or ch == "}" or ch == "[" or ch == "]" or ch == "=" or ch == "," then
            tokens[table.getn(tokens) + 1] = { kind = ch }
            index                          = index + 1

        elseif ch == "\"" or ch == "'" then
            local quote  = ch
            local parts  = {}
            local closed = nil

            index = index + 1

            while index <= limit do
                local current = string.sub(text, index, index)
                local nextChar

                if current == "\\" then
                    nextChar = string.sub(text, index + 1, index + 1)

                    if nextChar == "n" then
                        parts[table.getn(parts) + 1] = "\n"
                    elseif nextChar == "r" then
                        parts[table.getn(parts) + 1] = "\r"
                    elseif nextChar == "t" then
                        parts[table.getn(parts) + 1] = "\t"
                    elseif nextChar == "\\" or nextChar == "\"" or nextChar == "'" then
                        parts[table.getn(parts) + 1] = nextChar
                    else
                        return nil, "invalid_escape"
                    end

                    index = index + 2
                elseif current == quote then
                    closed = true
                    index = index + 1
                    break
                else
                    parts[table.getn(parts) + 1] = current
                    index = index + 1
                end
            end

            if not closed then return nil, "unterminated_string" end

            tokens[table.getn(tokens) + 1] = {
                kind = "string",
                value = table.concat(parts, ""),
            }
        else
            local rest     = string.sub(text, index)
            local numText
            local numValue
            local ident

            local _, _, matched = string.find(rest, "^(%-?%d+%.?%d*[eE][%+%-]?%d+)")
            if matched then
                numText = matched
            else
                _, _, matched = string.find(rest, "^(%-?%d+%.?%d*)")
                numText = matched
            end

            if numText then
                numValue = tonumber(numText)
                if numValue == nil then return nil, "invalid_number" end

                tokens[table.getn(tokens) + 1] = {
                    kind = "number",
                    value = numValue,
                }
                index = index + string.len(numText)
            else
                local _, _, capture = string.find(rest, "^([%a_][%w_]*)")
                ident = capture
                if not ident then
                    return nil, "unexpected_char"
                end

                if ident == "true" then
                    tokens[table.getn(tokens) + 1] = { kind = "boolean", value = true }
                elseif ident == "false" then
                    tokens[table.getn(tokens) + 1] = { kind = "boolean", value = false }
                elseif ident == "nil" then
                    tokens[table.getn(tokens) + 1] = { kind = "nil", value = nil }
                else
                    tokens[table.getn(tokens) + 1] = { kind = "identifier", value = ident }
                end

                index = index + string.len(ident)
            end
        end
    end

    tokens[table.getn(tokens) + 1] = { kind = "eof" }
    return tokens
end

local function parseTokens(tokens)
    local pos = 1
    local parseValue

    local function peek(offset)
        return tokens[pos + (offset or 0)]
    end

    local function consume(kind)
        local token = peek(0)

        if not token or token.kind ~= kind then return nil end

        pos = pos + 1
        return token
    end

    local function parseTable()
        local out         = {}
        local arrayIndex  = 1
        local token
        local key
        local keyValue
        local keyErr
        local explicitKey
        local value
        local valueErr

        if not consume("{") then return nil, "expected_table_start" end

        while true do
            token = peek(0)
            if not token then return nil, "unexpected_end" end

            if token.kind == "}" then
                consume("}")
                return out
            end

            key = nil
            explicitKey = nil

            if token.kind == "[" then
                consume("[")
                keyValue, keyErr = parseValue()
                if keyErr then return nil, keyErr end
                if keyValue == nil then return nil, "invalid_key" end
                if not consume("]") then return nil, "expected_key_close" end
                if not consume("=") then return nil, "expected_equals" end

                key = keyValue
                explicitKey = true
            elseif token.kind == "identifier" and peek(1) and peek(1).kind == "=" then
                key = token.value
                consume("identifier")
                consume("=")
                explicitKey = true
            end

            value, valueErr = parseValue()
            if valueErr then return nil, valueErr end

            if explicitKey then
                out[key] = value
            else
                out[arrayIndex] = value
                arrayIndex = arrayIndex + 1
            end

            token = peek(0)
            if token and token.kind == "," then
                consume(",")
            elseif token and token.kind == "}" then
            else
                if not token then return nil, "unexpected_end" end
                return nil, "expected_separator"
            end
        end
    end

    parseValue = function()
        local token = peek(0)

        if not token then return nil, "unexpected_end" end

        if token.kind == "string" then
            consume("string")
            return token.value
        end
        if token.kind == "number" then
            consume("number")
            return token.value
        end
        if token.kind == "boolean" then
            consume("boolean")
            return token.value
        end
        if token.kind == "nil" then
            consume("nil")
            return nil
        end
        if token.kind == "{" then
            return parseTable()
        end

        return nil, "unexpected_token"
    end

    local root, err = parseValue()
    if err then return nil, err end
    if not consume("eof") then return nil, "trailing_tokens" end

    return root
end

local function parseImportText(text)
    local body
    local tokens
    local tokenErr
    local root
    local parseErr
    local payload
    local importedKey

    if type(text) ~= "string" then return nil, nil, "invalid_text" end
    if string.len(text) > MAX_IMPORT_TEXT_SIZE then
        return nil, nil, "text_too_large"
    end
    if not string.find(text, "^%s*" .. EXPORT_HEADER) then
        return nil, nil, "missing_header"
    end

    body = string.gsub(text, "^%s*" .. EXPORT_HEADER, "", 1)
    body = trimString(body)
    if not body or body == "" then
        return nil, nil, "missing_payload"
    end

    tokens, tokenErr = tokenize(body)
    if tokenErr then return nil, nil, tokenErr end

    root, parseErr = parseTokens(tokens)
    if parseErr then return nil, nil, parseErr end
    if type(root) ~= "table" then return nil, nil, "invalid_payload" end

    payload = root.config
    if type(payload) ~= "table" then payload = root end
    if type(payload) ~= "table" then return nil, nil, "invalid_config" end

    importedKey = M.sanitizeProfileKey(root.profileKey)
    return M.sanitizeProfile(payload), importedKey, nil
end

local function makeUniqueImportedKey(baseKey)
    local base        = M.sanitizeProfileKey(baseKey) or M.characterKey()
    local candidate
    local suffixIndex

    if type(SNSProfiles.profiles[base]) ~= "table" then
        return base
    end

    candidate = base .. " (" .. IMPORT_SUFFIX_LABEL .. ")"
    if type(SNSProfiles.profiles[candidate]) ~= "table" then
        return candidate
    end

    suffixIndex = 2
    while true do
        candidate = base .. " (" .. IMPORT_SUFFIX_LABEL .. " " .. suffixIndex .. ")"
        if type(SNSProfiles.profiles[candidate]) ~= "table" then
            return candidate
        end
        suffixIndex = suffixIndex + 1
    end
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function exportProfile(key)
    local exportKey = key

    if not exportKey and M.GetActiveProfileKeyInternal then
        exportKey = M.GetActiveProfileKeyInternal()
    end
    if type(exportKey) ~= "string" then
        return nil, "profile_missing"
    end
    if type(SNSProfiles.profiles[exportKey]) ~= "table" then
        return nil, "profile_missing"
    end

    return serializeProfile(exportKey, SNSProfiles.profiles[exportKey])
end

local function importProfile(text)
    local importedProfile
    local importedKey
    local parseErr
    local newKey

    importedProfile, importedKey, parseErr = parseImportText(text)
    if parseErr then return nil, parseErr end

    newKey = makeUniqueImportedKey(importedKey or M.characterKey())
    SNSProfiles.profiles[newKey] = importedProfile
    return newKey
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.ExportProfileInternal = exportProfile
M.ImportProfileInternal = importProfile
