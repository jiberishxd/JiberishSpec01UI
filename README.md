# Jiberish SPEC-01 UI

[![Checks](https://github.com/jiberishxd/JiberishSpec01UI/actions/workflows/ci.yml/badge.svg)](https://github.com/jiberishxd/JiberishSpec01UI/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![WoW](https://img.shields.io/badge/World%20of%20Warcraft-Retail%2012.x%20%7C%20Forever-blue)

A complete World of Warcraft interface built from the SPEC-01/HARDWARE design system:
machined housings, LCD readouts, LED lamps, real key travel and click sounds, across the whole
game UI. It is a standalone addon: no ElvUI or other framework is required.

The visual language is [SPEC-01/HARDWARE](https://spec-01.vercel.app/) by
[Shu Ding](https://github.com/shuding), used under the MIT License. This project adapts it for
World of Warcraft; it is a fan project and is not affiliated with Blizzard Entertainment,
Vercel or Shu Ding.

> **Status: 0.6.0, under active development.** Played daily on Forever realms and Retail 12.x.
> Expect rough edges; please [report bugs](../../issues/new/choose).

## Contents

- [What it covers](#what-it-covers)
- [Install](#install)
- [Getting started](#getting-started)
- [Commands](#commands)
- [Development](#development)
- [Contributing](#contributing)
- [Credits and licenses](#credits-and-licenses)

## What it covers

- **Console (CX-1).** Action bars, the micro menu, function keys and stats in one device along
  the bottom. Player, target, focus, target of target, pet and cast bars can be embedded in it
  as recessed bays. Every block can be dragged, reshaped and snapped on a pixel grid in the
  console editor.
- **Unit frames, raid, boss and arena frames** with LCD readouts, LED meters and 3D or LED-matrix
  portraits; health and casts keep working when the game hides exact values in combat.
- **Nameplates** as dark glass plates with level chips (in difficulty colours), dot meters,
  quest markers and a distance nav tape.
- **Navigation.** An NV-3 compass tape across the top of the screen (heading, movement direction,
  quests, flight masters, rares and learned town services at their bearing) and a toggleable
  NV-4 overlay map of the area around you.
- **Aura timeline** of your buffs and cooldowns riding a line toward zero.
- **Quest tracker (OT-1), chat (CH-1), minimap, bags and bank, info panel, damage meter,
  tooltips, loot and notifications**, each as a SPEC-01 device.
- **Every Blizzard window** (character, spellbook, talents, quests, collections, auction house
  and more) reskinned with SPEC-01 controls.
- **Fade styles and sounds**: idle fading with hardware animations (CRT power-down, relay bank,
  iris, roll-top and more) and the reference's synthesized key, latch and switch sounds.
- **Away screen**, a gadget drawer (timer, volume mixer, CPU meter), a calendar and a combat cue.
- **Two layouts** (*Jiberish main* and *Integrated console*), solved for your screen at 1080p,
  1440p, 4K and ultrawide, plus your own saved layouts.

Two finishes (Paper and Graphite), any key colour, and IBM Plex Mono or Audiowide (both
bundled) as typefaces.

## Install

**From a release (recommended):** download the latest `JiberishSpec01UI-x.y.z.zip` from
[Releases](../../releases), and extract it into your AddOns folder so you end up with
`World of Warcraft/<client>/Interface/AddOns/JiberishSpec01UI/JiberishSpec01UI.toc`, where
`<client>` is `_retail_` or `_forever_`.

**From source:** copy the `JiberishSpec01UI` folder from this repository into
`Interface/AddOns`. On macOS, `make install` checks the code and copies it into each client
it finds under `/Applications/World of Warcraft` (set `WOW=` to use another path).

Restart the game fully after installing or updating, since the game only picks up new files on
startup.

## Getting started

- **`/spec`** opens the settings hub on **Quick setup**: layout, finish, key colour, typeface,
  UI scale, fade style, sounds and motion, each on one device.
- **What's new** (`/spec whatsnew`) lists what changed in this version, with a key to each page.
- **Edit mode** (`/spec edit`): a handle on every frame. Drag to move, snap to a pixel grid and
  to other frames, nudge with the arrow keys. A handle's gear (or a right-click) opens that
  frame's settings. **Console** in the edit strip opens the console editor.
- **Search**: `/spec <word>` opens the hub searching every setting for that word.
- **Undo** (or Ctrl+Z in the hub) takes back the last change; **Reset page** restores a page's
  defaults. Changes that need a reload light one amber lamp in the hub's header.
- **Profiles**: per character or per specialization, with export and import as a text string.
  An import shows exactly what will change before anything is applied, and can be undone.

## Commands

| Command | What it does |
|---|---|
| `/spec` | Open or close the settings hub |
| `/spec <page>` | Open a page: `theme`, `fonts`, `layout`, `unitframes`, `nameplates`, `chat`, `fade` … |
| `/spec <word>` | Search every setting for that word |
| `/spec help` | List every command |
| `/spec whatsnew` | What changed in this version |
| `/spec quick` | Quick setup |
| `/spec setup` | Run the installer again |
| `/spec edit` | Edit mode: move and arrange every frame (`move`/`unlock`; `lock` leaves) |
| `/spec console` | Edit the console's banks, keys and bays |
| `/spec reset` | Put every frame back in its default spot |
| `/spec map` | Show or hide the overlay map (also a key binding under AddOns) |
| `/spec drawer` | Open the gadget drawer (`timer`, `volume`, `cpu` open a gadget) |
| `/spec calendar` | Open the calendar |
| `/spec afk` | Preview the away screen |
| `/spec deck` | The component deck: every SPEC-01 part on one page |

## Development

The addon is plain Lua 5.1 for the WoW client; the tooling is standard-library Python 3 (no
Lua runtime or extra packages needed).

```bash
make check     # every Lua check, then the unit tests and the layout/console/navigation harnesses
make lint      # Lua checks only
make test      # unit tests only
make harness   # render layout, console and navigation previews to build/harness/
make install   # check, then copy the addon into each installed WoW client (macOS paths)
make hooks     # check staged Lua files on every commit
```

`make check` runs, for every Lua file: a syntax and globals check, a check for globals read
before their local exists, per-function local and upvalue limits, and the main chunk's local
count (Lua refuses more than 200, which stops a file loading in game; the check warns at 160
and fails at 190). The harnesses run the real layout solver, console editor and navigation code
through `tools/lua/minilua.py`, a small Lua 5.1 interpreter written in Python.

### Layout

```
JiberishSpec01UI/            the addon (this folder is what players install)
  Core.lua                   addon table, saved variables, migrations, slash commands
  Kit/                       the SPEC-01 component kit: theme tokens, shells, keys, lamps,
                             LCDs, controls, overlays, motion, pixel snapping, shared helpers
  Modules/                   one feature per file group (unit frames, console, nameplates …)
  Media/Fonts, Media/Hardware  fonts, generated art, rendered SPEC-01 art and sounds
tests/                       unit tests, Lua test files and the harnesses
tools/                       check runner, Lua tooling and the media build scripts
```

Media is generated, not hand-edited: `tools/capture-hardware-reference.py` renders the control
art from the reference page (needs Google Chrome), `tools/build-hardware-sounds.py` renders the
sounds (needs ffmpeg with LAME), and `tools/build-hardware-art.py` and
`tools/build-hardware-materials.py` draw the shapes, glyphs and materials. The tests check the
media against `tests/fixtures/hardware-media.json`.

### Rules the code follows

WoW 12.x hides some values from addons in combat ("secret values") and blocks addons from
protected actions. Every module follows the same rules, and reviews check them:

- Never compare, test or do arithmetic on a value that may be secret; check `issecretvalue`
  first (`UI.Util.IsSecret`), and pass secrets only to setters such as `SetText` or `SetValue`.
- Only post-hook Blizzard code (`hooksecurefunc`, `HookScript`); keep our data in side tables,
  never on Blizzard frames; never move protected frames in combat; never reparent Edit Mode
  system frames.
- Reloads go through the secure reload key (`Kit:ReloadKey`), since `ReloadUI` is blocked.
- Keep every file's main chunk well under 200 locals.

## Contributing

Bug reports, ideas and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
Release notes are in [CHANGELOG.md](CHANGELOG.md).

## Credits and licenses

- **SPEC-01/HARDWARE** by [Shu Ding](https://github.com/shuding) — the design system this
  interface is built on. MIT License.
- **IBM Plex Mono** by IBM and **Audiowide** by Astigmatic — bundled typefaces, SIL Open Font
  License 1.1.

The addon's own code is released under the [MIT License](LICENSE). Third-party material keeps
its own license; the full texts ship inside the addon folder, and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists what is used where.

World of Warcraft is a trademark of Blizzard Entertainment, Inc. This is a fan-made addon, not
affiliated with or endorsed by Blizzard Entertainment, Vercel or Shu Ding.
