"""Draw hand labels and model boxes on the manual test frames, to check the scoring.

    python training/overlay_manual.py                       # stock COCO, 5 worst frames
    python training/overlay_manual.py --model models/railguard_best.pt --n 8

Green:  hand labels, with the best IoU any hazard-class prediction reaches.
Orange: model boxes of the 7 hazard classes (what eval_manual.py scores).
Grey:   model boxes of other classes (e.g. "train", "bench"): seen by the
        model but filtered out by RailGuard.
Frames are chosen by most labels missed at IoU 0.5, largest boxes first.
Also prints every label: class, height, best IoU, and the box that reached it.
Writes outputs/figures/manual_overlay/<frame>.png.
"""

import argparse
import glob
import os

import cv2
from ultralytics import YOLO

from tp_confidence import iou, labels_for  # training/tp_confidence.py

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DAY = os.path.join(ROOT, "data", "dataset", "testset_manual")
OUT = os.path.join(ROOT, "outputs", "figures", "manual_overlay")
NAMES = ["person", "car", "motorcycle", "bus", "truck", "cow", "elephant"]
GREEN, ORANGE, GREY = (60, 200, 60), (0, 140, 255), (170, 170, 170)


def text(img, s, x, y, colour, scale):
    th = max(1, int(scale * 2))
    (w, h), _ = cv2.getTextSize(s, cv2.FONT_HERSHEY_SIMPLEX, scale, th)
    y = max(h + 4, y)
    cv2.rectangle(img, (x, y - h - 4), (x + w + 4, y + 2), (0, 0, 0), -1)
    cv2.putText(img, s, (x + 2, y - 2), cv2.FONT_HERSHEY_SIMPLEX, scale, colour, th, cv2.LINE_AA)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=os.path.join(ROOT, "models", "yolov8s.pt"))
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--imgsz", type=int, default=1280)
    ap.add_argument("--n", type=int, default=5, help="frames to draw")
    args = ap.parse_args()

    model = YOLO(args.model)
    images = [p for p in sorted(glob.glob(os.path.join(DAY, "images", "*.jpg")))
              if os.path.exists(os.path.join(DAY, "labels", os.path.splitext(os.path.basename(p))[0] + ".txt"))]
    frames = []
    print(f"{'frame':12s}{'label':12s}{'h px':>6s}{'best IoU':>9s}  best hazard box        best any-class box")
    for img in images:
        gts = labels_for(img)
        if not gts:
            continue
        r = model.predict(img, imgsz=args.imgsz, conf=args.conf, verbose=False)[0]
        H, W = r.orig_shape
        preds = [(model.names[k], c, b) for k, c, b in zip(r.boxes.cls.int().tolist(),
                 r.boxes.conf.tolist(), r.boxes.xyxyn.tolist())]
        info, missed = [], []
        for c, b in gts:
            hz = max(((iou(b, pb), n, pc) for n, pc, pb in preds if n in NAMES), default=(0, "-", 0))
            anyc = max(((iou(b, pb), n, pc) for n, pc, pb in preds), default=(0, "-", 0))
            hpx = (b[3] - b[1]) * H
            info.append((c, b, hz[0]))
            if hz[0] < 0.5:
                missed.append(hpx)
            print(f"{os.path.basename(img)[:-4]:12s}{NAMES[c]:12s}{hpx:6.0f}{hz[0]:9.2f}  "
                  f"{hz[1]:>10s} {hz[2]:.2f}       {anyc[1]:>10s} {anyc[2]:.2f} IoU {anyc[0]:.2f}")
        frames.append((len(missed), sum(missed), img, info, preds, W, H))

    os.makedirs(OUT, exist_ok=True)
    frames.sort(key=lambda f: (f[0], f[1]), reverse=True)
    for n_missed, _, img, info, preds, W, H in frames[:args.n]:
        im = cv2.imread(img)
        s = max(1.0, W / 1280)
        lw = max(2, int(2 * s))
        for name, pc, (x1, y1, x2, y2) in preds:
            col = ORANGE if name in NAMES else GREY
            p1, p2 = (int(x1 * W), int(y1 * H)), (int(x2 * W), int(y2 * H))
            cv2.rectangle(im, p1, p2, col, lw)
            text(im, f"{name} {pc:.2f}", p1[0], p2[1] + int(22 * s), col, 0.55 * s)
        for c, (x1, y1, x2, y2), best in info:
            p1, p2 = (int(x1 * W), int(y1 * H)), (int(x2 * W), int(y2 * H))
            cv2.rectangle(im, p1, p2, GREEN, lw)
            text(im, f"LABEL {NAMES[c]} IoU {best:.2f}", p1[0], p1[1] - 4, GREEN, 0.55 * s)
        text(im, f"{os.path.basename(img)}  green: labels  orange: hazard-class predictions  "
                 f"grey: other classes  (conf >= {args.conf})", 10, int(30 * s), (255, 255, 255), 0.6 * s)
        out = os.path.join(OUT, os.path.basename(img)[:-4] + ".png")
        cv2.imwrite(out, im if W <= 1600 else cv2.resize(im, (1600, int(H * 1600 / W))))
        print(f"wrote {out}  ({n_missed} labels missed)")


if __name__ == "__main__":
    main()
