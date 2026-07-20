"""
RailGuard Fusion Module
Combines YOLO object detection + TEP-Net ego-path detection.
Only objects inside (or near) the train's track corridor are flagged as threats.
"""

import os
import sys
import cv2
import numpy as np
from PIL import Image

# ---- Paths (adjust only if your folders differ) ----
RAIL_GUARD_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEPNET_ROOT = os.path.join(os.path.dirname(RAIL_GUARD_ROOT), "train-ego-path-detection")
sys.path.insert(0, TEPNET_ROOT)

from ultralytics import YOLO
from src.utils.interface import Detector  # TEP-Net

# ---- Settings ----
VIDEO_IN = os.path.join(RAIL_GUARD_ROOT, "data", "videos", "processed", "test2min.mp4")
VIDEO_OUT = os.path.join(RAIL_GUARD_ROOT, "data", "videos", "results", "fusion_test2min.mp4")
TEPNET_MODEL = os.path.join(TEPNET_ROOT, "weights", "chromatic-laughter-5")  # regression model
YOLO_CLASSES = [0, 2, 3, 5, 7, 19, 20]  # person, car, motorcycle, bus, truck, cow, elephant
CONF = 0.25
CORRIDOR_MARGIN_PX = 60   # safety margin added on each side of the track corridor
FRAME_SKIP = 3            # process every 3rd frame (CPU speed); set 1 for full quality

# ---- Load models ----
print("Loading models...")
yolo = YOLO("yolov8n.pt")
tepnet = Detector(TEPNET_MODEL, None, "pytorch", "cpu")
print("Models loaded.")


def corridor_mask_from_egopath(egopath, shape):
    """Build a binary corridor mask from TEP-Net output (rail point lists or mask)."""
    h, w = shape[:2]
    mask = np.zeros((h, w), dtype=np.uint8)

    if egopath is None:
        return mask

    # Segmentation head -> PIL image or numpy mask
    if isinstance(egopath, Image.Image):
        m = np.array(egopath.convert("L").resize((w, h)))
        mask[m > 0] = 255
    elif isinstance(egopath, np.ndarray):
        m = cv2.resize(egopath.astype(np.uint8), (w, h))
        mask[m > 0] = 255
    else:
        # Classification/regression heads -> (left_rail_points, right_rail_points)
        try:
            left, right = egopath
            left = [(int(x), int(y)) for x, y in left]
            right = [(int(x), int(y)) for x, y in right]
            if len(left) >= 2 and len(right) >= 2:
                polygon = np.array(left + right[::-1], dtype=np.int32)
                cv2.fillPoly(mask, [polygon], 255)
        except Exception:
            return mask

    # Expand corridor by safety margin
    if CORRIDOR_MARGIN_PX > 0:
        kernel = cv2.getStructuringElement(
            cv2.MORPH_ELLIPSE, (CORRIDOR_MARGIN_PX, CORRIDOR_MARGIN_PX)
        )
        mask = cv2.dilate(mask, kernel)
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
    out = cv2.VideoWriter(
        VIDEO_OUT, cv2.VideoWriter_fourcc(*"mp4v"), fps / FRAME_SKIP, (w, h)
    )

    frame_idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        frame_idx += 1
        if frame_idx % FRAME_SKIP != 0:
            continue

        # --- TEP-Net ego-path ---
        pil_img = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        egopath = tepnet.detect(pil_img)
        corridor = corridor_mask_from_egopath(egopath, frame.shape)

        # --- YOLO detections ---
        results = yolo.predict(frame, conf=CONF, imgsz=1280,
                               classes=YOLO_CLASSES, verbose=False)

        # --- Draw corridor overlay (green, semi-transparent) ---
        overlay = frame.copy()
        overlay[corridor > 0] = (0, 180, 0)
        frame = cv2.addWeighted(overlay, 0.25, frame, 0.75, 0)

        # --- Fusion check per detection ---
        threats = 0
        for box in results[0].boxes:
            x1, y1, x2, y2 = map(int, box.xyxy[0])
            cls_name = yolo.names[int(box.cls[0])]
            # ground-contact point of the object = bottom-center of the box
            gx = (x1 + x2) // 2
            gy = min(y2, h - 1)
            on_track = corridor[gy, gx] > 0

            if on_track:
                threats += 1
                color, label = (0, 0, 255), f"THREAT: {cls_name}"
                thickness = 3
            else:
                color, label = (160, 160, 160), cls_name
                thickness = 1

            cv2.rectangle(frame, (x1, y1), (x2, y2), color, thickness)
            cv2.putText(frame, label, (x1, y1 - 8),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, color, 2)

        if threats > 0:
            cv2.putText(frame, "!! ALERT !!", (30, 60),
                        cv2.FONT_HERSHEY_SIMPLEX, 1.5, (0, 0, 255), 4)

        out.write(frame)
        if frame_idx % 90 == 0:
            print(f"Processed {frame_idx}/{total} frames "
                  f"({100*frame_idx/total:.1f}%)")

    cap.release()
    out.release()
    print(f"Done! Output: {VIDEO_OUT}")


if __name__ == "__main__":
    main()
