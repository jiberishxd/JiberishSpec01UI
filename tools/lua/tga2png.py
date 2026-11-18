"""Render a TGA texture's alpha as a grey PNG preview: tga2png.py in.tga out.png"""
import sys, struct, zlib
data = open(sys.argv[1], 'rb').read()
w, h = struct.unpack_from('<HH', data, 12)
raw, off = bytearray(), 18
while len(raw) < w*h*4:
    p = data[off]; off += 1; n = (p & 127) + 1
    if p & 128: raw += data[off:off+4]*n; off += 4
    else: raw += data[off:off+4*n]; off += 4*n
rows = []
for y in range(h):
    src = h-1-y
    row = bytearray([0])
    for x in range(w):
        a = raw[(src*w+x)*4+3]
        v = 245 - round(a*225/255)
        row += bytes((v, v, v))
    rows.append(bytes(row))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t+d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')
open(sys.argv[2], 'wb').write(png)
