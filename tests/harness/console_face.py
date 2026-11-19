"""A face-on drawing of the console as ActionBars.lua now lays it out (header
micro strip, round function keys with legends beside, banks, docked frames)."""
import math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import console_edit as ce
import layouts as run

LEGENDS = {'fnL': ['MOUNT', 'HEARTH', 'MAP', 'BAGS'], 'fnR': ['DRAWER', 'MOVE', 'CAL', 'MENU']}
MICRO = 13


def face(title, cfg, path):
    px = (768 / 2160) / 0.64
    blocks, cw, ch = ce.blocks_for(cfg, px)
    S = 740 / cw
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="780" height="%d" font-family="Menlo,monospace">' % (ch * S + 80),
         '<rect width="100%" height="100%" fill="#5a2a14"/>', '<g transform="translate(20,30)">',
         '<rect width="%.1f" height="%.1f" rx="%.1f" fill="#1c1c1b" stroke="#444"/>' % (cw * S, ch * S, 14 * S)]
    t = lambda x, y, s, txt, col='#bdbdb5', anchor='start': o.append(
        '<text x="%.1f" y="%.1f" fill="%s" font-size="%.1f" text-anchor="%s">%s</text>' % (x * S, y * S, col, s * S, anchor, txt))
    # Header: name, centred micro strip, page and LV readouts.
    t(10, 15, 8, 'CX-1  CONSOLE', '#e6e6dc')
    right = 10 + 104 + 80
    nameEnd = 10 + 70 + 12
    readouts = cw - right - 12
    key, gap = 18, 3
    sw = MICRO * key + (MICRO - 1) * gap
    x0 = (nameEnd + readouts) / 2 - sw / 2
    for i in range(MICRO):
        o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="#2b2b29" stroke="#555"/>' % (
            (x0 + i * (key + gap)) * S, 3 * S, key * S, key * S, 3 * S))
    t(cw - 10 - 104, 15, 7, 'PAGE ●○○○○○ 01', '#9a9a90')
    t(cw - 10, 15, 7, 'LV 29  57.7%', '#9a9a90', 'end')
    for b in blocks:
        x, y, w, h = b['x'], b['y'], b['w'], b['h']
        if b['kind'] == 'bank':
            n, size = 12, 34
            t(x + 2, y + 8, 6.5, 'BANK ' + 'CBA'[int(b['key'][-1]) - 1 if False else 0] if False else 'BANK', '#8a8a80')
            for i in range(n):
                o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="#3a3a37" stroke="#666"/>' % (
                    (x + 2 + i * (size + 5)) * S, (y + 11) * S, size * S, size * S, 4 * S))
        elif b['kind'] == 'fn':
            side = b['key']
            for i, legend in enumerate(LEGENDS[side]):
                ky = y + i * (22 + 4)
                kx = x if side == 'fnL' else x + w - 22
                o.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="#d8d6cc" stroke="#8a887f"/>' % (
                    (kx + 11) * S, (ky + 11) * S, 11 * S))
                if side == 'fnL': t(kx + 27, ky + 14, 6, legend, '#9a9a90')
                else: t(kx - 5, ky + 14, 6, legend, '#9a9a90', 'end')
        elif b['kind'] == 'deck':
            o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#262624"/>' % (x * S, y * S, w * S, h * S))
            t(x + 2, y + 9, 6, 'XP/HR --  ·  TO LEVEL --  ·  THIS LEVEL 2H 43M  ·  SESSION 555', '#9a9a90')
        elif b.get('bay'):
            key = b['key']
            heading = {'uf.player': 'UNIT A', 'uf.target': 'UNIT B', 'uf.focus': 'FOCUS', 'uf.targettarget': 'TOT', 'uf.pet': 'PET',
                     'cb.player': 'CAST A', 'cb.target': 'CAST B'}[key]
            live = key in ('uf.player', 'uf.pet')
            name = {'uf.player': 'JIBERISH', 'uf.pet': 'WOLF'}.get(key, '')
            level = {'uf.player': 'LV 29', 'uf.pet': 'LV 29'}.get(key, '')
            o.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="%s"/>' % ((x + 2) * S, (y + 5) * S, 2 * S, '#39d353' if live else '#3a3a37'))
            t(x + 8, y + 8, 6.5, heading, '#8a8a80')
            nx = x + 8 + len(heading) * 4.2 + 5
            if name: t(nx, y + 8, 6.5, name, '#e6e6dc')
            rx0 = nx + len(name) * 4.2 + (6 if name else 0)
            rx1 = x + w - (len(level) * 4.2 + 6 if level else 0)
            o.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#3c3c38" stroke-width="1"/>' % (rx0 * S, (y + 5.5) * S, rx1 * S, (y + 5.5) * S))
            if level: t(x + w, y + 8, 6.5, level, '#8a8a80', 'end')
            by, bh = y + 11, h - 11
            o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="#0e0e0d" stroke="#000" stroke-width="1"/>' % (x * S, by * S, w * S, bh * S, 5 * S))
            o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#000" opacity="0.35"/>' % ((x + 2) * S, (by + 1) * S, (w - 4) * S, 4 * S))
            if live and key == 'uf.player':
                ins = 3
                fx, fy, fw, fh = x + ins, by + ins, w - 2 * ins, bh - 2 * ins - 18
                o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="#7d8a76"/>' % ((fx + fh + 4) * S, fy * S, (fw - fh - 4) * S, 17 * S, 2 * S))
                t(fx + fw - 4, fy + 13, 11, '100', '#20261d', 'end')
                o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#2b9e48"/>' % ((fx + fh + 4) * S, (fy + 21) * S, (fw - fh - 4) * S, 7 * S))
                o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#4a7bd8"/>' % ((fx + fh + 4) * S, (fy + 31) * S, (fw - fh - 4) * S, 4 * S))
                o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="#30302d"/>' % (fx * S, fy * S, fh * S, fh * S, 3 * S))
                for i in range(5):
                    o.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="#e8a33a"/>' % ((fx + 6 + i * 10) * S, (fy + fh + 10) * S, 3 * S))
            elif live:
                o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#2b9e48"/>' % ((x + 4) * S, (by + 14) * S, (w - 8) * S, 6 * S))
                t(x + 4, by + 10, 6.5, 'WOLF', '#cfcfc5')
            else:
                o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="#59614f"/>' % ((x + 2) * S, (by + 2) * S, (w - 4) * S, (bh - 4) * S, 3 * S))
                empty = {'uf.target': 'NO TARGET', 'uf.focus': 'NO FOCUS', 'uf.targettarget': 'NO TARGET OF TARGET'}.get(key, '')
                if empty: t(x + w / 2, by + bh / 2 + 3, 7, empty, '#6f7864', 'middle')
        else:
            o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="#2a3644" stroke="#58a6ff" opacity="0.8"/>' % (
                x * S, y * S, w * S, h * S, 4 * S))
            t(x + w / 2, y + h / 2 + 3, 7, b['key'].split('.')[-1].upper(), '#cfe3ff', 'middle')
    o.append('</g></svg>')
    with open(path, 'w') as f: f.write('\n'.join(o))
    print(title, 'console %.1f x %.1f' % (cw, ch), path)


def run_all():
    os.makedirs(run.OUT, exist_ok=True)
    face('main', run.PRESET_SETTINGS['main'], os.path.join(run.OUT, 'face-main.svg'))
    face('integrated', run.PRESET_SETTINGS['integrated'], os.path.join(run.OUT, 'face-integrated.svg'))


if __name__ == '__main__':
    run_all()
