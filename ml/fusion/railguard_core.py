"""
RailGuard Core — shared fusion logic.
Imported by fusion.py, live_demo.py, and later the evaluation scripts.
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
from src.utils.interface import Detector

# ---- Shared defaults ----
GAUGE_M = 1.676
YOLO_CLASSES = [0, 2, 3, 5, 7, 19, 20]  # person, car, motorcycle, bus, truck, cow, elephant


def load_models(yolo_weights="yolov8n.pt", tepnet_model_name="chromatic-laughter-5", device="cuda"):
    yolo = YOLO(yolo_weights)
    tepnet_path = os.path.join(TEPNET_ROOT, "weights", tepnet_model_name)
    tepnet = Detector(tepnet_path, None, "pytorch", device)
    return yolo, tepnet


def build_corridor_and_rails(egopath, shape, expand_factor=3.0):
    """Perspective-aware corridor mask + per-row track pixel width."""
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
            e = half_w * expand_factor
            exp_left.append((int(cx - e), int(y)))
            exp_right.append((int(cx + e), int(y)))
            yi = int(np.clip(y, 0, h - 1))
            width_by_row[yi] = max(width_by_row[yi], 2.0 * half_w)
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


def focal_from_fov(frame_width, hfov_deg=60.0):
    return (frame_width / 2.0) / math.tan(math.radians(hfov_deg / 2.0))


def estimate_distance_m(row_y, width_by_row, focal_px):
    y = int(np.clip(row_y, 0, len(width_by_row) - 1))
    wpx = width_by_row[y]
    if wpx <= 1:
        return None
    return (focal_px * GAUGE_M) / wpx


def classify_threats(boxes, corridor, width_by_row, focal_px, brake_distance_m=100.0):
    """boxes: list of (x1,y1,x2,y2,cls_name). Returns annotated list + worst distance."""
    h, w = corridor.shape[:2]
    out = []
    worst = None
    for (x1, y1, x2, y2, cls_name) in boxes:
        gx = int(np.clip((x1 + x2) // 2, 0, w - 1))
        gy = int(np.clip(y2, 0, h - 1))
        on_track = corridor[gy, gx] > 0
        d = estimate_distance_m(gy, width_by_row, focal_px) if on_track else None
        if on_track and d is not None and (worst is None or d < worst):
            worst = d
        out.append((x1, y1, x2, y2, cls_name, on_track, d))
    return out, worst
