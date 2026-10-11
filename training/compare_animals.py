"""Compare detectors per class across the railway and animal test sets.

Each model is evaluated on:
  railway val        the real 43-frame validation split (railguard.yaml)
  synthetic test     held-out animals pasted on held-out frames (animal_test.yaml)
  wildlife test      held-out African Wildlife elephants (wildlife_elephant_test.yaml)
plus the confidence on the one real labelled railway elephant (frame_0050).

Usage (repo root):
    python training/compare_animals.py \
        --model baseline=models/railguard_best.pt \
        --model augmented=C:/Users/USER/runs/detect/railguard_animals/weights/best.pt
Writes outputs/evaluation/animal_comparison.md
"""
import argparse
import os

from ultralytics import YOLO

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
YOLO_DIR = os.path.join(ROOT, "data", "dataset", "yolo")
OUT_DIR = os.path.join(ROOT, "outputs", "evaluation")
DATASETS = {
    "railway val": "railguard.yaml",
    "synthetic test": "animal_test.yaml",
    "wildlife test": "wildlife_elephant_test.yaml",
}
REAL_ELEPHANT = ("frame_0050", 6)
IMGSZ = 1280


def evaluate(model, label, ds_name, yaml):
    m = model.val(data=yaml, imgsz=IMGSZ, batch=8, device=0, plots=False,
                  verbose=False, project=os.path.join(OUT_DIR, "compare"),
                  name=f"{label}_{ds_name.replace(' ', '_')}", exist_ok=True)
    per_class = {model.names[int(c)]: (m.box.ap50[i], m.box.ap[i])
                 for i, c in enumerate(m.box.ap_class_index)}
    return m.box.map50, m.box.map, per_class


def real_elephant_conf(model):
    """Best elephant confidence overlapping the labelled elephant in frame_0050."""
    stem, cls = REAL_ELEPHANT
    img = os.path.join(ROOT, "data", "dataset", "images", stem + ".jpg")
    gt = [l.split() for l in open(os.path.join(ROOT, "data", "dataset", "labels", stem + ".txt"))]
    gt = [tuple(map(float, g[1:])) for g in gt if int(g[0]) == cls][0]
    gx1, gy1, gx2, gy2 = gt[0] - gt[2] / 2, gt[1] - gt[3] / 2, gt[0] + gt[2] / 2, gt[1] + gt[3] / 2
    r = model.predict(img, imgsz=IMGSZ, conf=0.001, classes=[cls], verbose=False)[0]
    best = 0.0
    for (x1, y1, x2, y2), c in zip(r.boxes.xyxyn.tolist(), r.boxes.conf.tolist()):
        ix = max(0, min(x2, gx2) - max(x1, gx1))
        iy = max(0, min(y2, gy2) - max(y1, gy1))
        inter = ix * iy
        union = (x2 - x1) * (y2 - y1) + (gx2 - gx1) * (gy2 - gy1) - inter
        if union and inter / union > 0.3:
            best = max(best, c)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", action="append", metavar="LABEL=PATH",
                    help="model to compare; repeatable")
    args = ap.parse_args()
    models = dict(m.split("=", 1) for m in (args.model or
                  [f"baseline={os.path.join(ROOT, 'models', 'railguard_best.pt')}"]))

    datasets = {k: os.path.join(YOLO_DIR, v) for k, v in DATASETS.items()
                if os.path.exists(os.path.join(YOLO_DIR, v))}
    rows, real, order = {}, {}, []
    for label, path in models.items():
        model = YOLO(path)
        order = order or list(model.names.values())
        for ds_name, yaml in datasets.items():
            print(f"== {label} on {ds_name}")
            rows[(label, ds_name)] = evaluate(model, label, ds_name, yaml)
        real[label] = real_elephant_conf(model)

    lines = ["# Animal-class comparison", ""]
    for ds_name in datasets:
        classes = sorted({c for (_, d), (_, _, pc) in rows.items() if d == ds_name for c in pc},
                         key=order.index)
        lines += [f"## {ds_name}", "",
                  "| Model | mAP50 | mAP50-95 | " + " | ".join(f"{c} AP50" for c in classes) + " |",
                  "| :--- | ---: | ---: | " + " | ".join("---:" for _ in classes) + " |"]
        for label in models:
            map50, map5095, pc = rows[(label, ds_name)]
            cells = [f"{pc[c][0]:.3f}" if c in pc else "–" for c in classes]
            lines.append(f"| {label} | {map50:.3f} | {map5095:.3f} | " + " | ".join(cells) + " |")
        lines.append("")
    lines += ["## Real railway elephant (frame_0050)", "",
              "| Model | Best elephant confidence |", "| :--- | ---: |"]
    lines += [f"| {label} | {c:.3f} |" for label, c in real.items()]

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, "animal_comparison.md")
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"\nSaved {out}")


if __name__ == "__main__":
    main()
