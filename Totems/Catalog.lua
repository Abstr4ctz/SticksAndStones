-- SticksAndStones: Totems/Catalog.lua
-- Support module for spellbook scanning and canonical totem metadata indexes
-- in the Totems pod.
-- Owns TotemsInternal.bySpellId, TotemsInternal.byUnitName,
-- TotemsInternal.byElement, and TotemsInternal.canonicalSpellIdBySpellId.
-- Exports catalog rebuild, snapshot, and level-refresh policy helpers on
-- TotemsInternal.
-- Side effects: creates a hidden private tooltip scanner at load time and reads
-- spellbook, DBC, and tooltip APIs during rebuildCatalog().

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = TotemsInternal  -- created by Totems facade, loaded first per TOC order

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local BOOKTYPE_SPELL   = "spell"
local MAX_PLAYER_LEVEL = 60
local MAX_SCAN_LINES   = 30

local UnitLevel = UnitLevel

-- Maps DBC tool-item IDs to SNS element constants (EARTH=1 .. AIR=4).
local TOOL_ID_TO_ELEMENT = {
    [5175] = SNS.EARTH,
    [5176] = SNS.FIRE,
    [5177] = SNS.WATER,
    [5178] = SNS.AIR,
}

-- Hardcoded tick intervals in seconds for known periodic totems.
-- Keyed by DBC base name. Unlisted totems receive 0.
local TICK_INTERVALS = {
    ["Tremor Totem"]            = 4,
    ["Poison Cleansing Totem"]  = 5,
    ["Disease Cleansing Totem"] = 5,
    ["Earthbind Totem"]         = 3,
    ["Magma Totem"]             = 2,
    ["Stoneclaw Totem"]         = 1.5,
}

-- Hardcoded ranges in yards for totems whose spellbook tooltip omits range.
-- Keyed by DBC base name. Unlisted totems fall back to tooltip parsing only.
local RANGE_FALLBACKS = {
    ["Grounding Totem"] = 30,
}

-- Roman numeral suffixes for ranks 2-10; index = rank - 1.
-- Ranks above 10 fall back to a plain numeric string in buildUnitName().
local ROMAN_SUFFIXES = { "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }

------------------------------------------------------------------------
-- Private state
------------------------------------------------------------------------

local scanTooltip = CreateFrame("GameTooltip", nil, UIParent)
local scanLines   = {}
for i = 1, MAX_SCAN_LINES do
    local left  = scanTooltip:CreateFontString(nil, "ARTWORK", "GameTooltipText")
    local right = scanTooltip:CreateFontString(nil, "ARTWORK", "GameTooltipText")
    scanTooltip:AddFontStrings(left, right)
    scanLines[i] = left
end
scanTooltip:Hide()

M.bySpellId  = {}
M.byUnitName = {}
M.byElement  = {
    [SNS.EARTH] = {},
    [SNS.FIRE]  = {},
    [SNS.WATER] = {},
    [SNS.AIR]   = {},
}
M.canonicalSpellIdBySpellId = {}

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function newElementBuckets()
    return {
        [SNS.EARTH] = {},
        [SNS.FIRE]  = {},
        [SNS.WATER] = {},
        [SNS.AIR]   = {},
    }
end

-- Returns the unit name for a totem given its base name and numeric rank.
-- rank 1 -> baseName; rank 2-10 -> "baseName ROMAN"; rank > 10 -> "baseName N".
local function buildUnitName(baseName, rank)
    if rank <= 1 then return baseName end
    local suffix = ROMAN_SUFFIXES[rank - 1]
    if suffix then return baseName .. " " .. suffix end
    return baseName .. " " .. tostring(rank)
end

-- Resolves a numeric rank from WoW rank text (e.g. "Rank 5" -> 5).
-- Returns 1 for nil, empty, or strings with no digit sequence.
local function resolveRankNumber(rankText)
    if not rankText or string.len(rankText) == 0 then return 1 end
    local _, _, digits = string.find(rankText, "(%d+)")
    if digits then return tonumber(digits) end
    return 1
end

-- Resolves a DBC spell ID from a spellbook name and rank text.
-- Three-step fallback: exact rank string -> normalized "Rank N" -> base name only.
-- Returns the spell ID on success, or nil when all steps fail.
-- Note: GetSpellSlotTypeIdForName returns (slotNum, bookType, spellId); we take
-- the third return value. The single-string argument combines name and rank as
-- "SpellName(Rank N)" per the confirmed working prototype.
local function resolveSpellId(spellbookName, spellbookRankText)
    local _, _, spellId

    -- Step 1: exact rank text as returned by GetSpellName.
    local fullName
    if spellbookRankText and spellbookRankText ~= "" then
        fullName = spellbookName .. "(" .. spellbookRankText .. ")"
        _, _, spellId = GetSpellSlotTypeIdForName(fullName)
        if spellId and spellId > 0 then return spellId end
    end

    -- Step 2: normalized "Rank N" form (handles non-standard rank strings).
    local rankNumber     = resolveRankNumber(spellbookRankText)
    local normalizedName = spellbookName .. "(Rank " .. rankNumber .. ")"
    if normalizedName ~= fullName then
        _, _, spellId = GetSpellSlotTypeIdForName(normalizedName)
        if spellId and spellId > 0 then return spellId end
    end

    -- Step 3: base name only (for single-rank spells with no rank text).
    _, _, spellId = GetSpellSlotTypeIdForName(spellbookName)
    if spellId and spellId > 0 then return spellId end

    return nil
end

local function wipeMap(map)
    for key in pairs(map) do
        map[key] = nil
    end
end

local function wipeElementBuckets(buckets)
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        wipeMap(buckets[element])
    end
end

local function buildCanonicalSpellIdMap(bestByBaseName)
    wipeMap(M.canonicalSpellIdBySpellId)

    for spellId, record in pairs(M.bySpellId) do
        local bestRecord = bestByBaseName[record.element][record.baseName]
        M.canonicalSpellIdBySpellId[spellId] = bestRecord and bestRecord.spellId or spellId
    end
end

local function parseTooltipRange(textLower)
    local _, _, digits = string.find(textLower, "within%s+(%d+%.?%d*)%s+yards")
    if not digits then
        _, _, digits = string.find(textLower, "within%s*(%d+%.?%d*)%s*yd")
    end
    if not digits then
        _, _, digits = string.find(textLower, "(%d+%.?%d*)%s*yards")
    end
    if not digits then return nil end

    local range = tonumber(digits)
    if not range then return nil end
    return math.floor(range)
end

local function parseTooltipManaCost(textLower)
    local _, _, digits = string.find(textLower, "^(%d+)%s+mana")
    if not digits then
        _, _, digits = string.find(textLower, "^mana%s*:%s*(%d+)")
    end
    if not digits then
        _, _, digits = string.find(textLower, "(%d+)%s+mana")
    end
    if not digits then return nil end

    return tonumber(digits)
end

-- Reads range in yards and numeric mana cost from the spellbook tooltip.
-- Mana cost parsing prefers the concrete value shown by the client.
-- Returns rangeYards|nil, manaCost|nil.
local function readTooltipData(slotIndex)
    scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTooltip:ClearLines()
    scanTooltip:SetSpell(slotIndex, BOOKTYPE_SPELL)

    local rangeYards = nil
    local manaCost   = nil

    for i = 1, MAX_SCAN_LINES do
        local fontStr = scanLines[i]
        if not fontStr then break end
        local text = fontStr:GetText()
        if text then
            local textLower = string.lower(text)
            if rangeYards == nil then rangeYards = parseTooltipRange(textLower) end
            if manaCost == nil then manaCost = parseTooltipManaCost(textLower) end
        end

        if rangeYards ~= nil and manaCost ~= nil then
            scanTooltip:Hide()
            return rangeYards, manaCost
        end
    end

    scanTooltip:Hide()
    return rangeYards, manaCost
end

local function resolveRangeYards(baseName, tooltipRangeYards)
    if tooltipRangeYards ~= nil then return tooltipRangeYards end
    if not baseName then return nil end
    return RANGE_FALLBACKS[baseName]
end

local function shallowCopyRecord(record)
    local copy = {}
    for key, value in pairs(record) do
        copy[key] = value
    end
    return copy
end

local function copyElementSnapshotList(sourceList, targetList, snapshotBySpellId)
    for i = 1, table.getn(sourceList) do
        local record = sourceList[i]
        if record ~= nil then
            targetList[i] = snapshotBySpellId[record.spellId]
        end
    end
end

local function buildTotemRecord(slotIndex, spellbookName, spellbookRankText)
    local spellId     = resolveSpellId(spellbookName, spellbookRankText)
    if not spellId then return nil end

    -- Read tool-item ID first; returned table is a reused buffer.
    local totemInfo   = GetSpellRecField(spellId, "totem")
    local toolId      = totemInfo and totemInfo[1]
    local element     = TOOL_ID_TO_ELEMENT[toolId]
    if not element then return nil end

    local dbcName     = GetSpellRecField(spellId, "name")
    local dbcRankText = GetSpellRecField(spellId, "rank")
    local iconId      = GetSpellRecField(spellId, "spellIconID")
    local manaCost    = GetSpellRecField(spellId, "manaCost") or 0
    local manaCostPct = GetSpellRecField(spellId, "manaCostPercentage") or 0

    local icon        = iconId and GetSpellIconTexture(iconId) or nil
    local durationMs  = GetSpellDuration(spellId)
    local duration    = (durationMs and durationMs > 0) and (durationMs / 1000) or 0

    local baseName    = dbcName or spellbookName
    local rank        = resolveRankNumber(dbcRankText)
    local unitName    = buildUnitName(baseName, rank)
    local rangeYards, tooltipManaCost = readTooltipData(slotIndex)

    rangeYards = resolveRangeYards(baseName, rangeYards)
    if tooltipManaCost ~= nil then
        manaCost = tooltipManaCost
    end

    return {
        spellId      = spellId,
        baseName     = baseName,
        rank         = rank,
        element      = element,
        unitName     = unitName,
        icon         = icon,
        duration     = duration,
        rangeYards   = rangeYards,
        tickInterval = TICK_INTERVALS[baseName] or 0,
        manaCost     = manaCost,
        manaCostPct  = manaCostPct,
    }
end

local function storeTotemRecord(totemRecord, bestByBaseName)
    local spellId  = totemRecord.spellId
    local unitName = totemRecord.unitName
    local element  = totemRecord.element
    local baseName = totemRecord.baseName

    M.bySpellId[spellId]   = totemRecord
    M.byUnitName[unitName] = totemRecord

    -- byElement keeps only the highest rank per totem type.
    local current = bestByBaseName[element][baseName]
    if not current or totemRecord.rank > current.rank then
        bestByBaseName[element][baseName] = totemRecord
    end
end

local function rebuildCatalogSlot(slotIndex, bestByBaseName)
    local spellbookName, spellbookRankText = GetSpellName(slotIndex, BOOKTYPE_SPELL)
    if not spellbookName then return end

    local totemRecord = buildTotemRecord(slotIndex, spellbookName, spellbookRankText)
    if not totemRecord then return end

    storeTotemRecord(totemRecord, bestByBaseName)
end

local function compareByBaseName(a, b)
    return a.baseName < b.baseName
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function shouldTrackLevelRefresh(newLevel)
    local level = tonumber(newLevel)
    if level == nil and UnitLevel then
        level = UnitLevel("player")
    end
    return type(level) == "number" and level < MAX_PLAYER_LEVEL
end

local function resolveCanonicalSpellId(spellId)
    if type(spellId) ~= "number" then return nil end
    if not M.bySpellId[spellId] then return nil end
    return M.canonicalSpellIdBySpellId[spellId] or spellId
end

-- Allocates a fully detached copy; catalog refresh is event-driven, not hot-path.
local function buildCatalogSnapshot()
    local catalog = {
        bySpellId  = {},
        byUnitName = {},
        byElement  = newElementBuckets(),
    }

    for spellId, record in pairs(M.bySpellId) do
        local recordCopy = shallowCopyRecord(record)
        catalog.bySpellId[spellId] = recordCopy
        if recordCopy.unitName ~= nil then
            catalog.byUnitName[recordCopy.unitName] = recordCopy
        end
    end

    for element = 1, SNS.MAX_TOTEM_SLOTS do
        copyElementSnapshotList(
            M.byElement[element],
            catalog.byElement[element],
            catalog.bySpellId
        )
    end

    return catalog
end

-- Wipes all three indexes and rebuilds them from the current spellbook.
--
--   M.bySpellId [spellId]   = totemRecord   (all ranks)
--   M.byUnitName[unitName]  = totemRecord   (all ranks; unitName is unique per rank)
--   M.byElement [element]   = { totemRecord, ... }
--       one entry per unique totem type (baseName), highest rank only,
--       sorted alphabetically by baseName.
--
-- All three indexes reference the same totemRecord tables - no copies.
-- Note: GetSpellRecField returns a reused table for array fields. The "totem"
-- field (tool-item IDs) is read and consumed before any subsequent DBC call.
local function rebuildCatalog()
    wipeMap(M.bySpellId)
    wipeMap(M.byUnitName)
    wipeElementBuckets(M.byElement)
    wipeMap(M.canonicalSpellIdBySpellId)

    -- Temporary: highest-rank record per (element, baseName) for byElement.
    local bestByBaseName = newElementBuckets()

    local numTabs = GetNumSpellTabs()
    for tab = 1, numTabs do
        local _, _, offset, count = GetSpellTabInfo(tab)
        for i = 1, count do
            rebuildCatalogSlot(offset + i, bestByBaseName)
        end
    end

    -- Collect best-rank records into byElement and sort each list by baseName.
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        local list     = M.byElement[element]
        local listSize = 0
        for _, record in pairs(bestByBaseName[element]) do
            listSize = listSize + 1
            list[listSize] = record
        end
        table.sort(list, compareByBaseName)
    end

    buildCanonicalSpellIdMap(bestByBaseName)
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.BuildCatalogSnapshot    = buildCatalogSnapshot
M.RebuildCatalog          = rebuildCatalog
M.ResolveCanonicalSpellId = resolveCanonicalSpellId
M.ShouldTrackLevelRefresh = shouldTrackLevelRefresh
