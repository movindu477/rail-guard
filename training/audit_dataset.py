"""Audit the training data before a run: class counts per split, and test-set leaks.

    python training/audit_dataset.py
    python training/audit_dataset.py --data data/dataset/yolo/railguard_animals.yaml

Part 1, per split (train / val / each test set):
  label files, how many contain objects, instances per class 0-6,
  labels with a class id outside 0-6, labels with coordinates outside 0-1.
  PASS when every class has instances in both train and val.

Part 2, test-set isolation:
  1. no file name in two splits
  2. no identical image (by content hash) in two splits
  3. synthetic images: no background frame used in both train and test,
     and test backgrounds are not in the real train/val/negative frames
  4. synthetic images: train only uses train cut-outs, test only test cut-outs
  5. no val frame within 3 video frames of a train frame (near-duplicates)

Exits non-zero when any check fails.
"""

import argparse
import csv
import glob
import hashlib
import os
import re
import sys
from collections import Counter, defaultdict

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATASET = os.path.join(ROOT, "data", "dataset")
YOLO_DIR = os.path.join(DATASET, "yolo")
TEST_YAMLS = {"test: synthetic animals": "animal_test.yaml",
              "test: wildlife elephants": "wildlife_elephant_test.yaml"}
IMG_EXT = (".jpg", ".jpeg", ".png", ".bmp")


def load_yaml(path):
    with open(path) as f:
        cfg = yaml.safe_load(f)
    base = cfg.get("path") or os.path.dirname(path)
    as_list = lambda v: v if isinstance(v, list) else [v]
    dirs = lambda key: [os.path.normpath(os.path.join(base, d)) for d in as_list(cfg[key])]
    return dirs("train"), dirs("val"), cfg["names"]


def images_in(dirs):
    return sorted(p for d in dirs for p in glob.glob(os.path.join(d, "*"))
                  if p.lower().endswith(IMG_EXT))


def label_path(img):
    """YOLO convention: .../images/... -> .../labels/..., extension -> .txt."""
    head, tail = img.rsplit(os.sep + "images" + os.sep, 1)
    return os.path.join(head, "labels", os.path.splitext(tail)[0] + ".txt")


def audit_split(images, n_classes):
    s = {"images": len(images), "labels": 0, "with_objects": 0,
         "counts": Counter(), "bad_class": [], "bad_coord": []}
    for img in images:
        lp = label_path(img)
        if not os.path.exists(lp):
            continue
        s["labels"] += 1
        has = False
        for ln, line in enumerate(open(lp), 1):
            parts = line.split()
            if not parts:
                continue
            has = True
            cls = int(float(parts[0]))
            coords = [float(x) for x in parts[1:5]]
            if not 0 <= cls < n_classes:
                s["bad_class"].append(f"{os.path.basename(lp)}:{ln} class {cls}")
            else:
                s["counts"][cls] += 1
            if len(coords) != 4 or any(not 0 <= c <= 1 for c in coords):
                s["bad_coord"].append(f"{os.path.basename(lp)}:{ln} {parts[1:5]}")
        s["with_objects"] += has
    return s


def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description="Audit class counts and test-set isolation")
    ap.add_argument("--data", default=os.path.join(YOLO_DIR, "railguard_animals.yaml"),
                    help="training dataset YAML")
    args = ap.parse_args()

    train_dirs, val_dirs, names = load_yaml(args.data)
    n_classes = len(names)
    splits = {"train": images_in(train_dirs), "val": images_in(val_dirs)}
    for label, y in TEST_YAMLS.items():
        p = os.path.join(YOLO_DIR, y)
        if os.path.exists(p):
            splits[label] = images_in(load_yaml(p)[1])

    # ---------------- Part 1: class counts ----------------
    print(f"Training config: {os.path.relpath(args.data, ROOT)}")
    for d in train_dirs:
        print(f"  train  {os.path.relpath(d, DATASET)}  ({len(images_in([d]))} images)")
    for d in val_dirs:
        print(f"  val    {os.path.relpath(d, DATASET)}  ({len(images_in([d]))} images)")
    print()

    stats = {k: audit_split(v, n_classes) for k, v in splits.items()}
    cols = list(stats)
    w0, wc = 16, max(12, *(len(c) + 2 for c in cols))
    print(f"{'':{w0}s}" + "".join(f"{c:>{wc}s}" for c in cols))
    for key, title in (("images", "images"), ("labels", "label files"),
                       ("with_objects", "  with objects")):
        print(f"{title:{w0}s}" + "".join(f"{stats[c][key]:>{wc}d}" for c in cols))
    print("-" * (w0 + wc * len(cols)))
    for i in range(n_classes):
        print(f"{i} {names[i]:{w0 - 2}s}" + "".join(f"{stats[c]['counts'][i]:>{wc}d}" for c in cols))
    print("-" * (w0 + wc * len(cols)))
    for key, title in (("bad_class", "class id not 0-6" if n_classes == 7 else "bad class id"),
                       ("bad_coord", "coord not in 0-1")):
        print(f"{title:{w0}s}" + "".join(f"{len(stats[c][key]):>{wc}d}" for c in cols))
    print()

    failures = []
    for c in cols:
        for key in ("bad_class", "bad_coord"):
            for item in stats[c][key][:5]:
                print(f"  {c}: {item}")
            if stats[c][key]:
                failures.append(f"{c}: {len(stats[c][key])} labels with {key.replace('_', ' ')}")
    missing = [(split, names[i]) for split in ("train", "val") for i in range(n_classes)
               if stats[split]["counts"][i] == 0]
    for split, name in missing:
        failures.append(f"{split}: no '{name}' instances")
    print("PASS: every class present in train and val" if not missing
          else "FAIL: classes missing -> " + ", ".join(f"{n} ({s})" for s, n in missing))

    # ---------------- Part 2: test-set isolation ----------------
    print("\n=== Test-set isolation ===")
    split_of = {p: k for k, v in splits.items() for p in v}

    by_name = defaultdict(set)
    for p, k in split_of.items():
        by_name[os.path.basename(p).lower()].add(k)
    name_clash = {n: s for n, s in by_name.items() if len(s) > 1}
    print(f"1. File names in two splits:        {len(name_clash)}")
    for n, s in list(name_clash.items())[:5]:
        print(f"     {n}: {sorted(s)}")

    by_hash = defaultdict(set)
    for p, k in split_of.items():
        by_hash[md5(p)].add(k)
    dup = {h: s for h, s in by_hash.items() if len(s) > 1}
    print(f"2. Identical images in two splits:  {len(dup)}")
    for s in list(dup.values())[:5]:
        print(f"     {sorted(s)}")
    for n, k in ((name_clash, "file names shared"), (dup, "identical images shared")):
        if n:
            failures.append(f"{len(n)} {k} between splits")

    manifest = os.path.join(DATASET, "synthetic", "manifest.csv")
    if os.path.exists(manifest):
        rows = list(csv.DictReader(open(manifest)))
        bg = defaultdict(set)
        for r in rows:
            bg[r["split"]].add(r["source_frame"])
        shared_bg = bg["train"] & bg["test"]
        real = {os.path.splitext(os.path.basename(p))[0]
                for d in ("train", "val", "negatives")
                for p in images_in([os.path.join(YOLO_DIR, "images", d)])}
        test_bg_in_real = bg["test"] & real
        print(f"3. Synthetic backgrounds in train and test:      {len(shared_bg)}")
        print(f"   Synthetic test backgrounds in real train/val: {len(test_bg_in_real)}")
        wrong_cut = [r for r in rows
                     if not os.path.exists(os.path.join(DATASET, "animal_cutouts", r["class"],
                                                        r["split"], r["cutout"]))]
        print(f"4. Synthetic animals using the other split's cut-outs: {len(wrong_cut)}")
        for r in wrong_cut[:5]:
            print(f"     {r['image']} ({r['split']}) uses {r['class']}/{r['cutout']}")
        if shared_bg:
            failures.append(f"{len(shared_bg)} synthetic backgrounds in both train and test")
        if test_bg_in_real:
            failures.append(f"{len(test_bg_in_real)} synthetic test backgrounds also in real splits")
        if wrong_cut:
            failures.append(f"{len(wrong_cut)} synthetic animals use the wrong split's cut-out")

    # Frames come from one ride video in time order: neighbouring frames are
    # near-identical, so no val frame should have a train frame right next to it.
    # Synthetic images count as their background frame.
    src = {}
    if os.path.exists(manifest):
        for r in csv.DictReader(open(manifest)):
            src[r["image"]] = r["source_frame"]

    def frame_of(p):
        stem = os.path.splitext(os.path.basename(p))[0]
        m = re.search(r"frame_(\d+)", src.get(stem, stem))
        return int(m.group(1)) if m else None

    train_f = {f for f in map(frame_of, splits["train"]) if f is not None}
    val_f = {f for f in map(frame_of, splits["val"]) if f is not None}
    near = [v for v in val_f if any(abs(v - t) <= 3 for t in train_f)]
    gap = min((abs(a - b) for a in val_f for b in train_f), default=None)
    print(f"5. Val frames within +-3 video frames of a train frame: {len(near)}/{len(val_f)}"
          f"   (closest gap: {gap} frames)")
    if near:
        failures.append(f"{len(near)} val frames within 3 video frames of a train frame")
    test_f = {f for k, v in splits.items() if k.startswith("test")
              for f in map(frame_of, v) if f is not None}
    if test_f:
        test_near = sum(any(abs(t - x) <= 2 for x in train_f) for t in test_f)
        print(f"Note: synthetic test backgrounds within +-2 frames of a train frame: "
              f"{test_near}/{len(test_f)} (the test animals are unseen; these scenes are not)")

    print("\n" + ("ALL CHECKS PASSED" if not failures else "FAILED:\n  " + "\n  ".join(failures)))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
