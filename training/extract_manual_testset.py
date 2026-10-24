"""Extract frames for a hand-labelled test set.

    # daytime set: the two validation stretches of the day ride
    python training/extract_manual_testset.py --video data/videos/raw/srilanka_clean_full.mp4 \
        --ranges 86-204,1034-1194 --every 5
    # night set (illumination experiment E4), kept separate
    python training/extract_manual_testset.py --video data/videos/raw/srilanka_night_full.mp4 \
        --ranges 0-118 --every 5 --out data/dataset/testset_night

Writes images/manual_NNN.jpg (no labels: they are drawn by hand, from scratch)
and provenance.csv with the source video and timestamp of every frame.

For the daytime ride it also reports, per frame, the nearest frame of the
training dataset (frame_0001..frame_0598 sit one every ~2 s along that ride)
and which split it is in, so a test frame next to a TRAIN frame is visible.
"""

import argparse
import csv
import os

import cv2

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data", "dataset", "testset_manual")
SPLIT = os.path.join(ROOT, "data", "dataset", "yolo", "split.txt")
DAY_RIDE = "srilanka_clean_full.mp4"
# dataset frame n sits at ~ T0 + (n - 1) * DT seconds into the daytime ride
# (measured by matching frames 1, 150, 300, 450, 598 against the video)
T0, DT, N_FRAMES = 6.0, 2.0, 598


def split_of_frames():
    where = {}
    if os.path.exists(SPLIT):
        for line in open(SPLIT):
            if line.startswith("#") or not line.strip():
                continue
            subset, source, name = line.rstrip("\n").split("\t")
            if source in ("real", "negative"):
                where[os.path.splitext(name)[0]] = subset
    return where


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True)
    ap.add_argument("--ranges", required=True, help="seconds, e.g. 86-204,1034-1194")
    ap.add_argument("--every", type=float, default=5.0, help="seconds between frames")
    ap.add_argument("--out", default=OUT, help="output folder (default data/dataset/testset_manual)")
    args = ap.parse_args()
    out_dir = os.path.abspath(args.out)

    ranges = [tuple(float(x) for x in r.split("-")) for r in args.ranges.split(",")]
    img_dir = os.path.join(out_dir, "images")
    os.makedirs(img_dir, exist_ok=True)
    if os.listdir(img_dir):
        raise SystemExit(f"{img_dir} is not empty; move it aside before re-extracting.")

    day = os.path.basename(args.video) == DAY_RIDE
    where = split_of_frames() if day else {}
    cap = cv2.VideoCapture(args.video)
    fps = cap.get(cv2.CAP_PROP_FPS)
    rows, k = [], 0
    for lo, hi in ranges:
        t = lo
        while t <= hi:
            cap.set(cv2.CAP_PROP_POS_FRAMES, int(round(t * fps)))
            ok, frame = cap.read()
            if not ok:
                break
            name = f"manual_{k:03d}.jpg"
            cv2.imwrite(os.path.join(img_dir, name), frame)
            row = {"image": name, "video": os.path.basename(args.video), "time_s": round(t, 1)}
            if day:
                n = min(max(round((t - T0) / DT) + 1, 1), N_FRAMES)
                stem = f"frame_{n:04d}"
                row.update(nearest_dataset_frame=stem,
                           seconds_away=round(abs(t - (T0 + (n - 1) * DT)), 1),
                           its_split=where.get(stem, "unused"))
            rows.append(row)
            k += 1
            t += args.every
    cap.release()

    with open(os.path.join(out_dir, "provenance.csv"), "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(rows[0]))
        wr.writeheader()
        wr.writerows(rows)
    print(f"Extracted {len(rows)} frames to {img_dir}")
    if day:
        from collections import Counter
        print("Nearest dataset frame is in:", dict(Counter(r["its_split"] for r in rows)))


if __name__ == "__main__":
    main()
