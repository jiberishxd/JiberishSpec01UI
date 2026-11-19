"""Kit/Util.lua behaves as documented, run offline through tools/lua/minilua.py."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Util(unittest.TestCase):
    def test_util_helpers(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / 'tools/lua/minilua.py'), str(ROOT / 'tests/lua/util.lua'),
             str(ROOT / 'JiberishSpec01UI/Kit/Util.lua')],
            capture_output=True, text=True, cwd=ROOT, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip().splitlines()[-1:], ['ok'], result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
