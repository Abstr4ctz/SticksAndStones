-- SticksAndStones: Display/Cooldowns.lua
-- Cooldown overlay support module for the Display pod.
-- Owns cooldown-provider normalization, resolved cooldown selection,
-- cooldown sweep/text frame lifecycle, and the tracked cooldown update loop.
-- Exports cooldown helpers on DisplayInternal.
-- Side effects: creates one hidden update frame for tracked cooldown text refresh.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = DisplayInternal

local CreateFrame            = CreateFrame
local GetTime               = GetTime
local GetSpellIdCooldown    = GetSpellIdCooldown
local CooldownFrame_SetTimer = CooldownFrame_SetTimer
local time                   = time

------------------------------------------------------------------------
-- Private constants
------------------------------------------------------------------------

local COOLDOWN_SWEEP_MIN_MS     = 1500
local VANILLA_TIME_WRAP_MS      = 2 ^ 32
local VANILLA_TIME_WRAP_SECONDS = VANILLA_TIME_WRAP_MS / 1000
local COOLDOWN_UPDATE_INTERVAL  = 0.1

local scratchCandidateA         = {}
local scratchCandidateB         = {}
local scratchResolvedCooldown   = {}

------------------------------------------------------------------------
-- Owned state
------------------------------------------------------------------------

M.cooldownUpdateFrame    = nil
M.cooldownUpdateLastTick = 0

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function clearCooldownText(frame)
    if not frame or not frame.cooldownText then return end

    frame.cooldownText:Hide()
    frame.cooldownText:SetText("")
    frame.cooldownTextValue = false
end

local function clearCooldownFrame(frame)
    if not frame or not frame.cooldown then return end

    frame.cooldown:Hide()
    frame.cooldownSpellId  = false
    frame.cooldownSource   = false
    frame.cooldownStart    = -1
    frame.cooldownDuration = -1
    frame.cooldownVisible  = false
    clearCooldownText(frame)
end

local function getSafeRemainingSeconds(startS, durationS)
    if type(startS) ~= "number" or type(durationS) ~= "number" or durationS <= 0 then
        return 0
    end

    local now = GetTime()
    if type(now) ~= "number" then
        return 0
    end

    if startS <= now then
        return durationS - (now - startS)
    end

    local sysTime = time()
    if type(sysTime) ~= "number" then
        return 0
    end

    local startupTime = sysTime - now
    local cdTime      = VANILLA_TIME_WRAP_SECONDS - startS
    local cdStartTime = startupTime - cdTime
    local cdEndTime   = cdStartTime + durationS
    return cdEndTime - sysTime
end

local function normalizeCooldownMs(value)
    if type(value) ~= "number" then return nil end

    -- Nampower can surface wrapped negative millisecond values as huge uint32s.
    if value > (VANILLA_TIME_WRAP_MS / 2) then
        value = value - VANILLA_TIME_WRAP_MS
    end

    return value
end

local function clearCooldownCandidate(candidate)
    candidate.source     = nil
    candidate.startS     = nil
    candidate.durationS  = nil
    candidate.remainingS = nil
end

local function hasCooldownCandidate(candidate)
    return candidate
       and candidate.source     ~= nil
       and candidate.startS     ~= nil
       and candidate.durationS  ~= nil
       and candidate.remainingS ~= nil
end

local function copyCooldownCandidate(target, source)
    if not target or not hasCooldownCandidate(source) then return nil end

    target.source     = source.source
    target.startS     = source.startS
    target.durationS  = source.durationS
    target.remainingS = source.remainingS
    return target
end

local function buildCooldownCandidate(candidate, source, isOnCooldown, startS, durationMs)
    clearCooldownCandidate(candidate)

    if isOnCooldown ~= 1 then return nil end
    if source ~= "individual" and source ~= "category" then return nil end
    if type(startS) ~= "number" then return nil end

    durationMs = normalizeCooldownMs(durationMs)
    if type(durationMs) ~= "number" or durationMs <= COOLDOWN_SWEEP_MIN_MS then return nil end

    local durationS  = durationMs / 1000
    local remainingS = getSafeRemainingSeconds(startS, durationS)
    if remainingS <= 0 then return nil end

    candidate.source     = source
    candidate.startS     = startS
    candidate.durationS  = durationS
    candidate.remainingS = remainingS
    return candidate
end

local function pickResolvedCooldown(best, candidate)
    if not hasCooldownCandidate(candidate) then
        if hasCooldownCandidate(best) then
            return best
        end
        return nil
    end

    if not hasCooldownCandidate(best) then
        return copyCooldownCandidate(best, candidate)
    end

    if candidate.remainingS > best.remainingS then
        return copyCooldownCandidate(best, candidate)
    end

    if candidate.remainingS == best.remainingS
   and candidate.source     == "individual"
   and best.source          ~= "individual" then
        return copyCooldownCandidate(best, candidate)
    end

    return best
end

local function copyResolvedCooldown(candidate)
    if not hasCooldownCandidate(candidate) then return nil end

    scratchResolvedCooldown.source     = candidate.source
    scratchResolvedCooldown.startS     = candidate.startS
    scratchResolvedCooldown.durationS  = candidate.durationS
    scratchResolvedCooldown.remainingS = candidate.remainingS
    return scratchResolvedCooldown
end

local function resolveSpellCooldown(spellId)
    if not spellId or type(GetSpellIdCooldown) ~= "function" then return nil end

    local cooldown = GetSpellIdCooldown(spellId)
    if type(cooldown) ~= "table" then return nil end

    buildCooldownCandidate(
        scratchCandidateA,
        "individual",
        cooldown.isOnIndividualCooldown,
        cooldown.individualStartS,
        cooldown.individualDurationMs
    )
    local best = pickResolvedCooldown(
        scratchCandidateA,
        buildCooldownCandidate(
            scratchCandidateB,
            "category",
            cooldown.isOnCategoryCooldown,
            cooldown.categoryStartS,
            cooldown.categoryDurationMs
        )
    )
    return copyResolvedCooldown(best)
end

local function formatCooldownText(remainingS)
    if type(remainingS) ~= "number" or remainingS <= 0 then return false end

    local formatter = M.FormatTimerText
    if type(formatter) == "function" then
        return formatter(math.ceil(remainingS))
    end

    return tostring(math.ceil(remainingS))
end

local function applyCooldownText(frame, remainingS)
    if not frame or not frame.cooldownText then return end

    local text = formatCooldownText(remainingS)
    if not text then
        clearCooldownText(frame)
        return
    end

    if text ~= frame.cooldownTextValue then
        frame.cooldownText:SetText(text)
        frame.cooldownTextValue = text
    end

    frame.cooldownText:Show()
end

local function hasTrackedCooldownFrames()
    local buttons = M.buttons
    if not buttons then return false end

    local element
    local i
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        local btn = buttons[element]
        if btn and btn.cooldownVisible and btn:IsShown() then return true end
        if btn and btn.peek and btn.peek.cooldownVisible and btn.peek:IsShown() then return true end

        local root = btn and btn.flyout
        if root and root:IsShown() then
            for i = 1, table.getn(root.entries) do
                local entry = root.entries[i]
                if entry and entry.cooldownVisible and entry:IsShown() then
                    return true
                end
            end
        end
    end

    return false
end

local function syncResolvedCooldown(frame, spellId, resolved)
    if not frame or not frame.cooldown or not resolved then return end

    if frame.cooldownVisible
   and frame.cooldownSpellId  == spellId
   and frame.cooldownSource   == resolved.source
   and frame.cooldownStart    == resolved.startS
   and frame.cooldownDuration == resolved.durationS then
        applyCooldownText(frame, resolved.remainingS)
        return
    end

    frame.cooldown:Show()
    CooldownFrame_SetTimer(frame.cooldown, resolved.startS, resolved.durationS, 1)
    frame.cooldownSpellId  = spellId
    frame.cooldownSource   = resolved.source
    frame.cooldownStart    = resolved.startS
    frame.cooldownDuration = resolved.durationS
    frame.cooldownVisible  = true
    applyCooldownText(frame, resolved.remainingS)
end

local function refreshCooldownFrame(frame)
    if not frame or not frame.cooldownVisible then return end
    if not frame:IsShown() then return end

    local spellId = frame.cooldownSpellId
    if not spellId then
        clearCooldownFrame(frame)
        return
    end

    local resolved = resolveSpellCooldown(spellId)
    if not resolved then
        clearCooldownFrame(frame)
        return
    end

    syncResolvedCooldown(frame, spellId, resolved)
end

local function refreshTrackedCooldownFrames()
    local buttons = M.buttons
    if not buttons then return end

    local element
    local i
    for element = 1, SNS.MAX_TOTEM_SLOTS do
        local btn = buttons[element]
        refreshCooldownFrame(btn)
        refreshCooldownFrame(btn and btn.peek)

        local root = btn and btn.flyout
        if root and root:IsShown() then
            for i = 1, table.getn(root.entries) do
                refreshCooldownFrame(root.entries[i])
            end
        end
    end
end

local function ensureCooldownUpdateFrame()
    if M.cooldownUpdateFrame then return M.cooldownUpdateFrame end

    local frame = CreateFrame("Frame", nil, UIParent)
    frame:Hide()
    M.cooldownUpdateFrame = frame
    return frame
end

local function onCooldownUpdate()
    local now = GetTime()
    if (now - M.cooldownUpdateLastTick) < COOLDOWN_UPDATE_INTERVAL then return end

    M.cooldownUpdateLastTick = now
    refreshTrackedCooldownFrames()
    M.SyncCooldownUpdateFrame()
end

local function syncCooldownUpdateFrame()
    local frame = ensureCooldownUpdateFrame()

    if hasTrackedCooldownFrames() then
        if frame:GetScript("OnUpdate") ~= onCooldownUpdate then
            frame:SetScript("OnUpdate", onCooldownUpdate)
        end
        if not frame:IsShown() then
            M.cooldownUpdateLastTick = 0
            frame:Show()
        end
        return
    end

    frame:Hide()
end

local function applyCooldownFrame(frame, spellId, suppress)
    if not frame or not frame.cooldown or type(CooldownFrame_SetTimer) ~= "function" then return end

    if suppress or spellId == nil then
        clearCooldownFrame(frame)
        return
    end

    local resolved = resolveSpellCooldown(spellId)
    if not resolved then
        clearCooldownFrame(frame)
        return
    end

    syncResolvedCooldown(frame, spellId, resolved)
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.ClearCooldownFrame      = clearCooldownFrame
M.ApplyCooldownFrame      = applyCooldownFrame
M.SyncCooldownUpdateFrame = syncCooldownUpdateFrame
