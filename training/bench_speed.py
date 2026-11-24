"""Time the detector properly: load once, warm up, then measure inference only.

    python training/bench_speed.py

Reports median milliseconds per frame for each model, plain and 2x2 tiled
(5 passes), on real test frames. The first calls to a CUDA model are much
slower than the rest (kernel autotuning, memory allocation), so warm-up runs
are discarded; quoting a cold run as the frame rate overstates the cost.
"""

import glob
import os
import statistics
import time

import cv2
from ultralytics import YOLO

from eval_tiled import predict_tiled

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAMES = sorted(glob.glob(os.path.join(ROOT, "data", "dataset", "testset_manual", "images", "*.jpg")))[:10]
MODELS = ["yolov8s.pt", "yolov8m.pt", "yolov8x.pt"]
IMGSZ = 1280
WARMUP = 3


def bench(fn, frames):
    for f in frames[:WARMUP]:
        fn(f)
    times = []
    for f in frames:
        t0 = time.perf_counter()
        fn(f)
        times.append((time.perf_counter() - t0) * 1000)
    return statistics.median(times)


def main():
    if not FRAMES:
        print("no test frames found")
        return
    print(f"{len(FRAMES)} frames, imgsz={IMGSZ}, {WARMUP} warm-up runs discarded\n")
    print(f"{'model':<12}{'plain':>12}{'2x2 tiled':>12}{'plain fps':>12}{'tiled fps':>12}")
    print("-" * 60)
    for name in MODELS:
        path = os.path.join(ROOT, "models", name)
        if not os.path.exists(path):
            print(f"{name:<12}  not in models/, skipped")
            continue
        m = YOLO(path)
        plain = bench(lambda f: m.predict(f, imgsz=IMGSZ, conf=0.25, verbose=False), FRAMES)
        tiled = bench(lambda f: predict_tiled(m, f, IMGSZ, 0.25, 2, 2, 0.2, True), FRAMES)
        print(f"{name:<12}{plain:>10.0f}ms{tiled:>10.0f}ms"
              f"{1000/plain:>11.1f}{1000/tiled:>12.1f}")


if __name__ == "__main__":
    main()
