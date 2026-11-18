"""Flag globals a file reads that it also declares as locals: used before the local exists."""
import re, subprocess, sys
from pathlib import Path
CHECK = Path(__file__).with_name('luacheck51.py')
files = sys.argv[1:]
out = subprocess.run([sys.executable, str(CHECK), *files], capture_output=True, text=True).stdout.splitlines()
current, bad = None, 0
for line in out:
    m = re.match(r'(OK|ERR\S*)\s+(\S+)', line)
    if m:
        current = next((f for f in files if f.endswith('/' + m.group(2)) or f == m.group(2)), None)
        continue
    if line.strip().startswith('reads:') and current:
        src = Path(current).read_text()
        for name in line.split(':', 1)[1].split():
            # 'local X = X' (and 'local X, Y = X, Y') caches a real global on purpose.
            cached = re.search(r'\blocal\s+[\w, ]*\b%s\b[\w, ]*=[^\n]*\b%s\b' % (name, name), src)
            if not cached and re.search(r'\blocal\s+function\s+%s\b|\blocal\s+%s\b' % (name, name), src):
                print(f'{current}: {name} is read as a global but declared local in the file'); bad += 1
print('late locals:', bad)
