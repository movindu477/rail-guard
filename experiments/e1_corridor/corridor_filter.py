"""E1: does the safety corridor filter the right things, and does it follow curves?

    python experiments/e1_corridor/corridor_filter.py
    python experiments/e1_corridor/corridor_filter.py --model models/railguard_best.pt   # earlier model
    python experiments/e1_corridor/corridor_filter.py --skip-clip                       # curves only

Part 1 - the 2-minute clip, two corridor widths, same frames, same detections:
  derived  envelope_factor 1.9 + 0.5 m margin = 2.09 m either side (PipelineConfig default)
  old      envelope_factor 3.0, no margin     = 2.51 m either side (the earlier x3 corridor)
  Counts: total detections, on-track detections, frames with any on-track
  detection (what would alert without persistence) and alert frames (with it).
  Both settings run through RailGuardPipeline.process_frame; the second reuses
  the first's YOLO and TEP-Net outputs for the frame (cached), so the only
  difference between them is the corridor.

Part 2 - curve renders: run the pipeline on each render and, on every truth row
the corridor covers, test whether BOTH true rail positions fall inside it.

Writes outputs/evaluation/e1_corridor.csv.
"""

import argparse
import csv
import glob
import os
from collections import Counter

import cv2
import numpy as np

from railguard.config import REPO_ROOT, PipelineConfig
from railguard.pipeline import RailGuardPipeline

VIDEO_IN = os.path.join(REPO_ROOT, "data", "videos", "processed", "test2min.mp4")
RENDERS = os.path.join(REPO_ROOT, "simulation", "renders")
OUT = os.path.join(REPO_ROOT, "outputs", "evaluation", "e1_corridor.csv")
SETTINGS = {"derived": dict(envelope_factor=1.9, safety_margin_m=0.5),
            "old": dict(envelope_factor=3.0, safety_margin_m=0.0)}


class _Cached:
    """Stands in for a model inside a second pipeline: returns the outputs the
    first pipeline's real model produced for the current frame."""

    def __init__(self, real, method):
        self.real, self.method, self.last = real, method, None
        self.names = getattr(real, "names", None)

    def record(self, *a, **k):
        self.last = getattr(self.real, self.method)(*a, **k)
        return self.last

    def replay(self, *a, **k):
        return self.last


def make_pair(model_path):
    """Two pipelines (derived, old corridor) sharing one set of model outputs per frame."""
    a = RailGuardPipeline(PipelineConfig(yolo_weights=model_path, **SETTINGS["derived"]))
    b = RailGuardPipeline(PipelineConfig(yolo_weights=model_path, **SETTINGS["old"]))
    yolo, tep = _Cached(a.model, "predict"), _Cached(a.tepnet, "detect")
    a.model = type("Y", (), {"predict": staticmethod(yolo.record), "names": a.model.names})()
    a.tepnet = type("T", (), {"detect": staticmethod(tep.record)})()
    b.model = type("Y", (), {"predict": staticmethod(yolo.replay), "names": b.model.names})()
    b.tepnet = type("T", (), {"detect": staticmethod(tep.replay)})()
    return {"derived": a, "old": b}


def clip_part(model_path, every):
    pipes = make_pair(model_path)
    cap = cv2.VideoCapture(VIDEO_IN)
    stats = {k: Counter() for k in pipes}
    n = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if n % every == 0:
            for name in ("derived", "old"):           # derived first: it fills the cache
                res = pipes[name].process_frame(frame)
                s = stats[name]
                s["frames"] += 1
                s["detections"] += len(res.detections)
                s["on_track_detections"] += len(res.threats)
                s["frames_with_on_track"] += bool(res.threats)
                s["alert_frames"] += res.alert is not None
        n += 1
        if n % 600 == 0:
            print(f"  clip frame {n}")
    cap.release()
    return stats


def curve_part():
    views = sorted(os.path.basename(p)[:-len("_truth.csv")]
                   for p in glob.glob(os.path.join(RENDERS, "curve_*_truth.csv")))
    if not views:   # earlier interactive renders, if the build_scene sweep has not been run
        views = [v for v in ("straight_ref", "curve1000", "curve500", "curve300", "curve150")
                 if os.path.exists(os.path.join(RENDERS, f"{v}_truth.csv"))]
    pipe = RailGuardPipeline(PipelineConfig())
    rows = []
    for v in views:
        img = cv2.imread(os.path.join(RENDERS, f"{v}_clean.png"))
        pipe._track = None                                   # fresh ego-path for each render
        res = pipe.process_frame(img)
        h = img.shape[0]
        truth = list(csv.DictReader(open(os.path.join(RENDERS, f"{v}_truth.csv"))))
        covered = hits = 0
        far = None
        for t in truth:
            y = int(round(float(t["row_y_px"])))
            if not 0 <= y < h or not res.corridor[y].any():
                continue
            sep = float(t.get("rail_sep_px") or t["true_rail_sep_px"])
            cx = float(t["track_centre_px"])
            xs = [int(round(cx - sep / 2)), int(round(cx + sep / 2))]
            inside = all(0 <= x < img.shape[1] and res.corridor[y, x] > 0 for x in xs)
            covered += 1
            hits += inside
            far = float(t.get("true_alongtrack_m") or t["true_distance_m"])
        rows.append({"render": v, "rows_covered": covered, "both_rails_inside": hits,
                     "hit_rate": round(hits / covered, 3) if covered else "",
                     "corridor_reaches_m": far if far is not None else "",
                     "track_rows_in_truth": len(truth)})
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=PipelineConfig().yolo_weights)
    ap.add_argument("--every", type=int, default=1, help="use every Nth clip frame")
    ap.add_argument("--skip-clip", action="store_true")
    args = ap.parse_args()

    out = []
    if not args.skip_clip:
        print(f"Part 1: clip, model {os.path.basename(args.model)}")
        stats = clip_part(args.model, args.every)
        print(f"\n{'':24s}{'derived 2.09 m':>16s}{'old 2.51 m':>14s}{'change':>10s}")
        for key in ("frames", "detections", "on_track_detections", "frames_with_on_track", "alert_frames"):
            a, b = stats["derived"][key], stats["old"][key]
            ch = f"{100 * (a / b - 1):+.0f}%" if b and key != "frames" else ""
            print(f"{key:24s}{a:>16d}{b:>14d}{ch:>10s}")
            out.append({"part": "clip", "model": os.path.basename(args.model), "item": key,
                        "derived": a, "old": b})

    print("\nPart 2: corridor vs true rails on the curve renders")
    print(f"{'render':22s}{'rows covered':>13s}{'both rails in':>15s}{'hit rate':>10s}{'reaches m':>11s}")
    for r in curve_part():
        print(f"{r['render']:22s}{r['rows_covered']:>13d}{r['both_rails_inside']:>15d}"
              f"{str(r['hit_rate']):>10s}{str(r['corridor_reaches_m']):>11s}")
        out.append({"part": "curves", "model": "", "item": r["render"],
                    "derived": f"{r['both_rails_inside']}/{r['rows_covered']} rows, reaches {r['corridor_reaches_m']} m",
                    "old": ""})

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=["part", "model", "item", "derived", "old"])
        wr.writeheader()
        wr.writerows(out)
    print(f"\nSaved {OUT}")


if __name__ == "__main__":
    main()
