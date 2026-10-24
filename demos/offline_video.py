"""Run the RailGuard pipeline on a recorded video and write an annotated copy.

    python demos/offline_video.py
    python demos/offline_video.py --input clip.mp4 --output out.mp4 --calib camera/calibration/elp_wide.npz

Draws the corridor, every detection (on-track vs off-track), the distance to
each on-track object and the alert banner. Without --calib, distances use an
assumed field of view and every frame says so.
"""

import argparse
import os
import time
from collections import Counter

import cv2

from railguard.config import REPO_ROOT, PipelineConfig
from railguard.pipeline import RailGuardPipeline

from draw import draw  # demos/draw.py

VIDEO_IN = os.path.join(REPO_ROOT, "data", "videos", "processed", "test2min.mp4")
VIDEO_OUT = os.path.join(REPO_ROOT, "outputs", "videos", "pipeline_2min.mp4")


def main():
    ap = argparse.ArgumentParser(description="RailGuard: annotate a recorded video")
    ap.add_argument("--input", default=VIDEO_IN, help="input video path")
    ap.add_argument("--output", default=VIDEO_OUT, help="output video path")
    ap.add_argument("--calib", help="calibration .npz from camera/calibration/calibrate.py")
    ap.add_argument("--segment-every", type=int, default=1, help="run TEP-Net every Nth frame")
    ap.add_argument("--max-frames", type=int, help="stop after this many frames")
    args = ap.parse_args()

    cap = cv2.VideoCapture(args.input)
    if not cap.isOpened():
        raise SystemExit(f"ERROR: cannot open {args.input}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if args.max_frames:
        total = min(total, args.max_frames)

    opts = dict(segment_every=args.segment_every)
    config = PipelineConfig.from_calibration(args.calib, **opts) if args.calib else PipelineConfig(**opts)
    print("Loading models...")
    pipeline = RailGuardPipeline(config)
    print(f"Detecting: {[pipeline.model.names[i] for i in pipeline.keep_ids]}")
    print(f"Focal length: {config.focal_px(w):.0f} px at {w}x{h}"
          f"{f' (from {args.calib})' if args.calib else ''}")

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    out = cv2.VideoWriter(args.output, cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))

    class_counts, alert_counts = Counter(), Counter()
    n, t0 = 0, time.time()
    while n < total:
        ok, frame = cap.read()
        if not ok:
            break
        res = pipeline.process_frame(frame)
        class_counts.update(d.cls_name for d in res.detections)
        alert_counts[res.alert] += 1
        draw(frame, res, calibrated=args.calib is not None, persist=config.persist_frames)
        out.write(frame)
        n += 1
        if n % 300 == 0:
            print(f"Processed {n}/{total} ({100 * n / total:.0f}%), "
                  f"{n / (time.time() - t0):.1f} FPS")

    cap.release()
    out.release()
    print(f"Done: {n} frames in {time.time() - t0:.0f} s -> {args.output}")
    print(f"Detections by class: {dict(class_counts)}")
    print(f"Frames by alert: { {k or 'none': v for k, v in alert_counts.items()} }")


if __name__ == "__main__":
    main()
