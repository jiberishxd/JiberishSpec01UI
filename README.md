# Jiberish SPEC-01 UI

A standalone World of Warcraft addon that reskins the Blizzard interface in the style of
[SPEC-01/HARDWARE](https://spec-01.vercel.app/) by Shu Ding. No other addon is required.

SPEC-01 is used under the MIT license; the notice ships in
`JiberishSpec01UI/Media/Hardware/LICENSE-SPEC-01.txt`. The control art is rendered from its
stylesheet at twice its design size and the sounds are rendered from its sound recipe.

**Status: early. The component kit and sounds have been seen working in game; the unit frames,
action bars, minimap, chat and window skins in this version have not been run yet.**

The reference's typeface, IBM Plex Mono (SIL OFL 1.1, `JiberishSpec01UI/Media/Fonts/OFL.txt`),
ships with the addon.

## Install

Copy the `JiberishSpec01UI` folder into `Interface/AddOns` and restart the game.

## The hub

`/spec` opens the hub, the one place to set everything up, like ElvUI's options. A sidebar
lists the sections; each section has a style picker and its options:

- **Quick setup** (where the hub opens): layout, finish, key color, typeface, UI scale, fade,
  sounds and motion, each on one device. **What's new** lists this version's changes with a key
  to each page; **Commands** lists every `/spec` command.
- **Overview**: the style for every part of the interface at once, with a status lamp per
  part (green running, red failed to start with the reason, gray off).
- **Search** (top of the sidebar) finds any option on any page. Options new in this version
  carry a NEW lamp until you open their page in this version.
- **Theme**:
  - Finish, key color (or your own), typeface, text scale, outline and shadow.
  - Borders, corner rounding, shadows, housing opacity, color softness, bar brightness.
  - Motion speed, smooth bars, LCD ghost digits.
  - Fading parts of the interface while idle.
  - A live sample device that repaints as you change things.
- **Layout**:
  - A map of your screen: drag any frame, or set its anchor, X/Y, scale, opacity and visibility exactly.
  - Presets: Console, Classic, Healer, Tank/DPS centre, Minimal and Widescreen.
  - Screen layouts for 1080p, 1440p and 4K (compact or comfortable), picked automatically or by hand.
  - Saved layouts of your own.
  - **Edit mode** (`/spec edit`, `/spec move`, or **Move UI** in the hub's header): a handle on
    every frame and an EDIT MODE strip at the top of the screen.
    - Drag a frame to move it. Drag its corner grip to resize it.
    - The wheel scales a frame; Ctrl+wheel changes its opacity.
    - Arrow keys nudge the selected frame. Ctrl+Z undoes, and Esc locks.
    - The strip has grid size, snap and guides, the console editor, the layout map, undo,
      reset all, and Done.
    - A handle's gear (or a right-click on it) opens that frame's settings page; the selected
      frame's inspector chip sets its anchor, position, scale and opacity, hides it or resets it.
- **Profiles**: per-character profiles, copy and reset, and export and import as a text string.
- **Setup**: the first-run guide (`/spec setup`) and a short tour of the hub.
- **Sounds**: every kind of sound (windows, menus, tabs, checkboxes, buttons, errors, quest
  ready, loot, alerts) as SPEC-01, the game's, both or off. The game's own sound is muted
  when SPEC-01 replaces it.
- **Unit frames**, **Raid, boss and arena**, **Nameplates**, **Action bars**, **Buffs**,
  **Objectives**, **Minimap**, **Chat**, **Windows**, **Bags**, **Info panel**, **Damage meters**,
  **Banners and loot**, **Notifications**, **Quality of life**: each has a page of options, from
  sizes, text formats, colors and aura filters to per-bar fading.
- **Components** (all 52 SPEC-01 elements, live) and **About**.

Style changes take effect after a reload: the amber lamp in the hub's header lights and lists
them (hover it), and its Reload key reloads. **Undo** (or Ctrl+Z) takes back the last change
made in the hub and **Reset page** puts a page back to its defaults. `/spec help` lists every
command; `/spec` followed by any other word searches the settings.

## Foundation (0.3)

- **Exact pixels.** Every housing, edge, corner, shadow and bevel is drawn from code in
  physical screen pixels, so it stays sharp at any size and UI scale. The UI scale is saved
  and put back whenever the game changes it; **Theme → Screen** has a pixel-perfect setting.
- **Softer housings.** A faint shadow, a crisp edge, a slightly translucent fill (adjustable
  under **Theme → Housing opacity**) and a 1 px bevel, in Paper, Dark or LCD.
- **One rhythm.** Everything moves at one of three speeds (0.12, 0.2 or 0.4 s, and 0.3 s for
  closing): fades ease with a sine, movement with a cubic. Windows rise 8 px as they open and
  sink 4 px as they close. Nothing runs while nothing moves.
- **Placement.** `/spec move` shows a handle over every SPEC-01 frame. Frames snap to an
  8-unit grid and to the edges and centres of other frames; hold Shift to place freely.
  (Since 0.6.0 this is edit mode: right-click a handle for that frame's settings, and reset it
  from its inspector chip.) A fight starting locks everything.
- **Sounds** never double up: the same sound plays at most once per 0.1 s.

## Unit frames

Compact devices: player and target are 224 × 70, with a printed header (combat lamp, model
code, name, level), the 3D portrait on a black display, an LCD with the class or creature
type and the health percentage over unlit "888" segments, and health and power meters as LED
dots, a pill or a flat bar. Target of target, pet, focus and four party frames are compact
versions; class resources (combo points, holy power, runes, ...) are lamps under the player.

- **Cast bars** for the player and target run on the game's own timing, so they stay smooth
  and correct in every fight; an interrupted cast holds a moment in red.
- **Motion:** a new target fades in, its bars glide up from zero and its portrait swells a
  little past full and settles. A light runs along every frame as combat starts and ends.
- Health text, bars and casts are worked out by the game itself, so they keep working when
  the game hides exact values in combat.

## The whole interface (0.4)

- **Console.** One CX-1 device along the bottom holds the action keys (our own secure buttons,
  1–3 rows, with paging for stances, forms, vehicles and skyriding, and the game's own key
  bindings). The player and target frames are docked into it, with cast bars under the keys
  and experience or reputation as LED dots along the base. Pet and stance keys sit in small
  strips; side bars, the menu and bags, and the extra ability are devices of their own. The
  'free' layout gives every bar its own device and mover.
- **Nameplates.** Our own dark glass plates replace the game's: a level chip, the name, health
  as dots, a pill or a bar, a target lamp, a threat lamp, a cast bar and your debuffs.
- **Windows.** Every Blizzard window, dialog and menu is a dark device with a printed header.
  Content sits on black screens, and buttons, checkboxes, tabs, scroll bars, dropdowns, item
  slots and fields are SPEC-01 controls. Opening and closing windows plays the reference's sounds.
- **Tooltips** are dark glass, with item quality as a lit line along the top.
- **Objectives and buffs.** The tracker is an OT-1 device, with lamps for objectives and dot
  meters for progress. Buffs sit on keys, each with an LCD timer.
- **Loot and notifications.** An LT-1 loot window whose rows cascade in, roll devices with a
  dot timer, and a loot feed. Queued banners cover level-ups (counting LCD digits), quest
  completion, achievements, zones and reputation.

## Everything else (0.5)

- **Raid, boss and arena frames**: dark glass cells for up to 40, with role, leader, ready
  check, summon, dispel, boss debuffs, your heals over time, private auras, incoming heals
  and range fade. Boss and arena devices, with spec preview before an arena starts.
- **Bags and bank**: a BG-1 bag device with search, sort, sections or a grid, item level and
  quality edges, and a BK-1 bank with bank, reagent and warband tabs. Junk is sold and gear
  repaired at vendors.
- **Info panel**: LCD data texts for time, latency, gold, durability, bags, friends, guild,
  spec, coordinates, experience and item level.
- **Damage meters**: Details! and the game's own meter as SPEC-01 devices, an optional dock,
  and a built-in DM-1 meter.
- **Quality of life**: an away screen, cursor ring, quieter errors, faster looting, optional
  gossip and quest automation, delete fill-in, camera zoom, combat text and interrupt calls.
- **Chat**: copy, clickable web addresses, short channel names, saved history, link
  tooltips, unread lamps and glass chat bubbles.

## 0.5.1

- **Nameplate nav tape**: a row of hairline ticks on top of your target's plate, with the
  distance bracket centred above it.
  - A caret marks where the unit is across your view, and the ticks near it lift and light.
  - The tape scrolls as the unit or your view moves, and ripples while the unit runs.
  - The caret turns red while the unit is targeting you.
- **Swing timers** (Forever): the game's main hand, off hand and ranged timers as SPEC-01
  meters, with a spark, quarter ticks and red when out of range.

## Development

Standard library Python only.

- `tools/capture-hardware-reference.py` renders the control art from the live reference
  page with the installed Google Chrome and writes `Kit/Skin.lua`.
- `tools/build-hardware-sounds.py` renders the sounds (needs ffmpeg with LAME).
- `tools/build-hardware-art.py` draws the flat shapes, icons and LED tiles.
- `python3 -m unittest discover -s tests` checks the media against its manifest.
