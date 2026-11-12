"""Logo assets from assets/images/logo.jpg (the RailGuard logo).

    python tool/make_logo_assets.py      (from mobile/, with the repo venv)

assets/images/logo_mark.png
    The logo trimmed to its drawing and centred on a white square with even
    margins, for the round logo in the app's header.
android/app/src/main/res/mipmap-*/ic_launcher.png
    Launcher icon: the logo centred on a white circle (transparent outside),
    at every Android density.
"""

import os

from PIL import Image, ImageDraw, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
MOBILE = os.path.join(HERE, "..")
SRC = os.path.join(MOBILE, "assets", "images", "logo.jpg")
RES = os.path.join(MOBILE, "android", "app", "src", "main", "res")
LAUNCHER = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def trimmed(im):
    """The logo cut to its drawing (anything clearly darker than the white page)."""
    mask = ImageOps.invert(im.convert("L")).point(lambda v: 255 if v > 40 else 0)
    return im.crop(mask.getbbox())


def centred_square(art, size, fill):
    """art scaled to `fill` of the square, centred on white."""
    sq = Image.new("RGB", (size, size), "white")
    scale = fill * size / max(art.size)
    a = art.resize((round(art.width * scale), round(art.height * scale)), Image.LANCZOS)
    sq.paste(a, ((size - a.width) // 2, (size - a.height) // 2))
    return sq


def main():
    art = trimmed(Image.open(SRC).convert("RGB"))
    centred_square(art, 512, 0.70).save(os.path.join(MOBILE, "assets", "images", "logo_mark.png"))

    for density, px in LAUNCHER.items():
        big = px * 4   # draw large, scale down for smooth edges
        icon = centred_square(art, big, 0.62).convert("RGBA")
        circle = Image.new("L", (big, big), 0)
        ImageDraw.Draw(circle).ellipse([0, 0, big - 1, big - 1], fill=255)
        icon.putalpha(circle)
        icon.resize((px, px), Image.LANCZOS).save(
            os.path.join(RES, f"mipmap-{density}", "ic_launcher.png"))
    print("wrote assets/images/logo_mark.png and launcher icons", list(LAUNCHER))


if __name__ == "__main__":
    main()
