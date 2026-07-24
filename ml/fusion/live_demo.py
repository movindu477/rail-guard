"""
RailGuard LIVE Demo v2 (threaded)
- Display runs at full video FPS (smooth)
- Inference runs in a background thread, overlays update as fast as CPU allows
Press Q to quit.
"""

import os
os.environ["OMP_NUM_THREADS"] = "4"
import sys
import math
import time
import threading
import cv2
cv2.setNumThreads(4)
import numpy as np
from PIL import Image

RAIL_GUARD_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEPNET_ROOT = os.path.join(os.path.dirname(RAIL_GUARD_ROOT), "train-ego-path-detection")
sys.path.insert(0, TEPNET_ROOT)

from ultralytics import YOLO
from src.utils.interface import Detector

VIDEO_IN = os.path.join(RAIL_GUARD_ROOT, "data", "videos", "processed", "test2min.mp4")
TEPNET_MODEL = os.path.join(TEPNET_ROOT, "weights", "logical-tree-1")
YOLO_CLASSES = [0, 2, 3, 5, 7, 19, 20]
CONF = 0.3
YOLO_IMGSZ = 416          # smaller = faster inference, steadier FPS
DISPLAY_EVERY_INFER = False
EXPAND_FACTOR = 3.0
GAUGE_M = 1.676
ASSUMED_HFOV_DEG = 60.0
BRAKE_DISTANCE_M = 100.0
BEEP_COOLDOWN_S = 1.0

ALERT_WAV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "alert.wav")
try:
    import winsound
    def beep(freq=1000, dur=200):
        threading.Thread(
            target=lambda: winsound.PlaySound(ALERT_WAV, winsound.SND_FILENAME),
            daemon=True
        ).start()
except ImportError:
    def beep(freq=1000, dur=200):
        print("\a", end="")

print("Loading models...")
yolo = YOLO("yolov8n.pt")
tepnet = Detector(TEPNET_MODEL, None, "pytorch", "cpu")
print("Models loaded. Press Q in the window to quit.")

# ---- Shared state between threads ----
state_lock = threading.Lock()
latest_frame = None          # newest frame for the worker to process
shared = {
    "corridor": None,
    "width_by_row": None,
    "boxes": [],
    "infer_fps": 0.0,
    "running": True,
}


def build_corridor_and_rails(egopath, shape):
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


def inference_worker():
    global latest_frame
    while shared["running"]:
        with state_lock:
            frame = None if latest_frame is None else latest_frame.copy()
        if frame is None:
            time.sleep(0.01)
            continue
        time.sleep(0.001)  # yield to display thread

        t0 = time.time()

        # TEP-Net every 3rd cycle (track changes slowly), reuse in between
        if not hasattr(inference_worker, "_c"):
            inference_worker._c = 0
            inference_worker._corridor = None
            inference_worker._wbr = None
        inference_worker._c += 1

        if inference_worker._c % 3 == 1 or inference_worker._corridor is None:
            pil_img = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
            egopath = tepnet.detect(pil_img)
            c, wbr = build_corridor_and_rails(egopath, frame.shape)
            inference_worker._corridor = c
            inference_worker._wbr = wbr
        corridor = inference_worker._corridor
        width_by_row = inference_worker._wbr

        results = yolo.predict(frame, conf=CONF, imgsz=YOLO_IMGSZ,
                               classes=YOLO_CLASSES, max_det=10, verbose=False)
        boxes = []
        for box in results[0].boxes:
            x1, y1, x2, y2 = map(int, box.xyxy[0])
            boxes.append((x1, y1, x2, y2, yolo.names[int(box.cls[0])]))

        dt = time.time() - t0
        with state_lock:
            shared["corridor"] = corridor
            shared["width_by_row"] = width_by_row
            shared["boxes"] = boxes
            shared["infer_fps"] = 1.0 / dt if dt > 0 else 0


def main():
    global latest_frame
    cap = cv2.VideoCapture(VIDEO_IN)
    if not cap.isOpened():
        print(f"ERROR: cannot open {VIDEO_IN}")
        return
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    src_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    frame_interval = 1.0 / src_fps
    focal_px = (w / 2.0) / math.tan(math.radians(ASSUMED_HFOV_DEG / 2.0))

    worker = threading.Thread(target=inference_worker, daemon=True)
    worker.start()

    last_beep = 0.0
    while True:
        t_start = time.time()
        ret, frame = cap.read()
        if not ret:
            print("End of video.")
            break

        with state_lock:
            latest_frame = frame
        corridor = shared["corridor"]
        width_by_row = shared["width_by_row"]
        boxes = list(shared["boxes"])
        infer_fps = shared["infer_fps"]

        if corridor is not None:
            overlay = frame.copy()
            overlay[corridor > 0] = (0, 180, 0)
            frame = cv2.addWeighted(overlay, 0.25, frame, 0.75, 0)

        worst = None
        for (x1, y1, x2, y2, cls_name) in boxes:
            gx = np.clip((x1 + x2) // 2, 0, w - 1)
            gy = np.clip(y2, 0, h - 1)
            on_track = corridor is not None and corridor[gy, gx] > 0
            if on_track:
                wpx = width_by_row[gy] if width_by_row is not None else 0
                d = (focal_px * GAUGE_M) / wpx if wpx > 1 else None
                if d is not None and (worst is None or d < worst):
                    worst = d
                d_txt = f"~{d:.0f}m" if d else "?m"
                color, label, th = (0, 0, 255), f"THREAT: {cls_name} {d_txt}", 3
            else:
                color, label, th = (160, 160, 160), cls_name, 1
            cv2.rectangle(frame, (x1, y1), (x2, y2), color, th)
            cv2.putText(frame, label, (x1, y1 - 8),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)

        now = time.time()
        if worst is not None:
            if worst <= BRAKE_DISTANCE_M:
                cv2.putText(frame, f"!! BRAKE NOW !! ({worst:.0f}m)", (30, 60),
                            cv2.FONT_HERSHEY_SIMPLEX, 1.4, (0, 0, 255), 4)
                if now - last_beep > BEEP_COOLDOWN_S:
                    beep(1500, 400)
                    last_beep = now
            else:
                cv2.putText(frame, f"CAUTION ({worst:.0f}m)", (30, 60),
                            cv2.FONT_HERSHEY_SIMPLEX, 1.4, (0, 165, 255), 4)
                if now - last_beep > BEEP_COOLDOWN_S * 2:
                    beep(800, 150)
                    last_beep = now

        cv2.putText(frame, f"infer: {infer_fps:.1f} FPS", (w - 320, 50),
                    cv2.FONT_HERSHEY_SIMPLEX, 1.0, (255, 255, 0), 3)

        disp = cv2.resize(frame, (1280, int(1280 * h / w)))
        cv2.imshow("RailGuard LIVE", disp)
        if cv2.waitKey(1) & 0xFF == ord("q"):
            break

        # pace playback to real time
        elapsed = time.time() - t_start
        wait = frame_interval - elapsed
        if wait > 0:
            time.sleep(wait)

    shared["running"] = False
    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
