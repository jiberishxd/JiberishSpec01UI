"""make harness: every offline harness, with renders in build/harness/.

  * layouts.py       the layout presets solved by the real Layouts.lua on the standard screens
  * console_edit.py  console editor moves and the console's overlap resolve (ConsoleEditor.lua)
  * console_face.py  face-on drawings of the two presets' consoles
  * navtest.lua      Navigation.lua, Compass.lua and OverlayMap.lua with mocked frames
  * nav_preview.py   compass and map schematics
SVGs are converted to PNG with Quick Look where it exists (macOS)."""
import glob
import re
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import layouts  # noqa: E402
import console_edit  # noqa: E402
import console_face  # noqa: E402
import nav_preview  # noqa: E402


def navtest():
    out = subprocess.run([sys.executable, layouts.MINILUA, os.path.join(HERE, 'navtest.lua'), layouts.REPO],
                         capture_output=True, text=True, cwd=layouts.ROOT)
    return out.returncode, out.stdout + out.stderr


def main():
    os.makedirs(layouts.OUT, exist_ok=True)
    problems, _ = layouts.run_all()
    editor, _ = console_edit.main()
    console_face.run_all()
    nav_preview.run_all()
    code, text = navtest()
    print(text.strip().splitlines()[-1] if text.strip() else 'navtest: no output')
    failed = bool(problems or editor or code != 0 or not re.search(r'^failures\s+0\s*$', text, re.M))
    if shutil.which('qlmanage'):
        png = os.path.join(layouts.OUT, 'png')
        os.makedirs(png, exist_ok=True)
        subprocess.run(['qlmanage', '-t', '-s', '1400', '-o', png] + glob.glob(os.path.join(layouts.OUT, '*.svg')),
                       capture_output=True)
    print('renders:', layouts.OUT)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
