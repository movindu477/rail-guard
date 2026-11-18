"""How often the track plausibility gate fires, per clip.

    python experiments/e4_illumination/track_gate.py

The gate (railguard.core.geometry.track_plausible, applied in RailGuardPipeline)
marks a frame TRACK NOT DETECTED when its rails do not converge with distance.
A good gate is invisible on footage the track detector handles and loud on
footage it does not:
  day       daytime cab ride                     -> expect ~0% flagged
  night     night cab ride (headlight-lit)       -> expect ~0% flagged
  sidedoor  earlier night clip, filmed from a side door, outside TEP-Net's
            training conditions                  -> expect many frames flagged

Uses the E4a frame loop (fresh TEP-Net per clip). Writes
outputs/evaluation/e4_track_gate.csv.
"""

import csv
import os
import sys

from railguard.config import REPO_ROOT
from railguard.core.geometry import MAX_RAIL_CONVERGENCE

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from day_vs_night import DAY_CLIP, EVAL_DIR, NIGHT_CLIP, run_clip  # noqa: E402

CLIPS = [
    ("day", DAY_CLIP),
    ("night", NIGHT_CLIP),
    ("sidedoor", os.path.join(REPO_ROOT, "data", "videos", "processed", "night5min.mp4")),
]


def main():
    out = []
    for name, path in CLIPS:
        print(f"{name}: {os.path.basename(path)}")
        rows, _, _ = run_clip(name, path, "cuda", None)
        n = len(rows)
        flagged = sum(1 for r in rows if not r["plausible"])
        none = sum(1 for r in rows if not r["track_found"])
        out.append({"clip": name, "file": os.path.basename(path), "frames": n,
                    "flagged": flagged, "pct_flagged": round(100 * flagged / n, 1),
                    "of_which_no_track": none, "gate": f"far/near rail spacing >= {MAX_RAIL_CONVERGENCE}"})
    path = os.path.join(EVAL_DIR, "e4_track_gate.csv")
    with open(path, "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(out[0]))
        wr.writeheader()
        wr.writerows(out)
    print(f"\n{'clip':10s}{'file':>24s}{'frames':>8s}{'flagged':>9s}{'%':>7s}")
    for r in out:
        print(f"{r['clip']:10s}{r['file']:>24s}{r['frames']:>8d}{r['flagged']:>9d}{r['pct_flagged']:>7.1f}")
    print(f"Saved {path}")


if __name__ == "__main__":
    main()
