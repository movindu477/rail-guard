"""Prepare animal sources for RailGuard: elephants (African Wildlife) and cows (COCO).

Outputs (all under data/dataset/):
  wildlife_elephants/{images,labels}/{train,test}
      Elephant-only African Wildlife images, class remapped to RailGuard 6.
      Used for the raw-merge experiment and as a held-out elephant test set.
  animal_cutouts/{elephant,cow}/{train,test}/*.png
      RGBA cut-outs (segmentation-masked) for paste_augment.py.
      train/test come from the sources' own train/test splits, so test
      animals are never seen in training.

Masks come from a COCO-trained segmentation model, matched to the
ground-truth boxes; only whole, unoccluded, reasonably large animals are kept.

Run from the repo root:
    python training/prepare_animals.py
"""
import os
import random
import shutil
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np
from ultralytics import YOLO

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATASET = os.path.join(ROOT, "data", "dataset")
WILDLIFE = os.path.join(DATASET, "wildlife", "african-wildlife")
COCO = os.path.join(DATASET, "coco_cows", "coco")
OUT_ELEPHANTS = os.path.join(DATASET, "wildlife_elephants")
OUT_CUTOUTS = os.path.join(DATASET, "animal_cutouts")

SEG_MODEL = os.path.join(ROOT, "models", "yolo11m-seg.pt")
WILDLIFE_ELEPHANT = 1          # african-wildlife: buffalo, elephant, rhino, zebra
COCO_COW, COCO_ELEPHANT = 19, 20
RG_COW, RG_ELEPHANT = 5, 6     # RailGuard class ids

# Cut-out quality filters
MIN_SIDE_PX = 80               # animal box must be at least this big
BORDER_PX = 3                  # and not touch the image edge (truncated animal)
MAX_OVERLAP = 0.10             # other boxes may cover at most this share of it
MIN_FILL = 0.35                # mask pixels / box area
MIN_MAIN_COMPONENT = 0.85      # largest blob share of the mask (no fragments)
MATCH_IOU = 0.6                # seg box vs ground-truth box
MAX_CUTOUT_SIDE = 400          # cut-outs are only ever pasted smaller than this

# COCO images to fetch (individually, from the COCO image host)
COCO_MAX_IMAGES = {"train2017": 260, "val2017": 120}
COCO_URL = "http://images.cocodataset.org/{split}/{name}"

random.seed(0)


def read_labels(path):
    """YOLO label file -> list of (cls, cx, cy, w, h), normalised."""
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path):
        p = line.split()
        if len(p) >= 5:
            out.append((int(p[0]), *map(float, p[1:5])))
    return out


def to_xyxy(lbl, w, h):
    _, cx, cy, bw, bh = lbl
    return np.array([(cx - bw / 2) * w, (cy - bh / 2) * h,
                     (cx + bw / 2) * w, (cy + bh / 2) * h])


def iou(a, b):
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def covered_share(box, other):
    """Share of `box` area covered by `other`."""
    ix = max(0.0, min(box[2], other[2]) - max(box[0], other[0]))
    iy = max(0.0, min(box[3], other[3]) - max(box[1], other[1]))
    area = (box[2] - box[0]) * (box[3] - box[1])
    return ix * iy / area if area > 0 else 1.0


def good_box(box, others, w, h):
    """Whole, large enough, not truncated, not occluded."""
    x1, y1, x2, y2 = box
    if min(x2 - x1, y2 - y1) < MIN_SIDE_PX:
        return False
    if x1 < BORDER_PX or y1 < BORDER_PX or x2 > w - BORDER_PX or y2 > h - BORDER_PX:
        return False
    return all(covered_share(box, o) <= MAX_OVERLAP for o in others)


def extract_cutouts(seg, img_path, labels, target_cls, coco_cls, out_dir, prefix):
    """Save RGBA cut-outs for every good `target_cls` box in one image."""
    img = cv2.imread(img_path)
    if img is None:
        return 0
    h, w = img.shape[:2]
    boxes = [to_xyxy(l, w, h) for l in labels]
    targets = [i for i, l in enumerate(labels) if l[0] == target_cls
               and good_box(boxes[i], boxes[:i] + boxes[i + 1:], w, h)]
    if not targets:
        return 0

    r = seg.predict(img, classes=[coco_cls], conf=0.25, retina_masks=True,
                    verbose=False)[0]
    if r.masks is None:
        return 0
    seg_boxes = r.boxes.xyxy.cpu().numpy()
    seg_masks = r.masks.data.cpu().numpy() > 0.5

    saved = 0
    for i in targets:
        gt = boxes[i]
        ious = [iou(gt, sb) for sb in seg_boxes]
        if not ious or max(ious) < MATCH_IOU:
            continue
        mask = seg_masks[int(np.argmax(ious))]
        x1, y1, x2, y2 = gt.round().astype(int)
        mask = mask[y1:y2, x1:x2].astype(np.uint8)
        if mask.size == 0 or mask.mean() < MIN_FILL:
            continue
        n, cc, stats, _ = cv2.connectedComponentsWithStats(mask)
        if n < 2:
            continue
        areas = stats[1:, cv2.CC_STAT_AREA]
        if areas.max() / areas.sum() < MIN_MAIN_COMPONENT:
            continue
        mask = (cc == 1 + int(np.argmax(areas))).astype(np.uint8)

        # Crop tightly to the mask and store as RGBA
        ys, xs = np.nonzero(mask)
        mx1, mx2, my1, my2 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
        rgba = np.dstack([img[y1:y2, x1:x2], mask * 255])[my1:my2, mx1:mx2]
        scale = MAX_CUTOUT_SIDE / max(rgba.shape[:2])
        if scale < 1:
            rgba = cv2.resize(rgba, None, fx=scale, fy=scale,
                              interpolation=cv2.INTER_AREA)
        cv2.imwrite(os.path.join(out_dir, f"{prefix}_{i}.png"), rgba)
        saved += 1
    return saved


def reset_dir(path):
    if os.path.isdir(path):
        shutil.rmtree(path)
    os.makedirs(path)


def prepare_elephants(seg):
    """Elephant-only wildlife images (remapped to 6) + elephant cut-outs."""
    splits = {"train": ["train"], "test": ["val", "test"]}
    for out_split, src_splits in splits.items():
        img_out = os.path.join(OUT_ELEPHANTS, "images", out_split)
        lbl_out = os.path.join(OUT_ELEPHANTS, "labels", out_split)
        cut_out = os.path.join(OUT_CUTOUTS, "elephant", out_split)
        for d in (img_out, lbl_out, cut_out):
            reset_dir(d)

        n_img = n_cut = 0
        for s in src_splits:
            img_dir = os.path.join(WILDLIFE, "images", s)
            for f in sorted(os.listdir(img_dir)):
                stem = os.path.splitext(f)[0]
                labels = read_labels(os.path.join(WILDLIFE, "labels", s, stem + ".txt"))
                # Elephant-only images: other animals would become unlabelled
                # background (a buffalo taught as "not cow" would hurt).
                if not labels or any(l[0] != WILDLIFE_ELEPHANT for l in labels):
                    continue
                shutil.copy(os.path.join(img_dir, f), os.path.join(img_out, f))
                with open(os.path.join(lbl_out, stem + ".txt"), "w") as fh:
                    fh.write("\n".join(f"{RG_ELEPHANT} {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}"
                                       for _, cx, cy, w, h in labels))
                n_img += 1
                n_cut += extract_cutouts(seg, os.path.join(img_dir, f), labels,
                                         WILDLIFE_ELEPHANT, COCO_ELEPHANT,
                                         cut_out, f"{s}_{stem}")
        print(f"elephants {out_split}: {n_img} images, {n_cut} cut-outs")


def fetch(url, dst):
    if os.path.exists(dst):
        return dst
    try:
        urllib.request.urlretrieve(url, dst)
        return dst
    except Exception as e:
        print(f"  download failed {url}: {e}")
        return None


def prepare_cows(seg):
    """Cow cut-outs from COCO; images fetched one by one, not the full set."""
    for coco_split, out_split in (("train2017", "train"), ("val2017", "test")):
        lbl_dir = os.path.join(COCO, "labels", coco_split)
        img_dir = os.path.join(DATASET, "coco_cows", "images", coco_split)
        cut_out = os.path.join(OUT_CUTOUTS, "cow", out_split)
        os.makedirs(img_dir, exist_ok=True)
        reset_dir(cut_out)

        # Pre-filter on normalised boxes so only promising images are fetched
        candidates = []
        for f in sorted(os.listdir(lbl_dir)):
            labels = read_labels(os.path.join(lbl_dir, f))
            unit = [to_xyxy(l, 1, 1) for l in labels]
            for i, l in enumerate(labels):
                b = unit[i]
                if (l[0] == COCO_COW and min(l[3], l[4]) >= 0.15
                        and b[0] > 0.005 and b[1] > 0.005 and b[2] < 0.995 and b[3] < 0.995
                        and all(covered_share(b, o) <= MAX_OVERLAP
                                for o in unit[:i] + unit[i + 1:])):
                    candidates.append(f)
                    break
        random.shuffle(candidates)
        candidates = candidates[:COCO_MAX_IMAGES[coco_split]]
        print(f"cows {out_split}: fetching {len(candidates)} COCO images...")

        jobs = [(COCO_URL.format(split=coco_split, name=c[:-4] + ".jpg"),
                 os.path.join(img_dir, c[:-4] + ".jpg")) for c in candidates]
        with ThreadPoolExecutor(8) as ex:
            paths = list(ex.map(lambda j: fetch(*j), jobs))

        n_cut = 0
        for c, p in zip(candidates, paths):
            if p:
                labels = read_labels(os.path.join(lbl_dir, c))
                n_cut += extract_cutouts(seg, p, labels, COCO_COW, COCO_COW,
                                         cut_out, c[:-4])
        print(f"cows {out_split}: {n_cut} cut-outs")


def main():
    seg = YOLO(SEG_MODEL)  # downloads on first use
    prepare_elephants(seg)
    prepare_cows(seg)
    print(f"Done. Cut-outs in {OUT_CUTOUTS}")


if __name__ == "__main__":
    main()
