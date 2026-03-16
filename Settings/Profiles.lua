-- SticksAndStones: Settings/Profiles.lua
-- Profile list and CRUD support module for the Settings pod.
-- Owns profile-key enumeration, active-profile switching, and profile
-- create/rename/delete behavior on SNSProfiles.
-- Exports profile helpers on SettingsInternal.
-- Side effects: rewrites SNSProfiles.profiles / SNSProfiles.charActiveProfile
-- rows, and may rebind SNSConfig when the current character switches profiles.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = SettingsInternal

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function ensureProfileRow(key)
    if not key then return nil end
    if SNSProfiles.profiles[key] then return SNSProfiles.profiles[key] end

    SNSProfiles.profiles[key] = M.sanitizeProfile(nil)
    return SNSProfiles.profiles[key]
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function listProfiles()
    local keys  = {}
    local count = 0
    local key
    local profile

    for key, profile in pairs(SNSProfiles.profiles) do
        if type(key) == "string" and type(profile) == "table" then
            count = count + 1
            keys[count] = key
        end
    end

    table.sort(keys)
    return keys
end

local function getActiveProfileKey()
    local charKey

    charKey = M.characterKey()
    return M.resolveActiveProfileKey(charKey)
end

local function setActiveProfile(key)
    local charKey

    if not key or not SNSProfiles.profiles[key] then
        return nil, "profile_missing"
    end

    charKey = M.characterKey()
    SNSProfiles.charActiveProfile[charKey] = key
    M.bindCharacterProfile(charKey)
    return true
end

local function createProfile(key, sourceKey)
    local source = SNSConfig

    if SNSProfiles.profiles[key] then
        return nil, "profile_exists"
    end

    if sourceKey then
        if not SNSProfiles.profiles[sourceKey] then
            return nil, "profile_missing"
        end
        source = SNSProfiles.profiles[sourceKey]
    end

    SNSProfiles.profiles[key] = M.sanitizeProfile(source)
    return true
end

local function renameProfile(oldKey, newKey)
    local charKey
    local mappedCharKey
    local mappedKey

    if not SNSProfiles.profiles[oldKey] then
        return nil, "profile_missing"
    end
    if SNSProfiles.profiles[newKey] then
        return nil, "profile_exists"
    end

    SNSProfiles.profiles[newKey] = SNSProfiles.profiles[oldKey]
    SNSProfiles.profiles[oldKey] = nil

    for mappedCharKey, mappedKey in pairs(SNSProfiles.charActiveProfile) do
        if mappedKey == oldKey then
            SNSProfiles.charActiveProfile[mappedCharKey] = newKey
        end
    end

    charKey = M.characterKey()
    if SNSProfiles.charActiveProfile[charKey] == newKey then
        M.rebindProfileKey(newKey)
    end

    return true
end

local function deleteProfile(key)
    local charKey
    local activeKey
    local mappedCharKey
    local mappedKey

    if not SNSProfiles.profiles[key] then
        return nil, "profile_missing"
    end

    charKey = M.characterKey()
    activeKey = M.resolveActiveProfileKey(charKey)
    if key == activeKey then
        return nil, "profile_active"
    end

    SNSProfiles.profiles[key] = nil

    for mappedCharKey, mappedKey in pairs(SNSProfiles.charActiveProfile) do
        if mappedKey == key then
            local fallbackKey = M.sanitizeProfileKey(mappedCharKey) or mappedCharKey

            ensureProfileRow(fallbackKey)
            SNSProfiles.charActiveProfile[mappedCharKey] = fallbackKey
        end
    end

    return true
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.ListProfilesInternal        = listProfiles
M.GetActiveProfileKeyInternal = getActiveProfileKey
M.SetActiveProfileInternal    = setActiveProfile
M.CreateProfileInternal       = createProfile
M.RenameProfileInternal       = renameProfile
M.DeleteProfileInternal       = deleteProfile
