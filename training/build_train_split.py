"""Merge OSDaR23 and Open Images into one YOLO dataset folder, honestly.

    python training/build_train_split.py

Builds data/dataset/railguard_v2/{images,labels}/{train,val}/ and dataset.yaml.

Files are hard-linked, not copied, so the merged set costs almost no disk on
the same volume. Falls back to copying where linking is not possible.

Why a real folder rather than two train.txt lists: Ultralytics derives its
label-cache path from the first label file in the list. Both lists began with
OSDaR23 images, so train and val resolved to the SAME cache file and the
validation scan overwrote the training scan, silently shrinking the training
set from 4,520 images to 1,569 on any restart. Separate folders give separate
caches.

Splitting rules, both from mistakes already made in this project:

  OSDaR23      split by named sequence, never by frame. Consecutive frames in
               a sequence are near-identical; a frame-level split once put 33
               of 43 validation frames next to a training frame.
  Open Images  split by Open Images' own train / validation assignment, read
               back from provenance.csv.

The hand-labelled Sri Lankan test sets are not referenced here at all.
"""

import csv
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OSDAR = os.path.join(ROOT, "data", "dataset", "osdar23_yolo")
OPENIMG = os.path.join(ROOT, "data", "dataset", "openimages")
OUT = os.path.join(ROOT, "data", "dataset", "railguard_v2")

NAMES = ["person", "car", "motorcycle", "bus", "truck", "cow", "elephant"]


def link_or_copy(src, dst):
    if os.path.exists(dst):
        return
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


def label_for(img):
    """The YOLO label path beside an image, following the images/ -> labels/ rule."""
    head, name = os.path.split(img)
    parts = head.split(os.sep)
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == "images":
            parts[i] = "labels"
            break
    return os.path.join(os.sep.join(parts), os.path.splitext(name)[0] + ".txt")


def read_list(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf8") as f:
        return [ln.strip() for ln in f if ln.strip()]


def openimages_by_split():
    prov = os.path.join(OPENIMG, "provenance.csv")
    if not os.path.exists(prov):
        raise SystemExit(f"Missing {prov}; run training/fetch_openimages.py first")
    out = {"train": [], "validation": []}
    missing = 0
    with open(prov, encoding="utf8") as f:
        for row in csv.DictReader(f):
            p = os.path.join(OPENIMG, "images", "train", row["image"])
            if not os.path.exists(p):
                missing += 1
                continue
            out.setdefault(row["split"], []).append(p)
    if missing:
        print(f"  warning: {missing} rows in provenance.csv have no image on disk")
    return out


def place(images, split, counts):
    img_dir = os.path.join(OUT, "images", split)
    lbl_dir = os.path.join(OUT, "labels", split)
    os.makedirs(img_dir, exist_ok=True)
    os.makedirs(lbl_dir, exist_ok=True)
    for img in images:
        lbl = label_for(img)
        if not os.path.exists(lbl):
            counts["label missing, image skipped"] += 1
            continue
        base = os.path.basename(img)
        link_or_copy(img, os.path.join(img_dir, base))
        link_or_copy(lbl, os.path.join(lbl_dir, os.path.splitext(base)[0] + ".txt"))
        counts[split] += 1


def main():
    import collections
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)   # also clears any stale .cache from an earlier run
    os.makedirs(OUT)

    osdar_train = read_list(os.path.join(OSDAR, "train.txt"))
    osdar_val = read_list(os.path.join(OSDAR, "val.txt"))
    if not osdar_train:
        raise SystemExit(f"Missing {OSDAR}/train.txt; run training/osdar23_to_yolo.py first")
    oi = openimages_by_split()

    counts = collections.Counter()
    place(osdar_train + oi.get("train", []), "train", counts)
    place(osdar_val + oi.get("validation", []), "val", counts)

    with open(os.path.join(OUT, "dataset.yaml"), "w", encoding="utf8") as f:
        f.write(f"path: {os.path.abspath(OUT)}\n")
        f.write("train: images/train\nval: images/val\n\nnames:\n")
        for i, n in enumerate(NAMES):
            f.write(f"  {i}: {n}\n")

    print(f"\n{OUT}")
    print(f"  train {counts['train']:5d}  (OSDaR23 {len(osdar_train)}, "
          f"Open Images {len(oi.get('train', []))})")
    print(f"  val   {counts['val']:5d}  (OSDaR23 {len(osdar_val)}, "
          f"Open Images {len(oi.get('validation', []))})")
    if counts["label missing, image skipped"]:
        print(f"  skipped {counts['label missing, image skipped']} images with no label file")
    print("\nSeparate folders per split, so train and val get separate caches.")
    print("OSDaR23 is split by sequence; Open Images by its own split.")
    print("The Sri Lankan hand-labelled test sets are in neither.")


if __name__ == "__main__":
    main()
