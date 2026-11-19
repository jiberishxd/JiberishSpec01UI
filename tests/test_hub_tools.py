"""The hub's slash commands, Undo history, reload list and page resets behave
as documented (run offline through tools/lua/minilua.py), and the pages they
point at exist."""
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / 'JiberishSpec01UI'


class HubTools(unittest.TestCase):
    def test_slash_table_and_history(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / 'tools/lua/minilua.py'), str(ROOT / 'tests/lua/hub_tools.lua'),
             str(ADDON / 'Core.lua'), str(ADDON / 'Modules/HubHistory.lua')],
            capture_output=True, text=True, cwd=ROOT, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip().splitlines()[-1:], ['ok'], result.stdout + result.stderr)

    def test_commands_and_highlights_point_at_real_things(self):
        modules = ''.join(path.read_text() for path in sorted((ADDON / 'Modules').glob('*.lua')))
        pages = set(re.findall(r"UI:RegisterPage\('(\w+)'", modules))
        core = (ADDON / 'Core.lua').read_text()
        # Every page a command opens exists.
        for page in re.findall(r"UI:ToggleHub\('(\w+)', true\)", core):
            self.assertIn(page, pages, page)
        # Every UI method a command needs is defined somewhere.
        table = core.split('local COMMANDS = {', 1)[1].split('\nUI.commands', 1)[0]
        needs = set(re.findall(r"needs = '(\w+)'", table))
        for group in re.findall(r"needs = \{([^}]*)\}", table):
            needs.update(re.findall(r"'(\w+)'", group))
        source = core + modules
        for name in needs:
            self.assertRegex(source, rf'function UI:{name}\(', name)
        # What's new: every Open key goes to a real page or a real command.
        whatsnew = (ADDON / 'Modules/WhatsNew.lua').read_text()
        releases = whatsnew.split('local RELEASES = {', 1)[1].split('\nUI.releases', 1)[0]
        for page in re.findall(r"page = '(\w+)'", releases):
            self.assertIn(page, pages, page)
        words = set(re.findall(r"word = '(\w+)'", table))
        for command in re.findall(r"command = '(\w+)'", releases):
            self.assertIn(command, words, command)
        # The newest release is the addon's version.
        version = re.search(r'^## Version: (\S+)', (ADDON / 'JiberishSpec01UI.toc').read_text(), re.M).group(1)
        self.assertEqual(re.search(r"version = '([^']+)'", releases).group(1), version)
        self.assertIn(f'## {version}', (ROOT / 'CHANGELOG.md').read_text())

    def test_sidebar_lists_the_new_pages(self):
        hub = (ADDON / 'Modules/Hub.lua').read_text()
        groups = hub.split('local GROUPS = {', 1)[1].split('\n}', 1)[0]
        for page in ('quick', 'whatsnew', 'commands'):
            self.assertIn(f"'{page}'", groups)


if __name__ == '__main__':
    unittest.main()
