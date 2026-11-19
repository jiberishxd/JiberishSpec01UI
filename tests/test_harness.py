"""The offline harnesses (tests/harness/) as unit tests, without renders:
the layout presets solved by the real Layouts.lua on the standard screens, the
console editor's moves and overlap resolve (ConsoleEditor.lua), and the
navigation modules with mocked frames. `make harness` runs them with renders."""
import os
import re
import subprocess
import sys
import unittest

HARNESS = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'harness')
sys.path.insert(0, HARNESS)
import layouts  # noqa: E402
import console_edit  # noqa: E402


class LayoutPresets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.problems, cls.reference = layouts.run_all(render=False, verbose=False)

    def test_no_overlaps_off_screen_or_broken_mirrors(self):
        self.assertEqual(self.problems, [])

    def test_main_reproduces_the_reference_profile(self):
        # Within a few UI units of the user's own positions at the reference screen.
        reference = dict(self.reference)
        for key in layouts.REFERENCE_KEYS:
            if key in reference:
                self.assertLessEqual(reference[key], 8, key)


class ConsoleEditor(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.problems, cls.logs = console_edit.main(render=False, verbose=False)

    def test_arrangements_are_valid(self):
        self.assertEqual(self.problems, [])

    def test_moves_are_accepted_or_refused(self):
        def moves(name): return [line.split()[1:3] for line in self.logs[name] if line.startswith('MOVE')]
        self.assertEqual(moves('integrated-edited'), [['uf.pet', 'accepted'], ['cb.player', 'refused'], ['fnL', 'refused'],
                                                      ['uf.focus', 'accepted'], ['fnR', 'accepted']])
        self.assertEqual(moves('main-stance'), [['stance', 'refused'], ['deck', 'accepted'], ['stance', 'accepted']])
        self.assertIn(['fnR', 'refused'], moves('main-edited'))


class Navigation(unittest.TestCase):
    def test_navigation_modules(self):
        out = subprocess.run([sys.executable, layouts.MINILUA, os.path.join(HARNESS, 'navtest.lua'), layouts.REPO],
                             capture_output=True, text=True, cwd=layouts.ROOT)
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        self.assertRegex(out.stdout, re.compile(r'^failures\s+0\s*$', re.M), out.stdout[-2000:])


if __name__ == '__main__':
    unittest.main()
