"""Compare two detectors on the SAME labelled boxes, with a paired test.

    python training/compare_models.py --a models/yolov8s.pt --b models/yolov8x.pt

Why a paired test
-----------------
Both models are scored on the same frames and the same ground-truth boxes, so
the two results are not independent samples. Comparing their Wilson intervals
and asking whether they overlap throws that pairing away, and is far too
conservative: on 24 Nov 2026 every model comparison in this project came back
"cannot distinguish" using overlapping intervals, including pairs that differ
on a large and lopsided set of boxes.

McNemar's test asks the question the data can actually answer: among the boxes
where the two models DISAGREE, is the disagreement one-sided?

  b = found by A, missed by B
  c = found by B, missed by A

Boxes both models find, and boxes both miss, carry no information about which
is better and are correctly ignored. The p-value is an exact two-sided
binomial test on b and c, so it is valid for the small discordant counts this
test set produces — a normal approximation is not.

What this does NOT do
---------------------
It compares recall only. A model can win here by emitting more boxes; tiled
inference did exactly that on 24 Nov 2026, raising recall while precision fell
from 0.325 to 0.256. Always read this next to training/eval_precision.py.

A low p-value says the difference is unlikely to be chance. It says nothing
about whether the difference is big enough to matter, which is a judgement
about braking distance and false-alarm tolerance, not statistics.
"""

import argparse
import glob
import math
import os

from ultralytics import YOLO

from eval_manual import BANDS, NAMES, SETS, THRESH, match
from tp_confidence import labels_for


def exact_mcnemar(b, c):
    """Two-sided exact binomial p-value for b successes in b+c trials, p=0.5."""
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    tail = sum(math.comb(n, i) for i in range(0, k + 1)) / (2 ** n)
    return min(1.0, 2 * tail)


def hits_per_box(model, folder, imgsz, conf, min_iou):
    """For every labelled box in the set: True if this model found it.

    Returns (hits, heights) as flat lists in a fixed order, so two models can
    be compared box by box.
    """
    images = sorted(glob.glob(os.path.join(folder, "images", "*.jpg")))
    images = [p for p in images if os.path.exists(
        os.path.join(folder, "labels", os.path.splitext(os.path.basename(p))[0] + ".txt"))]
    to_ds = {i: NAMES.index(n) for i, n in model.names.items() if n in NAMES}
    hits, heights, classes = [], [], []
    for img in images:
        gts = labels_for(img)
        r = model.predict(img, imgsz=imgsz, conf=conf, verbose=False)[0]
        h = r.orig_shape[0]
        preds = [(c, to_ds[k], bb) for c, k, bb in zip(
            r.boxes.conf.tolist(), r.boxes.cls.int().tolist(), r.boxes.xyxyn.tolist())
            if k in to_ds]
        found = match(preds, gts, class_aware=False, min_iou=min_iou)
        for j, (cls, bb) in enumerate(gts):
            hits.append(j in found)
            heights.append((bb[3] - bb[1]) * h)
            classes.append(cls)
    return hits, heights, classes


def report(label, a_hits, b_hits, name_a, name_b):
    both = sum(1 for x, y in zip(a_hits, b_hits) if x and y)
    b_only = sum(1 for x, y in zip(a_hits, b_hits) if x and not y)
    c_only = sum(1 for x, y in zip(a_hits, b_hits) if y and not x)
    neither = sum(1 for x, y in zip(a_hits, b_hits) if not x and not y)
    n = len(a_hits)
    p = exact_mcnemar(b_only, c_only)
    ra = (both + b_only) / n if n else 0
    rb = (both + c_only) / n if n else 0
    verdict = ("separated" if p < 0.05 else
               "not separated" if b_only + c_only >= 10 else
               "too few disagreements to tell")
    print(f"\n{label}  ({n} boxes)")
    print(f"   both found {both}   both missed {neither}   disagree {b_only + c_only}")
    print(f"   {name_a} only: {b_only}      {name_b} only: {c_only}")
    print(f"   recall {ra:.3f} vs {rb:.3f}   exact McNemar p = {p:.4f}   -> {verdict}")
    return p


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--a", required=True, help="first model")
    ap.add_argument("--b", required=True, help="second model")
    ap.add_argument("--set", default="manual day", choices=list(SETS))
    ap.add_argument("--imgsz", type=int, default=1280)
    ap.add_argument("--conf", type=float, default=THRESH)
    ap.add_argument("--iou", type=float, default=0.5)
    args = ap.parse_args()

    na, nb = os.path.basename(args.a), os.path.basename(args.b)
    print(f"Paired comparison on '{args.set}', conf >= {args.conf}, IoU >= {args.iou}")
    print(f"  A = {na}\n  B = {nb}")
    print("Same boxes, same order. Boxes both models agree on carry no information.")

    folder = SETS[args.set]
    a_hits, heights, classes = hits_per_box(YOLO(args.a), folder, args.imgsz, args.conf, args.iou)
    b_hits, _, _ = hits_per_box(YOLO(args.b), folder, args.imgsz, args.conf, args.iou)

    report("ALL BOXES", a_hits, b_hits, na, nb)

    for lo, hi, label in BANDS:
        idx = [i for i, h in enumerate(heights) if lo <= h < hi]
        if len(idx) >= 10:
            report(f"size band {label}", [a_hits[i] for i in idx],
                   [b_hits[i] for i in idx], na, nb)

    for cid, cname in enumerate(NAMES):
        idx = [i for i, c in enumerate(classes) if c == cid]
        if len(idx) >= 20:
            report(f"class {cname}", [a_hits[i] for i in idx],
                   [b_hits[i] for i in idx], na, nb)

    print("\nRecall only. Read with eval_precision.py: a model can win here by "
          "emitting more boxes.")


if __name__ == "__main__":
    main()
