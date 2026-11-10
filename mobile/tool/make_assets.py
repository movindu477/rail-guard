"""Generate the app's train icon and alert sounds.

    python tool/make_assets.py          (from mobile/, with the repo venv)

assets/train_icon.png    128x128, transparent: a flat locomotive seen from
                         above, nose pointing up (the map rotates it to the heading)
assets/sounds/beep.wav   CAUTION: one short two-note beep
assets/sounds/alarm.wav  STOP: one cycle of a two-tone alarm; the app loops it
"""

import math
import os
import struct
import wave

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "assets")

ACCENT = (76, 195, 138, 255)     # RG.accent
BODY = (234, 244, 238, 255)
DARK = (15, 18, 20, 255)
GLASS = (27, 34, 39, 255)


def train_icon(path, size=128, ss=4):
    """Drawn at 4x and scaled down for smooth edges."""
    S = size * ss
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    u = S / 128   # drawing units: a 128-grid

    def box(x0, y0, x1, y1):
        return [x0 * u, y0 * u, x1 * u, y1 * u]

    def poly(pts):
        return [(x * u, y * u) for x, y in pts]

    # Body: long rounded rectangle with a tapered nose at the top.
    outline = poly([(46, 22), (52, 10), (76, 10), (82, 22), (82, 112), (78, 118),
                    (50, 118), (46, 112)])
    d.polygon(outline, fill=DARK)                       # dark edge for contrast on any map
    inner = poly([(50, 23), (55, 14), (73, 14), (78, 23), (78, 110), (75, 114),
                  (53, 114), (50, 110)])
    d.polygon(inner, fill=BODY)
    # Windscreen across the cab.
    d.polygon(poly([(54, 22), (58, 17), (70, 17), (74, 22), (74, 30), (54, 30)]), fill=GLASS)
    # Green stripe along the roof, and two roof grilles.
    d.rectangle(box(61, 34, 67, 108), fill=ACCENT)
    for y in (46, 76):
        d.rounded_rectangle(box(53, y, 59, y + 16), radius=2 * u, fill=GLASS)
        d.rounded_rectangle(box(69, y, 75, y + 16), radius=2 * u, fill=GLASS)
    im.resize((size, size), Image.LANCZOS).save(path)


def tone(freq, seconds, rate, volume=0.8, fade=0.01):
    n = int(seconds * rate)
    f = int(fade * rate)
    out = []
    for i in range(n):
        env = min(1.0, i / f, (n - i) / f) if f else 1.0
        out.append(volume * env * math.sin(2 * math.pi * freq * i / rate))
    return out


def write_wav(path, samples, rate):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(32767 * max(-1, min(1, s)))) for s in samples))


def main():
    os.makedirs(os.path.join(ASSETS, "sounds"), exist_ok=True)
    train_icon(os.path.join(ASSETS, "train_icon.png"))
    rate = 22050
    write_wav(os.path.join(ASSETS, "sounds", "beep.wav"),
              tone(880, 0.18, rate) + tone(0, 0.06, rate, 0) + tone(1175, 0.22, rate), rate)
    # One alarm cycle, ~1.2 s: high, low, gap. Looped by the app until acknowledged.
    write_wav(os.path.join(ASSETS, "sounds", "alarm.wav"),
              tone(988, 0.4, rate, 0.9) + tone(740, 0.4, rate, 0.9) + tone(0, 0.35, rate, 0), rate)
    print("wrote assets/train_icon.png, assets/sounds/beep.wav, assets/sounds/alarm.wav")


if __name__ == "__main__":
    main()
