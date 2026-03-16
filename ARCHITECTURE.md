# Architecture

> `ARCHITECTURE.md` is the canonical source of truth for the polished runtime architecture and cross-module contracts. Historical prompts, audit notes, and refactor logs are retained for reference only.

## Root

### Modules

- `Final/App.lua` - Root wiring module for addon bootstrap, runtime guards, root namespace publication, public entry surfaces, and callback routing.
- `Final/Minimap.lua` - Standalone root entry surface for the minimap button, tooltip, and drag positioning.
- `Final/Bindings.xml` - Keybinding entrypoints for element casts plus smart/force cast.
- `Final/SticksAndStones.toc` - Load manifest and SavedVariables declaration.

### Root Namespace And Bridge Verdict

- `SNS.EARTH`, `SNS.FIRE`, `SNS.WATER`, `SNS.AIR` - immutable root element vocabulary.
- `SNS.MAX_TOTEM_SLOTS` - immutable root slot count consumed across pods.
- `SNS.ELEMENT_NAMES` - immutable display and UI label vocabulary.
- `SNS.ACTION_TYPES` - immutable App-owned user-action vocabulary consumed by App and the Display pod.
- `SNS.features` - immutable runtime capability probes (`hasNampower`, `hasUnitXP`) populated by App after helper-based probing.
- `SNS.Minimap` - conditional module namespace attached by `Minimap.lua`.
- Removed bridge: `SNS.TotemStates` no longer exists. App now injects the Totems state contract explicitly through `Display.Initialize(catalog, states)`.
- Intentional App-mediated forwards that remain:
  - `App.GetChosenSnapshot()` -> `Totems.GetChosenSnapshot()`
  - `App.GetCatalog()` -> `Totems.GetCatalog()`
  These stay because Tier 1 rule 3 requires Settings-to-Totems traffic to flow through App rather than direct pod-to-pod calls.

### Startup Sequence

1. `Settings.Initialize()`
2. `Totems.Initialize()`
3. `Display.Initialize(Totems.GetCatalog(), Totems.States)`
4. `initializeMinimap()`
5. `wireCallbacks()`
6. `Totems.SetPollingEnabled(true)`
7. `Display.Render(Totems.GetSnapshot())`

- `Settings.Initialize()` must run first so `SNSConfig` exists before any other pod reads it.
- `Totems.Initialize()` publishes `Totems.States`, rebuilds the catalog, creates slot state, reconciles configured chosen state, injects `hasUnitXP` onto `TotemsInternal`, and initializes polling.
- Callbacks are wired before polling starts and before the first render.
- Totems initialization remains intentionally silent; App owns the first render after wiring is complete.

### Callback Routing

- `Totems.OnStateChanged(snapshot)` -> `Display.Render(snapshot)`
- `Totems.OnVisualRefresh(snapshot)` -> `Display.Render(snapshot)`
- `Totems.OnCatalogChanged(catalog)` -> `Display.SetCatalog(catalog)`
- `Totems.OnLifecycleAlert(element, guid)` -> `Display.PlayLifecycleAlert(element, guid)`
- `Display.OnUserAction(action)` -> App validates the action vocabulary and payload shape, then routes to the owning facade.
- `Settings.OnConfigChanged()` -> `Totems.ApplyConfig()`, `Display.ApplyConfig()`, and `SNS.Minimap.ApplyConfig()` when Minimap is attached.
- `Settings.OnFlyoutConfigChanged()` -> `Display.ApplyFlyoutConfig()`

Each outbound callback fires from exactly one facade owner:

- Totems: `OnStateChanged`, `OnVisualRefresh`, `OnCatalogChanged`, `OnLifecycleAlert`
- Display: `OnUserAction`
- Settings: `OnConfigChanged`, `OnFlyoutConfigChanged`

### TOC And Load Order

- `App.lua` loads first so root constants and runtime vocabulary exist at file scope before any pod support file reads them.
- Each pod facade loads before its support modules so the pod shared table exists before support-module export writes.
- `Minimap.lua` loads last because it guards on both `SNS` and the published `App` facade.
- The current order is correct and minimal for the live dependency flow:
  `App -> Settings -> Totems -> Display -> Minimap`.

## Totems Pod

### Module Responsibilities

- `Final/Totems/Totems.lua` - Facade, runtime coordinator, lifecycle-alert classifier, and world-entry teardown owner.
- `Final/Totems/Catalog.lua` - Canonical totem catalog builder and owner of spell indexes.
- `Final/Totems/Cast.lua` - Highest-rank canonical cast dispatcher.
- `Final/Totems/Detect.lua` - Cast/model/death correlation owner.
- `Final/Totems/FSM.lua` - Pure transition engine and smart-cast policy owner.
- `Final/Totems/Poll.lua` - Poll frame, expiry/range/existence collection, and spawn-duration fallback owner.

### State Ownership

- `Totems.lua` owns `Totems`, `TotemsInternal`, `TotemsInternal.slots`, the persistent snapshot table, callback slots, and facade-injected capability state such as `TotemsInternal.hasUnitXP`.
- `Catalog.lua` owns `bySpellId`, `byUnitName`, `byElement`, and `canonicalSpellIdBySpellId`.
- `Detect.lua` owns pending-cast state, delay slots, reusable drain buffers, and the pending-cast replacement query used by the facade.
- `Poll.lua` owns the hidden poll frame, tick timers, and reusable result buffers.
- `FSM.lua` owns the state enums, event enums, classification tables, and transition table.

### Public Contracts

- `Totems.Initialize()` publishes `Totems.States`, rebuilds the catalog, creates slots and snapshot state, reconciles configured chosen state, wires detect/catalog/world-entry event sources, injects root capability state, and initializes polling.
- `Totems.GetSnapshot()` returns the persistent snapshot contract. App forwards it unchanged and Display treats it as read-only.
- `Totems.GetCatalog()` and `Totems.OnCatalogChanged(catalog)` use detached catalog snapshots built by `Catalog.lua`.
- `Totems.GetChosenSnapshot()` returns a fresh `[1..4] = chosenSpellId|nil` array for Settings set seeding.
- `Totems.ApplyConfig()` reconciles chosen state against the active configured set, clears stale out-of-range state when range fading is disabled, and fires `OnStateChanged` only when the chosen-state result actually changes.
- `Totems.OnLifecycleAlert(element, guid)` fires only from the facade when an active totem is cleared for an alert-worthy cause after lifecycle classification has ruled out recall, player death, world-entry teardown, and same-element replacement.
- Cast/change entrypoints (`CastElementButton`, `ChangeElementButton`, `CastElementPeek`, `ChangeElementPeek`, `CastFlyout`, `SetChosenFromFlyout`, `CastSmart`, `CastForce`) validate external input at the facade boundary before mutating slot state or dispatching casts.
- `Totems.SetPollingEnabled(enabled)` is the only public polling control surface.

### Boundary Rules

- Outside the pod, code talks to `Totems` only.
- Support modules communicate only through `TotemsInternal`; they do not call each other directly and do not emit outbound callbacks.
- Only the facade reads root namespace state for Totems-owned behavior; support modules do not read `SNS`, `App`, or other pod facades.
- `FSM.lua` is pure: no WoW API calls, no display-derived data, no root reads.
- Totems may read `SNSConfig`; it never writes or rebinds it.

## Settings Pod

### Module Responsibilities

- `Final/Settings/Settings.lua` - Facade, `SNSConfig.<field>` write owner, callback owner, set-management owner, and UI-refresh coordinator.
- `Final/Settings/Rules.lua` - Pure schema/defaults/sanitization authority.
- `Final/Settings/Store.lua` - SavedVariables repair, active-profile resolution, and `SNSConfig` rebinding owner.
- `Final/Settings/Profiles.lua` - Profile list and CRUD owner.
- `Final/Settings/ImportExport.lua` - Deterministic profile serialization and strict text import owner.
- `Final/Settings/UI.lua` - Settings window shell, modal dialog/reset popup, tab registration, and shared UI primitive owner.
- `Final/Settings/UIGeneral.lua`, `Final/Settings/UISets.lua`, `Final/Settings/UIFlyouts.lua`, `Final/Settings/UIAdvanced.lua` - Tab owners for general controls, set controls, flyout controls, and advanced/profile controls.

### State Ownership

- `Settings.lua` owns the `Settings` facade, creates `SettingsInternal`, owns `OnConfigChanged` and `OnFlyoutConfigChanged`, and is the only module that writes `SNSConfig.<field>`.
- `Store.lua` is the only module that rebinds `SNSConfig = ...`.
- `Rules.lua` owns `DEFAULTS`, clamps, finite config vocabularies, and sanitizers. It makes zero WoW API calls.
- `SNSProfiles` writes are confined to `Store.lua`, `Profiles.lua`, and `ImportExport.lua`.
- UI modules own only transient frame/control state; they never write SavedVariables directly.

### Shared SettingsInternal Surface

- `Rules.lua` publishes schema constants, defaults, and sanitizers.
- `Store.lua` publishes store/bootstrap helpers used by the facade and profile/import code.
- `Profiles.lua` publishes profile CRUD helpers used by the facade and import logic.
- `ImportExport.lua` publishes import/export helpers used by the facade.
- `UI.lua` publishes the shell API on `SI.UI`, tab registration, reset/profile-dialog helpers, and shared UI primitives including `CHAT_PREFIX`, `printChat`, `setChecked`, `setButtonEnabled`, `createActionButton`, `createCheckboxRow`, `createDropdown`, `FALLBACK_ICON`, and `getElementName`.
- `UIGeneral.lua` publishes `DismissGeneralColorPicker`.
- `UIAdvanced.lua` publishes `SetAdvancedSelectedProfileKey`.

### Public Contracts

- `Settings.Initialize()` ensures the store and binds the active profile before any other pod reads `SNSConfig`.
- `Settings.ToggleUI()` is the only public settings-visibility entrypoint; shell methods live on `SI.UI`.
- All config setters, set-management entrypoints, profile operations, and import/export entrypoints validate at the facade boundary before mutation.
- `OnConfigChanged` fires only after config state is internally consistent and the visible UI has been refreshed.
- `OnFlyoutConfigChanged` fires only after flyout-related config state is internally consistent and the visible UI has been refreshed.

### Boundary Rules

- UI modules never write `SNSConfig` or `SNSProfiles` directly; all user-triggered writes go through public `Settings.*` entrypoints.
- `Settings.lua` never constructs frames; it talks to the UI only through `SI.UI`.
- Settings-side reads of Totems-owned data stay App-mediated:
  - `Settings.CreateSet()` seeds from `App.GetChosenSnapshot()`
  - `UIFlyouts.lua` reads catalog data through `App.GetCatalog()`
- `elements[element].flyoutDir` is the single persisted direction source for both peek anchoring and flyout layout; there is no separate global peek-direction field.
- `rangeFade` remains a persisted top-level setting and is exposed through the Settings facade and Advanced-tab checkbox.

## Display Pod

### Module Responsibilities

- `Final/Display/Display.lua` - Facade, boundary validator, render coordinator, config applier, and outbound user-action owner.
- `Final/Display/Frames.lua` - Button/peek/flyout frame construction and geometry helpers.
- `Final/Display/Flyouts.lua` - Flyout order/filter resolution and open/close lifecycle owner.
- `Final/Display/Interaction.lua` - Button/peek/flyout input, drag, mouse-wheel, and modifier-capture owner.
- `Final/Display/Cooldowns.lua` - Cooldown-provider normalization and overlay/text update owner.
- `Final/Display/Tooltip.lua` - Tooltip anchor/content/refresh owner.

### State Ownership

- `Display.lua` owns `Display`, creates `DisplayInternal`, owns `DisplayInternal.buttons`, `buttonState`, `catalog`, `snapshot`, `expirySoundThrottleUntil`, and the shared display constants consumed by support modules.
- `Display.lua` also owns the local state-visual dispatch tables built from the injected Totems state contract and the `peekInteractionDirty` scratch array.
- `Flyouts.lua` owns `flyoutOpenElement`, `flyoutCloseStartedAt`, the close-timer frame, and flyout scratch buffers.
- `Interaction.lua` owns modifier/input capture state and the Nampower event frame.
- `Cooldowns.lua` owns the cooldown update frame and reusable cooldown scratch state.
- `Tooltip.lua` owns tooltip runtime state stored on `DisplayInternal`.
- `Frames.lua` owns no long-lived mutable shared state; it constructs frames and keeps geometry math local.

### Public Contracts

- `Display.Initialize(catalog, states)` is App-owned parameter injection. It validates the App-forwarded catalog and Totems state contract, builds visual dispatch tables from `states`, creates the four button/peek/flyout sets, seeds shared state, and applies current config.
- `Display.SetCatalog(catalog)` accepts only a validated catalog snapshot, replaces `DisplayInternal.catalog`, resizes flyout pools, and re-renders if a snapshot is already present.
- `Display.Render(snapshot)` validates the Totems snapshot contract when a new snapshot is passed, stores it unchanged, renders all four elements, reconciles peek interaction, refreshes the open flyout and tooltip, and syncs cooldown state.
- `Display.PlayLifecycleAlert(element, guid)` accepts only App-routed Totems lifecycle alerts, applies the same sound gating/throttle path used by threshold crossing, and dedupes to one alert per active GUID lifecycle.
- `Display.ApplyConfig()` reads `SNSConfig` only; it reapplies scale/chrome/positions/input state, closes flyouts, updates interaction state, and never writes config.
- `Display.ApplyFlyoutConfig()` reapplies per-element peek anchoring and refreshes the currently open flyout plus dependent tooltip and cooldown state without running the full config path.
- `Display.OnUserAction` is the single outbound Display-to-App callback slot and fires only from `Display.lua`.

### Boundary Rules

- Outside the pod, code talks to `Display` only.
- Support modules communicate only through `DisplayInternal`; they do not call other pod facades or peer support-module globals directly.
- App is the only cross-pod router into Display: it forwards snapshot and catalog contracts, injects the Totems state contract into `Initialize`, routes Totems lifecycle alerts into `PlayLifecycleAlert`, and wires `OnUserAction`.
- Display may read `SNSConfig`; it never writes or rebinds it.
- No mutable root bridge remains for Totems states. The old `SNS.TotemStates` shim is gone.

## Verified Global Rules

- `SNSConfig` write ownership is clean:
  - `SNSConfig = ...` occurs only in `Final/Settings/Store.lua`
  - `SNSConfig.<field> = ...` occurs only in `Final/Settings/Settings.lua`
- No root module accesses `TotemsInternal`, `SettingsInternal`, or `DisplayInternal`.
- All public facade exports in `App`, `Totems`, `Settings`, `Display`, and `SNS.Minimap` have live in-repo callers.
- No dead public bridge surface remains. `SNS.TotemStates` and `SI.FALLBACK_ICONS` are gone.
- Callback ownership is singular and documented above.
