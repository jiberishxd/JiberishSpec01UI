"""Every check the addon gets before a commit, with no Lua runtime needed.

    python3 tools/check.py            check every Lua file, then run the unit tests
    python3 tools/check.py FILE ...   check just these files (no unit tests)

For each Lua file under JiberishSpec01UI/:
  * syntax and the globals it reads and writes (tools/lua/luacheck51.py),
  * globals read before a local of the same name exists (latelocals.py),
  * the main chunk's peak local count (Lua 5.1 refuses more than 200 at load,
    which stops the file loading in game): a warning from 160, a failure from 190,
  * per-function locals and upvalues against Lua's limits (lua_static.py).
Then the unit tests in tests/. Exits non-zero on any failure.
"""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / 'JiberishSpec01UI'
LUA = Path(__file__).resolve().parent / 'lua'
WARN_LOCALS, FAIL_LOCALS = 160, 190


def run(*args):
    return subprocess.run([sys.executable, *map(str, args)], capture_output=True, text=True, cwd=ROOT)


def lua_files(paths):
    if paths:
        return [Path(p).resolve() for p in paths if p.endswith('.lua')]
    return sorted(p for p in ADDON.rglob('*.lua'))


def main(argv):
    files = lua_files(argv)
    problems, warnings = [], []

    syntax = run(LUA / 'luacheck51.py', *files)
    for line in syntax.stdout.splitlines():
        if line.startswith('FAIL'):
            problems.append(line)

    late = run(LUA / 'latelocals.py', *files)
    for line in late.stdout.splitlines():
        if not line.startswith('late locals:'):
            problems.append(line)

    static = run(LUA / 'lua_static.py', *files)
    for line in static.stdout.splitlines():
        match = re.match(r'OK (.+?): main chunk (\d+) locals', line)
        if match:
            name, peak = Path(match.group(1)).relative_to(ROOT), int(match.group(2))
            if peak >= FAIL_LOCALS:
                problems.append(f'{name}: main chunk holds {peak} locals (limit 200; keep under {FAIL_LOCALS})')
            elif peak >= WARN_LOCALS:
                warnings.append(f'{name}: main chunk holds {peak} locals')
        elif line.strip():
            problems.append(line)

    for line in warnings:
        print('warn ', line)
    for line in problems:
        print('FAIL ', line)
    print(f'{len(files)} Lua files: {len(problems)} problems, {len(warnings)} warnings')

    failed = bool(problems)
    sys.stdout.flush()
    if not argv:
        tests = subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-q'], cwd=ROOT)
        failed = failed or tests.returncode != 0
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
