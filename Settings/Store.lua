-- SticksAndStones: Settings/Store.lua
-- Support module for SavedVariables schema repair, profile materialization,
-- and active-profile persistence/binding inside the Settings pod.
-- Exports Store services on SettingsInternal.
-- Side effects: reads UnitName/GetRealmName on characterKey(); resets or
-- repairs SNSProfiles on ensureStore(); rewrites SNSProfiles profile rows; and
-- rebinds SNSConfig when binding or resetting the current character profile.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M = SettingsInternal  -- created by Settings.lua, loaded first per TOC order

------------------------------------------------------------------------
-- Private state
------------------------------------------------------------------------

local storeWasJustCreated = false

------------------------------------------------------------------------
-- Private helpers
------------------------------------------------------------------------

local function buildEmptyStore()
    return {
        schemaVersion     = M.STORE_SCHEMA_VERSION,
        profiles          = {},
        charActiveProfile = {},
    }
end

local function hasCurrentSchema(store)
    return type(store) == "table" and store.schemaVersion == M.STORE_SCHEMA_VERSION
end

local function repairStoreTables(store)
    if type(store.profiles) ~= "table" then
        store.profiles = {}
    end
    if type(store.charActiveProfile) ~= "table" then
        store.charActiveProfile = {}
    end
end

local function buildStarterSetRow()
    local row = M.sanitizeSetRow({})
    if type(row) == "table" then
        return row
    end
    return {}
end

local function seedStarterSet(config)
    if type(config) ~= "table" then return config end

    if type(config.sets) ~= "table" then
        config.sets = {}
    end
    if table.getn(config.sets) > 0 then
        return config
    end

    config.sets[1] = buildStarterSetRow()
    config.activeSetIndex = 1
    return config
end

-- sanitizeProfile() returns a fresh table, so the repaired row is always
-- written back into the store before it is returned or rebound.
local function buildSanitizedProfile(key, shouldSeedStarterSet)
    local config = M.sanitizeProfile(SNSProfiles.profiles[key])
    if shouldSeedStarterSet then
        seedStarterSet(config)
    end
    SNSProfiles.profiles[key] = config
    return config
end

local function bindActiveProfile(key)
    local config = buildSanitizedProfile(key, false)
    SNSConfig = config
    return config
end

local function resetProfile(key)
    SNSProfiles.profiles[key] = nil
    return bindActiveProfile(key)
end

local function resolveActiveProfileKey(charKey)
    local storedKey = SNSProfiles.charActiveProfile[charKey]
    local activeKey = M.sanitizeProfileKey(storedKey)
    if not activeKey or not SNSProfiles.profiles[activeKey] then
        return charKey
    end
    return activeKey
end

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

-- Must not be called before PLAYER_LOGIN.
local function characterKey()
    return UnitName("player") .. "-" .. GetRealmName()
end

-- Rebinds SNSConfig to a specific stored profile row through the Store-owned
-- sanitize-and-bind path.
local function rebindProfileKey(key)
    return bindActiveProfile(key)
end

-- Schema-version mismatch triggers a full reset; no migration is attempted.
-- On a matching version, missing sub-tables are repaired in place.
local function ensureStore()
    if not hasCurrentSchema(SNSProfiles) then
        SNSProfiles = buildEmptyStore()
        storeWasJustCreated = true
        return
    end
    repairStoreTables(SNSProfiles)
    storeWasJustCreated = false
end

-- Ensures the character's own profile row exists, resolves the persisted
-- active-profile mapping, saves the repaired mapping, and rebinds SNSConfig.
local function bindCharacterProfile(charKey)
    -- The starter set is only injected for the very first profile materialized
    -- from a newly created SavedVariables root.
    local shouldSeedStarterSet = storeWasJustCreated and type(SNSProfiles.profiles[charKey]) ~= "table"
    local ownConfig = buildSanitizedProfile(charKey, shouldSeedStarterSet)
    local activeKey = resolveActiveProfileKey(charKey)

    SNSProfiles.charActiveProfile[charKey] = activeKey
    storeWasJustCreated = false

    if activeKey == charKey then
        SNSConfig = ownConfig
        return ownConfig
    end
    return bindActiveProfile(activeKey)
end

-- Resolves and persists the current character's active-profile mapping, then
-- rebuilds that active profile from defaults and rebinds SNSConfig.
local function resetCharacterProfile(charKey)
    local activeKey = resolveActiveProfileKey(charKey)
    SNSProfiles.charActiveProfile[charKey] = activeKey
    return resetProfile(activeKey)
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.characterKey            = characterKey
M.rebindProfileKey        = rebindProfileKey
M.ensureStore             = ensureStore
M.resolveActiveProfileKey = resolveActiveProfileKey
M.bindCharacterProfile    = bindCharacterProfile
M.resetCharacterProfile   = resetCharacterProfile
