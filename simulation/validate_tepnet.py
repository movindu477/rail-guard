"""How much distance error does track detection alone cause, and how far does it reach?

    python simulation/validate_tepnet.py                          # wide, tele
    python simulation/validate_tepnet.py --views wide_pitch_m3 wide_pitch_p0 wide_pitch_p3 wide_pitch_p6
    python simulation/validate_tepnet.py --sweep                  # every *_pitch_* render

For each Blender render simulation/renders/{view}_clean.png this runs TEP-Net
exactly as the pipeline does, turns its rails into a rail separation per image
row (railguard.core.geometry.rail_width_by_row) and converts that to distance
with the render's own focal length ({view}_camera.txt):

    D = fx * 1.676 / separation

and compares it row by row with {view}_truth.csv. Two errors are reported:
  detection error  D from TEP-Net's separation vs D from the TRUE separation,
                   same formula: the error caused by track detection alone
  total error      D from TEP-Net's separation vs the true ground distance.
                   The formula gives depth along the camera's line of sight, so
                   with a tilted camera it differs from ground distance (up to
                   ~3% at 6 deg, ~12% at 15 deg) even with perfect rails.
  corrected error  the same after railguard.core.distance.depth_to_ground(),
                   the pipeline's pitch correction; it should equal the
                   detection error, i.e. only TEP-Net's own error remains.

Reach: the top-most image row where TEP-Net still returns rails, as a share of
the image height, and the true distance at that row. Valid range: the
longest continuous stretch along the track where the detection error stays
within +-VALID_PCT % (it ends at BAD_RUN consecutive rows outside). TEP-Net can
return rails that are badly wrong, and an error that only crosses zero on its
way from +70% to -25% must not count as reach.

Outputs:
    outputs/evaluation/tepnet_sim_{view}.csv     every truth row: true vs predicted
    outputs/evaluation/tepnet_sim_summary.csv    one row per view (reach, errors)
    outputs/figures/tepnet_sim_{view}.png        TEP-Net rails (orange) over the true rails (green)
"""

import argparse
import csv
import glob
import os

import cv2
import numpy as np
from PIL import Image

from railguard.config import REPO_ROOT
from railguard.core.distance import depth_to_ground
from railguard.core.geometry import GAUGE_M, rail_width_by_row, track_centre_by_row
from railguard.segmentation.tepnet import DEFAULT_MODEL, load_tepnet

RENDERS = os.path.join(REPO_ROOT, "simulation", "renders")
EVAL_DIR = os.path.join(REPO_ROOT, "outputs", "evaluation")
FIG_DIR = os.path.join(REPO_ROOT, "outputs", "figures")
VALID_PCT = 10.0
BAD_RUN = 5
REPORT_AT = (6, 10, 15, 20, 30, 40, 50, 60, 75, 100, 150, 200, 300, 400, 500, 600)


def read_camera(view):
    with open(os.path.join(RENDERS, f"{view}_camera.txt")) as f:
        kv = dict(line.strip().split("=", 1) for line in f if "=" in line)
    if abs(float(kv["gauge_m"]) - GAUGE_M) > 1e-6:
        raise SystemExit(f"{view}: render gauge {kv['gauge_m']} differs from GAUGE_M {GAUGE_M}")
    height = float(kv["cam_height_m"]) - float(kv["rail_top_z"])    # camera above the rail tops
    return float(kv["fx_px"]), float(kv.get("pitch_deg", 0.0)), height


def read_truth(view):
    with open(os.path.join(RENDERS, f"{view}_truth.csv")) as f:
        return [{k: float(v) for k, v in r.items()} for r in csv.DictReader(f)]


def valid_stretch(covered):
    """(near m, far m) of the longest continuous stretch along the track where
    the detection error stays within VALID_PCT; a stretch ends at BAD_RUN
    consecutive rows outside it. (None, None) if there is no such stretch."""
    best, start, last_good, bad, count, best_count = (None, None), None, None, 0, 0, 0
    for r in sorted(covered, key=lambda r: r["true_distance_m"]):
        if abs(r["detection_error_pct"]) <= VALID_PCT:
            if start is None:
                start, count = r["true_distance_m"], 0
            last_good, bad, count = r["true_distance_m"], 0, count + 1
            if count > best_count:
                best, best_count = (start, last_good), count
        else:
            bad += 1
            if bad >= BAD_RUN:
                start, bad = None, 0
    return best


def load_render(view):
    return cv2.imread(os.path.join(RENDERS, f"{view}_clean.png"))   # BGR, alpha dropped


def compare(view, egopath, h, tag=None, image=None, verbose=True):
    """Score an ego-path (in the render's own pixel coordinates) against the
    truth rows of `view`. Writes the per-row table and overlay; returns a summary."""
    name = tag or view
    fx, pitch, cam_h = read_camera(view)
    truth = read_truth(view)
    rows = []
    width = rail_width_by_row(egopath, h) if egopath is not None else np.zeros(h)
    centre = track_centre_by_row(egopath, h) if egopath is not None else np.zeros(h)
    for t in truth:
        y = int(round(t["row_y_px"]))
        sep = float(width[y]) if 0 <= y < h else 0.0
        r = {"true_distance_m": t["true_distance_m"], "row_y_px": t["row_y_px"],
             "true_sep_px": t["true_rail_sep_px"], "pred_sep_px": "", "pred_distance_m": "",
             "detection_error_pct": "", "total_error_m": "", "total_error_pct": "",
             "corrected_distance_m": "", "corrected_error_pct": "", "centre_error_px": ""}
        if sep > 0:
            d = fx * GAUGE_M / sep
            d_formula = fx * GAUGE_M / t["true_rail_sep_px"]      # perfect rails, same formula
            r.update(pred_sep_px=round(sep, 2), pred_distance_m=round(d, 2),
                     detection_error_pct=round(100 * (d / d_formula - 1), 2),
                     total_error_m=round(d - t["true_distance_m"], 2),
                     total_error_pct=round(100 * (d / t["true_distance_m"] - 1), 2),
                     corrected_distance_m=round(depth_to_ground(d, pitch, cam_h), 2),
                     corrected_error_pct=round(100 * (depth_to_ground(d, pitch, cam_h) / t["true_distance_m"] - 1), 2),
                     centre_error_px=round(float(centre[y]) - t["track_centre_px"], 1))
        rows.append(r)

    os.makedirs(EVAL_DIR, exist_ok=True)
    with open(os.path.join(EVAL_DIR, f"tepnet_sim_{name}.csv"), "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(rows[0]))
        wr.writeheader()
        wr.writerows(rows)

    if image is not None:
        fig = image.copy()
        for t in truth:
            y, half, cx = int(round(t["row_y_px"])), t["true_rail_sep_px"] / 2, t["track_centre_px"]
            for x in (cx - half, cx + half):
                cv2.circle(fig, (int(round(x)), y), 2, (0, 200, 0), -1)
        for rail in (egopath or ()):
            pts = np.array([[float(x), float(y)] for x, y in rail], np.int32)
            cv2.polylines(fig, [pts], False, (0, 140, 255), 2, cv2.LINE_AA)
        os.makedirs(FIG_DIR, exist_ok=True)
        cv2.imwrite(os.path.join(FIG_DIR, f"tepnet_sim_{name}.png"), fig)

    covered = [r for r in rows if r["pred_sep_px"] != ""]
    summary = {"view": name, "pitch_deg": pitch, "fx_px": round(fx, 1),
               "track_visible_from_m": min(t["true_distance_m"] for t in truth),
               "track_rows_px": f"{min(t['row_y_px'] for t in truth):.0f}-{max(t['row_y_px'] for t in truth):.0f}",
               "rows_covered": f"{len(covered)}/{len(rows)}",
               "stop_row_px": "", "stop_row_pct": "", "reach_m": "", "valid_from_m": "", "valid_reach_m": "", "nearest_m": "",
               "median_detection_error_pct": "", "median_total_error_pct": "", "worst_total_error_pct": "",
               "median_corrected_error_pct": "", "worst_corrected_error_pct": ""}
    if covered:
        top = min(covered, key=lambda r: r["row_y_px"])
        det = np.array([r["detection_error_pct"] for r in covered])
        tot = np.array([r["total_error_pct"] for r in covered])
        cor = np.array([r["corrected_error_pct"] for r in covered])
        summary.update(stop_row_px=round(top["row_y_px"]), stop_row_pct=round(100 * top["row_y_px"] / h, 1),
                       reach_m=top["true_distance_m"],
                       valid_from_m=valid_stretch(covered)[0] or "none",
                       valid_reach_m=valid_stretch(covered)[1] or "none",
                       nearest_m=min(r["true_distance_m"] for r in covered),
                       median_detection_error_pct=round(float(np.median(det)), 1),
                       median_total_error_pct=round(float(np.median(tot)), 1),
                       worst_total_error_pct=round(float(tot[np.argmax(np.abs(tot))]), 1),
                       median_corrected_error_pct=round(float(np.median(cor)), 1),
                       worst_corrected_error_pct=round(float(cor[np.argmax(np.abs(cor))]), 1))

    if verbose:
        print(f"\n== {name}: pitch {pitch:+g} deg, fx {fx:.1f} px, rows covered {summary['rows_covered']}")
        if not covered:
            print("   TEP-Net found NO rails over the true track")
            return summary
        print(f"   stops at row {summary['stop_row_px']} ({summary['stop_row_pct']}% of height) "
              f"-> reach {summary['reach_m']:g} m, valid range (|error| <= {VALID_PCT:g}%) "
              f"{summary['valid_from_m']}-{summary['valid_reach_m']} m; track visible from {summary['track_visible_from_m']:g} m")
        print(f"   {'true m':>7s} {'pred m':>8s} {'detect %':>9s} {'total %':>8s} {'true sep':>9s} {'pred sep':>9s}")
        shown = set()
        for d in REPORT_AT:
            r = min(rows, key=lambda r: abs(r["true_distance_m"] - d))
            if abs(r["true_distance_m"] - d) > 0.5 * d or r["true_distance_m"] in shown:
                continue
            shown.add(r["true_distance_m"])
            if r["pred_sep_px"] == "":
                print(f"   {r['true_distance_m']:7g} {'-':>8s} {'-':>9s} {'-':>8s} {r['true_sep_px']:9.1f} {'none':>9s}")
            else:
                print(f"   {r['true_distance_m']:7g} {r['pred_distance_m']:8.1f} {r['detection_error_pct']:+9.1f} "
                      f"{r['total_error_pct']:+8.1f} {r['true_sep_px']:9.1f} {r['pred_sep_px']:9.1f}")
        print(f"   median error: detection {summary['median_detection_error_pct']:+}%, "
              f"total {summary['median_total_error_pct']:+}% (worst {summary['worst_total_error_pct']:+}%), "
              f"pitch-corrected {summary['median_corrected_error_pct']:+}% (worst {summary['worst_corrected_error_pct']:+}%)")
    return summary


def run_view(view, tepnet):
    bgr = load_render(view)
    egopath = tepnet.detect(Image.fromarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)))
    return compare(view, egopath, bgr.shape[0], image=bgr)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--views", nargs="*", default=["wide", "tele"])
    ap.add_argument("--sweep", action="store_true", help="every *_pitch_* render in simulation/renders")
    args = ap.parse_args()
    views = args.views
    if args.sweep:
        views = sorted({os.path.basename(p)[:-len("_clean.png")]
                        for p in glob.glob(os.path.join(RENDERS, "*_pitch_*_clean.png"))},
                       key=lambda v: (v.split("_")[0] != "wide", read_camera(v)[1]))   # by pitch

    print(f"TEP-Net model: {DEFAULT_MODEL}")
    tepnet = load_tepnet(DEFAULT_MODEL, "cuda")
    summaries = [run_view(v, tepnet) for v in views]

    with open(os.path.join(EVAL_DIR, "tepnet_sim_summary.csv"), "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(summaries[0]))
        wr.writeheader()
        wr.writerows(summaries)
    print(f"\n{'view':16s}{'pitch':>6s}{'% height':>9s}{'valid range m':>15s}"
          f"{'detect err':>11s}{'uncorrected':>12s}{'corrected':>10s}{'corr. worst':>12s}")
    for s in summaries:
        rng = f"{s['valid_from_m']}-{s['valid_reach_m']}"
        print(f"{s['view']:16s}{s['pitch_deg']:+6g}{str(s['stop_row_pct']):>9s}{rng:>15s}"
              f"{str(s['median_detection_error_pct']):>10s}%{str(s['median_total_error_pct']):>11s}%"
              f"{str(s['median_corrected_error_pct']):>9s}%{str(s['worst_corrected_error_pct']):>11s}%")
    print(f"\nPer-view tables and summary: {EVAL_DIR}   Overlays: {FIG_DIR}")


if __name__ == "__main__":
    main()
