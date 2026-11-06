"""E2: distance accuracy by distance band, for every simulation configuration.

    python experiments/e2_distance/distance_accuracy.py            # uses the existing per-row results
    python experiments/e2_distance/distance_accuracy.py --rerun    # re-runs TEP-Net first
    python experiments/e2_distance/distance_accuracy.py --views wide_pitch_m3 curve_wide_r300

Reports by distance band (0-50, 50-100, 100-200, 200-300, 300+ m), not as one
aggregate. Per configuration and band:
  TEP-Net + formula (what the pipeline reports, pitch-corrected) against the true
  distance along the track: n, mean error %, SD, and how many readings were
  FURTHER than the truth (not safe-sided: those would alert late), the worst
  over-read, and how many are still further after PipelineConfig.distance_margin
  (the pipeline compares (1 - margin) x distance with the braking distance).
  Formula only (perfect rails through the same formula and pitch correction):
  mean error % and the largest error in millimetres, so the formula's own
  accuracy sits in the same table as the detection error.

Per-row TEP-Net results come from simulation/validate_tepnet.py
(outputs/evaluation/tepnet_sim_{view}.csv); --rerun regenerates them with it.
Only rows where TEP-Net returned rails count as readings.

Writes outputs/evaluation/e2_distance.csv.
"""

import argparse
import csv
import glob
import os
import sys

import numpy as np

from railguard.config import REPO_ROOT, PipelineConfig
from railguard.core.distance import depth_to_ground
from railguard.core.geometry import GAUGE_M

sys.path.insert(0, os.path.join(REPO_ROOT, "simulation"))   # simulation/ is scripts, not a package
from validate_tepnet import EVAL_DIR, RENDERS, read_camera, read_truth  # noqa: E402

BANDS = [(0, 50), (50, 100), (100, 200), (200, 300), (300, float("inf"))]
OUT = os.path.join(EVAL_DIR, "e2_distance.csv")


def band_of(d):
    return next(f"{lo:g}-{hi:g} m" if hi != float("inf") else f"{lo:g}+ m" for lo, hi in BANDS if lo <= d < hi)


def all_views():
    """Every full-frame render (crops and their inputs are not configurations)."""
    return sorted(os.path.basename(p)[:-len("_clean.png")] for p in glob.glob(os.path.join(RENDERS, "*_clean.png")))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--views", nargs="*", help="default: every render in simulation/renders")
    ap.add_argument("--rerun", action="store_true", help="re-run TEP-Net via validate_tepnet first")
    args = ap.parse_args()
    views = args.views or all_views()
    margin = PipelineConfig().distance_margin

    if args.rerun:
        from railguard.segmentation.tepnet import DEFAULT_MODEL, load_tepnet
        from validate_tepnet import run_view
        tepnet = load_tepnet(DEFAULT_MODEL, "cuda")
        for v in views:
            run_view(v, tepnet)

    out = []
    for v in views:
        fx, pitch, cam_h = read_camera(v)
        truth = read_truth(v)
        res_path = os.path.join(EVAL_DIR, f"tepnet_sim_{v}.csv")
        if not truth:
            out.append({"view": v, "band": "all", "n": 0, "note": "track never fully in frame"})
            continue
        if not os.path.exists(res_path):
            print(f"  {v}: no TEP-Net results yet (run with --rerun)")
            continue
        readings = [r for r in csv.DictReader(open(res_path)) if r["corrected_error_pct"] != ""]
        for lo, hi in BANDS:
            name = band_of(lo)
            errs = np.array([float(r["corrected_error_pct"]) for r in readings
                             if lo <= float(r["true_distance_m"]) < hi])
            # formula only: perfect rails, same formula and pitch correction
            f_m = [depth_to_ground(fx * GAUGE_M / t["true_rail_sep_px"], pitch, cam_h) - t["true_distance_m"]
                   for t in truth if lo <= t["true_distance_m"] < hi]
            f_pct = [100 * e / t["true_distance_m"] for e, t in
                     zip(f_m, [t for t in truth if lo <= t["true_distance_m"] < hi])]
            if not len(errs) and not f_m:
                continue
            further = int((errs > 0).sum())
            # effective = measured x (1 - margin); still further than the truth?
            after = int((((1 + errs / 100) * (1 - margin)) > 1).sum())
            out.append({
                "view": v, "band": name, "n": len(errs),
                "mean_error_pct": round(float(errs.mean()), 2) if len(errs) else "",
                "sd_pct": round(float(errs.std(ddof=1)), 2) if len(errs) > 1 else "",
                "n_further_than_truth": further if len(errs) else "",
                "all_safe_sided": ("yes" if further == 0 else "no") if len(errs) else "",
                "worst_over_read_pct": round(float(errs.max()), 2) if len(errs) and errs.max() > 0 else "",
                "n_further_after_margin": after if len(errs) else "",
                "formula_n": len(f_m),
                "formula_mean_error_pct": round(float(np.mean(f_pct)), 3) if f_m else "",
                "formula_max_abs_error_mm": round(1000 * float(np.max(np.abs(f_m))), 1) if f_m else "",
                "note": "",
            })

    fields = ["view", "band", "n", "mean_error_pct", "sd_pct", "n_further_than_truth", "all_safe_sided",
              "worst_over_read_pct", "n_further_after_margin",
              "formula_n", "formula_mean_error_pct", "formula_max_abs_error_mm", "note"]
    with open(OUT, "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=fields, restval="")
        wr.writeheader()
        wr.writerows(out)

    print(f"{'view':24s}{'band':>11s}{'n':>5s}{'mean %':>8s}{'SD %':>7s}{'further':>9s}{'worst %':>9s}"
          f"{'after margin':>13s}{'formula %':>11s}{'formula max mm':>16s}")
    for r in out:
        if r.get("note"):
            print(f"{r['view']:24s}  {r['note']}")
            continue
        print(f"{r['view']:24s}{r['band']:>11s}{r['n']:>5d}{str(r['mean_error_pct']):>8s}{str(r['sd_pct']):>7s}"
              f"{(str(r['n_further_than_truth']) + '/' + str(r['n'])) if r['n'] else '-':>9s}"
              f"{str(r['worst_over_read_pct']):>9s}{str(r['n_further_after_margin']):>13s}"
              f"{str(r['formula_mean_error_pct']):>11s}{str(r['formula_max_abs_error_mm']):>16s}")
    bad = [r for r in out if r.get("n_further_after_margin")]
    total = sum(r["n"] for r in out if r.get("n"))
    print(f"\nWith distance_margin {margin:.0%}: {sum(r['n_further_after_margin'] for r in bad)} of {total} "
          f"readings still further than the truth"
          + (", in: " + ", ".join(sorted({r['view'] for r in bad})) if bad else ""))
    print(f"Saved {OUT}")


if __name__ == "__main__":
    main()
