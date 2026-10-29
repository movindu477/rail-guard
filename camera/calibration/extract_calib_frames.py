"""Pick the best calibration frames from a video made with capture_video.py.

    python camera/calibration/extract_calib_frames.py --video camera/calibration/videos/wide.avi \
        --out camera/calibration/images_wide

Pass 1 reads every frame (every --step-th) and keeps the ones where the whole
board is found, recording its position, size, tilt, sharpness (variance of
the Laplacian inside the board, so the background does not count) and speed.
Blurry frames are dropped two ways, so no fixed percentage is assumed:
  - a frame much softer than the sharpest frame within +-0.5 s (the board is
    about the same size there, so the comparison is fair): brief blur;
  - a frame where the board moves fast: motion blur grows with speed, and
    during a fast sweep every neighbour is soft too. Frames up to --max-speed
    px per frame always pass; in a faster video, the slower half passes.
Pass 2 picks --n frames that are as different from each other as possible
(farthest-point sampling over position, size and signed tilt, starting from
the sharpest frame) and saves them as calib_NNN.jpg for calibrate.py.
"""
import argparse
import glob
import math
import os

import cv2
import numpy as np

from capture_calib import TILT, find_board, measure   # camera/calibration/capture_calib.py

CRITERIA = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001)


def pose_vector(m):
    """Board pose as a vector; distances between vectors mean 'how different'."""
    yaw = m["yaw"] * (-1 if m["lr"] < 0 else 1)      # signed: which side is further away
    pitch = m["pitch"] * (-1 if m["tb"] < 0 else 1)
    return np.array([m["cx"], m["cy"], 0.5 * math.log(m["width"] / 0.2), 2 * yaw, 2 * pitch])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True)
    ap.add_argument("--out", required=True, help="folder for calib_NNN.jpg (must be empty)")
    ap.add_argument("--n", type=int, default=25, help="frames to keep")
    ap.add_argument("--pattern", default="6x8", help="inner corners, rows x cols")
    ap.add_argument("--step", type=int, default=2, help="look at every Nth frame")
    ap.add_argument("--min-width", type=float, default=0.12,
                    help="smallest board width, as a share of the frame width")
    ap.add_argument("--local-sharp", type=float, default=0.85,
                    help="keep frames at least this sharp relative to the sharpest within +-0.5 s")
    ap.add_argument("--max-speed", type=float, default=3.0,
                    help="board movement (px per frame) that always passes; faster videos keep their slower half")
    args = ap.parse_args()
    rows, cols = (int(n) for n in args.pattern.lower().split("x"))
    if glob.glob(os.path.join(args.out, "*.jpg")):
        raise SystemExit(f"{args.out} already has photos; move them aside first.")
    os.makedirs(args.out, exist_ok=True)

    # ---- pass 1: find the board in every frame ----
    cap = cv2.VideoCapture(args.video)
    if not cap.isOpened():
        raise SystemExit(f"Cannot open {args.video}")
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    window = max(1, int(round((cap.get(cv2.CAP_PROP_FPS) or 20) * 0.5)))   # +-0.5 s in frames
    cands, i, prev = [], -1, None
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        i += 1
        if i % args.step:
            continue
        h, w = frame.shape[:2]
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        small = cv2.resize(gray, (w // 2, h // 2))
        if not find_board(small, rows, cols, cv2.CALIB_CB_FAST_CHECK)[0]:
            continue                      # quick reject: no board
        ok, c, pat = find_board(gray, rows, cols, None)
        if not ok:
            continue
        c = cv2.cornerSubPix(gray, c, (11, 11), (-1, -1), CRITERIA)
        try:
            m = measure(c, pat, w, h)
        except (ValueError, ZeroDivisionError):
            continue
        if m["width"] < args.min_width:
            continue
        x1, y1 = np.floor(c.min(axis=(0, 1))).astype(int)
        x2, y2 = np.ceil(c.max(axis=(0, 1))).astype(int)
        sharp = cv2.Laplacian(gray[max(y1, 0):y2, max(x1, 0):x2], cv2.CV_64F).var()
        speed = None   # mean corner movement per frame since the previous sampled frame
        if prev is not None and prev[1].shape == c.shape and i - prev[0] <= 2 * args.step:
            speed = float(np.linalg.norm(c - prev[1], axis=-1).mean()) / (i - prev[0])
        prev = (i, c)
        cands.append({"i": i, "m": m, "sharp": sharp, "speed": speed, "v": pose_vector(m)})
        if len(cands) % 25 == 0:
            print(f"  frame {i}/{total}: {len(cands)} usable so far")
    cap.release()
    if not cands:
        raise SystemExit("No usable board frames found (whole board visible and big enough).")

    idx = np.array([c["i"] for c in cands])
    sharp = np.array([c["sharp"] for c in cands])
    speeds = [c["speed"] for c in cands if c["speed"] is not None]
    speed_cut = max(args.max_speed, float(np.median(speeds))) if speeds else float("inf")
    soft = fast = 0
    pool = []
    for k, c in enumerate(cands):
        near = sharp[np.abs(idx - c["i"]) <= window]
        if c["sharp"] < args.local_sharp * near.max():
            soft += 1
        elif c["speed"] is not None and c["speed"] > speed_cut:
            fast += 1
        else:
            pool.append(c)
    print(f"{len(cands)} frames with a usable board; dropped {soft} softer than their "
          f"neighbours and {fast} moving faster than {speed_cut:.1f} px/frame; {len(pool)} left")
    if not pool:
        raise SystemExit("Every board frame was blurred or moving fast - record again, moving more slowly.")

    # ---- pass 2: farthest-point sampling for variety ----
    picked = [max(pool, key=lambda c: c["sharp"])]
    while len(picked) < min(args.n, len(pool)):
        best = max((c for c in pool if c not in picked),
                   key=lambda c: min(np.linalg.norm(c["v"] - p["v"]) for p in picked))
        picked.append(best)
    picked.sort(key=lambda c: c["i"])

    wanted = {c["i"]: k for k, c in enumerate(picked)}
    cap = cv2.VideoCapture(args.video)
    i = -1
    while wanted:
        ok, frame = cap.read()
        if not ok:
            break
        i += 1
        if i in wanted:
            cv2.imwrite(os.path.join(args.out, f"calib_{wanted.pop(i):03d}.jpg"), frame)
    cap.release()

    cells = {(min(int(c["m"]["cx"] * 3), 2), min(int(c["m"]["cy"] * 3), 2)) for c in picked}
    tilted = sum(max(c["m"]["yaw"], c["m"]["pitch"]) >= TILT for c in picked)
    print(f"Saved {len(picked)} frames to {args.out}")
    print(f"  screen areas covered: {len(cells)}/9   tilted views: {tilted}   "
          f"board width {min(c['m']['width'] for c in picked):.2f}-{max(c['m']['width'] for c in picked):.2f}")
    if len(picked) < 15:
        print("  WARNING: fewer than 15 frames - record a longer or slower video.")
    if tilted < 6:
        print("  WARNING: fewer than 6 tilted views - tilt the board more (~30 deg) when recording.")
    if len(cells) < 6:
        print("  WARNING: the board did not reach enough of the screen - move it into the corners.")


if __name__ == "__main__":
    main()
