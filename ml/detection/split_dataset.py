"""Split annotated frames into train/val sets for YOLO fine-tuning."""
import os, shutil, random

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
IMG = os.path.join(ROOT, "data", "dataset", "images")
LBL = os.path.join(ROOT, "data", "dataset", "labels")
OUT = os.path.join(ROOT, "data", "dataset", "yolo")

random.seed(42)

pairs = []
for f in os.listdir(IMG):
    if not f.lower().endswith((".jpg", ".png")):
        continue
    lbl = os.path.join(LBL, os.path.splitext(f)[0] + ".txt")
    if os.path.exists(lbl) and os.path.getsize(lbl) > 0:
        pairs.append(f)

random.shuffle(pairs)
split = int(len(pairs) * 0.8)
train, val = pairs[:split], pairs[split:]
print(f"Usable frames: {len(pairs)} | train: {len(train)} | val: {len(val)}")

for name, subset in [("train", train), ("val", val)]:
    os.makedirs(os.path.join(OUT, "images", name), exist_ok=True)
    os.makedirs(os.path.join(OUT, "labels", name), exist_ok=True)
    for f in subset:
        shutil.copy(os.path.join(IMG, f), os.path.join(OUT, "images", name, f))
        lbl = os.path.splitext(f)[0] + ".txt"
        shutil.copy(os.path.join(LBL, lbl), os.path.join(OUT, "labels", name, lbl))

yaml = f"""path: {OUT}
train: images/train
val: images/val
names:
  0: person
  1: car
  2: motorcycle
  3: bus
  4: truck
  5: cow
  6: elephant
"""
with open(os.path.join(OUT, "railguard.yaml"), "w") as f:
    f.write(yaml)
print(f"Done. Config: {os.path.join(OUT, 'railguard.yaml')}")
