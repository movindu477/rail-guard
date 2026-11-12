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

By default a set is skipped until every image in it has a label file.
--labelled-only scores just the images that have one, and always says how many:
"scored on 25 of 57 images (labelled subset)" on screen, and images_scored /
images_in_set in every CSV row, so a figure cannot be quoted without its sample
size. It refuses a set with fewer than 10 labelled images.
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
MIN_LABELLED = 10  # --labelled-only: fewer labelled images than this and the set is not scored


def match(preds, gts, class_aware, min_iou=0.5):
    """preds: [(conf, cls, box)], gts: [(cls, box)] -> set of matched gt indices."""
    hit = set()
    for _, pc, pb in sorted(preds, reverse=True):
        best, best_j = min_iou, None
        for j, (gc, gb) in enumerate(gts):
            if j in hit or (class_aware and gc != pc):
                continue
            o = iou(pb, gb)
            if o >= best:
                best, best_j = o, j
        if best_j is not None:
            hit.add(best_j)
    return hit


def score_set(model, folder, imgsz, labelled_only=False, conf=THRESH, min_iou=0.5):
    """Returns (rows, note, images_scored, images_in_set); rows is None if the
    set is not scored (and note says why)."""
    all_images = sorted(glob.glob(os.path.join(folder, "images", "*.jpg")))
    labelled = [p for p in all_images if os.path.exists(
        os.path.join(folder, "labels", os.path.splitext(os.path.basename(p))[0] + ".txt"))]
    total = len(all_images)
    if labelled_only:
        if not labelled:
            return None, f"0 of {total} images labelled: skipped", 0, total
        if len(labelled) < MIN_LABELLED:
            return (None, f"only {len(labelled)} of {total} images labelled: refused "
                    f"(--labelled-only needs at least {MIN_LABELLED})", 0, total)
        images = labelled
    else:
        if not all_images or len(labelled) < total:
            return (None, f"{len(labelled)}/{total} images labelled: skipped, label every image "
                    f"first (or use --labelled-only)", 0, total)
        images = all_images

    to_ds = {i: NAMES.index(n) for i, n in model.names.items() if n in NAMES}
    n_cls, hit_cls = [0] * 7, [0] * 7
    n_band, hit_band = [0] * len(BANDS), [0] * len(BANDS)
    n_all = hit_aware = hit_agn = 0
    for img in images:
        gts = labels_for(img)
        r = model.predict(img, imgsz=imgsz, conf=conf, verbose=False)[0]
        h = r.orig_shape[0]
        preds = [(c, to_ds[k], b) for c, k, b in zip(r.boxes.conf.tolist(), r.boxes.cls.int().tolist(),
                                                     r.boxes.xyxyn.tolist()) if k in to_ds]
        aware = match(preds, gts, class_aware=True, min_iou=min_iou)
        agn = match(preds, gts, class_aware=False, min_iou=min_iou)
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
    scope = (f"scored on {len(images)} of {total} images (labelled subset)"
             if len(images) < total else f"scored on all {total} images")
    return rows, f"{scope}, {n_all} boxes", len(images), total


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", required=True, help="output .csv")
    ap.add_argument("--imgsz", type=int, default=1280)
    ap.add_argument("--sets", nargs="*", default=list(SETS), help="which sets (default: all)")
    ap.add_argument("--conf", type=float, default=THRESH,
                    help=f"confidence threshold (default {THRESH}, the pipeline's; other values are diagnostics)")
    ap.add_argument("--iou", type=float, default=0.5,
                    help="IoU needed to count a box as found (default 0.5; other values are diagnostics)")
    ap.add_argument("--labelled-only", action="store_true",
                    help="score only images that have a label file (says how many; "
                         f"needs at least {MIN_LABELLED})")
    args = ap.parse_args()

    model = YOLO(args.model)
    out_rows = []
    print(f"Model: {args.model}  ({len(model.names)} classes), conf >= {args.conf}, IoU >= {args.iou}"
          + ("   [diagnostic settings, not the pipeline's]" if (args.conf, args.iou) != (THRESH, 0.5) else ""))
    for name in args.sets:
        rows, note, scored, total = score_set(model, SETS[name], args.imgsz, args.labelled_only,
                                              args.conf, args.iou)
        print(f"\n== {name}: {note}")
        if rows is None:
            continue
        print(f"   {'metric':24s}{'subset':12s}{'boxes':>7s}{'recall':>9s}")
        for metric, subset, n, rec in rows:
            few = n < MIN_TO_RANK
            print(f"   {metric:24s}{subset:12s}{n:>7d}{str(rec):>9s}"
                  + (f"   too few boxes to rank models (< {MIN_TO_RANK})" if few and n else ""))
            out_rows.append({"set": name, "images_scored": scored, "images_in_set": total,
                             "conf": args.conf, "iou": args.iou,
                             "metric": metric, "subset": subset,
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
