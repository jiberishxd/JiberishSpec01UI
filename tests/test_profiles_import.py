"""The profile import preview and the profile strings, run offline through
tools/lua/minilua.py against the shipped default profile string
(Modules/DefaultProfile.lua) and a modified copy: changes grouped by hub page
with the hub's own row labels, the three apply modes, the "Before import"
snapshot and Undo, and the plain-words problems for damaged strings."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProfileImport(unittest.TestCase):
    def test_preview_apply_undo_and_problems(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / 'tools/lua/minilua.py'), str(ROOT / 'tests/lua/profiles_import.lua'),
             str(ROOT / 'JiberishSpec01UI')],
            capture_output=True, text=True, cwd=ROOT, timeout=300)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip().splitlines()[-1:], ['ok'], result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
