"""Capture checkerboard frames for camera calibration.

SPACE saves the current frame, ESC quits.

    python camera/calibration/capture_calib.py --out camera/calibration/images
"""
import argparse
import os

import cv2

from railguard.camera.capture import open_camera

TARGET = 20

parser = argparse.ArgumentParser()
parser.add_argument("--out", required=True, help="folder to save frames into")
out = parser.parse_args().out
os.makedirs(out, exist_ok=True)

cap = open_camera()
count = 0

while True:
    ok, frame = cap.read()
    if not ok:
        break

    preview = frame.copy()  # keep the saved frame free of the overlay text
    cv2.putText(preview, f"Saved: {count}/{TARGET}", (20, 50),
                cv2.FONT_HERSHEY_SIMPLEX, 1.5, (0, 255, 0), 3)
    cv2.imshow("calibration capture", preview)

    key = cv2.waitKey(1) & 0xFF
    if key == 32:  # SPACE
        name = f"calib_{count:03d}.jpg"
        cv2.imwrite(os.path.join(out, name), frame)
        count += 1
        print(f"Saved {name} ({count}/{TARGET})")
    elif key == 27:  # ESC
        break

cap.release()
cv2.destroyAllWindows()
