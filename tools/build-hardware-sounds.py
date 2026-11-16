"""Render the SPEC-01 interaction sounds for the Hardware theme.

The voices are a direct port of `registry/hardware/lib/sound.ts` from SPEC-01 by
Shu Ding (https://github.com/shuding/spec-01, MIT; see
JiberishSpec01UI/Media/Hardware/LICENSE-SPEC-01.txt). The original synthesizes
each sound in the browser on every press: a burst of band-passed noise for the
contact and a decaying, falling oscillator for the body, with a little random
variation in pitch and level. WoW can only play files, so this renders three
varied takes of each voice with the same filters, envelopes and levels. One
uniform gain (MASTER) replaces the page's 0.55 master so the loudest voice peaks
just under full scale; relative levels are unchanged.

The standard library writes 16-bit WAV; ffmpeg encodes MP3 with LAME. (ffmpeg's
built-in Vorbis encoder made files WoW would not play.) Each file is padded with
silence to MIN_SECONDS, because the client is unreliable with very short streams.

    python3 tools/build-hardware-sounds.py [--ffmpeg /path/to/ffmpeg]
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'JiberishSpec01UI/Media/Hardware/Sounds'
FIXTURE = ROOT / 'tests/fixtures/hardware-media.json'
RATE = 44100
MASTER = 0.98
TAKES = 3
MIN_SECONDS = 0.25
FLOOR = 0.0001


def biquad(samples, kind, freq, q):
    """Web Audio's BiquadFilterNode: band-pass (constant 0 dB peak) or high-pass."""
    w = 2 * math.pi * freq / RATE
    cos = math.cos(w)
    if kind == 'bandpass':
        alpha = math.sin(w) / (2 * q)
        b0, b1, b2 = alpha, 0.0, -alpha
    else:
        # Web Audio reads a high-pass Q in decibels.
        alpha = math.sin(w) / (2 * 10 ** (q / 20))
        b0, b1, b2 = (1 + cos) / 2, -(1 + cos), (1 + cos) / 2
    a0, a1, a2 = 1 + alpha, -2 * cos, 1 - alpha
    x1 = x2 = y1 = y2 = 0.0
    out = []
    for x in samples:
        y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1, y2, y1 = x1, x, y1, y
        out.append(y)
    return out


def gain(index, level, attack, decay):
    """linearRampToValueAtTime(level, attack), then exponentialRampToValueAtTime(FLOOR, decay)."""
    t = index / RATE
    if t < attack:
        return level * t / attack
    if t >= decay:
        return FLOOR
    return level * (FLOOR / level) ** ((t - attack) / (decay - attack))


def burst(rng, at, freq, level, decay, q=1.0, kind='bandpass'):
    vary = lambda amount: 1 + rng.uniform(-1, 1) * amount
    count = int((decay + 0.02) * RATE)
    rate = vary(0.1)  # playbackRate: the noise buffer read a little fast or slow
    source = [rng.uniform(-1, 1) for _ in range(int(count * rate) + 2)]
    noise = []
    for i in range(count):
        position = i * rate
        base = int(position)
        noise.append(source[base] + (source[base + 1] - source[base]) * (position - base))
    noise = biquad(noise, kind, freq * vary(0.06), q)
    peak = level * vary(0.15)
    return at, [noise[i] * gain(i, peak, 0.0008, decay) for i in range(count)]


def tone(rng, at, freq, level, decay, to=None, shape='sine', attack=0.001):
    vary = lambda amount: 1 + rng.uniform(-1, 1) * amount
    count = int((decay + 0.02) * RATE)
    start = freq * vary(0.04)
    stop = max(20.0, (to or freq) / freq * start)
    peak = level * vary(0.12)
    phase, out = 0.0, []
    for i in range(count):
        t = i / RATE
        current = start * (stop / start) ** min(1.0, t / decay)
        phase += current / RATE
        cycle = phase % 1.0
        if shape == 'sine':
            value = math.sin(2 * math.pi * cycle)
        elif shape == 'square':
            value = 1.0 if cycle < 0.5 else -1.0
        else:
            value = 4 * cycle if cycle < 0.25 else (2 - 4 * cycle if cycle < 0.75 else 4 * cycle - 4)
        out.append(value * gain(i, peak, attack, decay))
    return at, out


def voices(rng):
    """Same voices, order and numbers as SPEC-01's sound.ts."""
    b = lambda at=0.0, **kw: burst(rng, at, **kw)
    t = lambda at=0.0, **kw: tone(rng, at, **kw)
    return {
        'down': lambda: [b(freq=2600, q=0.9, level=0.32, decay=0.022), t(freq=210, to=130, level=0.4, decay=0.05)],
        'down-primary': lambda: [b(freq=2100, q=0.8, level=0.36, decay=0.026), t(freq=165, to=100, level=0.55, decay=0.07)],
        'up': lambda: [b(freq=3900, q=1.2, level=0.16, decay=0.012), t(freq=300, to=240, level=0.1, decay=0.018)],
        'latch-down': lambda: [b(freq=2000, q=0.8, level=0.18, decay=0.018), t(freq=160, to=110, level=0.2, decay=0.045),
                               b(0.004, freq=1150, q=14, level=0.035, decay=0.05)],
        'latch-up': lambda: [b(freq=3200, q=1, level=0.11, decay=0.012), b(0.003, freq=1600, q=12, level=0.03, decay=0.04)],
        'tick': lambda: [b(kind='highpass', freq=3200, q=0.7, level=0.2, decay=0.006), t(freq=4300, level=0.035, decay=0.01)],
        'blip': lambda: [t(shape='square', freq=2350, level=0.035, decay=0.045, attack=0.002)],
        'type': lambda: [b(freq=3300, q=1.1, level=0.22, decay=0.014), t(freq=260, to=190, level=0.18, decay=0.03)],
        'type-space': lambda: [b(freq=2200, q=0.8, level=0.26, decay=0.022), t(freq=170, to=120, level=0.26, decay=0.05),
                               b(0.006, freq=900, q=6, level=0.05, decay=0.03)],
        'type-big': lambda: [b(freq=2600, q=0.9, level=0.26, decay=0.018), t(freq=200, to=140, level=0.28, decay=0.045)],
        'type-up': lambda: [b(freq=4400, q=1.3, level=0.08, decay=0.008)],
        'open': lambda: [b(freq=2600, q=1, level=0.1, decay=0.012), t(freq=520, to=820, level=0.045, decay=0.06, attack=0.003)],
        'success': lambda: [t(freq=1318, level=0.07, decay=0.09, attack=0.004), t(0.075, freq=1760, level=0.07, decay=0.16, attack=0.004)],
        'warning': lambda: [t(shape='triangle', freq=880, level=0.08, decay=0.08), t(0.11, shape='triangle', freq=880, level=0.08, decay=0.08)],
        'error': lambda: [t(shape='square', freq=220, level=0.04, decay=0.09), t(0.12, shape='square', freq=196, level=0.04, decay=0.14)],
    }


def mix(layers):
    length = max(int(at * RATE) + len(data) for at, data in layers) + int(0.004 * RATE)
    out = [0.0] * length
    for at, data in layers:
        start = int(at * RATE)
        for i, value in enumerate(data):
            out[start + i] += value
    out += [0.0] * max(0, int(MIN_SECONDS * RATE) - len(out))
    return [max(-1.0, min(1.0, value * MASTER)) for value in out]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg', default='ffmpeg')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    records = []
    with tempfile.TemporaryDirectory(prefix='jiberish-hardware-sound-') as scratch:
        rng = random.Random(5201)
        for old in list(OUT.glob('*.ogg')) + list(OUT.glob('*.mp3')):
            old.unlink()
        for voice, render in voices(rng).items():
            for take in range(1, TAKES + 1):
                samples = mix(render())
                name = f'{voice}-{take}'
                source = Path(scratch) / f'{name}.wav'
                with wave.open(str(source), 'wb') as output:
                    output.setnchannels(2); output.setsampwidth(2); output.setframerate(RATE)
                    output.writeframes(b''.join(struct.pack('<hh', *(round(v * 32767),) * 2) for v in samples))
                target = OUT / f'{name}.mp3'
                subprocess.run([args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', str(source),
                                '-map_metadata', '-1', '-bitexact', '-c:a', 'libmp3lame', '-b:a', '192k',
                                '-ar', str(RATE), '-ac', '2', '-id3v2_version', '0', '-write_id3v1', '0', str(target)], check=True)
                data = target.read_bytes()
                assert data[0] == 0xFF and data[1] & 0xE0 == 0xE0, target  # MPEG frame sync
                records.append({'path': f'Media/Hardware/Sounds/{name}.mp3', 'voice': voice, 'take': take,
                                'sha256': hashlib.sha256(data).hexdigest(),
                                'milliseconds': round(len(samples) * 1000 / RATE),
                                'peak': round(max(abs(v) for v in samples), 3)})
    fixture = json.loads(FIXTURE.read_text()) if FIXTURE.exists() else {}
    fixture['sounds'] = records
    fixture['soundTakes'] = TAKES
    FIXTURE.write_text(json.dumps(fixture, indent=2) + '\n')
    print(f'{len(records)} Hardware sounds, {sum((ROOT / "JiberishSpec01UI" / r["path"]).stat().st_size for r in records):,} bytes')


if __name__ == '__main__':
    main()
