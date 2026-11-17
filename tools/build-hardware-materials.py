"""Draw the housing materials: seamless surface detail laid over a housing's fill.

Standard library only (no Pillow). Each material is a signed detail field s(x, y)
in [-1, 1]: positive texels lighten the housing, negative ones darken it. It is
stored as one 32-bit TGA with white texels (alpha = s) where it lightens and
black texels (alpha = -s) where it darkens, so a single BLEND texture can do
both and the housing keeps its own color and hue. The runtime draws it at one
texel per physical pixel with nearest filtering and REPEAT wrap, at a strength
the player sets.

Every field is periodic by construction (lattice noise wraps its lattice,
scratches and fibres wrap their coordinates, regular patterns use periods that
divide the size), so the textures tile with no seam. `--preview DIR` also writes
PNG previews (2 x 2 tiles over a light and a dark housing) to check them by eye.
"""
import hashlib
import json
import math
from pathlib import Path
import random
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'JiberishSpec01UI/Media/Hardware/Materials'
FIXTURE = ROOT / 'tests/fixtures/hardware-media.json'

TAU = math.tau


# Encoding --------------------------------------------------------------------------------
def encode_tga(width, height, field):
    """field: rows top to bottom of signed floats. 32-bit RLE TGA, bottom-up."""
    out = bytearray(struct.pack('<BBBHHBHHHHBB', 0, 0, 10, 0, 0, 0, 0, 0, width, height, 32, 8))
    white, black = b'\xff\xff\xff', b'\x00\x00\x00'
    for y in range(height - 1, -1, -1):
        row = []
        for value in field[y]:
            alpha = int(round(min(abs(value), 1.0) * 255))
            row.append((white if value > 0 else black) + bytes((alpha,)) if alpha else b'\xff\xff\xff\x00')
        x = 0
        while x < width:
            run = 1
            while x + run < width and run < 128 and row[x + run] == row[x]:
                run += 1
            if run > 1:
                out.append(0x80 | (run - 1)); out += row[x]; x += run
                continue
            start = x; x += 1
            while x < width and x - start < 128 and not (x + 1 < width and row[x + 1] == row[x]):
                x += 1
            out.append(x - start - 1); out += b''.join(row[start:x])
    return bytes(out)


def decode_tga(data):
    width, height = struct.unpack_from('<HH', data, 12)
    raw, offset = bytearray(), 18
    while len(raw) < width * height * 4:
        packet = data[offset]; offset += 1
        count = (packet & 127) + 1
        size = 4 if packet & 128 else count * 4
        chunk = data[offset:offset + size]; offset += size
        raw += chunk * count if packet & 128 else chunk
    return width, height, bytes(raw)


# Periodic fields --------------------------------------------------------------------------
def smooth(t):
    return t * t * t * (t * (t * 6 - 15) + 10)


def lattice_noise(width, height, cells_x, cells_y, rng):
    """Value noise on a cells_x x cells_y lattice that wraps, sampled at every texel. -1..1."""
    grid = [[rng.uniform(-1, 1) for _ in range(cells_x)] for _ in range(cells_y)]
    xs = []
    for x in range(width):
        u = x * cells_x / width
        i = int(u)
        xs.append((i % cells_x, (i + 1) % cells_x, smooth(u - i)))
    field = []
    for y in range(height):
        v = y * cells_y / height
        j = int(v)
        ty = smooth(v - j)
        row0, row1 = grid[j % cells_y], grid[(j + 1) % cells_y]
        out = []
        for i0, i1, tx in xs:
            a = row0[i0] + (row0[i1] - row0[i0]) * tx
            b = row1[i0] + (row1[i1] - row1[i0]) * tx
            out.append(a + (b - a) * ty)
        field.append(out)
    return field


def fbm(width, height, base_x, base_y, octaves, rng, falloff=0.5):
    total = [[0.0] * width for _ in range(height)]
    amplitude, norm = 1.0, 0.0
    cx, cy = base_x, base_y
    for _ in range(octaves):
        layer = lattice_noise(width, height, cx, cy, rng)
        for y in range(height):
            row, src = total[y], layer[y]
            for x in range(width):
                row[x] += src[x] * amplitude
        norm += amplitude
        amplitude *= falloff
        cx, cy = min(cx * 2, width), min(cy * 2, height)
    for row in total:
        for x in range(width):
            row[x] /= norm
    return total


def white_noise(width, height, rng):
    return [[rng.gauss(0, 1) for _ in range(width)] for _ in range(height)]


def blur(field, radius_x=1, radius_y=1):
    """Box blur with wrap-around (keeps the field seamless)."""
    height, width = len(field), len(field[0])
    if radius_x:
        span = 2 * radius_x + 1
        out = []
        for row in field:
            acc = sum(row[x % width] for x in range(-radius_x, radius_x + 1))
            new = []
            for x in range(width):
                new.append(acc / span)
                acc += row[(x + radius_x + 1) % width] - row[(x - radius_x) % width]
            out.append(new)
        field = out
    if radius_y:
        span = 2 * radius_y + 1
        out = [[0.0] * width for _ in range(height)]
        for x in range(width):
            acc = sum(field[y % height][x] for y in range(-radius_y, radius_y + 1))
            for y in range(height):
                out[y][x] = acc / span
                acc += field[(y + radius_y + 1) % height][x] - field[(y - radius_y) % height][x]
        field = out
    return field


def normalize(field, target=1.0, percentile=0.995):
    """Scale so the given percentile of |s| sits at `target`."""
    values = sorted(abs(v) for row in field for v in row)
    top = values[min(len(values) - 1, int(len(values) * percentile))] or 1.0
    scale = target / top
    return [[max(-1.0, min(1.0, v * scale)) for v in row] for row in field]


def remove_mean(field):
    count = len(field) * len(field[0])
    mean = sum(sum(row) for row in field) / count
    return [[v - mean for v in row] for row in field]


def add(target, source, weight):
    for y, row in enumerate(target):
        src = source[y]
        for x in range(len(row)):
            row[x] += src[x] * weight
    return target


def stroke(field, ax, ay, bx, by, width, value):
    """An antialiased line segment, its coordinates wrapping around the tile."""
    height, size_x = len(field), len(field[0])
    x0, x1 = int(math.floor(min(ax, bx) - width - 1)), int(math.ceil(max(ax, bx) + width + 1))
    y0, y1 = int(math.floor(min(ay, by) - width - 1)), int(math.ceil(max(ay, by) + width + 1))
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy or 1e-9
    for y in range(y0, y1 + 1):
        row = field[y % height]
        py = y + 0.5
        for x in range(x0, x1 + 1):
            px = x + 0.5
            t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length))
            d = math.hypot(px - ax - dx * t, py - ay - dy * t)
            cover = max(0.0, min(1.0, width / 2 + 0.5 - d))
            if cover > 0:
                # Fade the tips so scratches start and end softly.
                tip = min(1.0, 4 * t, 4 * (1 - t))
                row[x % size_x] += value * cover * (0.35 + 0.65 * tip)


def curved_stroke(field, x, y, angle, length, width, value, bend, rng, steps=6):
    step = length / steps
    for _ in range(steps):
        angle += rng.uniform(-bend, bend)
        nx, ny = x + math.cos(angle) * step, y + math.sin(angle) * step
        stroke(field, x, y, nx, ny, width, value)
        x, y = nx, ny


# Materials -------------------------------------------------------------------------------
def brushed(width=1024, height=256, seed=3101):
    """Brushed metal: long horizontal grain, every line its own shade, drifting along its length."""
    rng = random.Random(seed)
    # Each line's shade, with a little correlation between neighbours.
    lines = [rng.gauss(0, 1) for _ in range(height)]
    lines = [0.6 * lines[y] + 0.2 * lines[(y - 1) % height] + 0.2 * lines[(y + 1) % height] for y in range(height)]
    drift = lattice_noise(width, height, 8, height // 2, rng)      # slow change along a line
    fibres = blur(white_noise(width, height, rng), 12, 0)            # fine streaks, stretched across
    field = []
    for y in range(height):
        row, d, f = [], drift[y], fibres[y]
        for x in range(width):
            row.append(lines[y] * (0.55 + 0.45 * d[x]) + 2.2 * f[x])
        field.append(row)
    # A few longer, brighter scratches along the grain.
    for _ in range(70):
        x, y = rng.uniform(0, width), rng.randrange(height) + 0.5
        stroke(field, x, y, x + rng.uniform(80, 420), y + rng.uniform(-0.6, 0.6), 0.8, rng.choice((1.6, -1.2)))
    return normalize(remove_mean(field), 0.9)


def machined(width=1024, height=256, seed=3203):
    """Machined: fine, even tool marks every 4 px, their depth wandering slowly along the cut."""
    rng = random.Random(seed)
    pitch = 4
    grooves = height // pitch
    depth = [0.75 + 0.25 * rng.random() for _ in range(grooves)]
    wander = lattice_noise(width, height, 16, 16, rng)
    chatter = lattice_noise(width, height, 128, 4, rng)
    fine = blur(white_noise(width, height, rng), 3, 0)
    field = []
    for y in range(height):
        groove = depth[y // pitch]
        # A rounded groove: lit on its upper flank, shaded on the lower (light from above).
        phase = (y % pitch + 0.5) / pitch
        profile = math.cos(TAU * phase) * 0.55 + math.sin(TAU * phase) * 0.45
        row, w, c, f = [], wander[y], chatter[y], fine[y]
        for x in range(width):
            row.append(profile * groove * (0.8 + 0.2 * w[x]) + 0.12 * c[x] + 0.35 * f[x])
        field.append(row)
    return normalize(remove_mean(field), 0.8)


def worn(width=1024, height=512, seed=3307):
    """Worn metal: a soft brushed base, scuffs and scratches in every direction, and polished wear."""
    rng = random.Random(seed)
    lines = [rng.gauss(0, 1) for _ in range(height)]
    base = blur(white_noise(width, height, rng), 10, 0)
    field = [[0.45 * lines[y] + 1.6 * base[y][x] for x in range(width)] for y in range(height)]
    # Wear: broad patches polished lighter or dulled darker.
    wear = fbm(width, height, 4, 2, 4, rng, 0.55)
    add(field, wear, 1.1)
    # Scuffs: clusters of short, slightly curved scratches.
    for _ in range(46):
        cx, cy = rng.uniform(0, width), rng.uniform(0, height)
        heading = rng.uniform(0, math.pi)
        for _ in range(rng.randint(6, 18)):
            curved_stroke(field, cx + rng.gauss(0, 18), cy + rng.gauss(0, 10), heading + rng.gauss(0, 0.25),
                          rng.uniform(10, 46), rng.uniform(0.5, 0.9), rng.uniform(0.6, 1.3), 0.08, rng, 4)
    # Single long scratches.
    for _ in range(90):
        curved_stroke(field, rng.uniform(0, width), rng.uniform(0, height), rng.uniform(0, TAU),
                      rng.uniform(30, 160), rng.uniform(0.5, 0.8), rng.choice((1.2, 1.0, -0.8)), 0.05, rng, 8)
    # Pits.
    for _ in range(500):
        x, y = rng.uniform(0, width), rng.uniform(0, height)
        stroke(field, x, y, x + 0.3, y + 0.3, rng.uniform(0.8, 1.5), -rng.uniform(0.6, 1.4))
    return normalize(remove_mean(field), 0.9)


def bead(width=512, height=512, seed=3409):
    """Bead-blasted / anodized: a fine, even grain with the faintest mottle."""
    rng = random.Random(seed)
    grain = white_noise(width, height, rng)
    soft = blur(grain, 1, 1)
    mottle = fbm(width, height, 8, 8, 3, rng)
    field = [[0.55 * grain[y][x] + 1.4 * soft[y][x] + 0.35 * mottle[y][x] for x in range(width)] for y in range(height)]
    return normalize(remove_mean(field), 0.85)


def paper(width=512, height=512, seed=3511):
    """Paper: soft cloudy formation, a felt of short fibres, and a fine tooth."""
    rng = random.Random(seed)
    clouds = fbm(width, height, 8, 8, 5, rng, 0.6)
    field = [[0.4 * clouds[y][x] for x in range(width)] for y in range(height)]
    for _ in range(5200):
        curved_stroke(field, rng.uniform(0, width), rng.uniform(0, height), rng.uniform(0, TAU),
                      rng.uniform(6, 30), rng.uniform(0.5, 0.8), rng.choice((0.6, 0.5, -0.55)), 0.3, rng, 5)
    tooth = blur(white_noise(width, height, rng), 1, 1)
    add(field, tooth, 0.9)
    return normalize(remove_mean(field), 0.85)


def plastic(width=512, height=512, seed=3613):
    """Molded plastic: a very fine orange peel, lit from the upper left."""
    rng = random.Random(seed)
    height_field = fbm(width, height, 112, 112, 2, rng, 0.5)
    fine = lattice_noise(width, height, 224, 224, rng)
    add(height_field, fine, 0.25)
    field = []
    for y in range(height):
        up, down = height_field[(y - 1) % height], height_field[(y + 1) % height]
        row, here = [], height_field[y]
        for x in range(width):
            gx = here[(x + 1) % width] - here[(x - 1) % width]
            gy = down[x] - up[x]
            # Lambert against a light up and to the left.
            row.append(-(gx * 0.6 + gy * 0.8))
        field.append(row)
    micro = white_noise(width, height, rng)
    add(field, micro, 0.012)
    return normalize(remove_mean(field), 0.8)


def etched(width=256, height=256, seed=3719):
    """Etched: fine engraved hatching at 45 degrees, each groove with a lit lower lip."""
    rng = random.Random(seed)
    pitch = 4
    depth = lattice_noise(width, height, 8, 8, rng)
    speck = blur(white_noise(width, height, rng), 1, 1)
    field = []
    for y in range(height):
        row = []
        for x in range(width):
            # Distance along the hatch normal, wrapping every `pitch` texels.
            d = ((x + y) % pitch) + 0.5
            groove = max(0.0, 1 - abs(d - 1.0) / 1.0)
            lip = max(0.0, 1 - abs(d - 2.2) / 0.9)
            strength = 0.8 + 0.2 * depth[y][x]
            row.append((-groove + 0.55 * lip) * strength + 0.07 * speck[y][x])
        field.append(row)
    return normalize(remove_mean(field), 0.8)


def carbon(width=128, height=128, seed=3821):
    """Carbon fibre: a 2 x 2 twill of 8 px tows. Each tow is a lit cylinder with fine fibres
    along it, dives under its neighbour at both ends, and the tows across catch more light."""
    rng = random.Random(seed)
    tow = 8
    cells = width // tow
    shade = [[rng.uniform(-0.06, 0.06) for _ in range(cells)] for _ in range(cells)]
    # Fibres: noise stretched along each direction of travel.
    along_x = blur(white_noise(width, height, rng), 5, 0)
    along_y = blur(white_noise(width, height, rng), 0, 5)
    field = []
    for y in range(height):
        row = []
        for x in range(width):
            i, j = x // tow, y // tow
            k = (i - j) % 4
            across = k < 2
            if across:
                u = (y % tow + 0.5) / tow                      # across the tow
                t = (k * tow + x % tow + 0.5) / (2 * tow)      # along its two-cell run
                fibre = along_x[y][x]
            else:
                u = (x % tow + 0.5) / tow
                t = ((0 if k == 3 else 1) * tow + y % tow + 0.5) / (2 * tow)
                fibre = along_y[y][x]
            cylinder = math.sin(math.pi * u) ** 0.7
            dive = min(1.0, min(t, 1 - t) / 0.14)              # darker where it goes under
            sheen = 0.42 if across else 0.12
            value = (sheen * cylinder - 0.18) * (0.35 + 0.65 * dive) - 0.55 * (1 - cylinder) ** 4
            row.append(value + 0.32 * fibre + shade[j][i])
        field.append(row)
    return normalize(remove_mean(field), 0.85)


MATERIALS = (
    ('brushed', brushed), ('machined', machined), ('worn', worn), ('bead', bead),
    ('paper', paper), ('plastic', plastic), ('etched', etched), ('carbon', carbon),
)


# Previews --------------------------------------------------------------------------------
def write_png(path, width, height, rows):
    """rows: lists of (r, g, b) bytes per pixel."""
    raw = b''.join(b'\x00' + bytes(row) for row in rows)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b'')
    Path(path).write_bytes(png)


def preview(name, field, directory, strength=0.6):
    """Two tiles across and down (seams visible if any), over a light and a dark housing."""
    height, width = len(field), len(field[0])
    show_w, show_h = min(width * 2, 768), min(height * 2, 384)
    off_x, off_y = width - show_w // 2, height - show_h // 2   # centre on the tile corner
    bases = ((251, 251, 250), (44, 44, 42))
    rows = []
    for base in bases:
        for y in range(show_h):
            src = field[(y + off_y) % height]
            row = bytearray()
            for x in range(show_w):
                s = src[(x + off_x) % width]
                a = min(abs(s), 1.0) * strength
                target = 255 if s > 0 else 0
                for channel in base:
                    row.append(int(round(channel * (1 - a) + target * a)))
            rows.append(row)
    write_png(Path(directory) / f'{name}.png', show_w, show_h * 2, rows)


def main():
    preview_dir = None
    if '--preview' in sys.argv:
        preview_dir = Path(sys.argv[sys.argv.index('--preview') + 1])
        preview_dir.mkdir(parents=True, exist_ok=True)
    only = [a for a in sys.argv[1:] if a in dict(MATERIALS)]
    OUT.mkdir(parents=True, exist_ok=True)
    fixture = json.loads(FIXTURE.read_text()) if FIXTURE.exists() else {}
    records = {r['name']: r for r in fixture.get('materials', [])}
    for name, build in MATERIALS:
        if only and name not in only:
            continue
        field = build()
        height, width = len(field), len(field[0])
        data = encode_tga(width, height, field)
        _, _, raw = decode_tga(data)
        (OUT / f'{name}.tga').write_bytes(data)
        records[name] = {'name': name, 'path': f'Media/Hardware/Materials/{name}.tga', 'size': [width, height],
                         'sha256': hashlib.sha256(data).hexdigest(), 'bgraSha256': hashlib.sha256(raw).hexdigest()}
        if preview_dir:
            preview(name, field, preview_dir)
        print(f'{name}: {width} x {height}, {len(data):,} bytes')
    fixture['materials'] = [records[name] for name, _ in MATERIALS if name in records]
    FIXTURE.write_text(json.dumps(fixture, indent=2) + '\n')


if __name__ == '__main__':
    main()
