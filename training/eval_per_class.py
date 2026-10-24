"""Per-class detection metrics on the locked test sets, for any YOLO model.

    python training/eval_per_class.py --model models/yolov8s.pt \
        --out outputs/evaluation/coco_metrics.csv
    python training/eval_per_class.py --model models/railguard_best.pt \
        --out outputs/evaluation/baseline_metrics.csv
    python training/eval_per_class.py --model runs/detect/<run>/weights/best.pt \
        --out outputs/evaluation/trained_metrics.csv

Predictions are matched to the dataset's classes BY NAME, so a stock COCO
model (cow = 19) and a RailGuard model (cow = 5) are scored the same way;
classes the dataset does not have are ignored. Matching and AP use
ultralytics' own code (validator.match_predictions, metrics.ap_per_class),
with predictions at conf 0.001, NMS IoU 0.7, max 300 per image.

Per (dataset, class): instances, mAP50, mAP50-95, and precision and recall at
the pipeline's 0.25 confidence threshold (mAP counts detections down to 0.001,
so it can look good at confidences the pipeline discards).

--with-val adds the railway val split. Only meaningful for models trained on
the current split: railguard_best.pt was trained before the re-split and has
seen many of today's val frames.
"""

import argparse
import csv
import glob
import os
from types import SimpleNamespace

import numpy as np
import torch
from ultralytics import YOLO
from ultralytics.engine.validator import BaseValidator
from ultralytics.utils.metrics import ap_per_class, box_iou

from tp_confidence import labels_for  # training/tp_confidence.py

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data", "dataset")
NAMES = ["person", "car", "motorcycle", "bus", "truck", "cow", "elephant"]
DATASETS = {
    "synthetic animals (test)": "synthetic/images/test",
    "wildlife elephants (test)": "wildlife_elephants/images/test",
}
RAILWAY_VAL = "yolo/images/val"
THRESH = 0.25  # PipelineConfig.conf_threshold
IOUV = torch.linspace(0.5, 0.95, 10)
_matcher = SimpleNamespace(iouv=IOUV)


def evaluate(model, folder, imgsz):
    to_ds = {i: NAMES.index(n) for i, n in model.names.items() if n in NAMES}
    tps, confs, pcls, tcls = [], [], [], []
    at = {c: {"tp": 0, "fp": 0} for c in range(len(NAMES))}
    for img in sorted(glob.glob(os.path.join(folder, "*.jpg"))):
        gts = labels_for(img)
        r = model.predict(img, imgsz=imgsz, conf=0.001, iou=0.7, max_det=300, verbose=False)[0]
        keep = [i for i, c in enumerate(r.boxes.cls.int().tolist()) if c in to_ds]
        boxes = r.boxes.xyxyn[keep].cpu()
        conf = r.boxes.conf[keep].cpu()
        pc = torch.tensor([to_ds[c] for c in r.boxes.cls.int()[keep].tolist()], dtype=torch.long)
        tc = torch.tensor([c for c, _ in gts], dtype=torch.long)
        tb = torch.tensor([g for _, g in gts], dtype=torch.float32).reshape(-1, 4)
        if len(pc):
            correct = (BaseValidator.match_predictions(_matcher, pc, tc, box_iou(tb, boxes))
                       if len(tc) else torch.zeros(len(pc), len(IOUV), dtype=torch.bool))
            tps.append(correct.numpy())
            confs.append(conf.numpy())
            pcls.append(pc.numpy())
            # precision/recall at the pipeline threshold, matched at IoU 0.5
            hi = conf >= THRESH
            if hi.any():
                c50 = (BaseValidator.match_predictions(_matcher, pc[hi], tc, box_iou(tb, boxes[hi]))[:, 0]
                       if len(tc) else torch.zeros(int(hi.sum()), dtype=torch.bool))
                for cls, ok in zip(pc[hi].tolist(), c50.tolist()):
                    at[cls]["tp" if ok else "fp"] += 1
        tcls.append(tc.numpy())

    tcls = np.concatenate(tcls)
    if not tps:
        return {}
    res = ap_per_class(np.concatenate(tps), np.concatenate(confs), np.concatenate(pcls), tcls)
    ap, classes = res[5], res[6]
    out = {}
    for i, c in enumerate(classes):
        n = int((tcls == c).sum())
        if n == 0:
            continue
        tp, fp = at[c]["tp"], at[c]["fp"]
        out[int(c)] = {"instances": n, "mAP50": float(ap[i, 0]), "mAP50-95": float(ap[i].mean()),
                       f"recall@{THRESH}": tp / n,
                       f"precision@{THRESH}": tp / (tp + fp) if tp + fp else 0.0}
    for c in set(tcls.tolist()) - set(out):  # never predicted at all
        out[int(c)] = {"instances": int((tcls == c).sum()), "mAP50": 0.0, "mAP50-95": 0.0,
                       f"recall@{THRESH}": 0.0, f"precision@{THRESH}": 0.0}
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", required=True, help="output .csv")
    ap.add_argument("--imgsz", type=int, default=1280)
    ap.add_argument("--with-val", action="store_true", help="also evaluate the railway val split")
    ap.add_argument("--val-only", action="store_true", help="evaluate only the railway val split")
    args = ap.parse_args()
    if args.val_only:
        datasets = {"railway val": RAILWAY_VAL}
    else:
        datasets = dict(DATASETS, **({"railway val": RAILWAY_VAL} if args.with_val else {}))

    model = YOLO(args.model)
    rows = []
    for ds, folder in datasets.items():
        for c, m in sorted(evaluate(model, os.path.join(DATA, folder), args.imgsz).items()):
            rows.append({"dataset": ds, "class": NAMES[c],
                         **{k: (round(v, 3) if isinstance(v, float) else v) for k, v in m.items()}})

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(rows[0]))
        wr.writeheader()
        wr.writerows(rows)

    print(f"\nModel: {args.model}  ({len(model.names)} classes)")
    keys = ["instances", "mAP50", "mAP50-95", f"recall@{THRESH}", f"precision@{THRESH}"]
    print(f"{'dataset':28s}{'class':12s}" + "".join(f"{k:>16s}" for k in keys))
    for r in rows:
        print(f"{r['dataset']:28s}{r['class']:12s}" + "".join(f"{r[k]:>16}" for k in keys))
    print(f"\nSaved {args.out}")


if __name__ == "__main__":
    main()
