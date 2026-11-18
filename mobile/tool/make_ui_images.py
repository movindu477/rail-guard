"""Copy and resize UI photos from `mobile images/` at the repo root into `assets/images/`.

    python tool/make_ui_images.py       (from mobile/, with the repo venv)

Each photo is resized to 1242 x 1552 at JPEG quality 82 (target < 300 KB) so the
app never ships multi-megabyte camera originals.
"""

import os
import sys

from PIL import Image, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
MOBILE = os.path.abspath(os.path.join(HERE, ".."))
REPO = os.path.abspath(os.path.join(MOBILE, ".."))
SRC_DIR = os.path.join(REPO, "mobile images")
DST_DIR = os.path.join(MOBILE, "assets", "images")

TARGET_SIZE = (1242, 1552)
JPEG_QUALITY = 82
MAX_BYTES = 300 * 1024


def process_image(name: str) -> None:
    src = os.path.join(SRC_DIR, name)
    stem, _ = os.path.splitext(name)
    dst = os.path.join(DST_DIR, f"{stem}.jpg")
    im = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
    resized = ImageOps.fit(im, TARGET_SIZE, method=Image.LANCZOS)
    os.makedirs(DST_DIR, exist_ok=True)
    resized.save(dst, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    size_kb = os.path.getsize(dst) / 1024
    print(f"wrote {os.path.relpath(dst, MOBILE)} ({TARGET_SIZE[0]}x{TARGET_SIZE[1]}, {size_kb:.1f} KB)")
    if os.path.getsize(dst) >= MAX_BYTES:
        raise RuntimeError(f"{dst} is {size_kb:.1f} KB (must be under 300 KB)")


def main() -> None:
    names = sys.argv[1:] or [
        f for f in sorted(os.listdir(SRC_DIR))
        if f.lower().endswith((".jpg", ".jpeg", ".png", ".webp"))
    ]
    for name in names:
        process_image(name)


if __name__ == "__main__":
    main()
