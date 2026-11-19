"""Schematic previews of the NV-3 compass and NV-4 map from the modules' layout rules (Graphite, green key)."""
import math
import os
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), 'build', 'harness')
PX = (768 / 2160) / 0.64  # UI units per physical pixel at 4K, UI scale 0.64
S = 2.2                   # drawing scale
INK, DIM, LAMP, HOUSING, LCD, LCDINK = '#ecece8', '#8a8a84', '#1abd42', '#1e1e1c', '#23261f', '#d9e4c8'
def snap(v): return math.floor(v / PX + 0.5) * PX
def rel(b, h): return (b - h + 540) % 360 - 180
def compass(heading=32, move=62):
    W, pad = 460, 8
    tapeW = W - 2 * pad; step = 5; spacing = max(3 * PX, snap(tapeW / 180 * step)); ppd = spacing / step; half = tapeW / 2
    minor, major, mid, lift = 3 * PX, 6 * PX, 4.5 * PX, 3 * PX
    header, tapeH = 18, snap(11 + 9 * PX); key = 16
    H = snap(pad + header + tapeH + 3 * PX + 2 * PX + snap(3 * PX + 5) + key + 10 + pad)
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" font-family="Audiowide,Menlo,monospace">' % (W * S + 40, H * S + 40),
         '<rect width="100%" height="100%" fill="#5b6b4f"/>', '<g transform="translate(20,20) scale(%g)">' % S,
         '<rect width="%g" height="%g" rx="5" fill="%s" stroke="#3d3d3a" stroke-width="0.5"/>' % (W, H, HOUSING)]
    t = lambda x, y, s, c, txt, anchor='middle', w='normal': o.append('<text x="%.2f" y="%.2f" font-size="%g" fill="%s" text-anchor="%s" font-weight="%s">%s</text>' % (x, y, s, c, anchor, w, txt))
    # header
    t(pad + 2, pad + 9, 6, DIM, 'NV-3', 'start', 'bold')
    o.append('<circle cx="%g" cy="%g" r="2.5" fill="#2fbf6a"/>' % (pad + 25, pad + 7))
    t(pad + 31, pad + 10, 7.5, INK, 'ELWYNN FOREST  <tspan fill="%s">GOLDSHIRE</tspan>' % DIM, 'start', 'bold')
    for x, w, txt in ((W / 2 - 28, 56, '%03d° %s' % (heading, ['N','NE','E','SE','S','SW','W','NW'][int((heading + 22.5) // 45) % 8])),
                      (W - pad - 70 - 4 - 56, 56, '7.0 Y/S'), (W - pad - 70, 70, '42.1  65.3')):
        o.append('<rect x="%g" y="%g" width="%g" height="14" rx="2" fill="%s"/>' % (x, pad, w, LCD)); t(x + w / 2, pad + 10, 7, LCDINK, txt, 'middle', 'bold')
    top = pad + header; base = top + tapeH
    left = heading - half / ppd; first = math.ceil(left * ppd / spacing - 1e-6)
    for i in range(int(tapeW / spacing) + 3):
        x = snap(first * spacing - left * ppd) + i * spacing
        if x > tapeW: break
        deg = ((first + i) * step) % 360
        maj = deg % 45 == 0; md = not maj and deg % 15 == 0
        near = max(0, 1 - abs(x - half) / (4.5 * spacing)); near = near * near * (3 - 2 * near)
        h = (major if maj else mid if md else minor) + near * lift
        fade = min(1, x / (0.18 * tapeW), (tapeW - x) / (0.18 * tapeW))
        col = LAMP if near > 0.5 else (INK if maj or md else DIM)
        o.append('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s" opacity="%.2f"/>' % (pad + x, base - h, PX, h, col, fade * (0.95 if maj else 0.75 if md else 0.5)))
    for deg, txt in [(0, 'N'), (45, 'NE'), (90, 'E'), (135, 'SE'), (180, 'S'), (225, 'SW'), (270, 'W'), (315, 'NW')] + [(d, str(d)) for d in (30, 60, 120, 150, 210, 240, 300, 330)]:
        x = half + rel(deg, heading) * ppd
        if 0 <= x <= tapeW:
            fade = min(1, x / (0.18 * tapeW), (tapeW - x) / (0.18 * tapeW))
            letter = not txt.isdigit()
            t(pad + x, base - 9 * PX - 1.5, 7.5 if letter and deg % 90 == 0 else 6.5 if letter else 5.5, LAMP if deg == 0 else INK if letter else DIM, txt, 'middle', 'bold' if letter else 'normal')
            o[-1] = o[-1].replace('<text', '<text opacity="%.2f"' % max(0, fade))
    o.append('<rect x="%g" y="%g" width="%g" height="%g" fill="%s" opacity="0.7"/>' % (pad, base, tapeW, PX, DIM))
    o.append('<rect x="%g" y="%g" width="%g" height="%g" fill="%s"/>' % (pad + half, base - 9 * PX, PX, 9 * PX, LAMP))
    o.append('<path d="M%g %g l%g %g h%g z" fill="%s"/>' % (pad + half, base + PX, -2.5 * PX, 3 * PX, 5 * PX, INK))
    mx = pad + half + rel(move, heading) * ppd
    o.append('<rect x="%g" y="%g" width="3" height="3" fill="%s" transform="rotate(45 %g %g)"/>' % (mx - 1.5, base - 1.5, LAMP, mx, base))
    # points: (kind glyph, lamp, bearing, yards)
    pts = [('Q', '#ffa800', 40, 142), ('!', '#ffa800', 47, 210), ('F', '#2f9e5f', -55 + 360, 380), ('?', '#ffa800', 25, 95), ('*', '#ff3b30', 118, 260), ('+', LAMP, 200, 520)]
    lead = snap(3 * PX + 5); lo, hi = key / 2 + 1, tapeW - key / 2 - 1
    row = []
    for g, c, b, d in pts:
        r = rel(b, heading); pinned = None
        if abs(r) > 89:
            if g != '+': continue
            pinned = 1 if r > 0 else -1
        pos = (hi if pinned == 1 else lo) if pinned else min(hi, max(lo, half + r * ppd))
        row.append([pos, g, c, d, pinned])
    row.sort()
    # spread (the same clusters as Nav.Spread)
    step = key + 4; clusters = []
    for p in row:
        clusters.append({'n': 1, 'sum': p[0], 'm': [p]})
        while True:
            cur = clusters[-1]; span = (cur['n'] - 1) * step; f = cur['sum'] / cur['n'] - span / 2; f = min(f, hi - span); f = max(f, lo); cur['first'] = f
            if len(clusters) < 2 or clusters[-2]['first'] + clusters[-2]['n'] * step <= f: break
            prev = clusters[-2]; prev['n'] += cur['n']; prev['sum'] += cur['sum']; prev['m'] += cur['m']; clusters.pop()
    for cl in clusters:
        for j, p in enumerate(cl['m']):
            kx = cl['first'] + j * step; pos, g, c, d, pinned = p
            if not pinned:
                o.append('<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="%s" stroke-width="%.2f" opacity="0.8"/>' % (pad + pos, base + PX, pad + kx, base + lead, DIM, PX * 1.2))
            if g == '+': o.append('<circle cx="%g" cy="%g" r="13" fill="%s" opacity="0.25"/>' % (pad + kx, base + lead + key / 2, LAMP))
            o.append('<rect x="%g" y="%g" width="%g" height="%g" rx="2" fill="#2c2c2a" stroke="#3d3d3a" stroke-width="0.5"/>' % (pad + kx - key / 2, base + lead, key, key))
            t(pad + kx, base + lead + key / 2 + 3, 8, INK, g, 'middle', 'bold')
            o.append('<circle cx="%g" cy="%g" r="1.3" fill="%s"/>' % (pad + kx + key / 2 - 3, base + lead + 3, c))
            o.append('<rect x="%g" y="%g" width="%g" height="9" rx="1.5" fill="%s"/>' % (pad + kx - (key + 10) / 2, base + lead + key + 1, key + 10, LCD))
            txt = str(d) if not pinned else (str(d) + '>' if pinned > 0 else '<' + str(d))
            t(pad + kx, base + lead + key + 8, 6, LCDINK, txt, 'middle', 'bold')
    o.append('</g></svg>')
    with open(os.path.join(OUT, 'compass-preview.svg'), 'w') as f: f.write('\n'.join(o))
    print('compass', W, 'x', round(H, 1), 'UI units; spacing', round(spacing, 3), 'ppd', round(ppd, 4), 'fov', round(tapeW / ppd, 1))
def overlay(size=300, radius=250, facing_deg=32):
    k = size / 2 / radius; o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" font-family="Audiowide,Menlo,monospace">' % (size * S + 60, size * S + 60),
        '<rect width="100%" height="100%" fill="#5b6b4f"/>', '<g transform="translate(30,30) scale(%g)">' % S,
        '<defs><clipPath id="w"><rect width="%g" height="%g"/></clipPath><radialGradient id="f"><stop offset="0.6" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient></defs>' % (size, size)]
    # bezel bars
    for x, y, w, h in ((-6, -6, size + 12, 6), (-6, size, size + 12, 6), (-6, 0, 6, size), (size, 0, 6, size)):
        o.append('<rect x="%g" y="%g" width="%g" height="%g" rx="1.5" fill="#2c2c2a" stroke="#3d3d3a" stroke-width="0.4"/>' % (x, y, w, h))
    o.append('<rect width="%g" height="%g" fill="#0d0d0c" opacity="0.3"/>' % (size, size))
    # tiles: zone 3000x2000 yd, 1002x668 texels, 256-texel tiles, player at 0.5,0.5
    tw = 256 * (3000 / 1002) * k; th = 256 * (2000 / 668) * k; cx, cy = 0.5 * 3000 * k, 0.5 * 2000 * k
    o.append('<g clip-path="url(#w)" opacity="0.6">')
    for col in range(1, 5):
        for row in range(1, 4):
            x, y = size / 2 - cx + (col - 1) * tw, size / 2 - cy + (row - 1) * th
            if x + tw < 0 or y + th < 0 or x > size or y > size: continue
            o.append('<rect x="%g" y="%g" width="%g" height="%g" fill="#6f7d55" stroke="#c9c2a0" stroke-width="0.6" stroke-dasharray="3 2"/>' % (x, y, tw, th))
            o.append('<text x="%g" y="%g" font-size="9" fill="#e8e2c4">tile %d</text>' % (max(x, 0) + 6, max(y, 0) + 14, (row - 1) * 4 + col))
    o.append('<path d="M60 220 C 120 160, 190 200, 260 90" stroke="#d8c79a" stroke-width="5" fill="none"/></g>')
    o.append('<text x="%g" y="12" font-size="8" fill="%s" text-anchor="middle" font-weight="bold">N</text>' % (size / 2, LAMP))
    for (e, n, g, c) in ((90, 0, 'Q', '#ffa800'), (0, 100, 'F', '#2f9e5f'), (-140, -60, '!', '#ffa800'), (180, 210, '+', LAMP)):
        x, y = size / 2 + e * k, size / 2 - n * k
        lim = size / 2 - 9; dx, dy = x - size / 2, y - size / 2; sc = min(1, lim / max(abs(dx), abs(dy), 1e-9)); x, y = size / 2 + dx * sc, size / 2 + dy * sc
        o.append('<rect x="%g" y="%g" width="14" height="14" rx="2" fill="#2c2c2a" stroke="#3d3d3a" stroke-width="0.5"/>' % (x - 7, y - 7))
        o.append('<text x="%g" y="%g" font-size="7" fill="%s" text-anchor="middle" font-weight="bold">%s</text>' % (x, y + 2.5, INK, g))
        o.append('<circle cx="%g" cy="%g" r="1.2" fill="%s"/>' % (x + 4, y - 4, c))
    for (e, n, col) in ((40, -30, '#f48cba'), (-20, 60, '#3fc7eb')):
        o.append('<circle cx="%g" cy="%g" r="3.5" fill="%s" stroke="#000" stroke-opacity="0.7"/>' % (size / 2 + e * k, size / 2 - n * k, col))
    a = math.radians(facing_deg); hs = 8
    pts = [(0, 1), (-0.62, -0.62), (0, -0.18), (0.62, -0.62)]
    def rot(p): return (size / 2 + (p[0] * math.cos(-a) - p[1] * math.sin(-a)) * hs, size / 2 - (p[0] * math.sin(-a) + p[1] * math.cos(-a)) * hs)
    o.append('<circle cx="%g" cy="%g" r="16" fill="%s" opacity="0.25"/>' % (size / 2, size / 2, LAMP))
    o.append('<polygon points="%s" fill="none" stroke="%s" stroke-width="1.1"/>' % (' '.join('%.1f,%.1f' % rot(p) for p in pts), LAMP))
    o.append('<rect x="%g" y="%g" width="54" height="11" rx="2" fill="%s"/>' % (size / 2 - 27, size - 17, LCD))
    o.append('<text x="%g" y="%g" font-size="6.5" fill="%s" text-anchor="middle" font-weight="bold">%d YD</text>' % (size / 2, size - 9, LCDINK, radius))
    o.append('</g></svg>')
    with open(os.path.join(OUT, 'map-preview.svg'), 'w') as f: f.write('\n'.join(o))
    print('map', size, 'units; tile', round(tw, 1), 'units;', round(k, 3), 'units per yard')
def run_all():
    os.makedirs(OUT, exist_ok=True)
    compass()
    overlay()


if __name__ == '__main__':
    run_all()
