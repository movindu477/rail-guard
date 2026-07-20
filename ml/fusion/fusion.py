"""
RailGuard Fusion Module v2
- Perspective-aware corridor (wide near, narrow far)
- Smooth full-FPS output (inference every Nth frame, drawing every frame)
"""

import os
import sys
import cv2
import numpy as np
from PIL import Image

RAIL_GUARD_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEPNET_ROOT = os.path.join(os.path.dirname(RAIL_GUARD_ROOT), "train-ego-path-detection")
sys.path.insert(0, TEPNET_ROOT)

from ultralytics import YOLO
from src.utils.interface import Detector  # TEP-Net

# ---- Settings ----
VIDEO_IN = os.path.join(RAIL_GUARD_ROOT, "data", "videos", "processed", "test5min.mp4")
VIDEO_OUT = os.path.join(RAIL_GUARD_ROOT, "data", "videos", "results", "fusion_test5min.mp4")
TEPNET_MODEL = os.path.join(TEPNET_ROOT, "weights", "chromatic-laughter-5")
YOLO_CLASSES = [0, 2, 3, 5, 7, 19, 20]
CONF = 0.25
EXPAND_FACTOR = 2.0   # corridor half-width = track half-width * this factor (tune: 1.5–3.0)
INFER_EVERY = 3       # run models every Nth frame, reuse results in between

print("Loading models...")
yolo = YOLO("yolov8n.pt")
tepnet = Detector(TEPNET_MODEL, None, "pytorch", "cpu")
print("Models loaded.")


def corridor_mask_from_egopath(egopath, shape):
    """Perspective-aware corridor: expand rails proportionally to local track width."""
    h, w = shape[:2]
    mask = np.zeros((h, w), dtype=np.uint8)
    if egopath is None:
        return mask
    try:
        left, right = egopath
        left = [(float(x), float(y)) for x, y in left]
        right = [(float(x), float(y)) for x, y in right]
        n = min(len(left), len(right))
        if n < 2:
            return mask

        exp_left, exp_right = [], []
        for i in range(n):
            lx, ly = left[i]
            rx, ry = right[i]
            cx = (lx + rx) / 2.0
            half_w = max(abs(rx - lx) / 2.0, 2.0)   # local track half-width in px
            e = half_w * EXPAND_FACTOR
            y = (ly + ry) / 2.0
            exp_left.append((int(cx - e), int(y)))
            exp_right.append((int(cx + e), int(y)))

        polygon = np.array(exp_left + exp_right[::-1], dtype=np.int32)
        polygon[:, 0] = np.clip(polygon[:, 0], 0, w - 1)
        polygon[:, 1] = np.clip(polygon[:, 1], 0, h - 1)
        cv2.fillPoly(mask, [polygon], 255)
    except Exception:
        pass
    return mask


def main():
    cap = cv2.VideoCapture(VIDEO_IN)
    if not cap.isOpened():
        print(f"ERROR: cannot open {VIDEO_IN}")
        return

    fps = cap.get(cv2.CAP_PROP_FPS)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    os.makedirs(os.path.dirname(VIDEO_OUT), exist_ok=True)
    out = cv2.VideoWriter(VIDEO_OUT, cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))

    corridor = np.zeros((h, w), dtype=np.uint8)
    boxes_cache = []   # list of (x1,y1,x2,y2,cls_name)
    frame_idx = 0

    while True:
        ret, frame = cap.read()
        if not ret:
            break
        frame_idx += 1

        # --- Inference only every Nth frame; reuse otherwise ---
        if frame_idx % INFER_EVERY == 1 or INFER_EVERY == 1:
            pil_img = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
            egopath = tepnet.detect(pil_img)
            corridor = corridor_mask_from_egopath(egopath, frame.shape)

            results = yolo.predict(frame, conf=CONF, imgsz=1280,
                                   classes=YOLO_CLASSES, verbose=False)
            boxes_cache = []
            for box in results[0].boxes:
                x1, y1, x2, y2 = map(int, box.xyxy[0])
                boxes_cache.append((x1, y1, x2, y2, yolo.names[int(box.cls[0])]))

        # --- Draw corridor overlay ---
        overlay = frame.copy()
        overlay[corridor > 0] = (0, 180, 0)
        frame = cv2.addWeighted(overlay, 0.25, frame, 0.75, 0)

        # --- Fusion check ---
        threats = 0
        for (x1, y1, x2, y2, cls_name) in boxes_cache:
            gx = np.clip((x1 + x2) // 2, 0, w - 1)
            gy = np.clip(y2, 0, h - 1)
            on_track = corridor[gy, gx] > 0
            if on_track:
                threats += 1
                color, label, th = (0, 0, 255), f"THREAT: {cls_name}", 3
            else:
                color, label, th = (160, 160, 160), cls_name, 1
            cv2.rectangle(frame, (x1, y1), (x2, y2), color, th)
            cv2.putText(frame, label, (x1, y1 - 8),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, color, 2)

        if threats > 0:
            cv2.putText(frame, "!! ALERT !!", (30, 60),
                        cv2.FONT_HERSHEY_SIMPLEX, 1.5, (0, 0, 255), 4)

        out.write(frame)
        if frame_idx % 300 == 0:
            print(f"Processed {frame_idx}/{total} ({100*frame_idx/total:.1f}%)")

    cap.release()
    out.release()
    print(f"Done! Output: {VIDEO_OUT}")


if __name__ == "__main__":
    main()
