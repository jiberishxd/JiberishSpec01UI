"""Hardware theme media is packaged, tintable and referenced correctly.

Standard library only: these checks run without Pillow or a Lua runtime.
"""
import hashlib
import json
from pathlib import Path
import re
import struct
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / 'JiberishSpec01UI'
HARDWARE = ADDON / 'Kit'
FIXTURE = json.loads((ROOT / 'tests/fixtures/hardware-media.json').read_text())


def decode(data):
    """Independent RLE reader: returns width, height and bottom-up BGRA bytes."""
    width, height = struct.unpack_from('<HH', data, 12)
    raw, offset = bytearray(), 18 + data[0]
    while len(raw) < width * height * 4:
        packet = data[offset]; offset += 1
        count = (packet & 127) + 1
        size = 4 if packet & 128 else count * 4
        chunk = data[offset:offset + size]; offset += size
        assert len(chunk) == size
        raw += chunk * count if packet & 128 else chunk
    assert offset == len(data) and len(raw) == width * height * 4
    return width, height, bytes(raw)


def lua_sources():
    return {path.name: path.read_text() for path in sorted(HARDWARE.glob('*.lua'))}


class HardwareMedia(unittest.TestCase):
    def test_textures_match_manifest_and_are_lossless_rle(self):
        records = FIXTURE['textures']
        self.assertEqual(len(records), 33)  # 32 + the navigation glyphs (icons-nav)
        on_disk = {p.name for p in (ADDON / 'Media/Hardware').glob('*.tga')}
        self.assertEqual(on_disk, {Path(r['path']).name for r in records})
        for record in records:
            data = (ADDON / record['path']).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), record['sha256'], record['path'])
            self.assertEqual(data[1:3], bytes((0, 10)), record['path'])  # true-color RLE
            self.assertEqual(data[16:18], bytes((32, 8)), record['path'])  # 32-bit, 8 alpha bits
            width, height, raw = decode(data)
            self.assertEqual([width, height], record['size'])
            self.assertEqual(hashlib.sha256(raw).hexdigest(), record['bgraSha256'])
            # Power-of-two sides load on every supported client.
            self.assertEqual(width & (width - 1), 0)
            self.assertEqual(height & (height - 1), 0)

    def test_materials_match_manifest_tile_and_match_the_lua_table(self):
        records = FIXTURE['materials']
        folder = ADDON / 'Media/Hardware/Materials'
        self.assertEqual({p.name for p in folder.glob('*')}, {Path(r['path']).name for r in records})
        theme = lua_sources()['Theme.lua']
        table = re.search(r'Kit\.MATERIALS = \{(.*?)\n\}', theme, re.S)[1]
        declared = {key: (int(w), int(h)) for key, w, h in
                    re.findall(r"key = '([\w-]+)', name = '[^']*', w = (\d+), h = (\d+)", table)}
        self.assertEqual(set(declared), {r['name'] for r in records})
        self.assertIn("key = 'matte'", table)
        total = 0
        for record in records:
            data = (ADDON / record['path']).read_bytes()
            total += len(data)
            self.assertEqual(hashlib.sha256(data).hexdigest(), record['sha256'], record['path'])
            self.assertEqual(data[1:3], bytes((0, 10)), record['path'])
            self.assertEqual(data[16:18], bytes((32, 8)), record['path'])
            width, height, raw = decode(data)
            self.assertEqual([width, height], record['size'])
            self.assertEqual(declared[record['name']], (width, height), record['name'])
            self.assertEqual(hashlib.sha256(raw).hexdigest(), record['bgraSha256'])
            self.assertEqual(width & (width - 1), 0)
            self.assertEqual(height & (height - 1), 0)
            # Detail only: white lightens, black darkens, alpha is how much.
            self.assertLessEqual({raw[i:i + 3] for i in range(0, len(raw), 4)}, {b'\x00\x00\x00', b'\xff\xff\xff'})
            # Seamless: the step across the wrap is no larger than an ordinary step inside the tile.
            def signed(x, y):
                i = (y * width + x) * 4
                return (raw[i + 3] if raw[i] else -raw[i + 3]) / 255
            def mean_step(pairs):
                pairs = list(pairs)
                return sum(abs(signed(*a) - signed(*b)) for a, b in pairs) / len(pairs)
            rows = range(0, height, max(1, height // 64))
            cols = range(0, width, max(1, width // 64))
            for wrap, inside in (
                    (mean_step(((width - 1, y), (0, y)) for y in rows),
                     mean_step(((width // 2 - 1, y), (width // 2, y)) for y in rows)),
                    (mean_step(((x, height - 1), (x, 0)) for x in cols),
                     mean_step(((x, height // 2 - 1), (x, height // 2)) for x in cols))):
                self.assertLess(wrap, inside * 1.6 + 0.02, record['name'])
        self.assertLess(total, 8_000_000)  # the whole set stays a reasonable download

    def test_tintable_art_is_white_and_shadows_are_black(self):
        dark = {'shadow', 'shell-shadow', 'inset-3', 'inset-6', 'grain', 'bezel-shade'}
        for record in FIXTURE['textures']:
            name = Path(record['path']).stem
            _, _, raw = decode((ADDON / record['path']).read_bytes())
            colors = {raw[i:i + 3] for i in range(0, len(raw), 4)}
            alphas = {raw[i + 3] for i in range(0, len(raw), 4)}
            if name in dark:
                self.assertEqual(colors, {b'\x00\x00\x00'}, name)
            elif name == 'bar-flat':
                self.assertEqual(alphas, {255})
            else:
                # White even where transparent, so linear filtering has no dark fringe.
                self.assertEqual(colors, {b'\xff\xff\xff'}, name)
            if name != 'bar-flat':
                self.assertGreater(len(alphas), 1, name)

    def test_nine_slice_margins_fit_their_textures(self):
        theme = lua_sources()['Theme.lua']
        table = re.search(r'local SLICES = \{(.*?)\}', theme, re.S)[1]
        margins = {name or bare: int(value)
                   for name, bare, value in re.findall(r"(?:\['([\w-]+)'\]|(\w+))\s*=\s*(\d+)", table)}
        sizes = {Path(r['path']).stem: r['size'] for r in FIXTURE['textures']}
        self.assertEqual(len(margins), 9)
        for name, margin in margins.items():
            self.assertIn(name, sizes)
            # Left and right (and top and bottom) margins must leave a stretchable centre.
            self.assertLess(margin * 2, min(sizes[name]), name)

    def test_icon_atlas_order_matches_the_lua_lookup(self):
        theme = lua_sources()['Theme.lua']
        block = re.search(r"for index, name in ipairs\(\{(.*?)\}\) do\s*Kit\.icons", theme, re.S)[1]
        self.assertEqual(re.findall(r"'([\w-]+)'", block), FIXTURE['icons'])
        self.assertLessEqual(len(FIXTURE['icons']), 64)
        used = set()
        for source in lua_sources().values():
            used |= set(re.findall(r"icon\s*=\s*'([\w-]+)'", source))
            used |= set(re.findall(r":Icon\([^,]+,\s*'([\w-]+)'", source))
            used |= set(re.findall(r":SetIcon\([^,]+,\s*'([\w-]+)'", source))
        self.assertTrue(used)
        self.assertLessEqual(used, set(FIXTURE['icons']), sorted(used - set(FIXTURE['icons'])))

    def test_menu_glyph_atlas_order_matches_the_lua_lookup(self):
        source = (ADDON / 'Modules/ActionBars.lua').read_text()
        block = re.search(r"local MENU_ICONS = \{(.*?)\}", source, re.S)[1]
        names = re.findall(r"'([\w-]+)'", block)
        self.assertEqual(names, FIXTURE['menuIcons'])
        self.assertLessEqual(len(names), 32)  # an 8 x 4 atlas
        glyphs = re.search(r"local GLYPH_OF = \{(.*?)\n\}", source, re.S)[1]
        self.assertLessEqual(set(re.findall(r"= '([\w-]+)'", glyphs)), set(names))

    def test_nav_glyph_atlas_order_matches_the_lua_lookup(self):
        source = (ADDON / 'Modules/Navigation.lua').read_text()
        block = re.search(r"local NAV_ICONS = \{(.*?)\}", source, re.S)[1]
        names = re.findall(r"'([\w-]+)'", block)
        self.assertEqual(names, FIXTURE['navIcons'])
        self.assertLessEqual(len(names), 32)  # an 8 x 4 atlas
        kinds = re.search(r"local KINDS = \{(.*?)\n\}", source, re.S)[1]
        self.assertLessEqual(set(re.findall(r"icon = '([\w-]+)'", kinds)), set(names))
        self.assertIn("'icons-nav.tga'", source)

    def test_sounds_match_manifest_and_the_lua_list(self):
        records = FIXTURE['sounds']
        voices = sorted({r['voice'] for r in records})
        theme = lua_sources()['Theme.lua']
        declared = re.findall(r"'([\w-]+)'", re.search(r'Kit\.sounds = \{(.*?)\}', theme, re.S)[1])
        self.assertEqual(sorted(declared), voices)
        # Every voice in SPEC-01's sound.ts, and this addon's seven mechanism voices.
        self.assertEqual(len(voices), 22)
        self.assertLessEqual({'power-down', 'power-up', 'relay', 'servo', 'shutter', 'iris', 'detent'}, set(voices))
        takes = int(re.search(r'Kit\.soundTakes = (\d+)', theme)[1])
        self.assertEqual(takes, FIXTURE['soundTakes'])
        self.assertEqual({(r['voice'], r['take']) for r in records}, {(v, t) for v in voices for t in range(1, takes + 1)})
        on_disk = {p.name for p in (ADDON / 'Media/Hardware/Sounds').glob('*')}
        self.assertEqual(on_disk, {f"{r['voice']}-{r['take']}.mp3" for r in records})
        for record in records:
            data = (ADDON / record['path']).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), record['sha256'], record['path'])
            # An MPEG audio frame sync, with no ID3 tag in front of it.
            self.assertEqual(data[0], 0xFF)
            self.assertEqual(data[1] & 0xE0, 0xE0)
            # Interface clicks stay short, small and unclipped, but long enough for the client to play.
            self.assertGreaterEqual(record['milliseconds'], 250)
            self.assertLess(record['milliseconds'], 400)
            self.assertLess(len(data), 16_000)
            self.assertLess(record['peak'], 0.99)
        # Every sound named inside a Play(...) call, including both arms of a condition.
        played = set()
        for source in lua_sources().values():
            for match in re.finditer(r'Play\(', source):
                depth, end = 1, match.end()
                while depth and end < len(source):
                    depth += {'(': 1, ')': -1}.get(source[end], 0)
                    end += 1
                played |= set(re.findall(r"'([\w-]+)'", source[match.end():end]))
        played -= {'primary', 'warning', 'error', 'success', ' '}  # tone names compared against, not played by name
        self.assertGreater(len(played), 8)
        self.assertLessEqual(played, set(declared), sorted(played - set(declared)))

    def test_baked_skin_matches_manifest_and_generated_lua(self):
        records = FIXTURE['skin']
        on_disk = {p.name for p in (ADDON / 'Media/Hardware/Skin').glob('*')}
        self.assertEqual(on_disk, {Path(r['path']).name for r in records})
        skin = lua_sources()['Skin.lua']
        accents = [a for a in FIXTURE['accents']]
        self.assertEqual(accents, ['red', 'yellow', 'green', 'blue', 'purple', 'ink', 'tint'])
        for record in records:
            data = (ADDON / record['path']).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), record['sha256'], record['path'])
            self.assertEqual(data[1:3], bytes((0, 10)), record['path'])
            self.assertEqual(data[16:18], bytes((32, 8)), record['path'])
            width, height, raw = decode(data)
            self.assertEqual([width, height], record['size'])
            (w, h), (l, t, r, b) = record['element'], record['pad']
            # Twice design size, including the shadow and lip drawn outside the control.
            self.assertEqual([width, height], [(w + l + r) * 2, (h + t + b) * 2], record['path'])
            alphas = {raw[i + 3] for i in range(0, len(raw), 4)}
            self.assertIn(0, alphas, record['path'])  # rendered on a transparent page
            self.assertGreater(max(alphas), 200, record['path'])
            entry = re.search(r"\['%s'\] = \{([^}]*)\}" % re.escape(record['name']), skin)[1]
            fields = dict(re.findall(r"(\w+) = ([\w']+)", entry))
            self.assertEqual([int(fields[k]) for k in 'whltrb'], [w, h, l, t, r, b], record['name'])
            if record['corner']:
                self.assertEqual(int(fields['c']), record['corner'])
                # The corners must leave a stretchable centre in the reference-size art.
                self.assertLessEqual(record['corner'] * 2, min(w, h) + 1, record['name'])
            self.assertEqual(fields.get('accent') == 'true', record['accent'])
        for name in {r['name'] for r in records if r['accent']}:
            files = {Path(r['path']).stem for r in records if r['name'] == name}
            self.assertEqual(files, {f'{name}-{accent}' for accent in accents})
        used = set()
        for source in lua_sources().values():
            used |= set(re.findall(r":Skin\([^,]+,\s*'([\w-]+)'", source))
            used |= set(re.findall(r"sprite = '([\w-]+)'", source))
            used |= set(re.findall(r"(?:up|down) = '([\w-]+)'", source))
        self.assertGreater(len(used), 15)
        self.assertLessEqual(used, {r['name'] for r in records}, sorted(used - {r['name'] for r in records}))

    def test_bundled_font_and_its_license(self):
        fonts = ADDON / 'Media/Fonts'
        self.assertEqual({p.name for p in fonts.iterdir()},
                         {'IBMPlexMono-Regular.ttf', 'IBMPlexMono-Bold.ttf', 'OFL.txt', 'Audiowide-Regular.ttf', 'OFL-Audiowide.txt'})
        self.assertIn('SIL Open Font License', (fonts / 'OFL.txt').read_text())
        audiowide = (fonts / 'OFL-Audiowide.txt').read_text()
        self.assertIn('SIL OPEN FONT LICENSE Version 1.1', audiowide)
        self.assertIn('Reserved Font Name "Audiowide"', audiowide)
        for name in ('IBMPlexMono-Regular.ttf', 'IBMPlexMono-Bold.ttf', 'Audiowide-Regular.ttf'):
            self.assertEqual((fonts / name).read_bytes()[:4], b'\x00\x01\x00\x00')  # TrueType outline font
        theme = (HARDWARE / 'Theme.lua').read_text()
        self.assertIn('IBMPlexMono-Regular.ttf', theme)
        self.assertIn('IBMPlexMono-Bold.ttf', theme)

    def test_every_hub_page_points_at_real_settings(self):
        core = (ADDON / 'Core.lua').read_text()
        defaults = core.split('local defaults = {', 1)[1].split('\nUI.defaults', 1)[0]
        modules = ''.join(path.read_text() for path in sorted((ADDON / 'Modules').glob('*.lua')))
        # Settings a module declares itself with UI:RegisterDefaults, between markers.
        defaults += ''.join(re.findall(r'-- defaults:begin(.*?)-- defaults:end', modules, re.S))
        paths = set(re.findall(r"\{'(?:switch|segmented|slider|color|dropdown|input)', '[^']*', '([\w.]+)'", modules))
        self.assertGreater(len(paths), 25)
        for path in paths:
            leaf = path.split('.')[-1]
            self.assertRegex(defaults, rf'\b{re.escape(leaf)}\s*=', path)

    def test_every_sprite_name_in_lua_is_baked(self):
        # A sprite missing from Kit/Skin.lua is a nil index that stops a whole module.
        skin = (HARDWARE / 'Skin.lua').read_text()
        baked = set(re.findall(r"\['([\w-]+)'\] = \{", skin))
        used = set()
        for path in ADDON.rglob('*.lua'):
            text = path.read_text()
            for pattern in (r":Skin\([^,()]+,\s*'([\w-]+)'", r"SetSprite\([^,()]+,\s*'([\w-]+)'", r"Behind\([^,()]+,\s*'([\w-]+)'",
                            r"sprite = '([\w-]+)'", r"(?:up|down) = '([\w-]+)'", r"SetSprite\([^,()]+, [^)]*?and '([\w-]+)' or '([\w-]+)'\)"):
                for match in re.findall(pattern, text):
                    used |= set(match) if isinstance(match, tuple) else {match}
            for pair in re.findall(r"\w+ = \{'([\w-]+)', '([\w-]+)'\}", text):
                if path.name == 'ActionBars.lua':
                    used |= set(pair)
        used = {name for name in used if name and not name.startswith(('mask-', 'bar-', 'tile-'))}
        used -= {'HARMFUL', 'HELPFUL', 'primary', 'dark', 'default', 'round', 'tick', 'down', 'up', 'latch-down', 'latch-up',
                 'down-primary', 'open', 'success', 'warning', 'error', 'blip', 'type', 'type-space', 'ink', 'dim', 'red',
                 # housing groups (Kit:Shell opts.group), not sprites
                 'console', 'unitframes', 'devices', 'screens'}
        self.assertGreater(len(used), 15)
        self.assertLessEqual(used, baked, sorted(used - baked))

    def test_upstream_license_ships_with_the_art(self):
        text = (ADDON / 'Media/Hardware/LICENSE-SPEC-01.txt').read_text()
        self.assertIn('MIT License', text)
        self.assertIn('Copyright (c) 2026 Shu Ding', text)
        self.assertIn('Permission is hereby granted, free of charge', text)

    def test_every_texture_file_named_in_lua_ships(self):
        shipped = {Path(r['path']).stem for r in FIXTURE['textures']}
        referenced = set()
        for source in lua_sources().values():
            referenced |= set(re.findall(r":Texture\([^,]+,\s*'([\w-]+)'", source))
            referenced |= set(re.findall(r"\.\.'([\w-]+)\.tga'", source))
            referenced |= set(re.findall(r"Tile\('([\w-]+)'", source))
        # Shapes built by name: 'round-'..radius, 'ring-'..radius, 'inset-'..radius.
        referenced -= {'round-', 'ring-', 'inset-'}
        self.assertGreaterEqual(len(referenced), 8)
        self.assertLessEqual(referenced, shipped, sorted(referenced - shipped))

    def test_toc_loads_every_lua_file_core_first(self):
        toc = (ADDON / 'JiberishSpec01UI.toc').read_text()
        listed = [line.strip().replace('\\', '/') for line in toc.splitlines() if line.strip() and not line.startswith('#')]
        self.assertEqual(listed[:4], ['Core.lua', 'Kit/Util.lua', 'Kit/Theme.lua', 'Kit/Skin.lua'])
        self.assertEqual(listed[listed.index('Kit/Deck.lua') + 1], 'Modules/Hub.lua')
        on_disk = {p.relative_to(ADDON).as_posix() for p in ADDON.rglob('*.lua')}
        self.assertEqual(set(listed), on_disk)
        # The kit loads before the modules that use it.
        self.assertLess(max(listed.index(n) for n in listed if n.startswith('Kit/')),
                        min(listed.index(n) for n in listed if n.startswith('Modules/')))
        for line in toc.splitlines():
            if line.startswith('## SavedVariables'):
                self.assertIn('JiberishSpec01DB', line)

    def test_deck_shows_every_component_once(self):
        deck = lua_sources()['Deck.lua']
        numbers = [int(n) for n in re.findall(r"^\t\{(\d+), '", deck, re.M)]
        self.assertEqual(len(numbers), 52)
        self.assertEqual(len(set(numbers)), 52)
        self.assertEqual(numbers, sorted(numbers))


if __name__ == '__main__':
    unittest.main()
