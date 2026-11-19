"""Solve the layout presets offline (the real Layouts.lua through minilua) on
several screens, check them and render each to SVG (build/harness/).

    python3 tests/harness/layouts.py      solve, check and render every preset and screen

tests/test_harness.py runs the same solves without rendering and fails on any problem."""
import json, math, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
REPO = os.path.join(ROOT, 'JiberishSpec01UI')
MINILUA = os.path.join(ROOT, 'tools', 'lua', 'minilua.py')
OUT = os.path.join(ROOT, 'build', 'harness')
PROFILE = json.load(open(os.path.join(HERE, 'fixtures', 'main-profile-layout.json')))

# Frame sizes in UI units, unscaled (from the modules' defaults and the profile).
SIZES = {
    'uf.player': (224, 70), 'uf.target': (224, 70), 'uf.targettarget': (128, 30), 'uf.pet': (128, 30), 'uf.focus': (176, 44),
    'uf.party1': (176, 44), 'uf.party2': (176, 44), 'uf.party3': (176, 44), 'uf.party4': (176, 44),
    'cb.player': (240, 30), 'cb.target': (224, 30),
    'tl.player': (272, 110), 'ab.extra': (60, 60), 'ab.zone': (60, 60),
    'ab.menu': (309, 34), 'ab.bags': (159, 34), 'ab.side': (85, 449),
    'bags.bags': (220, 40), 'bags.bank': (220, 40), 'dm.own': (270, 198),
    'group.small': (364, 226), 'group.large': (597, 172), 'group.boss': (200, 350), 'group.arena': (200, 350),
    'ip.main': (720, 26), 'ip.extra': (300, 26), 'ip.hud': (220, 98),
    'cue.status': (176, 62), 'cue.ring': (188, 188),
    'nt.banner': (388, 100), 'nt.loot': (236, 28), 'nt.lootwindow': (252, 102), 'nt.rolls': (320, 82),
    'drawer.tab': (34, 20),
    'nav.compass': (460, 86), 'nav.map': (300, 300),
}
DEFAULTS = {
    'bags.bags': ('BOTTOMRIGHT', -24, 210), 'bags.bank': ('TOPLEFT', 40, -110), 'ab.console': ('BOTTOM', 0, 12),
    'ab.side': ('RIGHT', -8, 0), 'ab.menu': ('BOTTOMRIGHT', -12, 12), 'ab.bags': ('BOTTOMRIGHT', -12, 52),
    'ab.extra': ('BOTTOM', 0, 300), 'ab.zone': ('BOTTOM', -90, 300), 'cue.status': ('TOP', 0, -96), 'cue.ring': ('CENTER', 0, -70),
    'drawer.tab': ('RIGHT', 0, -40), 'ip.hud': ('TOP', 0, -6), 'ip.main': ('TOP', 0, -4), 'ip.extra': ('TOPLEFT', 4, -4),
    'dm.own': ('BOTTOMRIGHT', -16, 260), 'nt.banner': ('TOP', 0, -64), 'nt.loot': ('RIGHT', -260, 0),
    'nt.lootwindow': ('LEFT', 260, 120), 'nt.rolls': ('BOTTOM', 0, 300), 'tl.player': ('BOTTOM', -228, 330),
    'uf.player': ('BOTTOM', -228, 236), 'uf.target': ('BOTTOM', 228, 236), 'uf.targettarget': ('BOTTOM', 422, 256),
    'uf.focus': ('LEFT', 300, 120), 'uf.pet': ('BOTTOM', -400, 196), 'cb.player': ('BOTTOM', 0, 196), 'cb.target': ('BOTTOM', 228, 166),
    'group.small': ('BOTTOMLEFT', 12, 220), 'group.large': ('BOTTOMLEFT', 12, 220), 'group.boss': ('RIGHT', -120, 0),
    'group.arena': ('RIGHT', -120, 0),
    'nav.compass': ('TOP', 0, -40), 'nav.map': ('CENTER', 420, 40),
}
for i in range(1, 5):
    DEFAULTS['uf.party%d' % i] = ('LEFT', 24, 200 - (i - 1) * 62)

PRESET_SETTINGS = {
    'main': dict(layout='console', dock=False, rows=2, side=True, keySize=34, consoleWidth=640, consoleHeight=0,
                 dockFocus=False, dockToT=False, dockPet=False),
    'integrated': dict(layout='console', dock=True, rows=3, side=True, keySize=34, consoleWidth=0, consoleHeight=0,
                       dockFocus=True, dockToT=True, dockPet=True),
}

# The console, as ActionBars.lua's LayoutConsoleNow lays it out (Hardware look,
# slim meter, text stats strip, default function keys), slots in console units.
PAD, HEAD, GAP, COL_GAP, ROW_GAP, AUX, BANK_H = 10, 24, 5, 14, 6, 24, 11


def console_layout(cfg, px):
    def snap(v): return math.floor(v / px + 0.5 + 0.001) * px
    fnW, fnH = 55, 100  # one column of 4 round keys, legends beside
    dock = cfg['dock']
    parts = {}
    if dock:
        parts.update(player=(224, 70), target=(224, 70), playerCast=(240, 30), targetCast=(224, 30))
        if cfg['dockFocus']: parts['focus'] = (176, 44)
        if cfg['dockToT']: parts['tot'] = (128, 30)
        if cfg['dockPet']: parts['pet'] = (128, 30)
    m = lambda k: parts.get(k, (0, 0))
    column = max([m(k)[0] for k in ('player', 'target', 'focus', 'tot', 'pet')] + [0])
    fixedW = cfg['consoleWidth'] if cfg['consoleWidth'] > 0 else None

    def side(fw):
        return (fw + COL_GAP if fw > 0 else 0) + (fnW + COL_GAP if fnW > 0 else 0)
    sideW = side(column)
    fnPart = fnW + COL_GAP
    castH = max(m('playerCast')[1], m('targetCast')[1])
    low = max(castH, m('pet')[1])
    castRow = low + ROW_GAP if low > 0 else 0
    xpH = (3 + 6) + (10 + 6)
    size = cfg['keySize']
    area = fixedW - PAD * 2 - sideW * 2 if fixedW else None
    if area and 12 * size + 55 > area: size = math.floor((area - 55) / 12)
    rows = cfg['rows']
    width = 12 * size + 55
    height = rows * (size + BANK_H) + (rows - 1) * GAP
    area = area or width
    ph = max(m('player')[1], m('target')[1])
    underMain = ph + AUX if ph > 0 else 0
    small = max(m('focus')[1], m('tot')[1])
    frames = max(ph, underMain + small if small > 0 else 0)
    body = max(height, frames + AUX if frames > 0 else 0, fnH)
    if dock:  # embedded bays on the bank row grid
        pitch = BANK_H + size + GAP
        main_rows = max(2, rows - 1 if small else rows)
        body = max(max(rows, main_rows + (1 if small else 0)) * pitch - GAP, fnH)
        if low: low, castRow = size, BANK_H + size + GAP
    up = lambda v: math.ceil(v / px - 0.001) * px
    cw = snap((fixedW or (PAD * 2 + width + sideW * 2)) / 2) * 2
    castY = up(HEAD + body + (GAP + BANK_H if dock else ROW_GAP))
    ch = up((castY + low if castRow > 0 else HEAD + body) + xpH + PAD)
    left = PAD + sideW
    slots = {}
    top = HEAD + (max(0, math.floor(min((body - frames) / 2, body - frames - AUX))) if frames > 0 else 0)
    leftX, rightX = PAD + fnPart, cw - PAD - fnPart - column
    cen = lambda x, w: x + (column - w) / 2

    def put(key, part, x, y, w=None, h=None):
        if part not in parts and part is not None: return
        pw_, ph_ = (w, h) if w else m(part)
        slots[key] = (snap(x), up(y), pw_, ph_)
    put('uf.player', 'player', cen(leftX, m('player')[0]), top + (ph - m('player')[1]) / 2)
    put('uf.target', 'target', cen(rightX, m('target')[0]), top + (ph - m('target')[1]) / 2)
    put('uf.focus', 'focus', cen(leftX, m('focus')[0]), top + underMain + (small - m('focus')[1]) / 2)
    put('uf.targettarget', 'tot', cen(rightX, m('tot')[0]), top + underMain + (small - m('tot')[1]) / 2)
    castW = snap((area - 8) / 2)
    if dock:
        put('cb.player', 'playerCast', left, castY + math.floor((low - castH) / 2), castW, 30)
        put('cb.target', 'targetCast', left + castW + 8, castY + math.floor((low - castH) / 2), castW, 30)
    put('uf.pet', 'pet', cen(leftX, m('pet')[0]), castY + math.floor((low - m('pet')[1]) / 2))
    # Fixed parts, for the render: banks, function keys, the deck along the base.
    inner = {}
    by = HEAD + max(0, math.floor((body - height) / 2))
    inner['banks'] = (snap(left + (area - width) / 2), by, width, height)
    inner['fnL'] = (PAD, HEAD + math.floor((body - fnH) / 2), fnW, fnH)
    inner['fnR'] = (cw - PAD - fnW, HEAD + math.floor((body - fnH) / 2), fnW, fnH)
    inner['deck'] = (PAD, ch - PAD - xpH, cw - 2 * PAD, xpH)
    inner['header'] = (0, 0, cw, HEAD)
    if dock: slots = {}  # embedded bays: checked by console_edit.py
    return cw, ch, slots, inner


def obstacles(W, H):
    # Edit Mode frames near their default spots (bottom-left origin): chat,
    # minimap, buffs, a short objective list under the minimap.
    return {'ChatFrame1': (35, 95, 430, 150), 'MinimapCluster': (W - 226, H - 240, 216, 230),
            'BuffFrame': (W - 640, H - 112, 400, 100), 'ObjectiveTrackerFrame': (W - 330, H - 400, 215, 160)}


def lua_value(v):
    if isinstance(v, bool): return 'true' if v else 'false'
    if isinstance(v, (int, float)): return repr(float(v))
    if isinstance(v, str): return json.dumps(v)
    if isinstance(v, (list, tuple)): return '{' + ', '.join(lua_value(x) for x in v) + '}'
    if isinstance(v, dict): return '{' + ', '.join('[%s] = %s' % (json.dumps(k), lua_value(x)) for k, x in v.items()) + '}'
    raise TypeError(v)


def solve(preset, W, H, phys, scale):
    cfg = PRESET_SETTINGS[preset]
    px = (768 / phys[1]) / scale
    cw, ch, slots, inner = console_layout(cfg, px)
    sizes = dict(SIZES)
    sizes['ab.console'] = (cw, ch)
    docked = {k: True for k in slots}
    if cfg['dock']:
        docked.update({k: True for k in ('uf.player', 'uf.target', 'cb.player', 'cb.target')})
        for k, flag in (('uf.focus', 'dockFocus'), ('uf.targettarget', 'dockToT'), ('uf.pet', 'dockPet')):
            if cfg[flag]: docked[k] = True
    order = ['ab.console'] + list(SIZES)
    ab = dict(cfg, fnKeys=True)
    db = {'layout': {'preset': preset, 'custom': {}}, 'movers': {}, 'actionbars': ab,
          'group': {'small': PROFILE['group']['small'], 'large': PROFILE['group']['large'],
                    'boss': {'width': 200, 'height': 46, 'spacing': 30}, 'arena': {'width': 200, 'height': 46, 'spacing': 30}},
          'infopanel': {'layout': 'strips', 'extra': True}}
    conf = {'W': W, 'H': H, 'uiScale': scale, 'physW': phys[0], 'physH': phys[1], 'sizes': sizes, 'defaults': DEFAULTS,
            'docked': docked, 'order': order, 'presets': [preset], 'db': db, 'obstacles': obstacles(W, H)}
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, 'conf_%s.lua' % preset)
    with open(path, 'w') as f: f.write('CONFIG = ' + lua_value(conf) + '\n')
    out = subprocess.run([sys.executable, MINILUA, os.path.join(HERE, 'harness_layouts.lua'), path,
                          os.path.join(REPO, 'Modules', 'Layouts.lua')], capture_output=True, text=True)
    if out.returncode != 0 or 'ERROR' in out.stdout:
        print(out.stdout[-3000:], out.stderr[-3000:]); raise SystemExit(1)
    rects = {}
    for line in out.stdout.splitlines():
        if line.startswith('RECT'):
            _, key, x, y, w, h, sc = line.split()
            rects[key] = tuple(map(float, (x, y, w, h, sc)))
        elif line.startswith('PRINT'): print('   ', line)
    return rects, (cw, ch, slots, inner), px


OVER = {('ab.menu', 'ab.console'), ('drawer.tab', 'ab.console'), ('bags.bags', 'dm.own'), ('nt.lootwindow', 'nt.rolls'),
        ('nt.banner', 'cue.status')}
EXCLUSIVE = {frozenset(p) for p in [('group.small', 'group.large'), ('group.boss', 'group.arena')]}


def overlaps(a, b, pad=0):
    return a[0] < b[0] + b[2] - pad and b[0] < a[0] + a[2] - pad and a[1] < b[1] + b[3] - pad and b[1] < a[1] + a[3] - pad


def check(preset, rects, W, H, obst, console, px):
    problems = []
    keys = sorted(rects)
    for i, a in enumerate(keys):
        for b in keys[i + 1:]:
            if frozenset((a, b)) in EXCLUSIVE or (a, b) in OVER or (b, a) in OVER: continue
            if overlaps(rects[a], rects[b]): problems.append('overlap %s / %s' % (a, b))
        for name, r in obst.items():
            if overlaps(rects[a], r): problems.append('covers %s: %s' % (name, a))
        x, y, w, h, _ = rects[a]
        if x < -0.01 or x + w > W + 0.01 or y + h > H + 0.01 or (y < -0.01 and not (a == 'drawer.tab' and y > -7)):
            problems.append('off screen %s (%.1f %.1f %.1f %.1f)' % (a, x, y, w, h))
    # Mirror pairs about the console's centre.
    c = rects.get('ab.console')
    if c and 'uf.player' in rects and 'uf.target' in rects:
        cx = c[0] + c[2] / 2
        p, t = rects['uf.player'], rects['uf.target']
        if abs((cx - (p[0] + p[2])) - (t[0] - cx)) > 0.6 or abs(p[1] - t[1]) > 0.6:
            problems.append('player/target not mirrored about the console (%.2f vs %.2f)' % (cx - p[0] - p[2], t[0] - cx))
    # Inside the console: no slot overlaps another or the banks, keys, deck or header.
    cw, ch, slots, inner = console
    names = sorted(slots)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if overlaps(slots[a], slots[b]): problems.append('console: %s / %s' % (a, b))
        for name, r in inner.items():
            if overlaps(slots[a], r): problems.append('console: %s over %s' % (a, name))
        x, y, w, h = slots[a]
        if x < 0 or y < 0 or x + w > cw or y + h > ch: problems.append('console: %s outside' % a)
        for v in (x, y):
            if abs(v / px - round(v / px)) > 1e-3: problems.append('console: %s off the pixel grid' % a)
    if slots:
        p, t = slots.get('uf.player'), slots.get('uf.target')
        if p and t and (abs(p[0] - (cw - t[0] - t[2])) > px + 1e-6 or p[1] != t[1]):
            problems.append('console: player/target not mirrored (%.2f vs %.2f)' % (p[0], cw - t[0] - t[2]))
    return problems


def user_rects(W, H):
    out = {}
    for key, m in PROFILE['movers'].items():
        if key not in SIZES: continue
        sc = m.get('scale', 1)
        w, h = SIZES[key][0] * sc, SIZES[key][1] * sc
        a = m['anchor']
        ax = 0 if 'LEFT' in a else W if 'RIGHT' in a else W / 2
        ay = 0 if 'BOTTOM' in a else H if 'TOP' in a else H / 2
        fx = 0 if 'LEFT' in a else w if 'RIGHT' in a else w / 2
        fy = 0 if 'BOTTOM' in a else h if 'TOP' in a else h / 2
        out[key] = (ax + m['1'] - fx, ay + m['2'] - fy, w, h, sc)
    return out


COLORS = {'ab': '#d9a441', 'uf': '#58a6ff', 'cb': '#7ee787', 'group': '#bc8cff', 'dm': '#ff7b72', 'ip': '#9e9e9e', 'nt': '#e3b341',
          'cue': '#f778ba', 'tl': '#56d4dd', 'bags': '#a5d6a7', 'drawer': '#cccccc', 'nav': '#ffa657'}


def svg(path, title, W, H, rects, obst, console, ref=None):
    S = 770 / W
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" font-family="Menlo,monospace">' % (900, H * S + 30),
         '<rect width="100%" height="100%" fill="#0d1117"/>',
         '<text x="6" y="18" fill="#e6edf3" font-size="13">%s</text>' % title,
         '<g transform="translate(0,30)"><rect width="%.1f" height="%.1f" fill="#161b22" stroke="#30363d"/>' % (W * S, H * S),
         '<line x1="%.1f" y1="0" x2="%.1f" y2="%.1f" stroke="#30363d" stroke-dasharray="4 4"/>' % (W * S / 2, W * S / 2, H * S)]
    def box(x, y, w, h, fill, stroke, label='', dash='', opacity=0.35, size=9):
        yy = (H - y - h) * S
        o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s" fill-opacity="%s" stroke="%s" %s/>' % (
            x * S, yy, w * S, h * S, fill, opacity, stroke, 'stroke-dasharray="%s"' % dash if dash else ''))
        if label: o.append('<text x="%.1f" y="%.1f" fill="#e6edf3" font-size="%d" text-anchor="middle">%s</text>' % (
            (x + w / 2) * S, yy + h * S / 2 + 3, size, label))
    for name, r in obst.items(): box(*r, '#30363d', '#6e7681', name.replace('Frame', '').replace('Cluster', ''), '3 3', 0.5)
    if ref:
        for key, r in ref.items(): box(r[0], r[1], r[2], r[3], 'none', '#ffffff', '', '2 2', 0)
    for key, r in rects.items():
        col = COLORS.get(key.split('.')[0], '#888')
        box(r[0], r[1], r[2], r[3], col, col, key.split('.', 1)[1] + ('' if abs(r[4] - 1) < 0.005 else ' %.2f' % r[4]))
    c = rects.get('ab.console')
    if c and console:
        cw, ch, slots, inner = console
        for name, r in list(inner.items()) + list(slots.items()):
            x, y, w, h = r
            col = '#555' if name in inner else COLORS.get(name.split('.')[0], '#888')
            box(c[0] + x * c[2] / cw, c[1] + c[3] - (y + h) * c[3] / ch, w * c[2] / cw, h * c[3] / ch, col, col,
                name.split('.')[-1] if name not in inner else '', '', 0.5, 7)
    o.append('</g></svg>')
    with open(path, 'w') as f: f.write('\n'.join(o))


SCREENS = [
    # name, UI width, height, physical size, UI scale
    ('ref-16x9-0.64', 2133.333, 1200, (3840, 2160), 0.64),
    ('ref-alt-1959x1200', 1959.4, 1200, (3024, 1852), 0.64),
    ('1080p', 1920, 1080, (1920, 1080), 0.7111),
    ('1440p-comfortable', 1706.667, 960, (2560, 1440), 0.8),
    ('1440p-compact', 2560, 1440, (2560, 1440), 0.5333),
    ('4K-comfortable', 1920, 1080, (3840, 2160), 0.7111),
    ('21x9-3440x1440', 2293.333, 960, (3440, 1440), 0.8),
    ('21x9-2560x1080', 2560, 1080, (2560, 1080), 0.7111),
]

# The core frames whose spots `main` must reproduce at the reference screen (UI units).
REFERENCE_KEYS = ('ab.console', 'uf.player', 'uf.target', 'cb.player', 'cb.target', 'uf.pet', 'uf.targettarget', 'uf.focus',
                  'group.large', 'group.small', 'ab.side', 'dm.own', 'tl.player', 'ab.extra', 'ab.zone')


def run_all(render=True, verbose=True):
    """Every preset on every screen: (problems, reference differences) as lists of strings / (key, distance)."""
    os.makedirs(OUT, exist_ok=True)
    all_problems, reference = [], []
    for preset in ('main', 'integrated'):
        for name, W, H, phys, scale in SCREENS:
            rects, console, px = solve(preset, W, H, phys, scale)
            obst = obstacles(W, H)
            probs = check(preset, rects, W, H, obst, console if preset == 'integrated' else (0, 0, {}, {}), px)
            ref = user_rects(W, H) if preset == 'main' and name.startswith('ref') else None
            diffs = []
            if ref:
                for key, r in ref.items():
                    if key in rects:
                        d = max(abs(rects[key][0] - r[0]), abs(rects[key][1] - r[1]), abs(rects[key][2] - r[2]), abs(rects[key][3] - r[3]))
                        diffs.append((d, key))
                diffs.sort(reverse=True)
                if name == 'ref-16x9-0.64': reference = [(k, d) for d, k in diffs]
            if render:
                out = os.path.join(OUT, '%s-%s.svg' % (preset, name))
                svg(out, '%s  %s  %gx%g UI units  (scale %.3f)' % (preset, name, W, H, scale), W, H, rects, obst,
                    console if preset == 'integrated' else None, ref)
            if verbose:
                print('%-11s %-20s console %.1fx%.1f  frames %d  problems %d' % (preset, name, console[0], console[1], len(rects), len(probs)))
                for p in probs: print('     ', p)
                if ref: print('      vs your profile: worst %s' % ', '.join('%s %.1f' % (k, d) for d, k in diffs[:8]))
            all_problems += ['%s %s: %s' % (preset, name, p) for p in probs]
    if verbose: print('total problems', len(all_problems))
    return all_problems, reference


if __name__ == '__main__':
    run_all()
