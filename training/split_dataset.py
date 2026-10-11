"""Split annotated frames into train/val sets for YOLO fine-tuning.

Also adds object-free frames as negatives and writes the dataset configs:
  yolo/railguard.yaml                 original real-data split (baseline)
  yolo/railguard_animals.yaml         + negatives + synthetic animals (paste_augment.py)
  yolo/railguard_raw_elephants.yaml   + raw African Wildlife elephants (prepare_animals.py)
  yolo/animal_test.yaml               held-out synthetic animals, for evaluation
  yolo/wildlife_elephant_test.yaml    held-out wildlife elephants, for evaluation
The optional configs are only written when their data exists.
Run paste_augment.py first so negatives never reuse a pasted frame.
"""
import os, shutil, random

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATASET = os.path.join(ROOT, "data", "dataset")
IMG = os.path.join(DATASET, "images")
LBL = os.path.join(DATASET, "labels")
OUT = os.path.join(DATASET, "yolo")
SYNTH = os.path.join(DATASET, "synthetic")
ELEPHANTS = os.path.join(DATASET, "wildlife_elephants")

# Object-free frames as a share of the final (augmented) training set
NEG_FRAC = 0.12

NAMES = """names:
  0: person
  1: car
  2: motorcycle
  3: bus
  4: truck
  5: cow
  6: elephant
"""

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


def count_images(path):
    return len(os.listdir(path)) if os.path.isdir(path) else 0


# ---- Negatives: object-free frames not already used for pasting ----
used_path = os.path.join(SYNTH, "used_frames.txt")
used = set(open(used_path).read().split()) if os.path.exists(used_path) else set()
empty = sorted(f for f in os.listdir(IMG)
               if f.lower().endswith((".jpg", ".png"))
               and os.path.splitext(f)[0] not in used
               and os.path.exists(os.path.join(LBL, os.path.splitext(f)[0] + ".txt"))
               and os.path.getsize(os.path.join(LBL, os.path.splitext(f)[0] + ".txt")) == 0)

n_synth = count_images(os.path.join(SYNTH, "images", "train"))
n_neg = min(len(empty), round(NEG_FRAC / (1 - NEG_FRAC) * (len(train) + n_synth)))
negatives = random.Random(0).sample(empty, n_neg)

for kind in ("images", "labels"):
    d = os.path.join(OUT, kind, "negatives")
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(d)
for f in negatives:
    shutil.copy(os.path.join(IMG, f), os.path.join(OUT, "images", "negatives", f))
    open(os.path.join(OUT, "labels", "negatives", os.path.splitext(f)[0] + ".txt"), "w").close()
print(f"Negatives: {n_neg} of {len(empty)} free empty frames "
      f"({NEG_FRAC:.0%} of {len(train) + n_synth + n_neg} training images)")


# ---- Dataset configs ----
def write_yaml(name, path, train_dirs, val_dirs):
    fmt = lambda dirs: dirs[0] if len(dirs) == 1 else "[" + ", ".join(dirs) + "]"
    with open(os.path.join(OUT, name), "w") as f:
        f.write(f"path: {path}\ntrain: {fmt(train_dirs)}\nval: {fmt(val_dirs)}\n{NAMES}")
    print(f"Config: {os.path.join(OUT, name)}")


write_yaml("railguard.yaml", OUT, ["images/train"], ["images/val"])
if n_synth:
    write_yaml("railguard_animals.yaml", DATASET,
               ["yolo/images/train", "yolo/images/negatives", "synthetic/images/train"],
               ["yolo/images/val"])
if count_images(os.path.join(SYNTH, "images", "test")):
    write_yaml("animal_test.yaml", DATASET, ["synthetic/images/test"],
               ["synthetic/images/test"])
if count_images(os.path.join(ELEPHANTS, "images", "train")):
    write_yaml("railguard_raw_elephants.yaml", DATASET,
               ["yolo/images/train", "wildlife_elephants/images/train"],
               ["yolo/images/val"])
if count_images(os.path.join(ELEPHANTS, "images", "test")):
    write_yaml("wildlife_elephant_test.yaml", DATASET, ["wildlife_elephants/images/test"],
               ["wildlife_elephants/images/test"])
