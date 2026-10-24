"""E3: how far ahead can RailGuard range an object?

Ranging needs the rail spacing at the object's row, so the farthest rangeable
distance in a frame is set by the farthest (top-most) row where the ego-path
gives a rail width. This runs the pipeline over a clip and records, per frame,
that row, the rail width there, and the distance it corresponds to.

    python experiments/e3_range/range_limit.py
    python experiments/e3_range/range_limit.py --calib camera/calibration/elp_wide.npz --input clip.mp4

Outputs:
    outputs/evaluation/range_limit.csv          summary (min / median / p95 / max)
    outputs/evaluation/range_limit_frames.csv   one row per frame
    outputs/figures/range_limit.png             histogram
"""

import argparse
import csv
import os

import cv2
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

from railguard.config import REPO_ROOT, PipelineConfig  # noqa: E402
from railguard.core.alerts import braking_distance_m  # noqa: E402
from railguard.core.geometry import GAUGE_M, MIN_RAIL_WIDTH_PX  # noqa: E402
from railguard.pipeline import RailGuardPipeline  # noqa: E402

VIDEO_IN = os.path.join(REPO_ROOT, "data", "videos", "processed", "test2min.mp4")
EVAL_DIR = os.path.join(REPO_ROOT, "outputs", "evaluation")
FIG_DIR = os.path.join(REPO_ROOT, "outputs", "figures")
BRAKING_M = (300, 400, 500)   # braking distances for < 60, 60-80, > 80 km/h

# Chart colours (light, print)
SURFACE, INK, INK_2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
SERIES = "#2a78d6"


def frame_limit(width_by_row):
    """(row, rail_width_px) of the farthest row with a known rail width, or None."""
    rows = np.flatnonzero(width_by_row > 0)
    if rows.size == 0:
        return None
    top = int(rows[0])
    return top, float(width_by_row[top])


def histogram(dist, median, p95, out_path, title_note):
    fig, ax = plt.subplots(figsize=(9, 4.8), dpi=150)
    fig.patch.set_facecolor(SURFACE)
    ax.set_facecolor(SURFACE)

    hi = max(BRAKING_M) * 1.08
    bins = np.arange(0, hi + 10, 10)
    ax.hist(np.clip(dist, 0, hi), bins=bins, color=SERIES, edgecolor=SURFACE, linewidth=2)

    ymax = ax.get_ylim()[1]
    # median label left of its line, p95 label right, so they never collide
    for x, label, style, dx, ha in ((median, f"median {median:.0f} m", "-", -4, "right"),
                                    (p95, f"95th pct {p95:.0f} m", "--", 4, "left")):
        ax.axvline(x, color=INK, linewidth=1.5, linestyle=style)
        ax.text(x + dx, ymax * 0.97, label, color=INK, fontsize=9, va="top", ha=ha,
                bbox=dict(facecolor=SURFACE, edgecolor="none", pad=1.5))
    for i, b in enumerate(BRAKING_M):
        ax.axvline(b, color=INK_2, linewidth=1, linestyle=":")
        ax.text(b + 4, ymax * (0.55 - 0.1 * i), f"braking {b} m", color=INK_2, fontsize=8.5)

    ax.set_xlim(0, hi)
    ax.set_xlabel("Farthest rangeable distance in the frame (m)", color=INK_2)
    ax.set_ylabel("Frames", color=INK_2)
    ax.set_title(f"Ranging limit per frame ({len(dist)} frames{title_note})",
                 color=INK, fontsize=11, loc="left")
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(GRID)
    ax.tick_params(colors=INK_2, labelsize=9)

    fig.tight_layout()
    fig.savefig(out_path, facecolor=SURFACE)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser(description="E3: per-frame ranging limit")
    ap.add_argument("--input", default=VIDEO_IN)
    ap.add_argument("--calib", help="calibration .npz; without it fx is ASSUMED")
    ap.add_argument("--max-frames", type=int)
    args = ap.parse_args()

    cap = cv2.VideoCapture(args.input)
    if not cap.isOpened():
        raise SystemExit(f"ERROR: cannot open {args.input}")
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if args.max_frames:
        total = min(total, args.max_frames)

    config = PipelineConfig.from_calibration(args.calib) if args.calib else PipelineConfig()
    pipeline = RailGuardPipeline(config)
    fx = config.focal_px(w)

    os.makedirs(EVAL_DIR, exist_ok=True)
    os.makedirs(FIG_DIR, exist_ok=True)
    rows = []
    n = 0
    while n < total:
        ok, frame = cap.read()
        if not ok:
            break
        lim = frame_limit(pipeline.process_frame(frame).width_by_row)
        if lim is None:
            rows.append((n, "", "", "", ""))
        else:
            row, wpx = lim
            rows.append((n, row, round(wpx, 2), round(fx * GAUGE_M / wpx, 1),
                         int(wpx <= MIN_RAIL_WIDTH_PX)))
        n += 1
        if n % 600 == 0:
            print(f"{n}/{total}")
    cap.release()

    with open(os.path.join(EVAL_DIR, "range_limit_frames.csv"), "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(("frame", "top_row", "rail_width_px", "max_range_m", "width_at_floor"))
        wr.writerows(rows)

    ranged = [r for r in rows if r[1] != ""]
    if not ranged:
        raise SystemExit("No frame had a usable ego-path.")
    dist = np.array([r[3] for r in ranged])
    wpx = np.array([r[2] for r in ranged])
    top = np.array([r[1] for r in ranged])
    at_floor = sum(r[4] for r in ranged)

    stats = {
        "max_range_m": (dist.min(), np.median(dist), np.percentile(dist, 95), dist.max()),
        "rail_width_px": (wpx.min(), np.median(wpx), np.percentile(wpx, 95), wpx.max()),
        "top_row": (top.min(), np.median(top), np.percentile(top, 95), top.max()),
    }
    with open(os.path.join(EVAL_DIR, "range_limit.csv"), "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(("metric", "min", "median", "p95", "max"))
        for k, v in stats.items():
            wr.writerow((k, *(round(float(x), 2) for x in v)))
        wr.writerow(())
        wr.writerow(("frames", n))
        wr.writerow(("frames_with_track", len(ranged)))
        wr.writerow(("frames_width_at_floor", at_floor))
        wr.writerow(("fx_px", round(fx, 1)))
        wr.writerow(("fx_source", args.calib or "assumed 60 deg HFOV"))
        wr.writerow(("frame_size", f"{w}x{h}"))
        wr.writerow(())
        wr.writerow(("distance_m", "rail_width_px_needed"))
        for d in BRAKING_M:
            wr.writerow((d, round(fx * GAUGE_M / d, 2)))

    d_med, d_p95 = float(np.median(dist)), float(np.percentile(dist, 95))
    histogram(dist, d_med, d_p95, os.path.join(FIG_DIR, "range_limit.png"),
              "" if args.calib else ", assumed focal length")

    print()
    print(f"Clip: {os.path.basename(args.input)}  {w}x{h}  {n} frames, "
          f"{len(ranged)} with a track ({n - len(ranged)} without)")
    print(f"fx = {fx:.0f} px ({'calibrated: ' + args.calib if args.calib else 'ASSUMED 60 deg HFOV, uncalibrated'})")
    print()
    print(f"{'':22s}{'min':>8s}{'median':>9s}{'p95':>8s}{'max':>8s}")
    for k, v in stats.items():
        print(f"{k:22s}" + "".join(f"{x:{wd}.1f}" for x, wd in zip(v, (8, 9, 8, 8))))
    print(f"frames where the far rail width hit the {MIN_RAIL_WIDTH_PX:g} px floor: {at_floor}")
    print()
    print(f"Rail width needed to range at braking distance (fx = {fx:.0f} px):")
    for d in BRAKING_M:
        print(f"  {d} m  ->  {fx * GAUGE_M / d:.2f} px between the rails")
    print(f"  speed tiers: <60 km/h {braking_distance_m(50):.0f} m, "
          f"60-80 {braking_distance_m(70):.0f} m, >80 {braking_distance_m(90):.0f} m")
    print()
    print(f"Saved {os.path.join(EVAL_DIR, 'range_limit.csv')}")
    print(f"Saved {os.path.join(FIG_DIR, 'range_limit.png')}")


if __name__ == "__main__":
    main()
