"""Merge a newly labelled frame set into the daytime test set.

    python training/merge_testset.py --from data/dataset/testset_manual_b --dry-run
    python training/merge_testset.py --from data/dataset/testset_manual_b

Renumbers incoming frames so they continue after the highest existing
manual_NNN, copies images and labels together, and APPENDS to provenance.csv
rather than replacing it, so every frame keeps the source video and timestamp
it was extracted from.

Refuses rather than guesses:

- a frame with no label file is a frame nobody decided about, which is not the
  same as a frame with nothing in it. An unlabelled frame silently counted as
  empty would lower every model's recall for free.
- a label file with no image, a malformed line, a class id outside 0-6, or a
  coordinate outside 0-1 stops the merge.
- an existing destination file is never overwritten.
- a frame whose image bytes already exist in the destination is a duplicate,
  not a new sample. On 24 Nov 2026 two extraction ranges shared an endpoint
  (400-520 and 520-640) and the extractor includes both ends, so t = 520.0 s
  entered the set twice. Both copies happened to be empty; had they held boxes,
  every count built on the set would have been quietly wrong.

Nothing is written until every check has passed, so a refusal leaves the
daytime set exactly as it was.
"""

import argparse
import csv
import glob
import hashlib
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.join(ROOT, "data", "dataset", "testset_manual")
NAMES = ["person", "car", "motorcycle", "bus", "truck", "cow", "elephant"]


def read_labels(path):
    """Returns boxes as [(cls, cx, cy, w, h)], or raises ValueError."""
    out = []
    for n, line in enumerate(open(path).read().splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 5:
            raise ValueError(f"{os.path.basename(path)} line {n}: expected 5 values, got {len(parts)}")
        try:
            cls = int(parts[0])
            cx, cy, w, h = (float(v) for v in parts[1:])
        except ValueError:
            raise ValueError(f"{os.path.basename(path)} line {n}: not a number: {line!r}")
        if not 0 <= cls < len(NAMES):
            raise ValueError(f"{os.path.basename(path)} line {n}: class id {cls} is outside 0-{len(NAMES)-1}")
        for name, v in (("cx", cx), ("cy", cy), ("w", w), ("h", h)):
            if not 0.0 <= v <= 1.0:
                raise ValueError(f"{os.path.basename(path)} line {n}: {name}={v} is outside 0-1")
        if w <= 0 or h <= 0:
            raise ValueError(f"{os.path.basename(path)} line {n}: zero-size box")
        out.append((cls, cx, cy, w, h))
    return out


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def next_index(dest_images):
    used = []
    for p in glob.glob(os.path.join(dest_images, "manual_*.jpg")):
        stem = os.path.splitext(os.path.basename(p))[0]
        try:
            used.append(int(stem.split("_")[1]))
        except (IndexError, ValueError):
            continue
    return max(used) + 1 if used else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="src", required=True, help="folder with images/ and labels/")
    ap.add_argument("--into", default=DEST, help=f"destination set (default {DEST})")
    ap.add_argument("--dry-run", action="store_true", help="check and report, write nothing")
    args = ap.parse_args()

    src_img = os.path.join(args.src, "images")
    src_lab = os.path.join(args.src, "labels")
    dst_img = os.path.join(args.into, "images")
    dst_lab = os.path.join(args.into, "labels")
    for d in (src_img, src_lab, dst_img, dst_lab):
        if not os.path.isdir(d):
            raise SystemExit(f"missing folder: {d}")

    images = sorted(glob.glob(os.path.join(src_img, "*.jpg")))
    if not images:
        raise SystemExit(f"no images in {src_img}")

    # ---- check everything before writing anything ----
    problems, plan, counts, boxes_total = [], [], [0] * len(NAMES), 0
    start = next_index(dst_img)

    # Same image already in the destination, or twice in this batch, is a
    # duplicate sample: it double-counts its boxes and its frame.
    dest_hashes = {}
    for p in glob.glob(os.path.join(dst_img, "*.jpg")):
        dest_hashes.setdefault(digest(p), os.path.basename(p))
    seen_here = {}
    for i, img in enumerate(images):
        stem = os.path.splitext(os.path.basename(img))[0]
        lab = os.path.join(src_lab, stem + ".txt")
        if not os.path.exists(lab):
            problems.append(f"{stem}: no label file. A frame nobody labelled is not an empty frame.")
            continue
        try:
            found = read_labels(lab)
        except ValueError as e:
            problems.append(str(e))
            continue
        for cls, *_ in found:
            counts[cls] += 1
        boxes_total += len(found)
        d = digest(img)
        if d in dest_hashes:
            problems.append(f"{stem}: identical to {dest_hashes[d]} already in the "
                            f"destination - duplicate sample, not a new frame")
            continue
        if d in seen_here:
            problems.append(f"{stem}: identical to {seen_here[d]} in this batch")
            continue
        seen_here[d] = stem

        new_stem = f"manual_{start + i:03d}"
        for ext, d in ((".jpg", dst_img), (".txt", dst_lab)):
            target = os.path.join(d, new_stem + ext)
            if os.path.exists(target):
                problems.append(f"{new_stem}{ext} already exists in the destination")
        plan.append((img, lab, new_stem, len(found)))

    orphans = [os.path.basename(p) for p in glob.glob(os.path.join(src_lab, "*.txt"))
               if not os.path.exists(os.path.join(src_img,
                   os.path.splitext(os.path.basename(p))[0] + ".jpg"))]
    for o in orphans:
        problems.append(f"{o}: label file with no image")

    print(f"{len(images)} frames in {args.src}")
    print(f"renumbering to manual_{start:03d} .. manual_{start + len(images) - 1:03d}")
    empty = sum(1 for *_, n in plan if n == 0)
    print(f"{boxes_total} boxes, {empty} frames deliberately empty")
    for i, n in enumerate(NAMES):
        if counts[i]:
            print(f"   {n:<12}{counts[i]:>5}")

    if problems:
        print(f"\nREFUSED, {len(problems)} problem(s). Nothing was written:")
        for p in problems[:30]:
            print(f"   {p}")
        if len(problems) > 30:
            print(f"   ... and {len(problems) - 30} more")
        raise SystemExit(1)

    if args.dry_run:
        print("\ndry run: all checks passed, nothing written")
        return

    # ---- write ----
    for img, lab, new_stem, _ in plan:
        shutil.copy2(img, os.path.join(dst_img, new_stem + ".jpg"))
        shutil.copy2(lab, os.path.join(dst_lab, new_stem + ".txt"))

    src_prov = os.path.join(args.src, "provenance.csv")
    dst_prov = os.path.join(args.into, "provenance.csv")
    if os.path.exists(src_prov):
        rename = {os.path.splitext(os.path.basename(i))[0] + ".jpg": s + ".jpg"
                  for i, _, s, _ in plan}
        rows = list(csv.DictReader(open(src_prov, newline="")))
        for r in rows:
            r["image"] = rename.get(r["image"], r["image"])
        existing = list(csv.DictReader(open(dst_prov, newline=""))) if os.path.exists(dst_prov) else []
        fields = list(dict.fromkeys([*(existing[0] if existing else {}), *(rows[0] if rows else {})]))
        with open(dst_prov, "w", newline="") as f:
            wr = csv.DictWriter(f, fieldnames=fields)
            wr.writeheader()
            wr.writerows(existing + rows)
        print(f"provenance.csv: {len(existing)} + {len(rows)} rows")

    total = len(glob.glob(os.path.join(dst_img, "*.jpg")))
    print(f"\nmerged. {args.into} now holds {total} frames")
    print("Next: training/check_manual_labels.py, then re-run the evaluations.")


if __name__ == "__main__":
    main()
