# Changelog

What changed in each version of Jiberish SPEC-01 UI, newest first. The in-game
**What's new** page (`/spec whatsnew`) shows the highlights, with a key to each page.

## 0.6.6 (2026-11-18)

### Fixes
- **Party frames are back.** The 0.6.5 standard profile had **Party as raid** on, so a party
  showed only as small raid cells. It is off in the standard profile, and turned off once in
  existing profiles; switch it back on (Raid, boss and arena page) if you prefer the cells.

## 0.6.5 (2026-11-18)

### Profiles
- **New standard profile.** New installs start from Jiberish's current setup (Graphite,
  Audiowide, the green key color, the main layout at UI scale 0.64, the frameless map and
  game icons, folded stance keys).
- **Blizzard Edit Mode layout.** The matching Edit Mode layout ships with it and is imported as
  **Jiberish SPEC-01** and made active on a new install. Existing installs can apply it with
  **Blizzard Edit Mode → Apply** on the Profiles page or `/spec editmode` (a reload follows).
  It was exported on Forever; a client that can't read it is left as it is.

### Console
- **Icons only.** The menu keys and function keys set into the console drop their keycaps and
  slots: just their icons, printed on the housing. **Icons only** on the Action bars page brings
  the keycaps back.
- The **Mount** function key's glyph is now a horse's head.

## 0.6.4 (2026-11-18)

### Navigation
- **Frameless overlay map.** The NV-4 map now has no frame, glass or scale chip by default:
  a round map with a soft edge over the world. A new **Tone** setting draws it **Muted** (no
  color, a cool light, so it reads as a projection) or in the **map colors**. Frame, shape,
  glass and the scale chip are still options on the Navigation page.
- **Game icons** are now the default on the compass tape and the map, drawn bare (no keycap
  or lamp, a soft shade behind for contrast): ! and ? for quests, and the game's mailbox,
  repair, banker, auctioneer, innkeeper, flight master, stable and trainer icons. Points the
  game has no icon for keep their SPEC-01 keycap. The printed glyphs are still an option.
- Existing profiles switch to the new map look and game icons once.

## 0.6.3 (2026-11-18)

### Console
- **The stance latch is now a key of its own,** set into the console's header by default
  (after CX-1 CONSOLE), with a lamp lit while the stance keys show. Folding hides the stance
  keys completely, with nothing left above the console, and the console gives back their
  room. The latch has its own handle in edit mode (`/spec move`), so it can go anywhere;
  until it's moved it follows the console.

## 0.6.2 (2026-11-18)

### Console
- **Stance key latch.** A slim latch key at the stance keys' left end folds them away behind
  it with a click (latch-down sound) and brings them back (latch-up). Folded, only the latch
  shows and the console gives back the room. Also `/spec stance`, and **Folded** on the Action
  bars page. In combat the fold waits for the fight to end (the latch lamp shows amber).

## 0.6.1 (2026-11-18)

### Fixes
- **You can move with the hub, edit mode or the console editor open.** They no longer take the
  keyboard: their own keys (arrows, Escape, Ctrl+Z) are bound only while they're open, and
  every other key goes straight to the game.
- **Stance and pet keys move again in the console editor.** They slide anywhere along the
  console's top edge (drag, or the arrow keys), and can still be dropped into the console
  where there's room. Dragging one above the console puts it back on the edge.
- **The flight map shows its map again** (Forever). The TX-2 skin had hidden the map picture
  along with the window art, leaving only the flight points.

### Unit frames
- **Portrait size** (Auto, or a size up to the frame's height) and **portrait side** (Auto,
  left or right) for each frame. A portrait taller than the readout keeps the readout and
  meters centred beside it.
- **Text placement:** move the name and the digits from where the shape puts them, and set
  the digits left, centre or right in the LCD (the LCD label takes the other end).
- **Bay height:** in the console editor a docked frame's bay has HEIGHT - and HEIGHT +; the
  frame inside follows it. The Height setting notes that a bay sets the size.

## 0.6.0 (2026-11-18)

### Settings hub
- The hub now opens on **Quick setup**: layout, finish, key color, typeface, UI scale, fade,
  sounds and motion, each on its own device with a readout and one line saying what it does.
  Every choice applies as you pick it.
- **Undo** in the header (or Ctrl+Z while the hub is open) takes back the last change made in
  the hub, with a toast naming it. A slider drag counts as one change.
- **Reset page** puts every setting on the current page back to its default, after asking.
  Undo brings them back. Your UI scale and frame positions are never touched.
- **One reload lamp.** An amber lamp in the header lights when a change needs a reload; point
  at it to see which changes are waiting, and press its Reload key. Changing a setting back
  puts the lamp out again.
- **What's new** and **Commands** pages. `/spec help` lists every command; `/spec` followed by
  any other word opens the hub searching for it. New: `/spec edit`, `/spec whatsnew`,
  `/spec quick`.
- NEW lamps now mean something: they mark only what changed in this version, and go out once
  you open the page.
- "More options" on each card is a full-width key, so hidden settings are easy to spot.

### Layouts and console editor
- Two layouts, **Jiberish main** and **Integrated console**, placed to fit your screen. The
  integrated one docks the player, target, focus, target of target, pet and both cast bars
  inside the console.
- **Console editor** (`/spec console`): every part of the console is a block you can drag on a
  pixel grid, with snapping and guides; blocks can't overlap. The stance and pet bars are
  blocks too.
- Docked unit frames sit in recessed bays cut into the console, each with a printed legend.
  The micro bar moves into the console's header, and function keys are round keycaps.
- One **edit mode** for moving frames: a strip at the top of the screen, and a gear on each
  handle that opens that frame's settings.

### Navigation
- **NV-3 compass tape** across the top of the screen: heading, speed, zone and coordinates,
  with quests, flight masters and other points of interest at their bearing.
- **NV-4 overlay map** (`/spec map`): a click-through local map with the same points, your
  group and your arrow.
- City maps never go blank, and town services (repair, mail, inn, trainers and more) are
  learned as you use them.

### Quest tracker
- The objective tracker becomes the **OT-1** instrument panel: quests on plates with status
  lamps, LCD counts, dot progress bars and timers, with motion and sounds as quests change.

### Chat
- Chat becomes the **CH-1** communications device: a printed header with an unread count,
  tabs on a track, black glass, and a text field with a channel badge and character count.

### Away screen
- A full **standby console** while you are away (`/spec afk` to preview): your character over
  the dimmed world, your stats, a log of what happened while you were gone, and a volume mixer.

### Unit frames
- With the key color on **Class**, every unit frame shows its own unit's class, and creatures
  their reaction.
- Lamps stay perfectly round at any UI scale; the range fade no longer fights the idle fade.

### Nameplates
- Plates are slim strips that open into a tight full plate on your target.
- Enemy levels show in difficulty colors; cast bars show on enemies only by default; quest
  markers are a steady symbol.

### Fade
- Fade parts of the interface out of combat, with triggers that bring them back (a target, a
  cast, low health, the mouse) and per-part control.
- Hardware styles for fading: CRT power down, detent, relay bank, iris, roll-top, phosphor
  afterglow and more, each with matching sounds.

### Fonts and profile
- **Audiowide** ships with the addon.
- New installs start from Jiberish's own profile (Audiowide, Graphite, green key color) at UI
  scale 0.64.

### Windows, minimap and more
- The character window and Blizzard's windows get a full SPEC-01 pass on both clients.
- The minimap's keys take clicks again, and its readouts sit on one LCD strip.
- LCD readouts shrink to fit their glass; the info panel's modules never overlap.
- No screws anywhere.

### Tooling
- `make check` runs every Lua check (syntax, globals, local limits) and the unit tests;
  `make harness` renders the layout, console editor and navigation harnesses offline.
- Shared helpers live in one file; action bars and unit frames are split into smaller files.
- Reload keys reload through a secure button, since the game blocks addons from reloading
  directly.
