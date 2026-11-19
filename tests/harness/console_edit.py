"""Console editor checks: the console's blocks (as the console module lays them
out), editor moves through ConsoleEditor.lua's real geometry (minilua), the
console's Resolve over the saved arrangement, invariants, SVG renders (build/harness/)."""
import math, os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layouts as run

HERE = os.path.dirname(os.path.abspath(__file__))
EDITOR = os.path.join(run.REPO, 'Modules', 'ConsoleEditor.lua')
PAD, HEAD, GAP, COL_GAP, ROW_GAP, AUX, BANK = 10, 24, 5, 14, 6, 24, 11


def blocks_for(cfg, px, columns=None):
    """The console's blocks in its automatic arrangement (ActionBars.lua LayoutConsoleNow)."""
    columns = columns or {}
    snap = lambda v: math.floor(v / px + 0.5 + 0.001) * px
    up = lambda v: math.ceil(v / px - 0.001) * px
    fnW, fnH = 55, 100  # one column of 4 round keys, legends beside
    parts = {}
    if cfg['dock']:
        parts.update(player=(224, 70), target=(224, 70), playerCast=(240, 30), targetCast=(224, 30))
        if cfg['dockFocus']: parts['focus'] = (176, 44)
        if cfg['dockToT']: parts['tot'] = (128, 30)
        if cfg['dockPet']: parts['pet'] = (128, 30)
    m = lambda k: parts.get(k, (0, 0))
    column = max([m(k)[0] for k in ('player', 'target', 'focus', 'tot', 'pet')] + [0])
    fixedW = cfg['consoleWidth'] if cfg['consoleWidth'] > 0 else None
    sideW = (column + COL_GAP if column else 0) + fnW + COL_GAP
    fnPart = fnW + COL_GAP
    castH = max(m('playerCast')[1], m('targetCast')[1])
    low = max(castH, m('pet')[1])
    castRow = low + ROW_GAP if low else 0
    deckH = (3 + 6 + 10 + 6) - ROW_GAP
    xpH = deckH + ROW_GAP
    size = cfg['keySize']
    area = fixedW - PAD * 2 - sideW * 2 if fixedW else None
    if area and 12 * size + 55 > area: size = math.floor((area - 55) / 12)
    bars = []
    for i in range(1, cfg['rows'] + 1):
        cols = columns.get(i, 12)
        lines = math.ceil(12 / cols)
        bars.append((i, cols * size + (cols - 1) * 5, lines * size + (lines - 1) * 5))
    width = max(b[1] for b in bars)
    height = sum(b[2] + BANK for b in bars) + (len(bars) - 1) * GAP
    area = area or width
    ph = max(m('player')[1], m('target')[1])
    under = ph + AUX if ph else 0
    small = max(m('focus')[1], m('tot')[1])
    frames = max(ph, under + small if small else 0)
    body = max(height, frames + AUX if frames else 0, fnH)
    embedded = cfg['dock'] and cfg.get('dockLook', 'embedded') != 'float'
    pitch = BANK + size + GAP
    if embedded:
        has_small = small > 0
        need = 44 + 18 + 6  # frame, class lamps under it, insets
        main_rows = max(2, cfg['rows'] - 1 if has_small else cfg['rows'])
        while (main_rows - 1) * pitch + size < need: main_rows += 1
        col_rows = main_rows + (1 if has_small else 0)
        body = max(max(cfg['rows'], col_rows) * pitch - GAP, fnH)
        if low: low, castRow = size, BANK + size + GAP
    cw = snap((fixedW or (PAD * 2 + width + sideW * 2)) / 2) * 2
    castY = up(HEAD + body + (GAP + BANK if embedded else ROW_GAP))
    ch = up((castY + low if castRow else HEAD + body) + xpH + PAD)
    left = PAD + sideW
    out = []

    def put(key, kind, x, y, w, h):
        if w > 0 and h > 0: out.append({'key': key, 'kind': kind, 'x': snap(x), 'y': up(y), 'w': w, 'h': h})
    y = HEAD + (0 if embedded else max(0, math.floor((body - height) / 2)))
    for i, w, h in reversed(bars):
        put('bank%d' % i, 'bank', left + (area - w) / 2 - 2, y, w + 4, BANK + h)
        y += BANK + h + GAP
    top = HEAD + (max(0, math.floor(min((body - frames) / 2, body - frames - AUX))) if frames else 0)
    lx, rx = PAD + fnPart, cw - PAD - fnPart - column
    cen = lambda x, w: x + (column - w) / 2
    castW = snap((area - 8) / 2)
    if embedded:
        main_bay = BANK + (main_rows - 1) * pitch + size
        sy = HEAD + main_rows * pitch
        ct = castY - BANK
        for key, part, x, yy, h in (('uf.player', 'player', lx, HEAD, main_bay), ('uf.target', 'target', rx, HEAD, main_bay),
                                    ('uf.focus', 'focus', lx, sy, BANK + size), ('uf.targettarget', 'tot', rx, sy, BANK + size)):
            if part in parts: put(key, 'unit', x, yy, column, h)
        put('cb.player', 'cast', left, ct, castW, BANK + size)
        put('cb.target', 'cast', left + castW + 8, ct, castW, BANK + size)
        if 'pet' in parts: put('uf.pet', 'unit', lx, ct, column, BANK + size)
        for b in out:
            if b['kind'] in ('unit', 'cast'): b['bay'] = True
        put('fnL', 'fn', PAD, HEAD + math.floor((body - fnH) / 2), fnW, fnH)
        put('fnR', 'fn', cw - PAD - fnW, HEAD + math.floor((body - fnH) / 2), fnW, fnH)
        put('deck', 'deck', PAD, ch - PAD - deckH, cw - 2 * PAD, deckH)
        return out, cw, ch
    put('uf.player', 'unit', cen(lx, m('player')[0]), top + (ph - m('player')[1]) / 2, *m('player'))
    put('uf.target', 'unit', cen(rx, m('target')[0]), top + (ph - m('target')[1]) / 2, *m('target'))
    put('uf.focus', 'unit', cen(lx, m('focus')[0]), top + under + (small - m('focus')[1]) / 2, *m('focus'))
    put('uf.targettarget', 'unit', cen(rx, m('tot')[0]), top + under + (small - m('tot')[1]) / 2, *m('tot'))
    castW = snap((area - 8) / 2)
    if cfg['dock']:
        put('cb.player', 'cast', left, castY, castW, 30)
        put('cb.target', 'cast', left + castW + 8, castY, castW, 30)
    put('uf.pet', 'unit', cen(lx, m('pet')[0]), castY + math.floor((low - m('pet')[1]) / 2), *m('pet'))
    put('fnL', 'fn', PAD, HEAD + math.floor((body - fnH) / 2), fnW, fnH)
    put('fnR', 'fn', cw - PAD - fnW, HEAD + math.floor((body - fnH) / 2), fnW, fnH)
    put('deck', 'deck', PAD, ch - PAD - deckH, cw - 2 * PAD, deckH)
    return out, cw, ch


def lua_blocks(blocks):
    return '{' + ', '.join('{key = "%s", kind = "%s", x = %r, y = %r, w = %r, h = %r%s}' % (
        b['key'], b['kind'], b['x'], b['y'], b['w'], b['h'], ', tucked = true' if b.get('tucked') else '') for b in blocks) + '}'


def scenarios(px):
    up = lambda v: math.ceil(v / px - 0.001) * px
    integrated = run.PRESET_SETTINGS['integrated']
    main = run.PRESET_SETTINGS['main']
    out = []
    # 1. The integrated console as it arranges itself (nothing moved).
    b, cw, ch = blocks_for(integrated, px)
    out.append(('integrated-auto', b, cw, ch, []))
    # 2. Integrated, edited: pet to the cast row's right cell, the cast bars
    # under their frames' banks side, a cast bar dropped on a bank (refused),
    # the left keys dragged into the header (refused), focus pulled onto the
    # player's left edge by the magnet, bar 1 reshaped to 6 x 2.
    b, cw, ch = blocks_for(integrated, px)
    by = {x['key']: x for x in b}
    t = by['uf.target']
    ops = [
        ('move', 'uf.pet', t['x'] + (224 - 128) / 2, by['uf.pet']['y']),
        ('move', 'cb.player', by['bank1']['x'] + 20, by['bank1']['y'] + 10),
        ('move', 'fnL', by['fnL']['x'], 4),
        ('move', 'uf.focus', by['uf.player']['x'] + 3 * px, by['uf.focus']['y'], True),
        ('move', 'fnR', cw + 400, by['fnR']['y']),
    ]
    b6, _, _ = blocks_for(integrated, px, {1: 6})
    bank6 = [x for x in b6 if x['key'] == 'bank1'][0]
    ops.append(('size', 'bank1', bank6['w'], bank6['h']))
    out.append(('integrated-edited', b, cw, ch, ops))
    # 3. Main's compact console, edited: both function key clusters stacked on
    # the left, the banks moved right of them, the meters narrowed under the banks.
    b, cw, ch = blocks_for(main, px)
    by = {x['key']: x for x in b}
    fl = by['fnL']
    d = by['deck']
    ops = [('move', 'fnR', fl['x'], fl['y'] + fl['h'] + 6),          # onto the meters: refused
           ('move', 'deck', d['x'], d['y'] + 80),                       # the meters lower: the console grows
           ('move', 'fnL', fl['x'], up(HEAD)),
           ('move', 'fnR', fl['x'], up(HEAD) + fl['h'] + 6),
           ('move', 'bank2', fl['x'] + fl['w'] + 14, by['bank2']['y'], True),
           ('move', 'bank1', fl['x'] + fl['w'] + 14, by['bank1']['y'], True)]
    out.append(('main-edited', b, cw, ch, ops))
    # 4. Main with stance keys (six stances): tucked on the top edge, dropped
    # on a bank (refused), into the body under the banks after the meters move
    # down (accepted), then reshaped to 3 x 2.
    b, cw, ch = blocks_for(main, px)
    by = {x['key']: x for x in b}
    size, sp = 24, 4
    sw, sh = 20 + 6 * size + 5 * sp, size + 16 + BANK
    left = PAD + 50 + COL_GAP
    b.append({'key': 'stance', 'kind': 'mini', 'x': left - 8, 'y': 8 - sh, 'w': sw, 'h': sh, 'tucked': True})
    d, b1 = by['deck'], by['bank1']
    ops = [('move', 'stance', b1['x'] + 10, b1['y'] + 4),
           ('move', 'deck', d['x'], d['y'] + 70),
           ('move', 'stance', b1['x'], b1['y'] + b1['h'] + 6, True),
           ('size', 'stance', 20 + 3 * size + 2 * sp, 2 * size + sp + 16 + BANK)]
    out.append(('main-stance', b, cw, ch, ops))
    return out
    nd = run.overlaps
    out.append(('main-edited', b, cw, ch, ops))
    return out


def lua_list(items):
    return '{' + ', '.join(items) + '}'


def main(render=True, verbose=True):
    """Every editor scenario: (problems, {scenario: log lines})."""
    px = (768 / 2160) / 0.64
    scen = scenarios(px)
    parts = []
    for name, blocks, cw, ch, ops in scen:
        left, top = math.ceil(PAD / px - 0.001) * px, math.ceil(HEAD / px - 0.001) * px
        limits = '{left = %r, top = %r, right = %r, bottom = %r}' % (left, top, 2400 - left, 600 - left)
        bounds = '{left = %r, top = %r}' % (left, top)
        oplist = lua_list(['{"%s", "%s", %r, %r%s}' % (o[0], o[1], o[2], o[3], ', true' if len(o) > 4 else '') for o in ops])
        parts.append('{name = "%s", blocks = %s, limits = %s, bounds = %s, step = %r, centre = %r, ops = %s}' % (
            name, lua_blocks(blocks), limits, bounds, 2 * px, cw / 2, oplist))
    os.makedirs(run.OUT, exist_ok=True)
    conf = os.path.join(run.OUT, 'conf_editor.lua')
    with open(conf, 'w') as f: f.write('CONFIG = {px = %r, scenarios = {%s}}\n' % (px, ', '.join(parts)))
    out = subprocess.run([sys.executable, run.MINILUA, os.path.join(HERE, 'harness_editor.lua'), conf, EDITOR],
                         capture_output=True, text=True)
    if out.returncode:
        print(out.stdout[-2000:], out.stderr[-2000:]); raise SystemExit(1)
    results, name = {}, None
    for line in out.stdout.splitlines():
        f = line.split()
        if f[0] == 'SCENARIO': name = f[1]; results[name] = {'rects': {}, 'log': []}
        elif f[0] == 'RECT': results[name]['rects'][f[1]] = tuple(map(float, f[2:6]))
        else: results[name]['log'].append(line)
    total, problems, logs = 0, [], {}
    for name, blocks, cw0, ch0, ops in scen:
        r = results[name]
        rects = r['rects']
        left, top = math.ceil(PAD / px - 0.001) * px, math.ceil(HEAD / px - 0.001) * px
        right = max([300 - PAD] + [x + w for x, y, w, h in rects.values()])
        bottom = max([HEAD] + [y + h for x, y, w, h in rects.values()])
        cw = math.floor((right + PAD) / 2 / px + 0.5 + 0.001) * px * 2
        ch = math.ceil((bottom + PAD) / px - 0.001) * px
        probs = []
        keys = sorted(rects)
        for i, a in enumerate(keys):
            for k in keys[i + 1:]:
                if run.overlaps(rects[a], rects[k]): probs.append('overlap %s / %s' % (a, k))
            x, y, w, h = rects[a]
            if x < left - 1e-3 or y < top - 1e-3 or x + w > cw - PAD + 1e-3 or y + h > ch - PAD + 1e-3:
                probs.append('outside the body: %s' % a)
            for v in (x, y):
                if abs(v / px - round(v / px)) > 1e-4: probs.append('off the pixel grid: %s %.4f' % (a, v))
        if abs((cw / px) % 2) > 1e-4 and abs((cw / px) % 2 - 2) > 1e-4: probs.append('console width not an even pixel count')
        if verbose:
            print('%-18s console %.1f x %.1f (was %.1f x %.1f)  problems %d' % (name, cw, ch, cw0, ch0, len(probs)))
            for line in r['log']: print('     ', line)
            for p in probs: print('      !', p)
        total += len(probs)
        problems += ['%s: %s' % (name, p) for p in probs]
        logs[name] = r['log']
        if render: svg(os.path.join(run.OUT, 'console-%s.svg' % name), name, cw, ch, rects, blocks, px)
    if verbose: print('total problems', total)
    return problems, logs


def svg(path, title, cw, ch, rects, original, px):
    S = 740 / cw
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="780" height="780" viewBox="0 0 780 780" font-family="Menlo,monospace">',
         '<rect width="100%" height="100%" fill="#0d1117"/>',
         '<text x="10" y="20" fill="#e6edf3" font-size="12">console %s  %.1f x %.1f units (%d x %d px)</text>' % (
             title, cw, ch, round(cw / px), round(ch / px)),
         '<g transform="translate(20,40)">',
         '<rect width="%.1f" height="%.1f" rx="10" fill="#3a3a36" stroke="#8b8b80"/>' % (cw * S, ch * S),
         '<rect width="%.1f" height="%.1f" fill="#2a2a27"/>' % (cw * S, 24 * S),
         '<text x="8" y="%.1f" fill="#c9c9bd" font-size="9">CX-1 CONSOLE (header)</text>' % (15 * S)]
    for b in original:
        if b['key'] in rects and (abs(b['x'] - rects[b['key']][0]) > 1e-6 or abs(b['y'] - rects[b['key']][1]) > 1e-6):
            o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="none" stroke="#ffffff" stroke-dasharray="3 3" opacity="0.5"/>' % (
                b['x'] * S, b['y'] * S, b['w'] * S, b['h'] * S))
    col = {'bank': '#d9a441', 'unit': '#58a6ff', 'cast': '#7ee787', 'fn': '#bc8cff', 'deck': '#9e9e9e', 'menu': '#f778ba'}
    kinds = {b['key']: b['kind'] for b in original}
    for key, (x, y, w, h) in rects.items():
        c = col.get(kinds.get(key), '#888')
        o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s" fill-opacity="0.35" stroke="%s"/>' % (
            x * S, y * S, w * S, h * S, c, c))
        o.append('<text x="%.1f" y="%.1f" fill="#e6edf3" font-size="9" text-anchor="middle">%s</text>' % (
            (x + w / 2) * S, (y + h / 2) * S + 3, key))
    o.append('</g></svg>')
    with open(path, 'w') as f: f.write('\n'.join(o))


if __name__ == '__main__':
    main()
