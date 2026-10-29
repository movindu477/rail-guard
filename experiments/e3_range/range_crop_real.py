"""E3: does the vanishing-point crop extend TEP-Net's reach on REAL footage?

    python experiments/e3_range/range_crop_real.py
    python experiments/e3_range/range_crop_real.py --every 15 --zoom 9

Per sampled frame:
  1. TEP-Net on the full frame: where its rails stop (top row, rail
     separation there) and the track centre at that row.
  2. Crop a band around that point: the crop's bottom edge sits --overlap px
     below where the full-frame rails stop, its height gives a --zoom
     upscale to the frame size (16:9 kept), centred on the track there.
  3. TEP-Net on the upscaled crop; its rails are mapped back to frame pixels.

There is no ground truth on this footage, so reach is reported as
  - the rail separation in px at the farthest row (focal-length independent)
  - a distance from the ASSUMED focal length (60 deg field of view)
and the crop is checked against the full frame where both see the track:
  - overlap agreement: rail separation, crop vs full frame, on the shared rows
  - continuity: track centre offset where the crop meets the full-frame rails
A crop that hallucinated rails would disagree on both.

Outputs:
  outputs/evaluation/range_crop_real.csv          one row per frame
  outputs/evaluation/range_crop_real_summary.csv  medians
  outputs/figures/range_crop_real_examples.png    full frame (orange) + crop (magenta) rails
"""

import argparse
import csv
import os

import cv2
import numpy as np
from PIL import Image

from railguard.config import REPO_ROOT, PipelineConfig
from railguard.core.geometry import GAUGE_M, rail_width_by_row, track_centre_by_row
from railguard.segmentation.tepnet import DEFAULT_MODEL, load_tepnet

VIDEO_IN = os.path.join(REPO_ROOT, "data", "videos", "processed", "test2min.mp4")
EVAL_DIR = os.path.join(REPO_ROOT, "outputs", "evaluation")
FIG_DIR = os.path.join(REPO_ROOT, "outputs", "figures")


def detect(tepnet, bgr):
    return tepnet.detect(Image.fromarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)))


def top_of(width):
    rows = np.flatnonzero(width > 0)
    return int(rows[0]) if rows.size else None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", default=VIDEO_IN)
    ap.add_argument("--every", type=int, default=30, help="use every Nth frame")
    ap.add_argument("--zoom", type=float, default=9.0, help="upscale factor of the crop")
    ap.add_argument("--overlap", type=int, default=20, help="crop rows below the full-frame stop row")
    args = ap.parse_args()

    tepnet = load_tepnet(DEFAULT_MODEL, "cuda")
    cap = cv2.VideoCapture(args.input)
    W, H = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fx = PipelineConfig().focal_px(W)
    crop_h = int(round(H / args.zoom))
    crop_w = int(round(crop_h * W / H))
    print(f"{os.path.basename(args.input)} {W}x{H}, assumed fx {fx:.0f} px; crop {crop_w}x{crop_h} -> {args.zoom:g}x")

    rows, examples, i = [], [], -1
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        i += 1
        if i % args.every:
            continue
        rec = {"frame": i, "full_top_row": "", "full_top_sep_px": "", "full_reach_m": "",
               "crop_top_row": "", "crop_top_sep_px": "", "crop_reach_m": "",
               "overlap_rows": 0, "overlap_sep_diff_pct": "", "junction_centre_offset_px": ""}
        ego = detect(tepnet, frame)
        w_full = rail_width_by_row(ego, H)
        c_full = track_centre_by_row(ego, H)
        top = top_of(w_full)
        if top is None:
            rows.append(rec)
            continue
        rec.update(full_top_row=top, full_top_sep_px=round(float(w_full[top]), 1),
                   full_reach_m=round(fx * GAUGE_M / float(w_full[top]), 1))

        # crop band around where the full-frame rails stop
        y1 = min(H, top + args.overlap)
        y0 = max(0, y1 - crop_h)
        x0 = int(round(min(max(float(c_full[top]) - crop_w / 2, 0), W - crop_w)))
        big = cv2.resize(frame[y0:y1, x0:x0 + crop_w], (W, H), interpolation=cv2.INTER_CUBIC)
        ego_c = detect(tepnet, big)
        if ego_c is not None:
            sx, sy = crop_w / W, (y1 - y0) / H
            back = tuple([(x0 + float(x) * sx, y0 + float(y) * sy) for x, y in rail] for rail in ego_c)
            w_crop = rail_width_by_row(back, H)
            c_crop = track_centre_by_row(back, H)
            ctop = top_of(w_crop)
            if ctop is not None:
                rec.update(crop_top_row=ctop, crop_top_sep_px=round(float(w_crop[ctop]), 2),
                           crop_reach_m=round(fx * GAUGE_M / float(w_crop[ctop]), 1))
                shared = np.flatnonzero((w_full > 0) & (w_crop > 0))
                if shared.size:
                    rec["overlap_rows"] = int(shared.size)
                    rec["overlap_sep_diff_pct"] = round(
                        float(np.median(100 * (w_crop[shared] / w_full[shared] - 1))), 1)
                    j = int(shared[0])     # farthest shared row: where the crop takes over
                    rec["junction_centre_offset_px"] = round(float(c_crop[j] - c_full[j]), 1)
                if len(examples) < 4 and i % (args.every * 20) == 0:
                    examples.append((i, frame.copy(), ego, back, (x0, y0, crop_w, y1 - y0)))
        rows.append(rec)
        if len(rows) % 20 == 0:
            print(f"  {len(rows)} frames done")
    cap.release()

    os.makedirs(EVAL_DIR, exist_ok=True)
    with open(os.path.join(EVAL_DIR, "range_crop_real.csv"), "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(rows[0]))
        wr.writeheader()
        wr.writerows(rows)

    def col(key, src=rows):
        return np.array([r[key] for r in src if r[key] != ""], float)

    both = [r for r in rows if r["full_top_row"] != "" and r["crop_top_row"] != ""]
    gain = np.array([float(r["crop_reach_m"]) / float(r["full_reach_m"]) for r in both])
    summary = {
        "frames": len(rows), "full_frame_with_track": len(col("full_top_row")),
        "crop_with_track": len(col("crop_top_row")),
        "full_reach_m_median": round(float(np.median(col("full_reach_m"))), 1),
        "full_reach_m_p95": round(float(np.percentile(col("full_reach_m"), 95)), 1),
        "full_top_sep_px_median": round(float(np.median(col("full_top_sep_px"))), 1),
        "crop_reach_m_median": round(float(np.median(col("crop_reach_m"))), 1) if both else "",
        "crop_reach_m_p95": round(float(np.percentile(col("crop_reach_m"), 95)), 1) if both else "",
        "crop_top_sep_px_median": round(float(np.median(col("crop_top_sep_px"))), 2) if both else "",
        "reach_gain_median_x": round(float(np.median(gain)), 2) if both else "",
        "overlap_sep_diff_pct_median": round(float(np.median(col("overlap_sep_diff_pct"))), 1) if both else "",
        "overlap_sep_diff_pct_iqr": (f"{np.percentile(col('overlap_sep_diff_pct'), 25):.1f} to "
                                     f"{np.percentile(col('overlap_sep_diff_pct'), 75):.1f}") if both else "",
        "junction_offset_px_median_abs": round(float(np.median(np.abs(col("junction_centre_offset_px")))), 1) if both else "",
        "assumed_fx_px": round(fx, 1), "zoom": args.zoom,
    }
    with open(os.path.join(EVAL_DIR, "range_crop_real_summary.csv"), "w", newline="") as f:
        wr = csv.writer(f)
        for k, v in summary.items():
            wr.writerow((k, v))

    # example figure: full-frame rails orange, crop rails magenta, crop box cyan
    tiles = []
    for i, frame, ego, back, (x0, y0, cw, ch) in examples:
        im = frame.copy()
        for rails, colour in ((ego, (0, 140, 255)), (back, (255, 0, 255))):
            for rail in rails or ():
                cv2.polylines(im, [np.array(rail, np.int32)], False, colour, 2, cv2.LINE_AA)
        cv2.rectangle(im, (x0, y0), (x0 + cw, y0 + ch), (255, 220, 0), 1)
        k = min(3.0, (W / 2) / cw, (H / 2) / ch)    # inset at most a quarter of the frame
        zoom = cv2.resize(im[y0:y0 + ch, x0:x0 + cw], (int(cw * k), int(ch * k)), interpolation=cv2.INTER_NEAREST)
        im[10:10 + zoom.shape[0], W - zoom.shape[1] - 10:W - 10] = zoom
        cv2.putText(im, f"frame {i}", (20, 40), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (255, 255, 255), 2)
        tiles.append(cv2.resize(im, (W // 2, H // 2)))
    if tiles:
        while len(tiles) % 2:
            tiles.append(np.zeros_like(tiles[0]))
        grid = np.vstack([np.hstack(tiles[k:k + 2]) for k in range(0, len(tiles), 2)])
        os.makedirs(FIG_DIR, exist_ok=True)
        cv2.imwrite(os.path.join(FIG_DIR, "range_crop_real_examples.png"), grid)

    print()
    for k, v in summary.items():
        print(f"  {k:32s} {v}")
    print(f"\nSaved {EVAL_DIR}\\range_crop_real*.csv and {FIG_DIR}\\range_crop_real_examples.png")


if __name__ == "__main__":
    main()
