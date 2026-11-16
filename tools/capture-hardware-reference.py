"""Bake Hardware theme artwork from the real SPEC-01 components.

SPEC-01 (https://github.com/shuding/spec-01, MIT) draws its controls with CSS:
layered gradients, inset highlights and soft shadows. WoW can only draw
textures, so this renders each control surface in headless Chrome at twice its
design size on a transparent background and saves it as a 32-bit RLE TGA for
nine-slice use. Text, icons and lamps are left out; the addon draws those.

Standard library only: Chrome is driven over its DevTools WebSocket and the
PNG screenshots are decoded here.

    python3 tools/capture-hardware-reference.py [--chrome PATH] [--url URL] [--only name,...] [--out DIR]
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import urllib.request
import zlib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'JiberishSpec01UI/Media/Hardware/Skin'
FIXTURE = ROOT / 'tests/fixtures/hardware-media.json'
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
URL = 'https://spec-01.vercel.app/'
SCALE = 2

_art = importlib.util.spec_from_file_location('hardware_art', ROOT / 'tools/build-hardware-art.py')
art = importlib.util.module_from_spec(_art)
_art.loader.exec_module(art)

# name: (JS expression for the element, padding around it in CSS px (left, top, right, bottom), options)
# Options: page (another reference page, reached in-app; default the components page),
#          corner (CSS px kept unstretched at each corner for nine-slice use; omit for fixed-size art),
#          tint (finish token the addon multiplies the art by), accent (rendered once per key color),
#          state ('active'), keep (keep descendants visible), nopseudo, before / after (JS), optional
BUTTON = "[...document.querySelectorAll('[data-kit=button]')].find(e => e.textContent.trim().toLowerCase() === '%s')"
CLICK = "(() => { const e = %s; if (e) e.click(); return new Promise(done => setTimeout(() => done(true), 450)) })()"
SPECS = {
    'module': ("document.querySelector('[data-kit=module]')", (20, 12, 20, 30), {'corner': 36, 'tint': 'skinPanel'}),
    'key': (BUTTON % 'stop', (10, 6, 10, 16), {'corner': 20, 'tint': 'skinKey'}),
    'key-down': (BUTTON % 'stop', (10, 6, 10, 16), {'corner': 20, 'tint': 'skinKey', 'state': 'active'}),
    'key-primary': (BUTTON % 'play', (14, 6, 14, 22), {'corner': 20, 'accent': True}),
    'key-primary-down': (BUTTON % 'play', (14, 6, 14, 22), {'corner': 20, 'accent': True, 'state': 'active'}),
    'key-round': ("document.querySelector('[data-kit=button][data-shape=round]')", (10, 6, 10, 16), {'tint': 'skinKey'}),
    'key-round-down': ("document.querySelector('[data-kit=button][data-shape=round]')", (10, 6, 10, 16),
                       {'tint': 'skinKey', 'state': 'active'}),
    'cap-in': ("document.querySelector('[data-kit=checkbox][data-checked]')", (18, 10, 18, 28), {'corner': 20}),
    'cap': ("document.querySelector('[data-kit=checkbox]:not([data-checked])')", (18, 10, 18, 28), {'corner': 20}),
    'switch-on': ("document.querySelector('[data-kit=switch]')", (4, 4, 4, 4), {'nopseudo': True, 'accent': True}),
    'switch-off': ("document.querySelector('[data-kit=switch]')", (4, 4, 4, 4),
                   {'nopseudo': True, 'tint': 'skinWell', 'before': CLICK % "document.querySelector('[data-kit=switch]')",
                    'after': CLICK % "document.querySelector('[data-kit=switch]')"}),
    'switch-thumb': ("document.querySelector('[data-kit=switch-thumb]')", (8, 6, 8, 12), {}),
    'segment-thumb': ("document.querySelector('[data-kit=segmented-indicator]')", (8, 6, 8, 12), {'corner': 10, 'tint': 'skinKey'}),
    'slider-track': ("document.querySelector('[data-kit=slider-track]')", (4, 4, 4, 4), {'corner': 4}),
    'slider-fill': ("document.querySelector('[data-kit=slider-indicator]')", (10, 10, 10, 10), {'corner': 4, 'accent': True}),
    'slider-thumb': ("document.querySelector('[data-kit=slider-thumb]')", (12, 8, 12, 14), {'keep': True, 'tint': 'skinKey'}),
    'knob-cap': ("document.querySelector('[data-kit=knob-cap]')", (10, 8, 14, 16), {'nopseudo': True, 'tint': 'skinKey'}),
    'glass': ("document.querySelector('[data-kit=input]')", (4, 4, 4, 6), {'corner': 21}),
    # The same dark glass without the highlight it casts on a light panel, for use over the game world.
    'screen': ("document.querySelector('[data-kit=input]')", (2, 2, 2, 2),
               {'corner': 21,
                'before': "(() => { const e = document.querySelector('[data-kit=input]'); e.style.boxShadow = getComputedStyle(e).boxShadow"
                          ".split(/,(?![^(]*\\))/).filter(s => s.includes('inset')).join(','); return true })()",
                'after': "(() => { document.querySelector('[data-kit=input]').style.boxShadow = ''; return true })()"}),
    'well': ("document.querySelector('[data-kit=stepper-input]')", (4, 4, 4, 4), {'corner': 20, 'tint': 'skinWell'}),
    'meter-track': ("document.querySelector('[data-kit=meter-track]')", (4, 4, 4, 4), {'corner': 8, 'tint': 'skinWell'}),
    'lcd': ("document.querySelector('[data-kit=lcd]')", (4, 4, 4, 6), {'corner': 14, 'tint': 'skinLcd'}),
    'badge': ("document.querySelector('[data-kit=badge]')", (6, 4, 6, 8), {'corner': 8, 'nopseudo': True, 'tint': 'skinKey'}),
    'avatar': ("document.querySelector('[data-kit=avatar]')", (8, 6, 8, 12), {'tint': 'skinKey'}),
    'led': ("document.querySelector('[data-kit=led]')", (8, 8, 8, 8), {'accent': True}),
    'toast': ("document.querySelector('[data-kit=toast]')", (14, 10, 14, 26),
              {'corner': 12, 'optional': True, 'before': CLICK % (BUTTON % 'save')}),
    'popover': ("document.querySelector('[data-kit=popover-surface]')", (24, 14, 24, 36),
                {'corner': 16, 'optional': True, 'tint': 'skinPanel', 'before': CLICK % (BUTTON % 'share'),
                 'after': "(() => { document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true})); return true })()"}),
    # The device pages: a housing, its black display and the charcoal rocker.
    'device': ("document.querySelector('section[data-device]')", (28, 16, 28, 44), {'page': '/music', 'corner': 32, 'tint': 'skinPanel'}),
    'display': ("document.querySelector('[data-kit=display-bezel]')", (14, 10, 14, 22),
                {'page': '/music', 'corner': 22, 'keep': True,
                 'before': "(() => { document.querySelectorAll('[data-kit=display-screen] *').forEach(e => e.style.setProperty('display', 'none', 'important')); return true })()"}),
    'rocker': ("document.querySelector('[data-kit=rocker-cap]')", (10, 6, 10, 16), {'page': '/music', 'corner': 19}),
}
GOTO = "(async () => { history.pushState({}, '', %s); dispatchEvent(new PopStateEvent('popstate')); await new Promise(done => setTimeout(done, 900)); return true })()"
# The reference's six key colors, in swatch order, under the addon's accent names; 'tint' is a
# near-white key the addon multiplies by a custom or class color.
ACCENTS = ('red', 'yellow', 'green', 'blue', 'purple', 'ink')
SET_ACCENT = """(() => { const keys = document.querySelectorAll('[data-kit=key-swatch]'); const i = %d;
    if (i >= 0) keys[i].click();
    else { const root = document.querySelector('[data-skin]'); root.style.setProperty('--theme-l', '0.92');
           root.style.setProperty('--theme-c', '0'); root.style.setProperty('--theme-h', '0') }
    return new Promise(done => setTimeout(() => done(keys.length), 250)) })()"""
READ_ACCENT = """(() => { const root = document.querySelector('[data-skin]'); const out = {};
    const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1;
    const ctx = canvas.getContext('2d', {willReadFrequently: true});
    for (const [name, value] of Object.entries({key: 'var(--key-color)', ink: 'var(--key-ink)', lamp: 'var(--key-lamp)',
                                                on: 'var(--on-accent)', edge: 'var(--key-color-edge)'})) {
        const probe = document.createElement('i'); probe.style.color = value; root.append(probe);
        ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = getComputedStyle(probe).color; ctx.fillRect(0, 0, 1, 1);
        out[name] = [...ctx.getImageData(0, 0, 1, 1).data].slice(0, 3); probe.remove() }
    return out })()"""

ISOLATE = """
html, body, [data-skin] { background: none !important; }
*, *::before, *::after { transition: none !important; animation: none !important; caret-color: transparent !important; }
body * { visibility: hidden !important; }
[data-cap] { visibility: visible !important; color: transparent !important; text-shadow: none !important; }
[data-cap][data-cap-keep] * { visibility: visible !important; }
[data-cap][data-cap-nopseudo]::before, [data-cap][data-cap-nopseudo]::after { display: none !important; }
"""


class WebSocket:
    """Just enough RFC 6455 to talk to Chrome's DevTools endpoint."""

    def __init__(self, url):
        host, rest = url.removeprefix('ws://').split('/', 1)
        name, port = host.split(':')
        self.socket = socket.create_connection((name, int(port)))
        key = base64.b64encode(os.urandom(16)).decode()
        self.socket.sendall((f'GET /{rest} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                             f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        self.buffer = b''
        while b'\r\n\r\n' not in self.buffer:
            self.buffer += self.socket.recv(65536)
        head, self.buffer = self.buffer.split(b'\r\n\r\n', 1)
        assert b' 101 ' in head.split(b'\r\n', 1)[0], head

    def read(self, count):
        while len(self.buffer) < count:
            chunk = self.socket.recv(1 << 20)
            assert chunk, 'DevTools connection closed'
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def send(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        header = bytes([0x81])
        if len(payload) < 126:
            header += bytes([0x80 | len(payload)])
        elif len(payload) < 65536:
            header += bytes([0x80 | 126]) + struct.pack('>H', len(payload))
        else:
            header += bytes([0x80 | 127]) + struct.pack('>Q', len(payload))
        self.socket.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def receive(self):
        message = b''
        while True:
            first, second = self.read(2)
            length = second & 127
            if length == 126:
                length = struct.unpack('>H', self.read(2))[0]
            elif length == 127:
                length = struct.unpack('>Q', self.read(8))[0]
            payload = self.read(length)
            opcode = first & 15
            if opcode == 8:
                raise ConnectionError('DevTools closed the socket')
            if opcode in (9, 10):
                continue
            message += payload
            if first & 0x80:
                return message.decode()


class Browser:
    def __init__(self, chrome, port=9339):
        self.profile = tempfile.TemporaryDirectory(prefix='jiberish-chrome-')
        self.process = subprocess.Popen([chrome, '--headless=new', f'--remote-debugging-port={port}',
                                         f'--user-data-dir={self.profile.name}', '--no-first-run', '--hide-scrollbars',
                                         '--window-size=1280,1000', '--force-device-scale-factor=1', 'about:blank'],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        target = None
        for _ in range(100):
            try:
                pages = json.loads(urllib.request.urlopen(f'http://127.0.0.1:{port}/json/list', timeout=1).read())
                target = next(p for p in pages if p['type'] == 'page')
                break
            except Exception:
                time.sleep(0.1)
        assert target, 'Chrome did not start'
        self.ws, self.next = WebSocket(target['webSocketDebuggerUrl']), 0

    def call(self, method, **params):
        self.next += 1
        self.ws.send(json.dumps({'id': self.next, 'method': method, 'params': params}))
        while True:
            reply = json.loads(self.ws.receive())
            if reply.get('id') == self.next:
                assert 'error' not in reply, (method, reply['error'])
                return reply.get('result', {})

    def js(self, expression):
        result = self.call('Runtime.evaluate', expression=expression, returnByValue=True, awaitPromise=True)
        assert 'exceptionDetails' not in result, result['exceptionDetails']
        return result['result'].get('value')

    def close(self):
        self.process.terminate()
        self.process.wait(timeout=10)
        self.profile.cleanup()


def decode_png(data):
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    offset, idat, header = 8, b'', None
    while offset < len(data):
        length, kind = struct.unpack('>I4s', data[offset:offset + 8])
        body = data[offset + 8:offset + 8 + length]
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
        offset += 12 + length
    width, height, depth, color, _, _, interlace = header
    assert depth == 8 and color in (2, 6) and interlace == 0, header
    channels = 4 if color == 6 else 3
    raw, stride = zlib.decompress(idat), width * channels
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        mode, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = previous[i]
            corner = previous[i - channels] if i >= channels else 0
            if mode == 1:
                line[i] = (line[i] + left) & 255
            elif mode == 2:
                line[i] = (line[i] + up) & 255
            elif mode == 3:
                line[i] = (line[i] + (left + up) // 2) & 255
            elif mode == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                line[i] = (line[i] + (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 255
        rows.append([tuple(line[x * channels:x * channels + 3]) + ((line[x * channels + 3],) if channels == 4 else (255,))
                     for x in range(width)])
        previous = line
    return width, height, rows


def bleed(rows, passes=6):
    """Give transparent texels the color of their nearest visible neighbors.

    Chrome leaves them black, which would darken the edges under WoW's linear filtering.
    """
    height, width = len(rows), len(rows[0])
    known = [[pixel[3] > 0 for pixel in row] for row in rows]
    for _ in range(passes):
        updates = []
        for y in range(height):
            for x in range(width):
                if known[y][x]:
                    continue
                total, count = [0, 0, 0], 0
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < height and 0 <= nx < width and known[ny][nx]:
                            for c in range(3):
                                total[c] += rows[ny][nx][c]
                            count += 1
                if count:
                    updates.append((y, x, tuple(round(v / count) for v in total)))
        if not updates:
            break
        for y, x, color in updates:
            rows[y][x] = color + (0,)
            known[y][x] = True
    return rows


def capture(browser, name):
    find, pad, options = SPECS[name]
    if options.get('before'):
        browser.js(options['before'])
    rect = browser.js(f"""(() => {{
        document.querySelectorAll('[data-cap]').forEach(e => {{
            e.removeAttribute('data-cap'); e.removeAttribute('data-cap-keep'); e.removeAttribute('data-cap-nopseudo') }});
        const e = {find};
        if (!e) return null;
        e.setAttribute('data-cap', '');
        {"e.setAttribute('data-cap-keep', '');" if options.get('keep') else ''}
        {"e.setAttribute('data-cap-nopseudo', '');" if options.get('nopseudo') else ''}
        e.scrollIntoView({{block: 'center'}});
        const r = e.getBoundingClientRect();
        return {{x: r.left + scrollX, y: r.top + scrollY, width: r.width, height: r.height}};
    }})()""")
    if not rect and options.get('optional'):
        return None
    assert rect, f'{name}: element not found'
    if options.get('state'):
        root = browser.call('DOM.getDocument')['root']['nodeId']
        node = browser.call('DOM.querySelector', nodeId=root, selector='[data-cap]')['nodeId']
        browser.call('CSS.forcePseudoState', nodeId=node, forcedPseudoClasses=[options['state']])
    left, top, right, bottom = pad
    clip = {'x': round(rect['x']) - left, 'y': round(rect['y']) - top,
            'width': round(rect['width']) + left + right, 'height': round(rect['height']) + top + bottom, 'scale': SCALE}
    shot = browser.call('Page.captureScreenshot', format='png', clip=clip, captureBeyondViewport=True)
    if options.get('state'):
        browser.call('CSS.forcePseudoState', nodeId=node, forcedPseudoClasses=[])
    if options.get('after'):
        browser.js(options['after'])
    width, height, rows = decode_png(base64.b64decode(shot['data']))
    return {'name': name, 'width': width, 'height': height, 'rows': bleed(rows), 'png': base64.b64decode(shot['data']),
            'element': [round(rect['width']), round(rect['height'])], 'pad': list(pad)}


def write_lua(records, accents):
    """Sizes and key colors for the addon, so Lua never drifts from the captured art."""
    lines = ['-- Generated by tools/capture-hardware-reference.py from SPEC-01 (MIT, Shu Ding). Do not edit by hand.',
             '-- w, h: the control\'s own size in design px; l, t, r, b: art drawn outside it (shadow, lip);',
             '-- c: corner kept unstretched for nine-slice use; tint: finish token; accent: one file per key color.',
             'local _, UI = ...', 'local Kit = UI.Kit', '', 'Kit.skin = {']
    seen = set()
    for record in records:
        if record['name'] in seen:
            continue
        seen.add(record['name'])
        (w, h), (l, t, r, b) = record['element'], record['pad']
        fields = [f'w = {w}', f'h = {h}', f'l = {l}', f't = {t}', f'r = {r}', f'b = {b}']
        if record['corner']:
            fields.append(f"c = {record['corner']}")
        if record['tint']:
            fields.append(f"tint = '{record['tint']}'")
        if record['accent']:
            fields.append('accent = true')
        lines.append(f"\t['{record['name']}'] = {{{', '.join(fields)}}},")
    lines += ['}', '', '-- sRGB values of each reference key color: the key itself, its ink on light panels, its lamp,',
              '-- the legend on a key cap, and the key\'s edge.', 'Kit.accentSkin = {']
    for accent, colors in accents.items():
        parts = [f"{role} = {{{', '.join(f'{v / 255:.4f}' for v in rgb)}}}" for role, rgb in colors.items()]
        lines.append(f"\t{accent} = {{{', '.join(parts)}}},")
    lines += ['}', '']
    (ROOT / 'JiberishSpec01UI/Kit/Skin.lua').write_text('\n'.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chrome', default=CHROME)
    parser.add_argument('--url', default=URL)
    parser.add_argument('--only', default='')
    parser.add_argument('--out', type=Path, default=OUT)
    parser.add_argument('--png', action='store_true', help='also keep the raw screenshots, for review')
    args = parser.parse_args()
    names = [n for n in args.only.split(',') if n] or list(SPECS)
    args.out.mkdir(parents=True, exist_ok=True)
    browser = Browser(args.chrome)
    records = []
    try:
        for domain in ('Page', 'DOM', 'CSS', 'Runtime'):
            browser.call(domain + '.enable')
        browser.call('Emulation.setDefaultBackgroundColorOverride', color={'r': 0, 'g': 0, 'b': 0, 'a': 0})
        browser.call('Page.navigate', url=args.url)
        for _ in range(200):
            if browser.js("document.readyState === 'complete' && !!document.querySelector('[data-kit=module]')"):
                break
            time.sleep(0.1)
        browser.js('document.fonts.ready.then(() => true)')
        browser.js(f"(() => {{ const s = document.createElement('style'); s.textContent = {json.dumps(ISOLATE)}; document.head.append(s); return true }})()")
        def save(name, file_name):
            result = capture(browser, name)
            if not result:
                print(f'{name}: not found, skipped')
                return
            data = art.encode_tga(result['width'], result['height'], result['rows'])
            (args.out / f'{file_name}.tga').write_bytes(data)
            if args.png:
                (args.out / f'{file_name}.png').write_bytes(result['png'])
            options = SPECS[name][2]
            records.append({'path': f'Media/Hardware/Skin/{file_name}.tga', 'name': name, 'size': [result['width'], result['height']],
                            'element': result['element'], 'pad': result['pad'], 'corner': options.get('corner'),
                            'tint': options.get('tint'), 'accent': bool(options.get('accent')), 'scale': SCALE,
                            'sha256': hashlib.sha256(data).hexdigest()})
            print(f"{file_name}: element {result['element']} -> {result['width']}x{result['height']} texels")

        for name in names:
            if not SPECS[name][2].get('accent') and not SPECS[name][2].get('page'):
                save(name, name)
        accents = {}
        for index, accent in enumerate(ACCENTS + ('tint',)):
            count = browser.js(SET_ACCENT % (index if accent != 'tint' else -1))
            assert count == len(ACCENTS), f'expected {len(ACCENTS)} key colors, found {count}'
            accents[accent] = browser.js(READ_ACCENT)
            for name in names:
                if SPECS[name][2].get('accent'):
                    save(name, f'{name}-{accent}')
        browser.js(SET_ACCENT % 0)  # back to the reference's default red for the device pages
        for page in sorted({SPECS[n][2]['page'] for n in names if SPECS[n][2].get('page')}):
            browser.js(GOTO % json.dumps(page))
            for name in names:
                if SPECS[name][2].get('page') == page:
                    save(name, name)
    finally:
        browser.close()
    if args.out == OUT and not args.only:
        fixture = json.loads(FIXTURE.read_text())
        fixture['skin'] = records
        fixture['accents'] = accents
        FIXTURE.write_text(json.dumps(fixture, indent=2) + '\n')
        write_lua(records, accents)
    print(f'{len(records)} captures')


if __name__ == '__main__':
    main()
