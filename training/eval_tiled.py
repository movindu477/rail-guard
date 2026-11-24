"""Score a detector with tiled (sliced) inference on the hand-labelled test sets.

    python training/eval_tiled.py --model models/yolov8x.pt --out outputs/evaluation/manual_v8x_tiled.csv

Why this exists
---------------
Two independent sweeps found that distant hazards are missed no matter what:

  input resolution  1280 / 1536 / 1920   -> 20-50 px recall 0.083 / 0.042 / 0.083
  model capacity    yolov8 s / m / l / x -> 20-50 px recall 0.083 / 0.042 / 0.042 / 0.083

Neither lever moves the small-object band. Tiling is the third lever and the
standard remedy: cut the frame into overlapping tiles and run the detector on
each one, so a 30 px object is fed to the network at the size of a 120 px
object. The cost is one forward pass per tile.

The full frame is ALWAYS scored as well, and the two sets of boxes are merged
with non-maximum suppression, so an object larger than a tile is not lost.

Scoring is identical to eval_manual.py (same matching, same bands, same Wilson
intervals), so the numbers are directly comparable; only the prediction step
differs. Run eval_manual.py on the same model first and compare like with like.
"""

import argparse
import csv
import glob
import math
import os

import cv2
from ultralytics import YOLO

from eval_manual import BANDS, MIN_TO_RANK, NAMES, SETS, THRESH, match, wilson_ci
from tp_confidence import labels_for


def nms(preds, thresh=0.6, contain=0.8):
    """preds: [(conf, cls, (x1,y1,x2,y2))] in pixels. Greedy, class-wise.

    Suppresses on IoU (the same object seen in two passes) and on containment
    (a tile-edge fragment sitting inside a whole box, which has low IoU with it
    and so survives plain NMS). Mirrors railguard/detection/tiled.py so the
    measurement and the pipeline agree.
    """
    keep = []
    for conf, cls, box in sorted(preds, reverse=True, key=lambda p: p[0]):
        x1, y1, x2, y2 = box
        area = max(1e-9, (x2 - x1) * (y2 - y1))
        drop = False
        for kc, kcls, kb in keep:
            if kcls != cls:
                continue
            ix1, iy1 = max(x1, kb[0]), max(y1, kb[1])
            ix2, iy2 = min(x2, kb[2]), min(y2, kb[3])
            iw, ih = max(0.0, ix2 - ix1), max(0.0, iy2 - iy1)
            inter = iw * ih
            if inter <= 0:
                continue
            union = (x2 - x1) * (y2 - y1) + (kb[2] - kb[0]) * (kb[3] - kb[1]) - inter
            if (union > 0 and inter / union >= thresh) or inter / area >= contain:
                drop = True
                break
        if not drop:
            keep.append((conf, cls, box))
    return keep


def tiles_for(w, h, cols, rows, overlap):
    """Tile rectangles in pixels, overlapping by `overlap` of a tile side."""
    tw, th = w / cols, h / rows
    ox, oy = tw * overlap, th * overlap
    out = []
    for r in range(rows):
        for c in range(cols):
            x0 = max(0, int(c * tw - ox))
            y0 = max(0, int(r * th - oy))
            x1 = min(w, int((c + 1) * tw + ox))
            y1 = min(h, int((r + 1) * th + oy))
            out.append((x0, y0, x1, y1))
    return out


def predict_tiled(model, img_path, imgsz, conf, cols, rows, overlap, full_frame=True):
    """Returns preds as [(conf, our_cls, normalised xyxy)] for the whole frame."""
    im = cv2.imread(img_path)
    if im is None:
        raise RuntimeError(f"could not read {img_path}")
    h, w = im.shape[:2]
    to_ds = {i: NAMES.index(n) for i, n in model.names.items() if n in NAMES}

    crops, offsets = [], []
    if full_frame:
        crops.append(im)
        offsets.append((0, 0))
    for x0, y0, x1, y1 in tiles_for(w, h, cols, rows, overlap):
        crops.append(im[y0:y1, x0:x1])
        offsets.append((x0, y0))

    raw = []
    for crop, (ox, oy) in zip(crops, offsets):
        r = model.predict(crop, imgsz=imgsz, conf=conf, verbose=False)[0]
        for c, k, b in zip(r.boxes.conf.tolist(), r.boxes.cls.int().tolist(), r.boxes.xyxy.tolist()):
            if k in to_ds:
                raw.append((c, to_ds[k], (b[0] + ox, b[1] + oy, b[2] + ox, b[3] + oy)))

    return [(c, k, (b[0] / w, b[1] / h, b[2] / w, b[3] / h)) for c, k, b in nms(raw)], h


def score_set(model, folder, imgsz, cols, rows, overlap, full_frame, conf, min_iou):
    all_images = sorted(glob.glob(os.path.join(folder, "images", "*.jpg")))
    labelled = [p for p in all_images if os.path.exists(
        os.path.join(folder, "labels", os.path.splitext(os.path.basename(p))[0] + ".txt"))]
    if not all_images or len(labelled) < len(all_images):
        return None, f"{len(labelled)}/{len(all_images)} images labelled: skipped", 0, len(all_images)

    n_cls, hit_cls = [0] * 7, [0] * 7
    n_band, hit_band = [0] * len(BANDS), [0] * len(BANDS)
    n_all = hit_aware = hit_agn = 0
    for img in all_images:
        gts = labels_for(img)
        preds, h = predict_tiled(model, img, imgsz, conf, cols, rows, overlap, full_frame)
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

    rows_out = []
    rate = lambda a, n: round(a / n, 3) if n else ""
    for c in range(7):
        if n_cls[c]:
            lo, hi = wilson_ci(hit_cls[c], n_cls[c])
            rows_out.append(("class-aware recall", NAMES[c], n_cls[c], rate(hit_cls[c], n_cls[c]), lo, hi))
    lo, hi = wilson_ci(hit_aware, n_all)
    rows_out.append(("class-aware recall", "all", n_all, rate(hit_aware, n_all), lo, hi))
    lo, hi = wilson_ci(hit_agn, n_all)
    rows_out.append(("class-agnostic recall", "all", n_all, rate(hit_agn, n_all), lo, hi))
    for (blo, bhi, label), n, a in zip(BANDS, n_band, hit_band):
        lo, hi = wilson_ci(a, n)
        rows_out.append(("class-agnostic recall", label, n, rate(a, n), lo, hi))
    return rows_out, f"scored on all {len(all_images)} images, {n_all} boxes", len(all_images), len(all_images)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", required=True, help="output .csv")
    ap.add_argument("--imgsz", type=int, default=1280)
    ap.add_argument("--cols", type=int, default=2)
    ap.add_argument("--rows", type=int, default=2)
    ap.add_argument("--overlap", type=float, default=0.2,
                    help="tile overlap as a fraction of a tile side (default 0.2)")
    ap.add_argument("--no-full-frame", action="store_true",
                    help="tiles only; by default the whole frame is scored too and merged")
    ap.add_argument("--sets", nargs="*", default=list(SETS))
    ap.add_argument("--conf", type=float, default=THRESH)
    ap.add_argument("--iou", type=float, default=0.5)
    args = ap.parse_args()

    model = YOLO(args.model)
    full = not args.no_full_frame
    n_passes = args.cols * args.rows + (1 if full else 0)
    print(f"Model: {args.model}  ({len(model.names)} classes), conf >= {args.conf}, IoU >= {args.iou}")
    print(f"Tiling: {args.cols}x{args.rows}, overlap {args.overlap:g}, "
          f"full frame {'included' if full else 'excluded'} -> {n_passes} passes per image")

    out_rows = []
    for name in args.sets:
        rows, note, scored, total = score_set(
            model, SETS[name], args.imgsz, args.cols, args.rows, args.overlap, full,
            args.conf, args.iou)
        print(f"\n== {name}: {note}")
        if rows is None:
            continue
        print(f"   {'metric':<23} {'subset':<13} {'boxes':>5}  {'recall':>7}  {'95% CI':>17}")
        for metric, subset, n, r, lo, hi in rows:
            flag = "   too few boxes to rank models (< %d)" % MIN_TO_RANK if 0 < n < MIN_TO_RANK else ""
            ci = f"[{lo:.3f}, {hi:.3f}]" if lo != "" else ""
            print(f"   {metric:<23} {subset:<13} {n:>5}  {r:>7}  {ci:>17}{flag}")
            out_rows.append([name, scored, total, args.conf, args.iou,
                             f"{args.cols}x{args.rows}", args.overlap, full,
                             metric, subset, n, r, lo, hi,
                             1 if 0 < n < MIN_TO_RANK else 0])

    if out_rows:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["set", "images_scored", "images_in_set", "conf", "iou",
                        "tiling", "overlap", "full_frame_included",
                        "metric", "subset", "boxes", "recall", "ci_low", "ci_high",
                        "too_few_to_rank"])
            w.writerows(out_rows)
        print(f"\nSaved {args.out}")


if __name__ == "__main__":
    main()
