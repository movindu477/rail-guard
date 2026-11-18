"""E4a: does track detection survive at night? Day cab ride vs night cab ride, no labels.

    python experiments/e4_illumination/day_vs_night.py
    python experiments/e4_illumination/day_vs_night.py --max-frames 600     # quick look

Both clips are forward-facing cab rides from YouTube with UNKNOWN cameras
(see SOURCES.md), so this experiment makes NO distance claims: nothing is
converted to metres. It reports whether the track was found and how far up
the image it reaches, in pixels and as a fraction of the frame.

Runs the pipeline's track stage (TEP-Net ego-path -> rail width per row, as in
RailGuardPipeline._update_track; object detection is not needed here) over both
clips and records per frame:
  track_found     TEP-Net returned an ego-path (>= 2 rail point pairs). TEP-Net
                  always returns one, so this is ~100% and says little on its own.
  converge        far rail width / near rail width. Real rails get closer with
                  distance, so on a real track this is well below 1; a path whose
                  rails stay apart or spread out cannot be the track.
  plausible       converge < 0.5: the honest "did it find the track" figure.
                  Necessary, not sufficient: it rejects impossible shapes but
                  cannot prove the rails are real (check the sample sheets).
  top_row         farthest (top-most) image row with a rail width
  top_frac        top_row / frame height (0 = top of image): how far up it reaches
  far_width_px    rail spacing at top_row, in pixels
  far_width_frac  far_width_px / frame width, so clips of different sizes compare
  luma            mean frame brightness (0-255)

Pixel extent still depends on each camera's field of view and mounting, which
differ between the clips and are unknown; the fractions remove frame size only.
Each clip gets a freshly loaded TEP-Net, because its auto-crop carries state
from frame to frame. Sample frames with the ego-path drawn on are saved to
outputs/figures/e4_samples_{day,night}.png.

Writes outputs/evaluation/e4_illumination.csv (summary) and
outputs/evaluation/e4_illumination_frames.csv (one row per frame).
"""

import argparse
import csv
import os
import sys

import cv2
import numpy as np
from PIL import Image

from railguard.config import REPO_ROOT
from railguard.core.geometry import (MAX_RAIL_CONVERGENCE, rail_convergence, rail_points,
                                     rail_width_by_row)
from railguard.segmentation.tepnet import DEFAULT_MODEL, load_tepnet

sys.path.insert(0, os.path.join(REPO_ROOT, "experiments", "e3_range"))
from range_limit import frame_limit  # noqa: E402  (same "farthest row" definition as E3)

VIDEOS = os.path.join(REPO_ROOT, "data", "videos")
DAY_CLIP = os.path.join(VIDEOS, "processed", "test2min.mp4")
NIGHT_CLIP = os.path.join(VIDEOS, "raw", "srilanka_night_full.mp4")   # cab ride, see SOURCES.md
EVAL_DIR = os.path.join(REPO_ROOT, "outputs", "evaluation")
FIG_DIR = os.path.join(REPO_ROOT, "outputs", "figures")
N_SAMPLES = 6
MAX_CONVERGE = MAX_RAIL_CONVERGENCE   # the pipeline's own plausibility gate (0.5)


def run_clip(name, path, device, max_frames):
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise SystemExit(f"ERROR: cannot open {path}")
    w, h = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if max_frames:
        total = min(total, max_frames)
    tepnet = load_tepnet(DEFAULT_MODEL, device)   # fresh: auto-crop state starts clean
    sample_at = set(np.linspace(0, total - 1, N_SAMPLES).astype(int).tolist())
    rows, samples = [], []
    for n in range(total):
        ok, frame = cap.read()
        if not ok:
            break
        egopath = tepnet.detect(Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)))
        found = bool(rail_points(egopath))
        widths = rail_width_by_row(egopath, h) if found else None
        lim = frame_limit(widths) if found else None
        row = {"clip": name, "frame": n, "track_found": 0, "converge": "", "plausible": 0,
               "top_row": "", "top_frac": "", "far_width_px": "", "far_width_frac": "",
               "luma": round(float(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).mean()), 1)}
        if lim is not None:
            top, wpx = lim
            conv = rail_convergence(widths)   # the same check RailGuardPipeline applies
            conv = 9.9 if conv is None else conv
            row.update(track_found=1, converge=round(conv, 3), plausible=int(conv < MAX_CONVERGE),
                       top_row=top, top_frac=round(top / h, 3), far_width_px=round(wpx, 2),
                       far_width_frac=round(wpx / w, 4))
        rows.append(row)
        if n in sample_at:
            samples.append(draw_sample(frame, egopath, row))
        if (n + 1) % 1200 == 0:
            print(f"  {name}: {n + 1}/{total}")
    cap.release()
    return rows, samples, (w, h)


def draw_sample(frame, egopath, row):
    im = frame.copy()
    if egopath is not None:
        for rail in egopath:
            pts = np.array([(int(x), int(y)) for x, y in rail], np.int32)
            if len(pts) > 1:
                cv2.polylines(im, [pts], False, (0, 255, 255), 3, cv2.LINE_AA)
    label = (f"frame {row['frame']}  far/near {row['converge']}  "
             f"{'PLAUSIBLE' if row['plausible'] else 'NOT A TRACK'}"
             if row["track_found"] else f"frame {row['frame']}  no track")
    cv2.rectangle(im, (0, 0), (im.shape[1], 46), (0, 0, 0), -1)
    cv2.putText(im, label + f"  luma {row['luma']}", (12, 32), cv2.FONT_HERSHEY_SIMPLEX, 1.0,
                (255, 255, 255), 2, cv2.LINE_AA)
    return cv2.resize(im, (960, int(960 * im.shape[0] / im.shape[1])))


def contact_sheet(samples, path):
    cols = 3
    while len(samples) % cols:
        samples.append(np.zeros_like(samples[0]))
    cv2.imwrite(path, np.vstack([np.hstack(samples[i:i + cols]) for i in range(0, len(samples), cols)]))


def summarise(name, path, rows, size):
    w, h = size
    good = [r for r in rows if r["plausible"]]
    col = lambda k: np.array([r[k] for r in good], float)
    pct = lambda a, q: round(float(np.percentile(a, q)), 3) if len(a) else ""
    return {
        "clip": name, "file": os.path.basename(path), "frame_size": f"{w}x{h}", "frames": len(rows),
        "pct_track_raw": round(100 * sum(r["track_found"] for r in rows) / len(rows), 1),
        "pct_plausible": round(100 * len(good) / len(rows), 1),
        # over plausible frames; "far" percentiles: p5 of top row / width = the farthest-reaching 5%
        "top_frac_median": pct(col("top_frac"), 50), "top_frac_p5": pct(col("top_frac"), 5),
        "far_width_px_median": pct(col("far_width_px"), 50), "far_width_px_p5": pct(col("far_width_px"), 5),
        "far_width_frac_median": pct(col("far_width_frac"), 50),
        "far_width_frac_p5": pct(col("far_width_frac"), 5),
        "luma_median": pct(np.array([r["luma"] for r in rows], float), 50),
        "distance_claims": "none: camera unknown (SOURCES.md)",
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--day", default=DAY_CLIP)
    ap.add_argument("--night", default=NIGHT_CLIP)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--max-frames", type=int, help="per clip, for a quick look")
    args = ap.parse_args()

    os.makedirs(EVAL_DIR, exist_ok=True)
    os.makedirs(FIG_DIR, exist_ok=True)
    all_rows, summary = [], []
    for name, path in (("day", args.day), ("night", args.night)):
        print(f"{name}: {os.path.basename(path)}")
        rows, samples, size = run_clip(name, path, args.device, args.max_frames)
        all_rows += rows
        summary.append(summarise(name, path, rows, size))
        contact_sheet(samples, os.path.join(FIG_DIR, f"e4_samples_{name}.png"))

    with open(os.path.join(EVAL_DIR, "e4_illumination_frames.csv"), "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(all_rows[0]))
        wr.writeheader()
        wr.writerows(all_rows)
    with open(os.path.join(EVAL_DIR, "e4_illumination.csv"), "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(summary[0]))
        wr.writeheader()
        wr.writerows(summary)

    print()
    print(f"{'':34s}" + "".join(f"{s['clip']:>14s}" for s in summary))
    for key, label in [("frame_size", "frame size"), ("frames", "frames"),
                       ("luma_median", "brightness median (0-255)"),
                       ("pct_track_raw", "% track returned (raw)"),
                       ("pct_plausible", "% PLAUSIBLE track"),
                       ("top_frac_median", "top of track, frac of height *"),
                       ("top_frac_p5", "  farthest 5% *"),
                       ("far_width_px_median", "far rail spacing px *"),
                       ("far_width_px_p5", "  farthest 5% (px) *"),
                       ("far_width_frac_median", "far rail spacing, frac of width *"),
                       ("far_width_frac_p5", "  farthest 5% *")]:
        print(f"{label:34s}" + "".join(f"{str(s[key]):>14s}" for s in summary))
    print(f"\n* plausible frames only (far/near rail width < {MAX_CONVERGE}). Smaller = reaches farther.")
    print("No distances: both cameras are unknown (SOURCES.md).")
    print(f"Check the rails by eye: {os.path.join(FIG_DIR, 'e4_samples_night.png')}")
    print(f"Saved {os.path.join(EVAL_DIR, 'e4_illumination.csv')}")


if __name__ == "__main__":
    main()
