"""Score a detector on the hand-labelled test sets (see training/manual_testset_rules.md).

    python training/eval_manual.py --model models/yolov8s.pt --out outputs/evaluation/manual_coco.csv
    python training/eval_manual.py --model runs/detect/railguard_animals/weights/best.pt \
        --out outputs/evaluation/manual_epoch1.csv

Three metrics per set, at the pipeline's confidence threshold (0.25) and IoU 0.5:
  class-aware recall      box found with the right class (per class and overall)
  class-agnostic recall   box found by any hazard-class detection (the headline)
  ... by size band        class-agnostic recall split by labelled box height

Predictions are matched to the 7 hazard classes by name, so stock COCO and
RailGuard models are scored the same way. Each prediction matches at most one
box (highest confidence first, to the best-overlapping unmatched box).
A set is skipped until every image in it has a label file.
"""

import argparse
import csv
import glob
import os

from ultralytics import YOLO

from tp_confidence import iou, labels_for  # training/tp_confidence.py

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETS = {
    "manual day": os.path.join(ROOT, "data", "dataset", "testset_manual"),
    "manual night": os.path.join(ROOT, "data", "dataset", "testset_night"),
}
NAMES = ["person", "car", "motorcycle", "bus", "truck", "cow", "elephant"]
THRESH = 0.25   # PipelineConfig.conf_threshold
MIN_TO_RANK = 20   # fewer boxes than this in a class or band: report it, don't rank models on it
BANDS = [(0, 20, "<20 px"), (20, 50, "20-50 px"), (50, 100, "50-100 px"), (100, 1e9, ">100 px")]


def match(preds, gts, class_aware):
    """preds: [(conf, cls, box)], gts: [(cls, box)] -> set of matched gt indices."""
    hit = set()
    for _, pc, pb in sorted(preds, reverse=True):
        best, best_j = 0.5, None
        for j, (gc, gb) in enumerate(gts):
            if j in hit or (class_aware and gc != pc):
                continue
            o = iou(pb, gb)
            if o >= best:
                best, best_j = o, j
        if best_j is not None:
            hit.add(best_j)
    return hit


def score_set(model, folder, imgsz):
    images = sorted(glob.glob(os.path.join(folder, "images", "*.jpg")))
    missing = [p for p in images if not os.path.exists(
        os.path.join(folder, "labels", os.path.splitext(os.path.basename(p))[0] + ".txt"))]
    if not images or missing:
        return None, f"{len(images) - len(missing)}/{len(images)} images labelled"

    to_ds = {i: NAMES.index(n) for i, n in model.names.items() if n in NAMES}
    n_cls, hit_cls = [0] * 7, [0] * 7
    n_band, hit_band = [0] * len(BANDS), [0] * len(BANDS)
    n_all = hit_aware = hit_agn = 0
    for img in images:
        gts = labels_for(img)
        r = model.predict(img, imgsz=imgsz, conf=THRESH, verbose=False)[0]
        h = r.orig_shape[0]
        preds = [(c, to_ds[k], b) for c, k, b in zip(r.boxes.conf.tolist(), r.boxes.cls.int().tolist(),
                                                     r.boxes.xyxyn.tolist()) if k in to_ds]
        aware = match(preds, gts, class_aware=True)
        agn = match(preds, gts, class_aware=False)
        for j, (c, b) in enumerate(gts):
            n_all += 1
            n_cls[c] += 1
            hit_cls[c] += j in aware
            hit_aware += j in aware
            hit_agn += j in agn
            px = (b[3] - b[1]) * h
            k = next(i for i, (lo, hi, _) in enumerate(BANDS) if lo <= px < hi)
            n_band[k] += 1
            hit_band[k] += j in agn

    rows = []
    rate = lambda a, n: round(a / n, 3) if n else ""
    for c in range(7):
        if n_cls[c]:
            rows.append(("class-aware recall", NAMES[c], n_cls[c], rate(hit_cls[c], n_cls[c])))
    rows.append(("class-aware recall", "all", n_all, rate(hit_aware, n_all)))
    rows.append(("class-agnostic recall", "all", n_all, rate(hit_agn, n_all)))
    for (lo, hi, label), n, a in zip(BANDS, n_band, hit_band):
        rows.append(("class-agnostic recall", label, n, rate(a, n)))
    return rows, f"{len(images)} images, {n_all} boxes"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", required=True, help="output .csv")
    ap.add_argument("--imgsz", type=int, default=1280)
    ap.add_argument("--sets", nargs="*", default=list(SETS), help="which sets (default: all)")
    args = ap.parse_args()

    model = YOLO(args.model)
    out_rows = []
    print(f"Model: {args.model}  ({len(model.names)} classes), conf >= {THRESH}, IoU >= 0.5")
    for name in args.sets:
        rows, note = score_set(model, SETS[name], args.imgsz)
        print(f"\n== {name}: {note}")
        if rows is None:
            print("   skipped: label every image first")
            continue
        print(f"   {'metric':24s}{'subset':12s}{'boxes':>7s}{'recall':>9s}")
        for metric, subset, n, rec in rows:
            few = n < MIN_TO_RANK
            print(f"   {metric:24s}{subset:12s}{n:>7d}{str(rec):>9s}"
                  + (f"   too few boxes to rank models (< {MIN_TO_RANK})" if few and n else ""))
            out_rows.append({"set": name, "metric": metric, "subset": subset,
                             "boxes": n, "recall": rec, "too_few_to_rank": int(few)})

    if out_rows:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", newline="") as f:
            wr = csv.DictWriter(f, fieldnames=list(out_rows[0]))
            wr.writeheader()
            wr.writerows(out_rows)
        print(f"\nSaved {args.out}")
    else:
        print("\nNothing scored yet; no file written.")


if __name__ == "__main__":
    main()
