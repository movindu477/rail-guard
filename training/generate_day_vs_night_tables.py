import csv
import glob
import math
import os
import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DAY_DIR = os.path.join(ROOT, "data", "dataset", "testset_manual")
NIGHT_DIR = os.path.join(ROOT, "data", "dataset", "testset_night")
TABLES_DIR = os.path.join(ROOT, "outputs", "tables")
os.makedirs(TABLES_DIR, exist_ok=True)

BANDS = [(0, 20, "<20 px"), (20, 50, "20-50 px"), (50, 100, "50-100 px"), (100, 1e9, ">100 px")]


def wilson_ci(k, n, z=1.96):
    if n == 0:
        return None, None
    p = k / n
    denom = 1 + (z ** 2) / n
    center = (p + (z ** 2) / (2 * n)) / denom
    margin = (z / denom) * math.sqrt((p * (1 - p)) / n + (z ** 2) / (4 * (n ** 2)))
    return round(max(0.0, center - margin), 3), round(min(1.0, center + margin), 3)


def get_boxes(folder):
    imgs = sorted(glob.glob(os.path.join(folder, "images", "*.jpg")))
    heights_px = []
    heights_frac = []
    bands_count = {label: 0 for _, _, label in BANDS}
    resolution = None

    for img in imgs:
        base = os.path.splitext(os.path.basename(img))[0]
        lbl = os.path.join(folder, "labels", base + ".txt")
        if not os.path.exists(lbl):
            continue
        im = cv2.imread(img)
        h, w = im.shape[:2]
        if resolution is None:
            resolution = (w, h)
        for line in open(lbl):
            p = line.split()
            if not p:
                continue
            h_norm = float(p[4])
            px = h_norm * h
            heights_px.append(px)
            heights_frac.append(h_norm)
            for lo, hi, label in BANDS:
                if lo <= px < hi:
                    bands_count[label] += 1
                    break

    return resolution, heights_px, heights_frac, bands_count


def generate_size_csv():
    day_res, day_px, day_frac, day_bands = get_boxes(DAY_DIR)
    night_res, night_px, night_frac, night_bands = get_boxes(NIGHT_DIR)

    path = os.path.join(TABLES_DIR, "day_vs_night_size.csv")
    rows = [
        {
            "set": "day",
            "resolution": f"{day_res[0]}x{day_res[1]}",
            "frame_height_px": day_res[1],
            "box_count": len(day_px),
            "median_height_px": round(float(np.median(day_px)), 1),
            "median_height_pct": round(float(np.median(day_frac)) * 100, 2),
            "mean_height_px": round(float(np.mean(day_px)), 1),
            "mean_height_pct": round(float(np.mean(day_frac)) * 100, 2),
            "band_under_20px": day_bands["<20 px"],
            "pct_under_20px": round(day_bands["<20 px"] / len(day_px) * 100, 1),
            "band_20_50px": day_bands["20-50 px"],
            "pct_20_50px": round(day_bands["20-50 px"] / len(day_px) * 100, 1),
            "band_50_100px": day_bands["50-100 px"],
            "pct_50_100px": round(day_bands["50-100 px"] / len(day_px) * 100, 1),
            "band_over_100px": day_bands[">100 px"],
            "pct_over_100px": round(day_bands[">100 px"] / len(day_px) * 100, 1),
        },
        {
            "set": "night",
            "resolution": f"{night_res[0]}x{night_res[1]}",
            "frame_height_px": night_res[1],
            "box_count": len(night_px),
            "median_height_px": round(float(np.median(night_px)), 1),
            "median_height_pct": round(float(np.median(night_frac)) * 100, 2),
            "mean_height_px": round(float(np.mean(night_px)), 1),
            "mean_height_pct": round(float(np.mean(night_frac)) * 100, 2),
            "band_under_20px": night_bands["<20 px"],
            "pct_under_20px": round(night_bands["<20 px"] / len(night_px) * 100, 1),
            "band_20_50px": night_bands["20-50 px"],
            "pct_20_50px": round(night_bands["20-50 px"] / len(night_px) * 100, 1),
            "band_50_100px": night_bands["50-100 px"],
            "pct_50_100px": round(night_bands["50-100 px"] / len(night_px) * 100, 1),
            "band_over_100px": night_bands[">100 px"],
            "pct_over_100px": round(night_bands[">100 px"] / len(night_px) * 100, 1),
        },
    ]

    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"Saved {path}")


def generate_recall_csv():
    # Load evaluation numbers from outputs/evaluation/manual_night_coco.csv
    eval_csv = os.path.join(ROOT, "outputs", "evaluation", "manual_night_coco.csv")
    eval_data = {}
    with open(eval_csv, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            if r["metric"] == "class-agnostic recall":
                key = (r["set"], r["subset"])
                eval_data[key] = {
                    "boxes": int(r["boxes"]),
                    "recall": float(r["recall"]) if r["recall"] != "" else None,
                    "ci_low": float(r["ci_low"]) if r["ci_low"] != "" else None,
                    "ci_high": float(r["ci_high"]) if r["ci_high"] != "" else None,
                    "too_few": int(r["too_few_to_rank"]),
                }

    subsets = ["<20 px", "20-50 px", "50-100 px", ">100 px", "all"]
    path = os.path.join(TABLES_DIR, "day_vs_night_recall.csv")
    rows = []

    for s in subsets:
        day_info = eval_data.get(("manual day", s), {})
        night_info = eval_data.get(("manual night", s), {})

        d_rec = day_info.get("recall")
        d_lo = day_info.get("ci_low")
        d_hi = day_info.get("ci_high")
        d_box = day_info.get("boxes", 0)

        n_rec = night_info.get("recall")
        n_lo = night_info.get("ci_low")
        n_hi = night_info.get("ci_high")
        n_box = night_info.get("boxes", 0)

        # Check overlap
        if d_lo is not None and d_hi is not None and n_lo is not None and n_hi is not None:
            overlap = not (d_hi < n_lo or n_hi < d_lo)
            overlap_str = "yes" if overlap else "no"
        else:
            overlap_str = "n/a"

        notes = []
        if d_box < 20 and d_box > 0:
            notes.append(f"Day N={d_box} < 20")
        if n_box < 20 and n_box > 0:
            notes.append(f"Night N={n_box} < 20")
        if n_box == 0:
            notes.append("No night boxes")

        rows.append({
            "size_band": s,
            "day_boxes": d_box,
            "day_recall": f"{d_rec:.3f}" if d_rec is not None else "",
            "day_ci_low": f"{d_lo:.3f}" if d_lo is not None else "",
            "day_ci_high": f"{d_hi:.3f}" if d_hi is not None else "",
            "night_boxes": n_box,
            "night_recall": f"{n_rec:.3f}" if n_rec is not None else "",
            "night_ci_low": f"{n_lo:.3f}" if n_lo is not None else "",
            "night_ci_high": f"{n_hi:.3f}" if n_hi is not None else "",
            "ci_overlap": overlap_str,
            "ranking_note": "; ".join(notes) if notes else "Both N >= 20 (rankable)",
        })

    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"Saved {path}")


if __name__ == "__main__":
    generate_size_csv()
    generate_recall_csv()
