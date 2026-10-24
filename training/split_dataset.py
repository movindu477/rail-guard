"""Split the railway frames and synthetic animals into train/val for YOLO fine-tuning.

The frames come from one ride video in time order (frame_0001 ... frame_0598,
about 2 s apart), so neighbouring frames show nearly the same scene. A random
split would put near-duplicates in train and val and make val look better than
it is. Instead, validation is two contiguous segments of the ride:

  segment A  chosen so the real labelled frames in it are ~20% of them and as
             representative as possible of every real class (0-4)
  segment B  chosen so the synthetic images in it are ~20% of them with as many
             cows and elephants as possible (5, 6)

Everything whose frame lies inside a segment (real frames and synthetic images
built on those backgrounds) goes to val. Anything within BUFFER frames of a
segment goes nowhere, so no training frame is a direct neighbour of a val frame.

Object-free frames not used for pasting are added to train as negatives.
The held-out test sets (synthetic/images/test, wildlife_elephants/images/test)
are never touched.

Writes under data/dataset/yolo/:
  images|labels/{train, val, train_synthetic, val_synthetic, negatives}
  railguard.yaml                 real frames only
  railguard_animals.yaml         real + negatives + synthetic   <- main training config
  railguard_raw_elephants.yaml   real + raw African Wildlife elephants
  animal_test.yaml               held-out synthetic animals (test)
  wildlife_elephant_test.yaml    held-out wildlife elephants (test)
  split_previous.txt             the split this replaced, if any
  split.txt                      which frame/image went where

Run paste_augment.py first, then this.
"""
import csv
import os
import random
import re
import shutil
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATASET = os.path.join(ROOT, "data", "dataset")
IMG = os.path.join(DATASET, "images")
LBL = os.path.join(DATASET, "labels")
OUT = os.path.join(DATASET, "yolo")
SYNTH = os.path.join(DATASET, "synthetic")
ELEPHANTS = os.path.join(DATASET, "wildlife_elephants")

VAL_FRAC = 0.2
BUFFER = 3          # frames dropped either side of a val segment (~6 s of video)
NEG_FRAC = 0.12     # object-free frames as a share of the final training set
REAL_CLASSES = range(5)        # person car motorcycle bus truck
ANIMAL_CLASSES = (5, 6)        # cow elephant

NAMES = """names:
  0: person
  1: car
  2: motorcycle
  3: bus
  4: truck
  5: cow
  6: elephant
"""

frame_no = lambda name: int(re.search(r"frame_(\d+)", name).group(1))


def classes_in(label_file):
    if not os.path.exists(label_file):
        return Counter()
    return Counter(int(float(line.split()[0])) for line in open(label_file) if line.strip())


def best_window(items, size, score, allowed=lambda lo, hi: True):
    """Contiguous run of `size` items (sorted by frame) with the highest score.
    items: [(frame, counts)]. Returns the (first_frame, last_frame) span."""
    best, best_span = None, None
    for i in range(len(items) - size + 1):
        lo, hi = items[i][0], items[i + size - 1][0]
        if not allowed(lo, hi):
            continue
        total = sum((c for _, c in items[i:i + size]), Counter())
        s = score(total)
        if best is None or s > best:
            best, best_span = s, (lo, hi)
    if best_span is None:
        raise SystemExit("No valid validation window found.")
    return best_span


def reset(*dirs):
    for d in dirs:
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)


def copy_pair(img_path, lbl_path, subset):
    name = os.path.basename(img_path)
    shutil.copy(img_path, os.path.join(OUT, "images", subset, name))
    dst = os.path.join(OUT, "labels", subset, os.path.splitext(name)[0] + ".txt")
    if os.path.exists(lbl_path):
        shutil.copy(lbl_path, dst)
    else:
        open(dst, "w").close()


def main():
    random.seed(42)

    # ---- What is available ----
    frames = sorted(f for f in os.listdir(IMG) if f.lower().endswith((".jpg", ".png")))
    lbl_of = lambda f: os.path.join(LBL, os.path.splitext(f)[0] + ".txt")
    labelled = [(frame_no(f), f) for f in frames
                if os.path.exists(lbl_of(f)) and os.path.getsize(lbl_of(f)) > 0]
    real_items = [(n, classes_in(lbl_of(f))) for n, f in labelled]

    synth = []   # (frame, image name, counts)
    syn_img_dir = os.path.join(SYNTH, "images", "train")
    if os.path.isdir(syn_img_dir):
        src = {}
        manifest = os.path.join(SYNTH, "manifest.csv")
        for r in csv.DictReader(open(manifest)):
            if r["split"] == "train":
                src[r["image"]] = frame_no(r["source_frame"])
        for f in sorted(os.listdir(syn_img_dir)):
            stem = os.path.splitext(f)[0]
            synth.append((src[stem], f,
                          classes_in(os.path.join(SYNTH, "labels", "train", stem + ".txt"))))
        synth.sort()

    # ---- Validation segments ----
    real_total = sum((c for _, c in real_items), Counter())
    span_a = best_window(
        real_items, round(VAL_FRAC * len(real_items)),
        score=lambda c: (min(c[k] / real_total[k] for k in REAL_CLASSES if real_total[k]),
                         sum(c[k] > 0 for k in REAL_CLASSES)))
    spans = [span_a]
    if synth:
        clear = lambda lo, hi: hi < span_a[0] - 2 * BUFFER or lo > span_a[1] + 2 * BUFFER
        span_b = best_window(
            [(n, c) for n, _, c in synth], round(VAL_FRAC * len(synth)),
            score=lambda c: (min(c[k] for k in ANIMAL_CLASSES), -abs(c[5] - c[6])),
            allowed=clear)
        spans.append(span_b)

    def where(n):
        if any(lo <= n <= hi for lo, hi in spans):
            return "val"
        if any(lo - BUFFER <= n <= hi + BUFFER for lo, hi in spans):
            return "drop"
        return "train"

    # ---- Keep a record of the split being replaced ----
    prev = []
    for subset in ("train", "val"):
        d = os.path.join(OUT, "images", subset)
        if os.path.isdir(d):
            prev += [f"{subset}\t{f}" for f in sorted(os.listdir(d))]
    if prev:
        with open(os.path.join(OUT, "split_previous.txt"), "w") as fh:
            fh.write("\n".join(prev) + "\n")

    subsets = ("train", "val", "train_synthetic", "val_synthetic", "negatives")
    reset(*(os.path.join(OUT, k, s) for k in ("images", "labels") for s in subsets))
    record = []

    # ---- Real labelled frames ----
    real_split = Counter()
    for n, f in labelled:
        dest = where(n)
        real_split[dest] += 1
        record.append(f"{dest}\treal\t{f}")
        if dest != "drop":
            copy_pair(os.path.join(IMG, f), lbl_of(f), dest)

    # ---- Synthetic animals (train pool only; test is never touched) ----
    syn_split = Counter()
    for n, f, _ in synth:
        dest = where(n)
        syn_split[dest] += 1
        record.append(f"{dest}\tsynthetic\t{f}")
        if dest != "drop":
            stem = os.path.splitext(f)[0]
            copy_pair(os.path.join(syn_img_dir, f),
                      os.path.join(SYNTH, "labels", "train", stem + ".txt"), dest + "_synthetic")

    # ---- Negatives: object-free frames, not pasted on, outside val segments and buffers ----
    used_path = os.path.join(SYNTH, "used_frames.txt")
    used = set(open(used_path).read().split()) if os.path.exists(used_path) else set()
    empty = [f for f in frames
             if os.path.splitext(f)[0] not in used
             and os.path.exists(lbl_of(f)) and os.path.getsize(lbl_of(f)) == 0
             and where(frame_no(f)) == "train"]
    n_train = real_split["train"] + syn_split["train"]
    n_neg = min(len(empty), round(NEG_FRAC / (1 - NEG_FRAC) * n_train))
    for f in random.Random(0).sample(empty, n_neg):
        copy_pair(os.path.join(IMG, f), lbl_of(f), "negatives")
        record.append(f"train\tnegative\t{f}")

    with open(os.path.join(OUT, "split.txt"), "w") as fh:
        fh.write("# subset\tsource\tfile\n" + "\n".join(record) + "\n")

    print(f"Val segments (frame numbers): " + ", ".join(f"{lo}-{hi}" for lo, hi in spans)
          + f"   buffer +-{BUFFER} frames")
    print(f"Real labelled frames: {len(labelled)} -> train {real_split['train']}, "
          f"val {real_split['val']}, dropped {real_split['drop']}")
    if synth:
        print(f"Synthetic images:     {len(synth)} -> train {syn_split['train']}, "
              f"val {syn_split['val']}, dropped {syn_split['drop']}")
    print(f"Negatives: {n_neg} of {len(empty)} eligible empty frames "
          f"({NEG_FRAC:.0%} of {n_train + n_neg} training images)")

    # ---- Dataset configs ----
    def write_yaml(name, path, train_dirs, val_dirs):
        fmt = lambda dirs: dirs[0] if len(dirs) == 1 else "[" + ", ".join(dirs) + "]"
        with open(os.path.join(OUT, name), "w") as f:
            f.write(f"path: {path}\ntrain: {fmt(train_dirs)}\nval: {fmt(val_dirs)}\n{NAMES}")
        print(f"Config: {os.path.join(OUT, name)}")

    count = lambda p: len(os.listdir(p)) if os.path.isdir(p) else 0
    write_yaml("railguard.yaml", OUT, ["images/train"], ["images/val"])
    if synth:
        write_yaml("railguard_animals.yaml", OUT,
                   ["images/train", "images/negatives", "images/train_synthetic"],
                   ["images/val", "images/val_synthetic"])
    if count(os.path.join(SYNTH, "images", "test")):
        write_yaml("animal_test.yaml", DATASET, ["synthetic/images/test"],
                   ["synthetic/images/test"])
    if count(os.path.join(ELEPHANTS, "images", "train")):
        write_yaml("railguard_raw_elephants.yaml", DATASET,
                   ["yolo/images/train", "wildlife_elephants/images/train"],
                   ["yolo/images/val"])
    if count(os.path.join(ELEPHANTS, "images", "test")):
        write_yaml("wildlife_elephant_test.yaml", DATASET, ["wildlife_elephants/images/test"],
                   ["wildlife_elephants/images/test"])


if __name__ == "__main__":
    main()
