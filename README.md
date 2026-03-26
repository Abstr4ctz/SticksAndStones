# Sticks and Stones

> Shaman totem management addon for World of Warcraft 1.12 (Vanilla)

---

## Table of Contents

1. [Requirements](#1-requirements)
2. [Installation](#2-installation)
3. [Getting Started](#3-getting-started)
4. [The Interface](#4-the-interface)
5. [Click Interactions](#5-click-interactions-button--peek)
6. [Mouse-Wheel Set Cycling](#6-mouse-wheel-set-cycling)
7. [Sets](#7-sets)
8. [Flyouts](#8-flyouts)
9. [Smart Cast & Force Cast](#9-smart-cast--force-cast)
10. [Range Fading](#10-range-fading)
11. [Profiles & Import/Export](#11-profiles--importexport)
12. [Slash Commands](#12-slash-commands)
13. [Key Bindings](#13-key-bindings)
14. [Configuration Reference](#14-configuration-reference)

---

## 1. Requirements

**Nampower** *(required)*
The addon will not load without Nampower.
→ https://gitea.com/avitasia/nampower/releases/

**UnitXP** *(optional)*
Enables live range checking and missing-totem detection for active totems. Without it, range fading is disabled and missing alerts rely on `UNIT_DIED` or normal expiry only.
→ https://codeberg.org/konaka/UnitXP_SP3/releases

---

## 2. Installation

Copy the `SticksAndStones-main` folder into your `Interface/AddOns` directory and rename it `SticksAndStones` so the path is:

```
Interface/AddOns/SticksAndStones/SticksAndStones.toc
```

---

## 3. Getting Started

Type `/sns` to open Settings.

The first time you log in, the four element buttons appear centered on screen. Unlock the buttons (**Settings → General**, uncheck **Locked**) to drag them freely.

Once positioned, lock the buttons again. Locked buttons accept all click and scroll interactions; unlocked buttons are in drag/edit mode.

---

## 4. The Interface

### Element Buttons
One per element: **Earth**, **Fire**, **Water**, **Air**. Each button shows the icon of the current *chosen* totem — the one you intend to cast for that element. An active totem (one physically in the ground) is indicated by a live countdown timer.

### Peek
A smaller secondary icon that appears adjacent to the main button when the slot holds two relevant totems simultaneously (chosen + a different active, or a QA/quick-access totem). The peek displays the secondary totem. Its direction relative to the main button is configured per-element in Settings via **Flyout Direction**.

### Flyout
A list of all known totems for that element, used to change your chosen totem or cast a totem directly without making it chosen. Flyout direction is also per-element.

---

## 5. Click Interactions (Button & Peek)

Buttons and peek frames share a two-button interaction model. The exact result depends on the current FSM state of that slot.

### Main Button

**Left-click** — Casts the totem most relevant to the current state:
- If a chosen totem is set: casts it (even if a different totem is active)
- If no chosen but an active exists: casts the active back down
- If only a QA totem is stored: casts the QA totem

**Right-click** — Modifies the chosen/QA slot state without casting:

| Slot State | Result |
|---|---|
| Chosen only | Ejects chosen into QA (slot becomes QA-only) |
| Active = Chosen | Clears chosen and QA; active stays up |
| Chosen + diff. Active | Clears chosen and QA; active stays up |
| Active only | Adopts the active as the new chosen |
| QA only | Promotes QA back to chosen |
| Chosen + QA | Ejects chosen into QA (old QA is replaced) |
| Active = Chosen + QA | Clears chosen and QA; active stays up |

> Right-click on the main button never casts anything.

### Peek Frame

The peek shows a secondary totem. Its click actions work on that secondary totem, not the main button's chosen totem.

**Left-click on peek** — Casts the secondary (peek) totem. Available when: active ≠ chosen, active-only, or QA states.

**Right-click on peek** — Restructures which totem is "chosen" using the secondary totem:

| Slot State | Result |
|---|---|
| Chosen + diff. Active | Active becomes chosen; old chosen becomes QA |
| Active only | Adopts active as chosen (same as button RMB) |
| QA only | Promotes QA to chosen |
| Chosen + QA | Swaps chosen and QA positions |
| Active = Chosen + QA | Promotes QA to chosen; active stays |

> Right-click on the peek never casts anything.

### Flyout Entries

| Click | Action |
|---|---|
| Left-click | Casts that totem immediately (does not change chosen) |
| Right-click | Sets that totem as the new chosen for the slot |

---

## 6. Mouse-Wheel Set Cycling

When the buttons are locked, scrolling the mouse wheel over any element button cycles through your saved sets:

| Scroll | Action |
|---|---|
| Up | Previous set |
| Down | Next set |

Cycling wraps around if **Wrap cycle** is enabled in **Settings → Sets**. If no sets are saved, the wheel has no effect.

---

## 7. Sets

A set stores one chosen totem per element (up to **20 sets** per profile).

**Creating a set**
Settings → Sets → *New Set* — seeds from your current chosen totems.

**Loading a set**
Click a set row in the Sets tab, or scroll the wheel over any button.

**Active set**
The currently loaded set is highlighted. Loading a set updates all four chosen slots simultaneously and fires an instant visual update.

**Sets and rank handling**
Sets store a canonical spell ID. If you learned a higher rank after saving the set, the new rank is substituted automatically on load.

---

## 8. Flyouts

Flyouts list all totem spells the character currently knows for one element. The order and visible entries are both configurable per-element.

**Flyout Mode** *(Settings → General)*

| Mode | Behavior |
|---|---|
| `free` | Flyout opens on hover, no modifier needed *(default)* |
| `dynamic` | Flyout opens only while a configured modifier key is held |
| `closed` | Flyouts are disabled entirely |

**Flyout Modifier** *(Settings → General)*
The modifier key used in `dynamic` mode. Default: `Shift`.

**Flyout Direction** *(Settings → General, per-element)*
Which side of the button the flyout and peek appear on. Options: `top` *(default)*, `bottom`, `left`, `right`.

**Flyout Order** *(Settings → Flyouts tab, per-element)*
Drag entries to reorder their position in the list. Unpositioned spells appear after the manually ordered entries.

**Flyout Filter** *(Settings → Flyouts tab, per-element)*
Check entries to hide them from the flyout permanently. Useful to suppress lower-rank totems you no longer want to see or cast.

> The flyout only shows available spells based on current character knowledge. It updates automatically when you learn new spells or level up.

---

## 9. Smart Cast & Force Cast

These actions cast multiple elements in one keystroke or command.

**Smart Cast** — `/sns smart` or keybind *Smart Cast Set*
Casts chosen totems that are missing or out of range. Skips an element if that totem is already active and in range.

**Force Cast** — `/sns force` or keybind *Force Cast Set*
Casts all chosen totems unconditionally. Replaces any totem already in the ground for those elements.

---

## 10. Range Fading

*Requires Nampower + UnitXP.*

When enabled (**Settings → Advanced → Range Fade**), buttons for active totems that are out of range dim to indicate they are no longer effective. The range check runs on the poll tick (default 0.3 s).

**Range Offset** *(Settings → Advanced)*
Adjusts the detection threshold by ±10 yards. Negative values make the fade trigger slightly earlier. Default: `-1.3` yards.

> If UnitXP is not loaded, the range check is disabled regardless of this setting. The **Range Fade** checkbox will still save the value for when UnitXP becomes available.

---

## 11. Profiles & Import/Export

Profiles are stored in the SavedVariable `SNSProfiles` and persist across sessions per character.

**Creating a profile**
Settings → Advanced → type a name → *Create*.

**Switching profiles**
Select a profile from the dropdown and click *Load*.

**Import/Export**
Settings → Advanced → Import/Export. The format is a self-contained text string. Copy it out to share a profile, or paste one in to import. Invalid data is rejected and reported in chat.

---

## 12. Slash Commands

| Command | Description |
|---|---|
| `/sns` | Open or close Settings |
| `/sns help` | Print the command list to chat |
| `/sns smart` | Smart cast chosen totems |
| `/sns force` | Force cast all chosen totems |

> Alias: `/sticksandstones` works for all of the above.

---

## 13. Key Bindings

Found under **Key Bindings → Sticks and Stones** in the WoW bindings interface.

| Binding | Action |
|---|---|
| Cast Earth Totem | Casts chosen Earth totem |
| Cast Fire Totem | Casts chosen Fire totem |
| Cast Water Totem | Casts chosen Water totem |
| Cast Air Totem | Casts chosen Air totem |
| Smart Cast Set | Smart cast (skip healthy, in-range totems) |
| Force Cast Set | Force cast all chosen totems |

---

## 14. Configuration Reference

Settings that have no direct GUI label or whose behavior is not obvious from the UI alone.

| Setting | Default | Range | Description |
|---|---|---|---|
| `pollInterval` | `0.3` | `0.1–5.0` | How often (in seconds) the addon checks active totem range/existence via UnitXP. Lower values give tighter detection at the cost of more CPU. |
| `expiryThresholdSecs` | `5` | `0–600` | The timer bar and threshold alert trigger when a totem's remaining duration drops to this many seconds. Set to `0` to disable only the threshold warning. |
| `expirySoundEnabled` | `false` | — | Plays one alert sound per active totem lifecycle: when it first crosses the expiry threshold, or if it never alerted earlier, when it expires or is destroyed. Silent clears (Totemic Recall, player death, world-entry teardown) do not play the sound. |
| `timerShowMinutes` | `false` | — | When a totem has more than 60 s remaining, show `M:SS` instead of raw seconds. Off by default to keep the display compact. |
| `snapAlign` | `true` | — | When dragging buttons, snaps to screen center and the edges/centers of other element buttons. Toggle off for free placement. |
| `clickThrough` | `false` | — | When locked and enabled, button clicks pass through to the game world. The `clickThroughMod` overrides this temporarily. |
| `clickThroughMod` | `ctrl` | `none`, `ctrl`, `alt`, `shift` | The modifier that temporarily re-enables input while `clickThrough` is active. Set to `none` for no override — all clicks pass through unconditionally. |
| `tooltipAnchorMode` | `frame` | `frame`, `cursor` | `frame`: tooltip is positioned relative to the button frame. `cursor`: tooltip follows the cursor. |
| `tooltipDirection` | `right` | `up`, `down`, `left`, `right` | Which side of the anchor the tooltip appears on. |
| `setsCycleWrap` | `false` | — | Whether scrolling past the first or last set wraps around to the other end. |
| `flyoutFilter` / `flyoutOrder` | *(empty)* | — | Per-element spell ID lists stored in the profile. Managed through the Flyouts tab. Both are rank-stable: if a higher rank is learned, the stored ID is remapped automatically. |
| `borderColorR/G/B` | `1/1/1` | — | Per-element tint override for the button border. Set through the color pickers in **Settings → General**. |
| `elementColorR/G/B` | `1/1/1` | — | Per-element tint override for the icon vertex color. Set through the color pickers in **Settings → General**. |
