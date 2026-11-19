"""Edit mode (Modules/Movers.lua, Modules/EditMode.lua) run offline with mocked
frames: every RegisterMover key in the addon opens a settings page the hub
registers, snapping and nudging land on whole pixels, and edit mode's states
(handles, the console editor in place, leaving) hold."""
import os
import re
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ADDON = os.path.join(ROOT, 'JiberishSpec01UI')
MINILUA = os.path.join(ROOT, 'tools', 'lua', 'minilua.py')
HARNESS = os.path.join(HERE, 'harness', 'movertest.lua')
# Keys the code builds without a literal (Meters' OWN_KEYS, Console's mini.mover).
BUILT = ['dm.own', 'dm.own2', 'dm.own3', 'ab.stance', 'ab.pet']


def scan():
    keys, pages = set(BUILT), set()
    for folder, _, files in os.walk(ADDON):
        for name in files:
            if not name.endswith('.lua') or name == 'Movers.lua':
                continue
            text = open(os.path.join(folder, name), encoding='utf-8').read()
            for match in re.finditer(r"RegisterMover\([^,]+,\s*'([^']+)'", text):
                key = match.group(1)
                keys.add(key)
            pages.update(re.findall(r"RegisterPage\('([^']+)'", text))
    return sorted(keys), sorted(pages)


class EditMode(unittest.TestCase):
    def test_edit_mode(self):
        keys, pages = scan()
        # Built keys ('uf.'..unit) are prefixes; the harness adds a suffix.
        self.assertIn('uf.', keys)
        args = ['page:' + page for page in pages] + ['mover:' + key for key in keys]
        out = subprocess.run([sys.executable, MINILUA, HARNESS, ADDON] + args, capture_output=True, text=True, cwd=ROOT)
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        self.assertNotIn('ERROR', out.stdout, out.stdout[-3000:])
        self.assertRegex(out.stdout, re.compile(r'^failures\s+0\s*$', re.M), out.stdout[-3000:])


if __name__ == '__main__':
    unittest.main()
