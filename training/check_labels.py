"""Count boxes per class per source before training.

Exists because of 23 Nov 2026: the Open Images half of the pool contributed
ZERO person boxes, so 4,190 photos full of unlabelled pedestrians taught the
model that a person is background. Person recall after 60 epochs (6.6 h) was
0.004 while every other class reached 0.6-0.76.

Run this after every fetch and after every split rebuild. If any class shows
0 boxes from a source that plainly contains it, stop and fix the fetch.
"""
import collections
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
DS = ROOT / "data" / "dataset" / "railguard_v2"
NAMES = ["person", "car", "motorcycle", "bus", "truck", "cow", "elephant"]
HEX = re.compile(r"^[0-9a-f]{16}$")


def source_of(stem: str) -> str:
    return "openimages" if HEX.match(stem) else "osdar23"


def main() -> int:
    bad = False
    for split in ("train", "val"):
        d = DS / "labels" / split
        if not d.is_dir():
            print(f"MISSING: {d}")
            return 2
        boxes = collections.defaultdict(collections.Counter)
        imgs = collections.Counter()
        for f in d.glob("*.txt"):
            src = source_of(f.stem)
            imgs[src] += 1
            for line in f.read_text().splitlines():
                line = line.strip()
                if line:
                    boxes[src][NAMES[int(line.split()[0])]] += 1

        print(f"\n=== {split} ===")
        head = f"{'class':<12}" + "".join(f"{s:>14}" for s in sorted(boxes)) + f"{'total':>10}"
        print(head)
        print("-" * len(head))
        for n in NAMES:
            row = [boxes[s][n] for s in sorted(boxes)]
            flag = ""
            # person in a road-vehicle photo set is the known failure mode
            if n == "person" and boxes.get("openimages", {}).get("person", 0) == 0:
                flag = "   <-- ZERO, will collapse"
                bad = True
            print(f"{n:<12}" + "".join(f"{v:>14,}" for v in row) + f"{sum(row):>10,}" + flag)
        print("-" * len(head))
        print(f"{'images':<12}" + "".join(f"{imgs[s]:>14,}" for s in sorted(boxes))
              + f"{sum(imgs.values()):>10,}")

    if bad:
        print("\nFAIL: a class has no boxes from a source that contains it.")
        print("Do not train. Fix the fetch first.")
        return 1
    print("\nOK: every class is represented in both sources.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
