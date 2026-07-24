"""
RailGuard Fusion Module v4
- Perspective-aware corridor (v3)
- NEW: distance estimation via rail-gauge reference (Sri Lanka broad gauge 1.676 m)
- NEW: tiered alerts (CAUTION / BRAKE NOW)
"""

import os
import sys
import math
import cv2
import numpy as np
from PIL import Image

RAIL_GUARD_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEPNET_ROOT = os.path.join(os.path.dirname(RAIL_GUARD_ROOT), "train-ego-path-detection")
sys.path.insert(0, TEPNET_ROOT)

from ultralytics import YOLO
from src.utils.interface import Detector  # TEP-Net

# ---- Settings ----
VIDEO_IN = os.path.join(RAIL_GUARD_ROOT, "data", "videos", "processed", "test2min.mp4")
VIDEO_OUT = os.path.join(RAIL_GUARD_ROOT, "data", "videos", "results", "fusion_finetuned_2min.mp4")
TEPNET_MODEL = os.path.join(TEPNET_ROOT, "weights", "chromatic-laughter-5")
YOLO_CLASSES = [0, 2, 3, 5, 7, 19, 20]
CONF = 0.25
EXPAND_FACTOR = 3.0
INFER_EVERY = 2

# ---- Distance estimation settings ----
GAUGE_M = 1.676          # Sri Lanka broad gauge (metres)
ASSUMED_HFOV_DEG = 60.0  # assumed horizontal field of view of the camera
BRAKE_DISTANCE_M = 100.0 # threats closer than this -> BRAKE NOW, else CAUTION

print("Loading models...")
yolo = YOLO("ml/detection/railguard_best.pt")
tepnet = Detector(TEPNET_MODEL, None, "pytorch", "cuda")
print("Models loaded.")


def build_corridor_and_rails(egopath, shape):
    """Returns (corridor_mask, rail_width_by_row) where rail_width_by_row[y] =
    pixel distance between rails at image row y (0 where unknown)."""
    h, w = shape[:2]
    mask = np.zeros((h, w), dtype=np.uint8)
    width_by_row = np.zeros(h, dtype=np.float32)
    if egopath is None:
        return mask, width_by_row
    try:
        left, right = egopath
        left = [(float(x), float(y)) for x, y in left]
        right = [(float(x), float(y)) for x, y in right]
        n = min(len(left), len(right))
        if n < 2:
            return mask, width_by_row

        exp_left, exp_right = [], []
        for i in range(n):
            lx, ly = left[i]
            rx, ry = right[i]
            cx = (lx + rx) / 2.0
            half_w = max(abs(rx - lx) / 2.0, 2.0)
            y = (ly + ry) / 2.0
            e = half_w * EXPAND_FACTOR
            exp_left.append((int(cx - e), int(y)))
            exp_right.append((int(cx + e), int(y)))
            yi = int(np.clip(y, 0, h - 1))
            width_by_row[yi] = max(width_by_row[yi], 2.0 * half_w)

        # fill gaps in width_by_row by interpolation between known rows
        known = np.where(width_by_row > 0)[0]
        if len(known) >= 2:
            all_rows = np.arange(h)
            width_by_row = np.interp(all_rows, known, width_by_row[known],
                                     left=0, right=0).astype(np.float32)

        polygon = np.array(exp_left + exp_right[::-1], dtype=np.int32)
        polygon[:, 0] = np.clip(polygon[:, 0], 0, w - 1)
        polygon[:, 1] = np.clip(polygon[:, 1], 0, h - 1)
        cv2.fillPoly(mask, [polygon], 255)
    except Exception:
        pass
    return mask, width_by_row


def estimate_distance_m(row_y, width_by_row, focal_px):
    """Distance from camera to an object standing at image row row_y."""
    wpx = width_by_row[int(row_y)] if 0 <= int(row_y) < len(width_by_row) else 0
    if wpx <= 1:
        return None
    return (focal_px * GAUGE_M) / wpx


def main():
    cap = cv2.VideoCapture(VIDEO_IN)
    if not cap.isOpened():
        print(f"ERROR: cannot open {VIDEO_IN}")
        return

    fps = cap.get(cv2.CAP_PROP_FPS)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    focal_px = (w / 2.0) / math.tan(math.radians(ASSUMED_HFOV_DEG / 2.0))
    print(f"Assumed focal length: {focal_px:.0f} px "
          f"(HFOV {ASSUMED_HFOV_DEG} deg, frame width {w})")

    os.makedirs(os.path.dirname(VIDEO_OUT), exist_ok=True)
    out = cv2.VideoWriter(VIDEO_OUT, cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))

    corridor = np.zeros((h, w), dtype=np.uint8)
    width_by_row = np.zeros(h, dtype=np.float32)
    boxes_cache = []
    frame_idx = 0

    while True:
        ret, frame = cap.read()
        if not ret:
            break
        frame_idx += 1

        if frame_idx % INFER_EVERY == 1 or INFER_EVERY == 1:
            pil_img = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
            egopath = tepnet.detect(pil_img)
            corridor, width_by_row = build_corridor_and_rails(egopath, frame.shape)

            results = yolo.predict(frame, conf=CONF, imgsz=1280,
                                   classes=YOLO_CLASSES, device=0, verbose=False)
            boxes_cache = []
            for box in results[0].boxes:
                x1, y1, x2, y2 = map(int, box.xyxy[0])
                boxes_cache.append((x1, y1, x2, y2, yolo.names[int(box.cls[0])]))

        overlay = frame.copy()
        overlay[corridor > 0] = (0, 180, 0)
        frame = cv2.addWeighted(overlay, 0.25, frame, 0.75, 0)

        worst = None  # closest threat distance this frame
        for (x1, y1, x2, y2, cls_name) in boxes_cache:
            gx = np.clip((x1 + x2) // 2, 0, w - 1)
            gy = np.clip(y2, 0, h - 1)
            on_track = corridor[gy, gx] > 0

            if on_track:
                d = estimate_distance_m(gy, width_by_row, focal_px)
                d_txt = f"~{d:.0f}m" if d else "?m"
                if d is not None and (worst is None or d < worst):
                    worst = d
                color = (0, 0, 255)
                label = f"THREAT: {cls_name} {d_txt}"
                th = 3
            else:
                color, label, th = (160, 160, 160), cls_name, 1

            cv2.rectangle(frame, (x1, y1), (x2, y2), color, th)
            cv2.putText(frame, label, (x1, y1 - 8),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, color, 2)

        # ---- Tiered alert banner ----
        if worst is not None:
            if worst <= BRAKE_DISTANCE_M:
                cv2.putText(frame, f"!! BRAKE NOW !! ({worst:.0f}m)", (30, 60),
                            cv2.FONT_HERSHEY_SIMPLEX, 1.5, (0, 0, 255), 4)
            else:
                cv2.putText(frame, f"CAUTION ({worst:.0f}m)", (30, 60),
                            cv2.FONT_HERSHEY_SIMPLEX, 1.5, (0, 165, 255), 4)

        out.write(frame)
        if frame_idx % 300 == 0:
            print(f"Processed {frame_idx}/{total} ({100*frame_idx/total:.1f}%)")

    cap.release()
    out.release()
    print(f"Done! Output: {VIDEO_OUT}")


if __name__ == "__main__":
    main()
