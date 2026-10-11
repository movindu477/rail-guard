"""
Auto-label extracted frames using YOLOv8m to bootstrap the dataset.
Outputs YOLO-format label files that you then review/correct.
"""
import os
from ultralytics import YOLO

RAIL_GUARD_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGES_DIR = os.path.join(RAIL_GUARD_ROOT, "data", "dataset", "images")
LABELS_DIR = os.path.join(RAIL_GUARD_ROOT, "data", "dataset", "labels")
os.makedirs(LABELS_DIR, exist_ok=True)

# COCO class ids we care about -> remapped to our own 0..6
COCO_KEEP = {0: 0, 2: 1, 3: 2, 5: 3, 7: 4, 19: 5, 20: 6}
# 0 person, 1 car, 2 motorcycle, 3 bus, 4 truck, 5 cow, 6 elephant

model = YOLO(os.path.join(RAIL_GUARD_ROOT, "models", "yolov8m.pt"))  # downloads first run (~50MB)

imgs = [f for f in os.listdir(IMAGES_DIR) if f.lower().endswith((".jpg", ".png"))]
print(f"Labeling {len(imgs)} images...")

for i, fname in enumerate(imgs, 1):
    path = os.path.join(IMAGES_DIR, fname)
    r = model.predict(path, conf=0.25, imgsz=1280, device=0, verbose=False)[0]
    lines = []
    for box in r.boxes:
        cid = int(box.cls[0])
        if cid not in COCO_KEEP:
            continue
        x, y, bw, bh = box.xywhn[0].tolist()  # normalized cx,cy,w,h
        lines.append(f"{COCO_KEEP[cid]} {x:.6f} {y:.6f} {bw:.6f} {bh:.6f}")
    label_path = os.path.join(LABELS_DIR, os.path.splitext(fname)[0] + ".txt")
    with open(label_path, "w") as f:
        f.write("\n".join(lines))
    if i % 50 == 0:
        print(f"  {i}/{len(imgs)}")

print("Auto-labeling done. Labels in data/dataset/labels/")
