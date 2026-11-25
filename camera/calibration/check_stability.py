"""Check that one folder of calibration photos really is ONE lens setting.

    python camera/calibration/check_stability.py --images camera/calibration/images_wide_v2

Splits the photos into the first half and the second half by capture order,
calibrates each half on its own, and compares fx. A varifocal lens that was
nudged between shots - or a folder holding photos from two sessions - gives
two different focal lengths, and a calibration that averages them completes
without complaint and returns an fx matching neither.

This happened on 25 Nov 2026: one folder gave fx 1934 (53 deg), another gave
2940 (36 deg), and the second had four photos left over from an earlier run
mixed in with sixteen new ones. Nothing in either calibration's output said so;
only comparing the two runs revealed it.

A single calibration cannot detect this. Two halves of the same data can.
"""

import argparse
import glob
import math
import os
import sys

import cv2
import numpy as np

CRITERIA = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001)


def corners_for(paths, pattern):
    cols, rows = pattern
    objp = np.zeros((cols * rows, 3), np.float32)
    objp[:, :2] = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2)
    obj, img, used, size = [], [], [], None
    for p in paths:
        g = cv2.imread(p, cv2.IMREAD_GRAYSCALE)
        if g is None:
            continue
        size = g.shape[::-1]
        ok, c = cv2.findChessboardCorners(
            g, (cols, rows),
            cv2.CALIB_CB_ADAPTIVE_THRESH + cv2.CALIB_CB_NORMALIZE_IMAGE)
        if not ok:
            continue
        cv2.cornerSubPix(g, c, (11, 11), (-1, -1), CRITERIA)
        obj.append(objp.copy())
        img.append(c)
        used.append(p)
    return obj, img, used, size


def calibrate(obj, img, size):
    if len(obj) < 4:
        return None
    rms, K, dist, _, _ = cv2.calibrateCamera(obj, img, size, None, None)
    return rms, K


def fov_deg(fx, width):
    return 2 * math.degrees(math.atan(width / (2 * fx)))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--images", required=True)
    ap.add_argument("--pattern", default="6x8")
    args = ap.parse_args()
    cols, rows = (int(v) for v in args.pattern.split("x"))

    paths = sorted(glob.glob(os.path.join(args.images, "*.jpg")))
    if len(paths) < 8:
        raise SystemExit(f"need at least 8 photos, found {len(paths)}")

    obj, img, used, size = corners_for(paths, (cols, rows))
    print(f"{len(used)} of {len(paths)} photos have a {cols}x{rows} board, {size[0]}x{size[1]}\n")

    whole = calibrate(obj, img, size)
    if whole is None:
        raise SystemExit("not enough usable photos")
    rms_all, K_all = whole

    half = len(obj) // 2
    groups = [("first half", slice(0, half)), ("second half", slice(half, None))]
    results = []
    for name, sl in groups:
        r = calibrate(obj[sl], img[sl], size)
        if r is None:
            print(f"{name}: too few photos")
            continue
        rms, K = r
        fx = K[0, 0]
        results.append((name, fx, K[1, 2], rms, len(obj[sl])))

    print(f"{'group':<14}{'photos':>7}{'fx':>10}{'FOV':>8}{'cy':>9}{'RMS px':>9}")
    print("-" * 57)
    print(f"{'all':<14}{len(obj):>7}{K_all[0,0]:>10.1f}"
          f"{fov_deg(K_all[0,0], size[0]):>7.1f}d{K_all[1,2]:>9.1f}{rms_all:>9.3f}")
    for name, fx, cy, rms, n in results:
        print(f"{name:<14}{n:>7}{fx:>10.1f}{fov_deg(fx, size[0]):>7.1f}d{cy:>9.1f}{rms:>9.3f}")

    print()
    if len(results) == 2:
        a, b = results[0][1], results[1][1]
        spread = abs(a - b) / ((a + b) / 2) * 100
        print(f"fx differs between halves by {spread:.1f}%")
        if spread > 5:
            print("FAIL: the two halves disagree. The zoom ring moved during capture,")
            print("      or this folder holds photos from more than one session.")
            print("      Tape the ring, delete the folder, and capture again in one go.")
        else:
            print("OK: both halves agree, so the lens setting held across the capture.")

    cy_off = abs(K_all[1, 2] - size[1] / 2)
    cx_off = abs(K_all[0, 2] - size[0] / 2)
    print(f"\nprincipal point is {cx_off:.0f} px horizontally and {cy_off:.0f} px "
          f"vertically from the image centre")
    if cy_off > 0.08 * size[1] or cx_off > 0.08 * size[0]:
        print("      That is a lot. Usually it means one part of the frame was")
        print("      never covered, so nothing constrained the solver there.")

    print(f"\nRMS over all photos: {rms_all:.3f} px "
          f"({'good' if rms_all < 0.5 else 'usable' if rms_all < 1.0 else 'too high'})")


if __name__ == "__main__":
    main()
