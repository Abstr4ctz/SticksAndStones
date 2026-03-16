-- SticksAndStones: Totems/Cast.lua
-- Support module for spellId-to-name resolution and cast dispatch in the
-- Totems pod.
-- Owns no state. Exports CastTotem on TotemsInternal.
-- Side effects: canonicalizes incoming spell IDs to the highest live rank for
-- that totem type, then calls CastSpellByName(baseName) after resolving the
-- spell through TotemsInternal.bySpellId. No frames. No event registration.

------------------------------------------------------------------------
-- Module alias
------------------------------------------------------------------------

local M               = TotemsInternal  -- created by Totems facade, loaded first per TOC order
local CastSpellByName = CastSpellByName

------------------------------------------------------------------------
-- Public entrypoints
------------------------------------------------------------------------

local function castTotem(spellId)
    local canonicalSpellId = M.ResolveCanonicalSpellId(spellId)
    if canonicalSpellId == nil then return end

    -- Totems intentionally casts the highest live rank for any recognized
    -- totem spell ID instead of preserving saved lower-rank spell IDs.
    local record = M.bySpellId[canonicalSpellId]
    if record == nil then return end

    local name = record.baseName
    if name == nil or name == "" then return end

    CastSpellByName(name)
end

------------------------------------------------------------------------
-- Internal exports
------------------------------------------------------------------------

M.CastTotem = castTotem
