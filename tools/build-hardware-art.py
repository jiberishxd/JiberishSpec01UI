"""Draw the original Hardware theme UI textures (panels, keys, wells, icons).

Standard library only, so the art can be rebuilt without Pillow. Every shape
is an analytic signed-distance field with one-texel antialiasing. Textures are
authored at twice their design size; the runtime shows them at half scale so
corners stay sharp on high-resolution displays. Tintable art is white with the
shape in alpha; shadows are black. Output is 32-bit RLE TGA (type 10), with
packets bounded to scanlines like the other generated families.
"""
import hashlib
import json
import math
from pathlib import Path
import random
import struct

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'JiberishSpec01UI/Media/Hardware'
FIXTURE = ROOT / 'tests/fixtures/hardware-media.json'

# Icon cells in atlas order. Kit/Theme.lua lists the same names.
ICONS = ('chevron-right', 'chevron-left', 'chevron-up', 'chevron-down', 'plus', 'minus', 'close', 'check',
         'play', 'stop', 'pause', 'record', 'more', 'search', 'info', 'trash',
         'filter', 'align-left', 'align-center', 'align-right', 'warning', 'speaker', 'calendar', 'grip',
         'user', 'tri-up', 'tri-down', 'tri-left', 'tri-right', 'copy', 'mail', 'power')


def encode_tga(width, height, pixels):
    """pixels: rows top to bottom of (r, g, b, a). Bottom-up RLE, 8 alpha bits."""
    out = bytearray(struct.pack('<BBBHHBHHHHBB', 0, 0, 10, 0, 0, 0, 0, 0, width, height, 32, 8))
    for y in range(height - 1, -1, -1):
        row = [bytes((b, g, r, a)) for r, g, b, a in pixels[y]]
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
    assert data[2] == 10 and data[16] == 32
    raw, offset = bytearray(), 18
    while len(raw) < width * height * 4:
        packet = data[offset]; offset += 1
        count = (packet & 127) + 1
        size = 4 if packet & 128 else count * 4
        chunk = data[offset:offset + size]; offset += size
        raw += chunk * count if packet & 128 else chunk
    return width, height, bytes(raw)


def clamp(value, low=0.0, high=1.0):
    return max(low, min(high, value))


def cover(distance):
    return clamp(0.5 - distance)


def rrect(px, py, x0, y0, x1, y1, radius):
    cx, cy, hw, hh = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2
    qx, qy = abs(px - cx) - (hw - radius), abs(py - cy) - (hh - radius)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius


def segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    t = clamp(((px - ax) * dx + (py - ay) * dy) / length) if length else 0
    return math.hypot(px - ax - dx * t, py - ay - dy * t)


def polygon(px, py, points):
    inside, distance = False, 1e9
    for i, (ax, ay) in enumerate(points):
        bx, by = points[(i + 1) % len(points)]
        distance = min(distance, segment(px, py, ax, ay, bx, by))
        if (ay > py) != (by > py) and px < (bx - ax) * (py - ay) / (by - ay) + ax:
            inside = not inside
    return -distance if inside else distance


def raster(width, height, alpha, color=(255, 255, 255)):
    rows = []
    for y in range(height):
        rows.append([color + (round(255 * clamp(alpha(x + 0.5, y + 0.5))),) for x in range(width)])
    return encode_tga(width, height, rows)


def solid(size, radius):
    return raster(size, size, lambda x, y: cover(rrect(x, y, 0, 0, size, size, radius)))


def ring(size, radius, stroke=2):
    def alpha(x, y):
        d = rrect(x, y, 0, 0, size, size, radius)
        return cover(d) - cover(d + stroke)
    return raster(size, size, alpha)


def shadow(size=64, spread=16, radius=12, strength=0.6):
    def alpha(x, y):
        d = rrect(x, y, spread, spread, size - spread, size - spread, radius)
        return strength if d <= 0 else strength * (1 - clamp(d / spread)) ** 2
    return raster(size, size, alpha, (0, 0, 0))


def inset(size, radius, depth=6, strength=0.34):
    # Recessed wells: a soft shade hugging the top inner edge.
    def alpha(x, y):
        d = rrect(x, y, 0, 0, size, size, radius)
        top = clamp(1 - y / depth)
        edge = clamp(1 + d / 3) * 0.35
        return cover(d) * strength * max(top, edge)
    return raster(size, size, alpha, (0, 0, 0))


def grain(size=128):
    rng = random.Random(1401)
    rows = [[(0, 0, 0, rng.randrange(0, 56)) for _ in range(size)] for _ in range(size)]
    return encode_tga(size, size, rows)


def bar_flat(width=256, height=32):
    rows = []
    for y in range(height):
        t = y / (height - 1)
        level = round(255 - 34 * t ** 1.4) if y else 255
        rows.append([(level, level, level, 255)] * width)
    return encode_tga(width, height, rows)


def bar_dots(width=256, height=16, pitch=8, dot=2.6):
    return raster(width, height, lambda x, y: cover(
        math.hypot((x % pitch) - pitch / 2, y - height / 2) - dot))


def bar_segments(width=256, height=16, pitch=4):
    return raster(width, height, lambda x, y: 1.0 if (x % pitch) < pitch - 1 and 1 <= y < height - 1 else 0.0)


def knob_ticks(size=128, count=31):
    center = size / 2
    ticks = []
    for i in range(count):
        angle = math.radians(225 - 270 * i / (count - 1))
        inner = 47 if i % 5 == 0 else 52
        ticks.append((center + math.cos(angle) * inner, center - math.sin(angle) * inner,
                      center + math.cos(angle) * 61, center - math.sin(angle) * 61))

    def alpha(x, y):
        r = math.hypot(x - center, y - center)
        if r < 44 or r > 64:
            return 0
        return cover(min(segment(x, y, *tick) for tick in ticks) - 1.0)
    return raster(size, size, alpha)


def icon_shapes(name):
    """Distances in a 16-unit design cell; negative is inside."""
    def lines(*points, width=1.5):
        return lambda x, y: min(segment(x, y, *points[i], *points[i + 1])
                                for i in range(len(points) - 1)) - width / 2

    def dot(cx, cy, radius):
        return lambda x, y: math.hypot(x - cx, y - cy) - radius

    def circle(cx, cy, radius, width=1.5):
        return lambda x, y: abs(math.hypot(x - cx, y - cy) - radius) - width / 2

    def fill(*points):
        return lambda x, y: polygon(x, y, points)

    def box(x0, y0, x1, y1, radius=1, width=None):
        if width is None:
            return lambda x, y: rrect(x, y, x0, y0, x1, y1, radius)
        return lambda x, y: abs(rrect(x, y, x0, y0, x1, y1, radius)) - width / 2

    table = {
        'chevron-right': [lines((6, 3), (11, 8), (6, 13))],
        'chevron-left': [lines((10, 3), (5, 8), (10, 13))],
        'chevron-up': [lines((3, 10), (8, 5), (13, 10))],
        'chevron-down': [lines((3, 6), (8, 11), (13, 6))],
        'plus': [lines((8, 3), (8, 13)), lines((3, 8), (13, 8))],
        'minus': [lines((3, 8), (13, 8))],
        'close': [lines((4, 4), (12, 12)), lines((12, 4), (4, 12))],
        'check': [lines((3, 8.5), (6.5, 12), (13, 4.5))],
        'play': [fill((5, 3), (13, 8), (5, 13))],
        'stop': [box(4, 4, 12, 12)],
        'pause': [box(4, 3, 7, 13, .6), box(9, 3, 12, 13, .6)],
        'record': [dot(8, 8, 4)],
        'more': [dot(3.5, 8, 1.3), dot(8, 8, 1.3), dot(12.5, 8, 1.3)],
        'search': [circle(7, 7, 4), lines((10, 10), (13.5, 13.5))],
        'info': [circle(8, 8, 6), lines((8, 7.5), (8, 11.5)), dot(8, 4.8, .9)],
        'trash': [lines((3, 4.5), (13, 4.5)), lines((6, 4.5), (6.5, 2.5), (9.5, 2.5), (10, 4.5)),
                  lines((4.5, 4.5), (5.2, 13.5), (10.8, 13.5), (11.5, 4.5))],
        'filter': [lines((2.5, 3), (13.5, 3), (9.5, 8), (9.5, 13), (6.5, 11.5), (6.5, 8), (2.5, 3))],
        'align-left': [lines((3, 4), (13, 4)), lines((3, 8), (9, 8)), lines((3, 12), (11, 12))],
        'align-center': [lines((3, 4), (13, 4)), lines((5, 8), (11, 8)), lines((4, 12), (12, 12))],
        'align-right': [lines((3, 4), (13, 4)), lines((7, 8), (13, 8)), lines((5, 12), (13, 12))],
        'warning': [lines((8, 2.5), (14, 13), (2, 13), (8, 2.5)), lines((8, 6.5), (8, 9.5)), dot(8, 11.3, .8)],
        'speaker': [fill((2.5, 6), (5.5, 6), (9, 3), (9, 13), (5.5, 10), (2.5, 10)),
                    lines((11.5, 5.5), (12.8, 8), (11.5, 10.5))],
        'calendar': [box(2.5, 3.5, 13.5, 13.5, 1.5, 1.5), lines((2.5, 6.8), (13.5, 6.8)),
                     lines((5.5, 2), (5.5, 4.5)), lines((10.5, 2), (10.5, 4.5))],
        'grip': [dot(x, y, 1) for x in (6, 10) for y in (4, 8, 12)],
        'user': [circle(8, 5.5, 2.5), lines((3, 13.5), (4, 10.8), (6, 9.8), (10, 9.8), (12, 10.8), (13, 13.5))],
        'tri-up': [fill((8, 4), (13, 11), (3, 11))],
        'tri-down': [fill((3, 5), (13, 5), (8, 12))],
        'tri-left': [fill((4, 8), (11, 3), (11, 13))],
        'tri-right': [fill((5, 3), (12, 8), (5, 13))],
        'copy': [box(5.5, 5.5, 13.5, 13.5, 1.5, 1.5), lines((10.5, 2.5), (2.5, 2.5), (2.5, 10.5))],
        'mail': [box(2, 3.5, 14, 12.5, 1.5, 1.5), lines((2.5, 4.5), (8, 9), (13.5, 4.5))],
        'power': [lines((8, 2.5), (8, 8)), lines((4.9, 4.6), (3.2, 7), (3.2, 9.5), (5, 12.3), (8, 13.3),
                                                 (11, 12.3), (12.8, 9.5), (12.8, 7), (11.1, 4.6))],
    }
    return table[name]


def icons(cell=32, columns=8):
    size = cell * columns
    shapes = [icon_shapes(name) for name in ICONS]
    scale = cell / 16

    def alpha(x, y):
        index = int(y // cell) * columns + int(x // cell)
        if index >= len(shapes):
            return 0
        u, v = (x % cell) / scale, (y % cell) / scale
        # Distances are in design units; one texel of antialiasing.
        return cover(min(shape(u, v) for shape in shapes[index]) * scale)
    return raster(size, size, alpha)


def menu_icon_shapes(name):
    """The micro menu and bag bar glyphs, in the same 16-unit cell as the icons.

    One stroke weight (1.6 units: heavy enough to hold at menu-key size) and
    one corner language throughout, so the set reads as one family on SPEC-01 keys.
    """
    W = 1.6

    def lines(*points, width=W):
        return lambda x, y: min(segment(x, y, *points[i], *points[i + 1])
                                for i in range(len(points) - 1)) - width / 2

    def dot(cx, cy, radius):
        return lambda x, y: math.hypot(x - cx, y - cy) - radius

    def circle(cx, cy, radius, width=W):
        return lambda x, y: abs(math.hypot(x - cx, y - cy) - radius) - width / 2

    def fill(*points):
        return lambda x, y: polygon(x, y, points)

    def box(x0, y0, x1, y1, radius=1, width=None):
        if width is None:
            return lambda x, y: rrect(x, y, x0, y0, x1, y1, radius)
        return lambda x, y: abs(rrect(x, y, x0, y0, x1, y1, radius)) - width / 2

    STAR = [(8.0, 4.4), (8.794, 6.508), (11.043, 6.611), (9.284, 8.017), (9.881, 10.189), (8.0, 8.95), (6.119, 10.189), (6.716, 8.017), (4.957, 6.611), (7.206, 6.508)]
    STAR_SMALL = [(9.3, 5.0), (9.947, 6.71), (11.773, 6.797), (10.346, 7.94), (10.828, 9.703), (9.3, 8.7), (7.772, 9.703), (8.254, 7.94), (6.827, 6.797), (8.653, 6.71)]
    RELOAD = [(11.214, 4.17), (12.33, 5.5), (12.924, 7.132), (12.924, 8.868), (12.33, 10.5), (11.214, 11.83), (9.71, 12.698), (8.0, 13.0), (6.29, 12.698), (4.786, 11.83), (3.67, 10.5), (3.076, 8.868), (3.076, 7.132), (3.67, 5.5), (4.786, 4.17)]
    table = {
        'character': [box(2.2, 2.2, 13.8, 13.8, 2, W), dot(8, 6.6, 2.3), lines((4.4, 13.8), (5, 11.6), (6.6, 10.4), (9.4, 10.4), (11, 11.6), (11.6, 13.8))],
        'spellbook': [box(3, 2.4, 13, 13.6, 1.2, W), lines((5.6, 2.4), (5.6, 13.6)), fill(*STAR_SMALL)],
        # A talent tree: a root that branches into two chosen nodes.
        'talents': [lines((8, 12.4), (8, 8.6)), lines((8, 8.6), (4.4, 5)), lines((8, 8.6), (11.6, 5)),
                    dot(3.9, 4, 2.1), dot(12.1, 4, 2.1), circle(8, 12.6, 1.6), dot(8, 8.6, 1.2)],
        'professions': [box(2.6, 2, 9, 5, 0.8), lines((9, 3.5), (14, 3.5), width=1.6), lines((1.8, 8.4), (14.2, 8.4), (12.4, 10.4), (10.2, 10.4), (10.8, 13.8), (5.2, 13.8), (5.8, 10.4), (3.6, 10.4), (1.8, 8.4))],
        'achievements': [lines((2.8, 2.6), (8, 1.6), (13.2, 2.6), (13.2, 8), (8, 14.2), (2.8, 8), (2.8, 2.6)), fill(*STAR)],
        'legacy': [lines((3.8, 2.4), (12.2, 2.4)), lines((3.8, 13.6), (12.2, 13.6)),
                   lines((5, 2.4), (5, 4.4), (8, 8), (5, 11.6), (5, 13.6)),
                   lines((11, 2.4), (11, 4.4), (8, 8), (11, 11.6), (11, 13.6)),
                   fill((6.2, 13.1), (9.8, 13.1), (8, 10.6))],
        'quest': [lines((4, 2.6), (4, 13.4)), lines((12, 2.6), (12, 13.4)), lines((2.6, 2.6), (13.4, 2.6), width=1.8), lines((2.6, 13.4), (13.4, 13.4), width=1.8), dot(2.6, 2.6, 1.1), dot(13.4, 13.4, 1.1), lines((8, 5), (8, 9.2), width=1.7), dot(8, 11.2, 1)],
        'guild': [lines((2.4, 2.4), (13.6, 2.4)), lines((4.4, 2.4), (4.4, 11.6), (8, 14), (11.6, 11.6), (11.6, 2.4)), lines((6.2, 6.4), (8, 8.4), (9.8, 6.4))],
        'social': [circle(6, 5.4, 2.1), lines((1.8, 13.6), (2.6, 10.6), (6, 9.4), (9.4, 10.6), (10.2, 13.6)), circle(11.4, 5.8, 1.7), lines((11.6, 9.4), (13.4, 10.2), (14.2, 13))],
        'finder': [lines((1.4, 8), (4.4, 4.4), (8, 3.3), (11.6, 4.4), (14.6, 8), (11.6, 11.6), (8, 12.7), (4.4, 11.6), (1.4, 8)), dot(8, 8, 2.4)],
        'journal': [lines((4, 7.2), (4, 5), (5.2, 2.8), (8, 2), (10.8, 2.8), (12, 5), (12, 7.2), (10.6, 8.8), (10.6, 10.8), (5.4, 10.8), (5.4, 8.8), (4, 7.2)), dot(6.5, 6.4, 1.25), dot(9.5, 6.4, 1.25), lines((7, 10.8), (7, 13.4)), lines((9, 10.8), (9, 13.4)), lines((5.4, 13.4), (10.6, 13.4))],
        'collections': [dot(8, 10.6, 2.9), dot(3.9, 7.4, 1.45), dot(6.4, 4.2, 1.45), dot(9.6, 4.2, 1.45), dot(12.1, 7.4, 1.45)],
        'menu': [circle(8, 8, 3.7, width=2.4), lines((12.619, 9.913), (14.19, 10.564), width=2.6), lines((9.913, 12.619), (10.564, 14.19), width=2.6), lines((6.087, 12.619), (5.436, 14.19), width=2.6), lines((3.381, 9.913), (1.81, 10.564), width=2.6), lines((3.381, 6.087), (1.81, 5.436), width=2.6), lines((6.087, 3.381), (5.436, 1.81), width=2.6), lines((9.913, 3.381), (10.564, 1.81), width=2.6), lines((12.619, 6.087), (14.19, 5.436), width=2.6)],
        'help': [circle(8, 8, 6.2), lines((5.8, 6.2), (6.4, 4.6), (8, 3.9), (9.6, 4.6), (10.2, 6.2), (9.6, 7.5), (8, 8.6), (8, 9.8)), dot(8, 11.9, 1)],
        'store': [lines((1.4, 2.8), (3.6, 2.8), (5.4, 10.4), (12.4, 10.4), (14, 4.8), (4.3, 4.8)), dot(6.2, 13, 1.3), dot(11.6, 13, 1.3)],
        'house': [lines((1.8, 8), (8, 2.4), (14.2, 8)), lines((3.6, 6.6), (3.6, 13.6), (12.4, 13.6), (12.4, 6.6)),
                  box(6.6, 9.4, 9.4, 13.6, 0.5)],
        'map': [lines((2, 4), (6, 2.5), (10, 4), (14, 2.5), (14, 12), (10, 13.5), (6, 12), (2, 13.5), (2, 4)),
                lines((6, 2.5), (6, 12)), lines((10, 4), (10, 13.5))],
        'pvp': [lines((3, 3), (12, 12)), lines((13, 3), (4, 12)), lines((9.4, 13.4), (13.4, 9.4)),
                lines((2.6, 9.4), (6.6, 13.4))],
        'backpack': [box(2.5, 5, 13.5, 14, 2.6, W), lines((2.5, 8.6), (13.5, 8.6)),
                     lines((5.6, 5), (5.6, 3), (10.4, 3), (10.4, 5)), dot(8, 10.8, 1.1)],
        'bag': [lines((4.6, 5.2), (2.8, 9), (2.8, 12.4), (4.8, 14), (11.2, 14), (13.2, 12.4), (13.2, 9), (11.4, 5.2)),
                lines((4.2, 5.2), (11.8, 5.2)), lines((6.6, 5.2), (6, 2.4)), lines((9.4, 5.2), (10, 2.4))],
        'reagent': [lines((6.5, 2.6), (6.5, 6), (3, 12.4), (4, 14), (12, 14), (13, 12.4), (9.5, 6), (9.5, 2.6)),
                    lines((5.4, 2.6), (10.6, 2.6)),
                    fill((4.7, 11), (11.3, 11), (12.2, 12.6), (11.6, 13.3), (4.4, 13.3), (3.8, 12.6))],
        'key': [circle(4.6, 8, 2.6), lines((7.2, 8), (14, 8)), lines((12, 8), (12, 10.6)), lines((9.8, 8), (9.8, 10))],
        # The console's function keys.
        'mount': [lines((4.2, 2.8), (3.2, 7), (4, 10.6), (5.8, 12.9), (8, 13.6), (10.2, 12.9), (12, 10.6), (12.8, 7), (11.8, 2.8)),
                  dot(5.4, 5.6, 0.75), dot(10.6, 5.6, 0.75), dot(5.2, 9.2, 0.75), dot(10.8, 9.2, 0.75)],
        'hearth': [box(3, 2.6, 13, 13.6, 4, W), circle(8, 8.1, 2.3), dot(8, 8.1, 0.9)],
        'drawer': [box(2.5, 3, 13.5, 13, 1.2, W), lines((2.5, 8), (13.5, 8)), lines((6.4, 5.5), (9.6, 5.5)),
                   lines((6.4, 10.5), (9.6, 10.5))],
        'move': [lines((8, 2.2), (8, 13.8)), lines((2.2, 8), (13.8, 8)), lines((6, 4.2), (8, 2.2), (10, 4.2)),
                 lines((6, 11.8), (8, 13.8), (10, 11.8)), lines((4.2, 6), (2.2, 8), (4.2, 10)), lines((11.8, 6), (13.8, 8), (11.8, 10))],
        'calendar': [box(2.5, 3.5, 13.5, 13.5, 1.5, W), lines((2.5, 6.8), (13.5, 6.8)), lines((5.5, 2), (5.5, 4.5)),
                     lines((10.5, 2), (10.5, 4.5)), dot(10, 10.4, 1.3)],
        'meter': [box(2.6, 9, 5.4, 13.6, 0.5), box(6.6, 5.4, 9.4, 13.6, 0.5), box(10.6, 2.4, 13.4, 13.6, 0.5)],
        'lock': [box(3.5, 7.4, 12.5, 14, 1.2, W), lines((5.6, 7.4), (5.6, 5), (6.4, 3.1), (8, 2.4), (9.6, 3.1), (10.4, 5), (10.4, 7.4)),
                 dot(8, 10.7, 1.1)],
        'reload': [lines(*RELOAD), fill((10.6, 1.6), (14.4, 3.2), (11.2, 5.8))],
        'macro': [lines((3, 4.6), (7, 8), (3, 11.4)), lines((8.6, 12), (13, 12))],
    }
    return table[name]


# Micro menu and bag bar glyphs in atlas order. ActionBarsMenu.lua lists the same names.
MENU_ICONS = ('character', 'spellbook', 'talents', 'professions', 'achievements', 'legacy', 'quest', 'guild',
              'social', 'finder', 'journal', 'collections', 'menu', 'help', 'store', 'house',
              'map', 'pvp', 'backpack', 'bag', 'reagent', 'key', 'mount', 'hearth',
              'drawer', 'move', 'calendar', 'meter', 'lock', 'reload', 'macro')


def menu_icons(cell=64, columns=8, rows=4):
    # Drawn at four times the design cell so they stay sharp on large keys.
    shapes = [menu_icon_shapes(name) for name in MENU_ICONS]
    scale = cell / 16

    def alpha(x, y):
        index = int(y // cell) * columns + int(x // cell)
        if index >= len(shapes):
            return 0
        u, v = (x % cell) / scale, (y % cell) / scale
        return cover(min(shape(u, v) for shape in shapes[index]) * scale)
    return raster(cell * columns, cell * rows, alpha)


def nav_icon_shapes(name):
    """The navigation glyphs (compass and overlay map keys), in the menu glyphs'
    16-unit cell, stroke weight and corner language."""
    W = 1.6

    def lines(*points, width=W):
        return lambda x, y: min(segment(x, y, *points[i], *points[i + 1])
                                for i in range(len(points) - 1)) - width / 2

    def dot(cx, cy, radius):
        return lambda x, y: math.hypot(x - cx, y - cy) - radius

    def circle(cx, cy, radius, width=W):
        return lambda x, y: abs(math.hypot(x - cx, y - cy) - radius) - width / 2

    def fill(*points):
        return lambda x, y: polygon(x, y, points)

    def box(x0, y0, x1, y1, radius=1, width=None):
        if width is None:
            return lambda x, y: rrect(x, y, x0, y0, x1, y1, radius)
        return lambda x, y: abs(rrect(x, y, x0, y0, x1, y1, radius)) - width / 2

    def bar(cx, cy, length, thick, angle):
        # A filled rectangle `length` long and `thick` wide, turned `angle` degrees.
        ux, uy = math.cos(math.radians(angle)), math.sin(math.radians(angle))
        vx, vy = -uy, ux
        a, b = length / 2, thick / 2
        return fill((cx - ux * a - vx * b, cy - uy * a - vy * b), (cx + ux * a - vx * b, cy + uy * a - vy * b),
                    (cx + ux * a + vx * b, cy + uy * a + vy * b), (cx - ux * a + vx * b, cy - uy * a + vy * b))

    def star(cx, cy, outer, inner, points=5, turn=-90):
        corners = []
        for i in range(points * 2):
            r = outer if i % 2 == 0 else inner
            a = math.radians(turn + i * 180 / points)
            corners.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        return fill(*corners)

    rays = [lines((8 + 3.6 * math.cos(a), 8 + 3.6 * math.sin(a)), (8 + 6 * math.cos(a), 8 + 6 * math.sin(a)))
            for a in (math.radians(i * 45) for i in range(8))]
    table = {
        # A map pin.
        'waypoint': [circle(8, 6.2, 3.4), dot(8, 6.2, 1.1), lines((5, 8.3), (8, 14), (11, 8.3))],
        # A quest in your log: a flag on its pole.
        'quest': [lines((4, 14), (4, 2.2)), fill((4.4, 2.4), (13, 4.8), (4.4, 7.6))],
        'turnin': [lines((5, 5.4), (5.8, 3.4), (8, 2.6), (10.2, 3.4), (11, 5.4), (10.2, 7.2), (8, 8.4), (8, 10.2), width=2),
                   dot(8, 13, 1.3)],
        'giver': [lines((8, 2.6), (8, 9.8), width=2.4), dot(8, 13, 1.4)],
        'world': [circle(8, 8, 5.8), lines((2.4, 8), (13.6, 8)), lines((8, 2.2), (6, 5), (5.4, 8), (6, 11), (8, 13.8)),
                  lines((8, 2.2), (10, 5), (10.6, 8), (10, 11), (8, 13.8))],
        'rare': [star(8, 8.4, 6.4, 2.7)],
        'treasure': [box(2.6, 6.4, 13.4, 13.6, 1.2, W), lines((2.6, 9.4), (13.4, 9.4)),
                     lines((3.4, 6.4), (4.4, 3.4), (11.6, 3.4), (12.6, 6.4)), dot(8, 9.4, 1.3)],
        'event': [circle(8, 8, 2.2)] + rays,
        # A gate with its portcullis.
        'dungeon': [lines((3, 14), (3, 7), (4.4, 4), (8, 2.6), (11.6, 4), (13, 7), (13, 14)), lines((1.8, 14), (14.2, 14)),
                    lines((6, 4.2), (6, 14), width=1.2), lines((10, 4.2), (10, 14), width=1.2), lines((3.4, 9), (12.6, 9), width=1.2)],
        # Flight: a pair of wings.
        'taxi': [lines((1.6, 3.6), (5.2, 7.6), (8, 6.6), (10.8, 7.6), (14.4, 3.6)),
                 lines((5.2, 7.6), (8, 13.2), (10.8, 7.6)), dot(8, 4.4, 1.3)],
        'portal': [circle(8, 8, 5.8), circle(8, 8, 2.8, width=1.3), dot(8, 8, 0.9)],
        # An inn: a bed with its pillow.
        'inn': [lines((2, 3.6), (2, 13.6)), lines((2, 10.4), (14, 10.4), (14, 13.6)), box(3.6, 6.6, 7, 9, 1),
                lines((8.2, 7.8), (12.4, 7.8), (14, 10.4))],
        'bank': [lines((2, 6), (8, 2.4), (14, 6), (2, 6)), lines((4.2, 7.6), (4.2, 11.8)), lines((8, 7.6), (8, 11.8)),
                 lines((11.8, 7.6), (11.8, 11.8)), lines((2, 13.4), (14, 13.4))],
        'mail': [box(2, 3.5, 14, 12.5, 1.5, W), lines((2.5, 4.5), (8, 9), (13.5, 4.5))],
        # Repair: a hammer.
        'repair': [lines((2.8, 13.4), (9.2, 7), width=1.9), bar(10.6, 5.4, 9.4, 3.4, 45)],
        # The auction house: a gavel on its block.
        'auction': [lines((3, 11), (8.4, 5.6), width=1.7), bar(9.8, 4.2, 7.4, 3.6, 45), box(7.4, 12, 14, 14, 0.6)],
        # A vendor: a purse.
        'vendor': [lines((4.6, 5.2), (2.8, 9), (2.8, 12.4), (4.8, 14), (11.2, 14), (13.2, 12.4), (13.2, 9), (11.4, 5.2)),
                   lines((4.2, 5.2), (11.8, 5.2)), lines((6.6, 5.2), (6, 2.4)), lines((9.4, 5.2), (10, 2.4)), dot(8, 10.2, 1.3)],
        # A class trainer: a shield.
        'trainer': [lines((3, 2.8), (13, 2.8), (13, 8), (8, 14), (3, 8), (3, 2.8)), lines((8, 4.6), (8, 11), width=1.3),
                    lines((5.4, 7), (10.6, 7), width=1.3)],
        # A profession trainer: an anvil.
        'profession': [fill((1.6, 4.6), (14.4, 4.6), (14.4, 6.4), (11.2, 8.2), (11.2, 10.4), (13, 13.6), (3, 13.6), (4.8, 10.4),
                            (4.8, 8.2), (1.6, 6.4))],
        # A stable: a horseshoe.
        'stable': [lines((4.2, 2.8), (3.2, 7), (4, 10.6), (5.8, 12.9), (8, 13.6), (10.2, 12.9), (12, 10.6), (12.8, 7), (11.8, 2.8)),
                   dot(5.4, 5.6, 0.75), dot(10.6, 5.6, 0.75)],
        'barber': [circle(4.6, 11.6, 2.1), circle(11.4, 11.6, 2.1), lines((6.2, 10), (12.4, 2.4)), lines((9.8, 10), (3.6, 2.4))],
        # Transmogrification: a coat hanger.
        'transmog': [lines((8, 5.8), (8, 4.6), (9.3, 3.6), (8.7, 2.2), (7.2, 2.4)), lines((8, 5.8), (1.8, 11.6), (14.2, 11.6), (8, 5.8))],
        # The guild bank: a vault door.
        'guildbank': [box(2.2, 2.2, 13.8, 13.8, 1.6, W), circle(8, 8, 3.2), lines((8, 6), (8, 10), width=1.2),
                      lines((6, 8), (10, 8), width=1.2), lines((3.8, 13.8), (3.8, 15), width=1.2)],
        'poi': [lines((8, 2.4), (13.6, 8), (8, 13.6), (2.4, 8), (8, 2.4)), dot(8, 8, 1.4)],
        # An entrance to another map: a door.
        'link': [box(4, 2.4, 12, 13.6, 0.8, W), dot(9.6, 8.4, 0.9), lines((1.6, 13.6), (14.4, 13.6))],
    }
    return table[name]


# Navigation glyphs in atlas order. Modules/Navigation.lua lists the same names.
NAV_ICONS = ('waypoint', 'quest', 'turnin', 'giver', 'world', 'rare', 'treasure', 'event',
             'dungeon', 'taxi', 'portal', 'inn', 'bank', 'mail', 'repair', 'auction',
             'vendor', 'trainer', 'profession', 'stable', 'barber', 'transmog', 'guildbank', 'poi',
             'link')


def nav_icons(cell=64, columns=8, rows=4):
    shapes = [nav_icon_shapes(name) for name in NAV_ICONS]
    scale = cell / 16

    def alpha(x, y):
        index = int(y // cell) * columns + int(x // cell)
        if index >= len(shapes):
            return 0
        u, v = (x % cell) / scale, (y % cell) / scale
        return cover(min(shape(u, v) for shape in shapes[index]) * scale)
    return raster(cell * columns, cell * rows, alpha)


def tile_dot(size=16, radius=4.6, inverse=False):
    # Square tiles: lit/unlit LED dots, and the perforated cover that turns any
    # native status bar into a dot meter without reading its (maybe secret) value.
    def alpha(x, y):
        inside = cover(math.hypot(x - size / 2, y - size / 2) - radius)
        return 1 - inside if inverse else inside
    return raster(size, size, alpha)


def nav_icon(size=64):
    # Settings-tree glyph: a knob with a pointer and a tick arc, 2.8/32 strokes.
    scale, center = size / 32, size / 2
    ticks = []
    for i in range(7):
        angle = math.radians(225 - 270 * i / 6)
        ticks.append((center + math.cos(angle) * 12.2 * scale, center - math.sin(angle) * 12.2 * scale,
                      center + math.cos(angle) * 14.2 * scale, center - math.sin(angle) * 14.2 * scale))

    def alpha(x, y):
        dial = abs(math.hypot(x - center, y - center) - 7.6 * scale) - 1.4 * scale
        pointer = segment(x, y, center, center - 1.5 * scale, center, center - 7.6 * scale) - 1.4 * scale
        tick = min(segment(x, y, *t) for t in ticks) - 1.1 * scale
        return cover(min(dial, pointer, tick))
    return raster(size, size, alpha)


def rounded_mask(size=256, radius=20):
    # Alpha mask for the minimap and icons: a square with softly rounded corners.
    return raster(size, size, lambda x, y: cover(rrect(x, y, 0, 0, size, size, radius)))


def shell_shadow(size=128, inset=32, radius=24):
    # A soft drop shadow around a rounded rectangle; nine-sliced at runtime.
    def alpha(x, y):
        d = rrect(x, y, inset, inset, size - inset, size - inset, radius)
        if d <= 0:
            return 1.0
        t = clamp(d / inset)
        return (1 - t) ** 2.2
    return raster(size, size, alpha, (0, 0, 0))


def glow(size=64):
    return raster(size, size, lambda x, y: clamp(1 - math.hypot(x - size / 2, y - size / 2) / (size / 2)) ** 2)


def sweep(width=64, height=16):
    # A soft horizontal band of light: bright in the middle, gone at both ends.
    return raster(width, height, lambda x, y: math.sin(math.pi * x / width) ** 2 * clamp(1 - abs(y - height / 2) / (height / 2)) ** 1.5)


# Round art at 512px for the minimap -------------------------------------------
# Drawn large and shown smaller, never stretched up. Pixels near an edge are
# sampled 4x4, so the circles stay smooth at any size in game.
ROUND = 512


def disc_cover(x, y, radius, centre=ROUND / 2, samples=4):
    """Coverage of the pixel at (x, y) by a disc, exact enough at the edge."""
    d = math.hypot(x + 0.5 - centre, y + 0.5 - centre)
    if d < radius - 1.5:
        return 1.0
    if d > radius + 1.5:
        return 0.0
    step, hits = 1 / samples, 0
    for sy in range(samples):
        for sx in range(samples):
            if math.hypot(x + (sx + 0.5) * step - centre, y + (sy + 0.5) * step - centre) <= radius:
                hits += 1
    return hits / (samples * samples)


def round_raster(alpha, color=(255, 255, 255), size=ROUND):
    rows = [[color + (round(255 * clamp(alpha(x, y))),) for x in range(size)] for y in range(size)]
    return encode_tga(size, size, rows)


def mask_round():
    # The minimap mask and the filled discs behind it: one pixel of margin.
    return round_raster(lambda x, y: disc_cover(x, y, ROUND / 2 - 1))


def bezel_ring(stroke=6):
    # A thin crisp ring at the disc's edge, for the bezel's machined highlight.
    outer = ROUND / 2 - 1
    return round_raster(lambda x, y: disc_cover(x, y, outer) - disc_cover(x, y, outer - stroke))


def bezel_shade(size=256, width=22):
    # The soft shade inside a bezel: darkest at the edge, gone toward the middle.
    # A soft gradient needs no more than 256px.
    outer, centre = size / 2 - 0.5, size / 2
    def alpha(x, y):
        inside = disc_cover(x, y, outer, centre)
        if inside <= 0:
            return 0.0
        d = outer - math.hypot(x + 0.5 - centre, y + 0.5 - centre)
        return inside * (1 - clamp(d / width)) ** 2
    return round_raster(alpha, (0, 0, 0), size)


def textures():
    # The code-built shell: one rounded fill (art radius 24) and its shadow.
    yield 'shell', raster(64, 64, lambda x, y: cover(rrect(x, y, 0, 0, 64, 64, 24)))
    yield 'shell-shadow', shell_shadow()
    yield 'glow', glow()
    yield 'sweep', sweep()
    yield 'mask-square', rounded_mask(256, 20)
    yield 'mask-icon', rounded_mask(64, 12)
    # Fill masks for the pill and bar meter styles, nine-sliced at runtime.
    yield 'mask-pill', raster(64, 32, lambda x, y: cover(rrect(x, y, 0, 0, 64, 32, 16)))
    yield 'mask-bar', raster(32, 32, lambda x, y: cover(rrect(x, y, 0, 0, 32, 32, 6)))
    yield 'tile-dot', tile_dot()
    yield 'tile-perf', tile_dot(inverse=True)
    yield 'nav', nav_icon()
    yield 'round-3', solid(16, 6)
    yield 'round-6', solid(32, 12)
    yield 'round-10', solid(64, 20)
    yield 'ring-3', ring(16, 6)
    yield 'ring-6', ring(32, 12)
    yield 'ring-10', ring(64, 20)
    yield 'circle', solid(64, 32)
    yield 'circle-ring', ring(64, 32, 3)
    yield 'mask-round', mask_round()
    yield 'bezel-ring', bezel_ring()
    yield 'bezel-shade', bezel_shade()
    yield 'shadow', shadow()
    yield 'inset-3', inset(16, 6)
    yield 'inset-6', inset(32, 12)
    yield 'grain', grain()
    yield 'bar-flat', bar_flat()
    yield 'bar-dots', bar_dots()
    yield 'bar-segments', bar_segments()
    yield 'knob-ticks', knob_ticks()
    yield 'icons', icons()
    yield 'icons-menu', menu_icons()
    yield 'icons-nav', nav_icons()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    records = []
    for name, data in textures():
        width, height, raw = decode_tga(data)
        (OUT / f'{name}.tga').write_bytes(data)
        records.append({'path': f'Media/Hardware/{name}.tga', 'size': [width, height],
                        'sha256': hashlib.sha256(data).hexdigest(),
                        'bgraSha256': hashlib.sha256(raw).hexdigest()})
    fixture = json.loads(FIXTURE.read_text()) if FIXTURE.exists() else {}
    fixture['textures'] = records
    fixture['icons'] = list(ICONS)
    fixture['menuIcons'] = list(MENU_ICONS)
    fixture['navIcons'] = list(NAV_ICONS)
    fixture.setdefault('sounds', [])
    FIXTURE.write_text(json.dumps(fixture, indent=2) + '\n')
    print(f'{len(records)} Hardware textures, {sum(len(d) for _, d in textures()):,} bytes')


if __name__ == '__main__':
    main()
