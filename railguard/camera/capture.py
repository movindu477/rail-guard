"""Opening the ELP USB camera: Media Foundation + MJPEG, the only path that
reaches 4K at ~30 FPS on Windows (see observations.md)."""

import cv2

def open_camera(index=1, width=1920, height=1080, backend=cv2.CAP_MSMF):
    cap = cv2.VideoCapture(index, backend)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open camera index {index}")
    fourcc = cv2.VideoWriter_fourcc(*"MJPG")
    cap.set(cv2.CAP_PROP_FOURCC, fourcc)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FOURCC, fourcc)
    return cap
