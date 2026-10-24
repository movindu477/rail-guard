"""How confident is a model on the animals it gets right?

mAP integrates precision-recall down to confidence 0.001, so it can look high
while the model only ever finds animals at confidences the pipeline throws
away (PipelineConfig.conf_threshold = 0.25). This prints, per test set and
class, the confidence of every true positive and the recall at 0.25.

    python training/tp_confidence.py --model models/railguard_best.pt

A ground-truth box is a true positive when a same-class prediction overlaps it
at IoU >= 0.5 (each prediction matched at most once, highest confidence first).
Also reports, for missed boxes, which other class the model put there.
"""

import argparse
import glob
import os
from collections import Counter

import numpy as np
from ultralytics import YOLO

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_SETS = {
    "synthetic test": os.path.join(ROOT, "data", "dataset", "synthetic", "images", "test"),
    "wildlife test": os.path.join(ROOT, "data", "dataset", "wildlife_elephants", "images", "test"),
}
ANIMALS = (5, 6)
THRESH = 0.25


def labels_for(img):
    head, tail = os.path.normpath(img).rsplit(os.sep + "images" + os.sep, 1)
    path = os.path.join(head, "labels", os.path.splitext(tail)[0] + ".txt")
    out = []
    for line in open(path):
        p = line.split()
        if p:
            c, cx, cy, w, h = int(float(p[0])), *map(float, p[1:5])
            out.append((c, (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)))
    return out


def iou(a, b):
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def main():
    ap = argparse.ArgumentParser(description="True-positive confidence on the animal test sets")
    ap.add_argument("--model", default=os.path.join(ROOT, "models", "railguard_best.pt"))
    ap.add_argument("--imgsz", type=int, default=1280)
    args = ap.parse_args()
    model = YOLO(args.model)
    print(f"Model: {args.model}\n")

    for set_name, folder in TEST_SETS.items():
        tp = {c: [] for c in ANIMALS}        # confidence of each matched GT box
        n_gt = Counter()
        confused = {c: Counter() for c in ANIMALS}  # missed at 0.25: what class was there instead
        fp_high = Counter()                  # same-class predictions >= 0.25 matching no GT
        for img in sorted(glob.glob(os.path.join(folder, "*.jpg"))):
            gts = labels_for(img)
            r = model.predict(img, imgsz=args.imgsz, conf=0.001, verbose=False)[0]
            preds = sorted(zip(r.boxes.conf.tolist(), r.boxes.cls.int().tolist(),
                               r.boxes.xyxyn.tolist()), reverse=True)
            used = set()
            for c, g in gts:
                n_gt[c] += 1
            for c in ANIMALS:
                for gi, (gc, g) in enumerate(gts):
                    if gc != c:
                        continue
                    for pi, (conf, pc, b) in enumerate(preds):
                        if pi not in used and pc == c and iou(b, g) >= 0.5:
                            used.add(pi)
                            tp[c].append(conf)
                            break
                    else:
                        tp[c].append(0.0)
                    if tp[c][-1] < THRESH:
                        other = [(conf, pc) for conf, pc, b in preds
                                 if pc != c and conf >= THRESH and iou(b, g) >= 0.5]
                        confused[c][model.names[max(other)[1]] if other else "nothing"] += 1
            for pi, (conf, pc, b) in enumerate(preds):
                if conf >= THRESH and pc in ANIMALS and pi not in used:
                    fp_high[model.names[pc]] += 1

        print(f"== {set_name}")
        for c in ANIMALS:
            if not n_gt[c]:
                continue
            v = np.array(tp[c])
            hit = v[v > 0]
            print(f"  {model.names[c]:9s} {n_gt[c]:4d} boxes | matched at any conf: {len(hit):4d} "
                  f"| TP conf median {np.median(hit) if len(hit) else 0:.3f}, "
                  f"p90 {np.percentile(hit, 90) if len(hit) else 0:.3f}, "
                  f"< 0.05: {np.sum(hit < 0.05)}, >= {THRESH}: {np.sum(v >= THRESH)} "
                  f"(recall@{THRESH} {np.mean(v >= THRESH):.0%})")
            print(f"  {'':9s} missed at {THRESH}, other class there instead: {dict(confused[c])}")
        print(f"  animal predictions >= {THRESH} matching no box: {dict(fp_high)}\n")


if __name__ == "__main__":
    main()
