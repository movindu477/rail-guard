"""Check hand-made labels before scoring (see training/manual_testset_rules.md).

    python training/check_manual_labels.py              # both sets
    python training/check_manual_labels.py --set day
    python training/check_manual_labels.py --dir some/folder   # any images/ + labels/ folder

Run it after the 5-frame dry run and after every export. It reports:
  - images with no label file yet (a frame with nothing in it still needs an EMPTY .txt)
  - label files with no matching image (wrong folder or renamed export)
  - malformed lines: not 5 fields, class id outside 0-6, coordinates outside 0-1,
    zero-size boxes
  - boxes under the 12 px minimum height (allowed for side-on vehicles: check them)
  - boxes per class, and how many label files are empty
Exits non-zero if anything is malformed, so a broken export is caught at once.
"""

import argparse
import glob
import os
import sys
from collections import Counter

import cv2

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETS = {"day": os.path.join(ROOT, "data", "dataset", "testset_manual"),
        "night": os.path.join(ROOT, "data", "dataset", "testset_night")}
NAMES = ["person", "car", "motorcycle", "bus", "truck", "cow", "elephant"]
MIN_PX = 12


def check(folder):
    images = {os.path.splitext(os.path.basename(p))[0]: p
              for p in glob.glob(os.path.join(folder, "images", "*.jpg"))}
    labels = {os.path.splitext(os.path.basename(p))[0]: p
              for p in glob.glob(os.path.join(folder, "labels", "*.txt"))}
    missing = sorted(set(images) - set(labels))
    orphans = sorted(set(labels) - set(images))
    bad, small, counts, empty = [], [], Counter(), 0
    for stem in sorted(set(labels) & set(images)):
        lines = [l for l in open(labels[stem]) if l.strip()]
        if not lines:
            empty += 1
            continue
        h, w = cv2.imread(images[stem]).shape[:2]
        for n, line in enumerate(lines, 1):
            p = line.split()
            where = f"{stem}.txt line {n}: {line.strip()}"
            try:
                cls, cx, cy, bw, bh = int(p[0]), *map(float, p[1:])
                if len(p) != 5:
                    raise ValueError
            except (ValueError, IndexError):
                bad.append(f"{where}  <- needs 5 numbers: class cx cy w h")
                continue
            if not 0 <= cls < len(NAMES):
                bad.append(f"{where}  <- class id must be 0-6 (was labels.txt loaded first?)")
            elif not all(0 <= v <= 1 for v in (cx, cy, bw, bh)):
                bad.append(f"{where}  <- coordinates must be between 0 and 1")
            elif bw <= 0 or bh <= 0:
                bad.append(f"{where}  <- zero-size box")
            else:
                counts[cls] += 1
                if bh * h < MIN_PX and bw * w < MIN_PX:
                    small.append(f"{stem}.txt line {n}: {NAMES[cls]} {bw * w:.0f}x{bh * h:.0f} px")
    return images, labels, missing, orphans, bad, small, counts, empty


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", choices=list(SETS), help="day or night (default: both)")
    ap.add_argument("--dir", help="check this folder instead (has images/ and labels/)")
    args = ap.parse_args()
    folders = {"custom": args.dir} if args.dir else ({args.set: SETS[args.set]} if args.set else SETS)

    failed = False
    for name, folder in folders.items():
        images, labels, missing, orphans, bad, small, counts, empty = check(folder)
        print(f"\n== {name}: {folder}")
        print(f"   images {len(images)}, label files {len(labels)} "
              f"({len(labels) - empty - len(orphans)} with boxes, {empty} empty)")
        if missing:
            print(f"   NOT LABELLED YET: {len(missing)} images, e.g. {', '.join(missing[:5])}")
        if orphans:
            print(f"   label files with no image: {len(orphans)}, e.g. {', '.join(orphans[:5])}")
        for b in bad[:15]:
            print(f"   MALFORMED  {b}")
        if len(bad) > 15:
            print(f"   ... and {len(bad) - 15} more malformed lines")
        for s in small[:10]:
            print(f"   under {MIN_PX} px (check it follows the rules): {s}")
        if counts:
            print("   boxes per class: " + ", ".join(f"{NAMES[c]} {counts[c]}" for c in sorted(counts))
                  + f"   (total {sum(counts.values())})")
        failed |= bool(bad or orphans)
        if not missing and not bad and not orphans:
            print("   OK: every image has a valid label file")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
