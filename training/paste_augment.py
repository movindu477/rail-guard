"""Copy-paste augmentation: put elephants and cows on/near the track.

Animal cut-outs (from prepare_animals.py) are pasted onto the object-free
railway frames. TEP-Net finds the ego-track in each frame; the rail spacing
at an image row (1.676 m broad gauge) sets the pixel scale there, so each
animal is pasted at a physically plausible size for its distance:

    height_px = height_m * rail_width_px(row) / 1.676

Most animals stand on the track (inside the fusion corridor), the rest just
beside it. Labels are written automatically in YOLO format.

Outputs (data/dataset/synthetic/):
  images/{train,test}, labels/{train,test}
  manifest.csv     one row per pasted animal
  used_frames.txt  empty frames consumed here (split_dataset.py skips them)
And a visual check: outputs/training/synthetic_preview.jpg

Run from the repo root:
    python training/paste_augment.py
"""
import argparse
import csv
import math
import os
import random
import shutil

import cv2
import numpy as np
from PIL import Image

from railguard.core.geometry import (
    GAUGE_M, focal_from_fov, rail_width_by_row, track_centre_by_row)
from railguard.segmentation.tepnet import load_tepnet

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DATASET = os.path.join(ROOT, "data", "dataset")
FRAMES_IMG = os.path.join(DATASET, "images")
FRAMES_LBL = os.path.join(DATASET, "labels")
CUTOUTS = os.path.join(DATASET, "animal_cutouts")
OUT = os.path.join(DATASET, "synthetic")
PREVIEW = os.path.join(ROOT, "outputs", "training", "synthetic_preview.jpg")
TEPNET_MODEL = "chromatic-laughter-5"

# Per-class physical size and distance range
ANIMALS = {
    # name: (RailGuard class id, height range m, distance range m)
    "elephant": (6, (2.3, 3.2), (12.0, 150.0)),   # Asian elephant + head/back
    "cow":      (5, (1.1, 1.6), (10.0, 120.0)),   # local cattle
}
PER_FRAME = ([1, 2, 3], [0.4, 0.4, 0.2])  # animals per frame, weights
ON_TRACK_P = 0.7          # share placed inside the corridor, rest beside it
MIN_HEIGHT_PX = 14        # smaller is unlabelable noise
MAX_HEIGHT_FRAC = 0.7     # of frame height
MAX_PAIR_IOU = 0.05       # pasted animals in one frame barely overlap
MIN_TRACK_ROWS = 40       # frames where TEP-Net sees less track are skipped
MIN_WIDTH_ROW_CORR = 0.9  # rail spacing must widen steadily toward the camera
HORIZON_FRAC = 0.4        # no foot point above this share of frame height
ASSUMED_HFOV_DEG = 60.0   # same assumption as the fusion pipeline


def color_match(rgb, mask, region, strength=(0.5, 0.3, 0.3)):
    """Pull the cut-out's LAB mean/std part-way toward the local background."""
    src = cv2.cvtColor(rgb, cv2.COLOR_BGR2LAB).astype(np.float32)
    bg = cv2.cvtColor(region, cv2.COLOR_BGR2LAB).astype(np.float32).reshape(-1, 3)
    fg = src[mask > 0.5]
    if len(fg) < 10:
        return rgb
    for c, s in enumerate(strength):
        mu_f, sd_f = fg[:, c].mean(), fg[:, c].std() + 1e-6
        mu_b, sd_b = bg[:, c].mean(), bg[:, c].std() + 1e-6
        mu = mu_f + s * (mu_b - mu_f)
        sd = sd_f + s * (sd_b - sd_f)
        src[..., c] = (src[..., c] - mu_f) / sd_f * sd + mu
    return cv2.cvtColor(np.clip(src, 0, 255).astype(np.uint8), cv2.COLOR_LAB2BGR)


def paste(frame, cutout, x1, y1, w, h):
    """Composite a resized RGBA cut-out with a soft contact shadow.
    Returns the visible box (x1, y1, x2, y2) or None."""
    H, W = frame.shape[:2]
    obj = cv2.resize(cutout, (w, h), interpolation=cv2.INTER_AREA)
    rgb = cv2.GaussianBlur(obj[..., :3], (0, 0), 0.5)  # match video softness
    alpha = obj[..., 3].astype(np.float32) / 255.0
    alpha = cv2.GaussianBlur(alpha, (0, 0), max(0.6, h / 150.0))

    # Clip to frame
    fx1, fy1 = max(0, x1), max(0, y1)
    fx2, fy2 = min(W, x1 + w), min(H, y1 + h)
    if fx2 - fx1 < 2 or fy2 - fy1 < 2:
        return None
    ox1, oy1 = fx1 - x1, fy1 - y1
    ox2, oy2 = ox1 + (fx2 - fx1), oy1 + (fy2 - fy1)

    # Contact shadow: a soft dark ellipse under the feet
    sh = np.zeros((H, W), np.float32)
    cv2.ellipse(sh, (x1 + w // 2, y1 + h - max(1, h // 40)),
                (max(2, int(w * 0.45)), max(1, int(h * 0.06))), 0, 0, 360, 1.0, -1)
    sh = cv2.GaussianBlur(sh, (0, 0), max(1.0, h / 30.0))
    frame[:] = (frame * (1 - 0.35 * sh[..., None])).astype(np.uint8)

    region = frame[fy1:fy2, fx1:fx2]
    a = alpha[oy1:oy2, ox1:ox2, None]
    rgb = color_match(rgb[oy1:oy2, ox1:ox2], a[..., 0], region)
    frame[fy1:fy2, fx1:fx2] = (a * rgb + (1 - a) * region).astype(np.uint8)

    ys, xs = np.nonzero(a[..., 0] > 0.5)
    if len(xs) == 0:
        return None
    return (fx1 + xs.min(), fy1 + ys.min(), fx1 + xs.max() + 1, fy1 + ys.max() + 1)


def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union else 0.0


def plan_instance(name, cutout, centre, width, focal_px, W, H, rng):
    """Choose distance, row, lateral offset and size. None if no fit."""
    _, (hmin, hmax), (dmin, dmax) = ANIMALS[name]
    rows = np.nonzero(width > 1)[0]
    rows = rows[rows >= HORIZON_FRAC * H]
    if len(rows) == 0:
        return None
    for _ in range(30):
        d = math.exp(rng.uniform(math.log(dmin), math.log(dmax)))
        target_w = focal_px * GAUGE_M / d
        row = rows[np.argmin(np.abs(width[rows] - target_w))]
        if abs(width[row] - target_w) / target_w > 0.15:
            continue  # TEP-Net does not see the track that far/near
        px_per_m = width[row] / GAUGE_M
        h = int(rng.uniform(hmin, hmax) * px_per_m)
        w = int(h * cutout.shape[1] / cutout.shape[0])
        if h < MIN_HEIGHT_PX or h > MAX_HEIGHT_FRAC * H:
            continue
        on_track = rng.random() < ON_TRACK_P
        # Corridor half-width in fusion is 1.5 rail spacings
        off = (rng.uniform(-1.0, 1.0) if on_track
               else rng.choice([-1, 1]) * rng.uniform(1.8, 3.0)) * width[row]
        foot_x = centre[row] + off
        x1 = int(foot_x - w / 2)
        if x1 < -0.2 * w or x1 + w > W + 0.2 * w:
            continue
        return dict(x1=x1, y1=int(row) - h, w=w, h=h, distance=d,
                    on_track=on_track)
    return None


def plausible_track(width):
    """TEP-Net output is usable: enough rows, and wider nearer the camera."""
    rows = np.nonzero(width > 0)[0]
    if len(rows) < MIN_TRACK_ROWS:
        return False
    return np.corrcoef(rows, width[rows])[0, 1] >= MIN_WIDTH_ROW_CORR


def load_cutouts(name, split):
    d = os.path.join(CUTOUTS, name, split)
    files = sorted(f for f in os.listdir(d) if f.endswith(".png"))
    return [(f, cv2.imread(os.path.join(d, f), cv2.IMREAD_UNCHANGED)) for f in files]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--train-instances", type=int, default=180,
                    help="pasted animals per class in the training set")
    ap.add_argument("--test-instances", type=int, default=60,
                    help="pasted animals per class in the held-out test set")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    empty = sorted(f[:-4] for f in os.listdir(FRAMES_LBL)
                   if f.startswith("frame_") and os.path.getsize(os.path.join(FRAMES_LBL, f)) == 0)
    rng.shuffle(empty)
    print(f"{len(empty)} empty frames available")

    for split in ("train", "test"):
        for kind in ("images", "labels"):
            d = os.path.join(OUT, kind, split)
            if os.path.isdir(d):
                shutil.rmtree(d)
            os.makedirs(d)

    tepnet = load_tepnet(TEPNET_MODEL, "cuda")
    focal_px = None
    used, manifest, previews = [], [], []
    pool = iter(empty)

    for split, target in (("train", args.train_instances), ("test", args.test_instances)):
        for name, (cls, _, _) in ANIMALS.items():
            cutouts = load_cutouts(name, split)
            print(f"{split}/{name}: {len(cutouts)} cut-outs, target {target} instances")
            placed = 0
            while placed < target:
                stem = next(pool, None)
                if stem is None:
                    print("  ran out of empty frames")
                    break
                frame = cv2.imread(os.path.join(FRAMES_IMG, stem + ".jpg"))
                H, W = frame.shape[:2]
                focal_px = focal_px or focal_from_fov(W, ASSUMED_HFOV_DEG)
                egopath = tepnet.detect(Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)))
                centre = track_centre_by_row(egopath, H)
                width = rail_width_by_row(egopath, H)
                if not plausible_track(width):
                    continue  # unusable track; frame stays free for negatives

                n = min(rng.choices(*PER_FRAME)[0], target - placed)
                plans = []
                for _ in range(n * 5):
                    if len(plans) == n:
                        break
                    fname, cut = rng.choice(cutouts)
                    if rng.random() < 0.5:
                        cut = cut[:, ::-1].copy()
                    p = plan_instance(name, cut, centre, width, focal_px, W, H, rng)
                    box = p and (p["x1"], p["y1"], p["x1"] + p["w"], p["y1"] + p["h"])
                    if p and all(iou(box, q["box"]) < MAX_PAIR_IOU for q in plans):
                        p.update(box=box, cut=cut, file=fname)
                        plans.append(p)
                if not plans:
                    continue

                # Far animals first, so nearer ones are drawn on top
                lines, out_name = [], f"syn_{name}_{stem}"
                for p in sorted(plans, key=lambda q: q["y1"] + q["h"]):
                    vis = paste(frame, p["cut"], p["x1"], p["y1"], p["w"], p["h"])
                    if vis is None:
                        continue
                    x1, y1, x2, y2 = vis
                    lines.append(f"{cls} {(x1 + x2) / 2 / W:.6f} {(y1 + y2) / 2 / H:.6f} "
                                 f"{(x2 - x1) / W:.6f} {(y2 - y1) / H:.6f}")
                    manifest.append([out_name, split, stem, name, p["file"],
                                     f"{p['distance']:.1f}", int(p["on_track"]),
                                     y2 - y1])
                if not lines:
                    continue
                cv2.imwrite(os.path.join(OUT, "images", split, out_name + ".jpg"),
                            frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
                with open(os.path.join(OUT, "labels", split, out_name + ".txt"), "w") as fh:
                    fh.write("\n".join(lines))
                used.append(stem)
                placed += len(lines)
                if len(previews) < 12 and split == "train" and rng.random() < 0.3:
                    previews.append((frame.copy(), lines))
            print(f"  placed {placed}")

    with open(os.path.join(OUT, "used_frames.txt"), "w") as fh:
        fh.write("\n".join(sorted(used)))
    with open(os.path.join(OUT, "manifest.csv"), "w", newline="") as fh:
        wr = csv.writer(fh)
        wr.writerow(["image", "split", "source_frame", "class", "cutout",
                     "distance_m", "on_track", "height_px"])
        wr.writerows(manifest)
    save_preview(previews)
    print(f"Done. {len(used)} frames used, {len(empty) - len(used)} left for negatives.")


def save_preview(previews):
    """Grid of pasted frames with their boxes, for a quick visual check."""
    tiles = []
    for frame, lines in previews:
        H, W = frame.shape[:2]
        for line in lines:
            _, cx, cy, w, h = map(float, line.split())
            cv2.rectangle(frame, (int((cx - w / 2) * W), int((cy - h / 2) * H)),
                          (int((cx + w / 2) * W), int((cy + h / 2) * H)), (0, 0, 255), 2)
        tiles.append(cv2.resize(frame, (W // 2, H // 2)))
    if not tiles:
        return
    while len(tiles) % 3:
        tiles.append(np.zeros_like(tiles[0]))
    rows = [np.hstack(tiles[i:i + 3]) for i in range(0, len(tiles), 3)]
    os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)
    cv2.imwrite(PREVIEW, np.vstack(rows))
    print(f"Preview: {PREVIEW}")


if __name__ == "__main__":
    main()
