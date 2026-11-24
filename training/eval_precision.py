"""Recall AND precision on the hand-labelled test sets, plain against tiled.

    python training/eval_precision.py --model models/yolov8s.pt

Why this exists
---------------
Every figure produced on 24 November 2026 was recall. Recall alone cannot
distinguish a detector that finds more real objects from one that simply emits
more boxes: a detector that fires everywhere scores 1.0. Tiled inference on a
100-frame clip reported 30 cars where single-pass reported 1, and nothing we
had measured could say whether those were vehicles or noise.

This is measurable here only because the hand-labelled sets are EXHAUSTIVE:
every object in those frames was marked by hand (training/manual_testset_rules.md).
So a prediction matching no labelled box is a false positive, not an unlabelled
object. The same claim could not be made against Open Images, which labels only
some instances per image.

For a braking system precision is the half that decides whether the system is
trusted. A missed hazard is dangerous once; an alarm that is usually wrong gets
the system switched off, and then every hazard is missed.

Reported per mode:
  recall      labelled boxes found
  precision   predictions that correspond to a labelled box
  FP/frame    false positives per frame, the number a driver experiences
"""

import argparse
import csv
import glob
import os

from ultralytics import YOLO

from eval_manual import NAMES, SETS, THRESH, match, wilson_ci
from eval_tiled import predict_tiled
from tp_confidence import labels_for


def count(model, folder, imgsz, conf, min_iou, tiled, cols, rows, overlap):
    images = sorted(glob.glob(os.path.join(folder, "images", "*.jpg")))
    images = [p for p in images if os.path.exists(
        os.path.join(folder, "labels", os.path.splitext(os.path.basename(p))[0] + ".txt"))]
    n_gt = n_pred = hit = 0
    for img in images:
        gts = labels_for(img)
        if tiled:
            preds, _ = predict_tiled(model, img, imgsz, conf, cols, rows, overlap, True)
        else:
            to_ds = {i: NAMES.index(n) for i, n in model.names.items() if n in NAMES}
            r = model.predict(img, imgsz=imgsz, conf=conf, verbose=False)[0]
            preds = [(c, to_ds[k], b) for c, k, b in zip(
                r.boxes.conf.tolist(), r.boxes.cls.int().tolist(), r.boxes.xyxyn.tolist())
                if k in to_ds]
        agn = match(preds, gts, class_aware=False, min_iou=min_iou)
        n_gt += len(gts)
        n_pred += len(preds)
        hit += len(agn)
    return len(images), n_gt, n_pred, hit


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default="models/yolov8s.pt")
    ap.add_argument("--out", default="outputs/evaluation/precision_plain_vs_tiled.csv")
    ap.add_argument("--imgsz", type=int, default=1280)
    ap.add_argument("--cols", type=int, default=2)
    ap.add_argument("--rows", type=int, default=2)
    ap.add_argument("--overlap", type=float, default=0.2)
    ap.add_argument("--sets", nargs="*", default=["manual day"])
    ap.add_argument("--conf", type=float, default=THRESH)
    ap.add_argument("--iou", type=float, default=0.5)
    args = ap.parse_args()

    model = YOLO(args.model)
    print(f"Model: {args.model}, conf >= {args.conf}, IoU >= {args.iou}")
    print("Hand-labelled sets are exhaustive, so a prediction matching no label is a "
          "false positive.\n")

    rows_out = []
    for name in args.sets:
        print(f"== {name}")
        print(f"   {'mode':<14}{'frames':>7}{'labels':>8}{'preds':>7}{'hits':>6}"
              f"{'recall':>9}{'precision':>11}{'FP/frame':>10}")
        for mode, tiled in (("single pass", False), (f"{args.cols}x{args.rows} tiled", True)):
            frames, n_gt, n_pred, hit = count(model, SETS[name], args.imgsz, args.conf,
                                              args.iou, tiled, args.cols, args.rows, args.overlap)
            if not frames:
                print(f"   {mode:<14} no labelled images")
                continue
            rec = hit / n_gt if n_gt else 0.0
            prec = hit / n_pred if n_pred else 0.0
            fp = (n_pred - hit) / frames
            rlo, rhi = wilson_ci(hit, n_gt)
            plo, phi = wilson_ci(hit, n_pred)
            print(f"   {mode:<14}{frames:>7}{n_gt:>8}{n_pred:>7}{hit:>6}"
                  f"{rec:>9.3f}{prec:>11.3f}{fp:>10.2f}")
            print(f"   {'':<14}{'':>7}{'':>8}{'':>7}{'':>6}"
                  f"{f'[{rlo},{rhi}]':>9}{f'[{plo},{phi}]':>11}")
            rows_out.append([name, mode, frames, n_gt, n_pred, hit,
                             round(rec, 3), rlo, rhi, round(prec, 3), plo, phi, round(fp, 2)])
        print()

    if rows_out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["set", "mode", "frames", "labelled_boxes", "predictions", "matched",
                        "recall", "recall_ci_low", "recall_ci_high",
                        "precision", "precision_ci_low", "precision_ci_high", "fp_per_frame"])
            w.writerows(rows_out)
        print(f"Saved {args.out}")


if __name__ == "__main__":
    main()
