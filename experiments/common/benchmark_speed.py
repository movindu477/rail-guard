"""Speed benchmark across resolutions and devices."""
import os, sys, time
import cv2
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from ultralytics import YOLO
from railguard.segmentation.tepnet import load_tepnet

VIDEO = os.path.join(ROOT, "data", "videos", "processed", "test2min.mp4")
MODEL = os.path.join(ROOT, "models", "railguard_best.pt")
N_FRAMES = 100

def grab_frames(n):
    cap = cv2.VideoCapture(VIDEO)
    frames = []
    while len(frames) < n:
        ok, f = cap.read()
        if not ok:
            break
        frames.append(f)
    cap.release()
    return frames

def bench_yolo(frames, imgsz, device):
    m = YOLO(MODEL)
    m.predict(frames[0], imgsz=imgsz, device=device, verbose=False)  # warmup
    t0 = time.time()
    for f in frames:
        m.predict(f, imgsz=imgsz, device=device, verbose=False)
    dt = (time.time() - t0) / len(frames)
    return dt * 1000

def bench_tepnet(frames, model_name, device):
    d = load_tepnet(model_name, device)
    pil = [Image.fromarray(cv2.cvtColor(f, cv2.COLOR_BGR2RGB)) for f in frames]
    d.detect(pil[0])  # warmup
    t0 = time.time()
    for p in pil:
        d.detect(p)
    dt = (time.time() - t0) / len(pil)
    return dt * 1000

def main():
    frames = grab_frames(N_FRAMES)
    print(f"Benchmarking on {len(frames)} frames\n")

    print("YOLO detection:")
    for dev in ["cuda", "cpu"]:
        for size in [416, 640, 1280]:
            ms = bench_yolo(frames, size, dev)
            print(f"  {dev:5s} imgsz={size:5d}  {ms:7.1f} ms  ({1000/ms:5.1f} FPS)")

    print("\nTEP-Net segmentation:")
    for dev in ["cuda", "cpu"]:
        for name in ["logical-tree-1", "chromatic-laughter-5"]:
            ms = bench_tepnet(frames, name, dev)
            print(f"  {dev:5s} {name:22s}  {ms:7.1f} ms  ({1000/ms:5.1f} FPS)")

if __name__ == "__main__":
    main()
