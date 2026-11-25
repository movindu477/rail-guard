"""Calibrate the same photos under several models and compare.

    python camera/calibration/try_models.py --images camera/calibration/images_wide_v4

The full OpenCV model has 4 intrinsics and 5 distortion terms. With limited or
imperfect data it can trade focal length against distortion and against the
principal point almost freely, so it fits the photos well and returns a focal
length that moves every time you recapture. On 25 Nov 2026 three captures of
one taped lens gave fx 1934, 2940 and 6257.

Constraining the model removes that freedom:

  fix principal point   cx, cy held at the image centre. Correct to within a
                        few pixels for most sensors, and it stops cx/cy
                        absorbing error that belongs to fx.
  fix k3                the third radial term is the least identifiable and
                        the first to run away (k3 = 8.95 in one run here).
  zero tangential       p1, p2 describe a lens not parallel to the sensor;
                        usually tiny, and estimating them from imperfect data
                        costs more than it buys.

A model whose fx barely moves as terms are removed is measuring the lens. One
whose fx swings by thousands of pixels is fitting noise, and the constrained
answer is the one to trust.
"""

import argparse
import glob
import math
import os

import cv2
import numpy as np

CRITERIA = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001)

MODELS = [
    ("full model (what we used)", 0),
    ("fix k3", cv2.CALIB_FIX_K3),
    ("fix k3 + zero tangential", cv2.CALIB_FIX_K3 | cv2.CALIB_ZERO_TANGENT_DIST),
    ("fix principal point", cv2.CALIB_FIX_PRINCIPAL_POINT),
    ("fix pp + k3", cv2.CALIB_FIX_PRINCIPAL_POINT | cv2.CALIB_FIX_K3),
    ("fix pp + k3 + tangential",
     cv2.CALIB_FIX_PRINCIPAL_POINT | cv2.CALIB_FIX_K3 | cv2.CALIB_ZERO_TANGENT_DIST),
    ("fix pp + k2 + k3 (k1 only)",
     cv2.CALIB_FIX_PRINCIPAL_POINT | cv2.CALIB_FIX_K2 | cv2.CALIB_FIX_K3
     | cv2.CALIB_ZERO_TANGENT_DIST),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--images", required=True)
    ap.add_argument("--pattern", default="6x8")
    args = ap.parse_args()
    cols, rows = (int(v) for v in args.pattern.split("x"))

    objp = np.zeros((cols * rows, 3), np.float32)
    objp[:, :2] = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2)
    obj, img, size = [], [], None
    for p in sorted(glob.glob(os.path.join(args.images, "*.jpg"))):
        g = cv2.imread(p, cv2.IMREAD_GRAYSCALE)
        if g is None:
            continue
        size = g.shape[::-1]
        ok, c = cv2.findChessboardCorners(
            g, (cols, rows),
            cv2.CALIB_CB_ADAPTIVE_THRESH + cv2.CALIB_CB_NORMALIZE_IMAGE)
        if ok:
            cv2.cornerSubPix(g, c, (11, 11), (-1, -1), CRITERIA)
            obj.append(objp.copy())
            img.append(c)
    if len(obj) < 6:
        raise SystemExit(f"only {len(obj)} usable photos")

    print(f"{len(obj)} photos, {size[0]}x{size[1]}\n")

    # The constrained runs need a sensible starting focal length. Seeding the
    # guess with fx = 1 leaves the optimiser stuck at fx = 1 and a 180 degree
    # field of view, which is what this script did on its first run. Start from
    # the unconstrained fit instead.
    seed_rms, seed_K, _, _, _ = cv2.calibrateCamera(obj, img, size, None, None)
    print(f"unconstrained seed: fx {seed_K[0,0]:.1f}, RMS {seed_rms:.3f}\n")

    print(f"{'model':<30}{'fx':>9}{'FOV':>8}{'cx':>8}{'cy':>8}{'RMS':>8}")
    print("-" * 71)
    centre = np.array([[seed_K[0, 0], 0, size[0] / 2],
                       [0, seed_K[1, 1], size[1] / 2],
                       [0, 0, 1]])
    fxs = []
    for name, flags in MODELS:
        K0 = centre.copy() if flags & cv2.CALIB_FIX_PRINCIPAL_POINT else None
        d0 = np.zeros(5) if K0 is not None else None
        try:
            rms, K, dist, _, _ = cv2.calibrateCamera(
                obj, img, size, K0, d0,
                flags=flags | (cv2.CALIB_USE_INTRINSIC_GUESS if K0 is not None else 0))
        except cv2.error as e:
            print(f"{name:<30} failed: {str(e).splitlines()[-1][:30]}")
            continue
        fx = K[0, 0]
        fov = 2 * math.degrees(math.atan(size[0] / (2 * fx)))
        fxs.append(fx)
        print(f"{name:<30}{fx:>9.1f}{fov:>7.1f}d{K[0,2]:>8.1f}{K[1,2]:>8.1f}{rms:>8.3f}")

    if len(fxs) > 1:
        spread = (max(fxs) - min(fxs)) / (sum(fxs) / len(fxs)) * 100
        print(f"\nfx spread across models: {spread:.1f}%")
        if spread > 15:
            print("The focal length depends heavily on which terms are free, so")
            print("these photos do not determine it. Usually the board is not")
            print("flat: tape it to rigid board, or print it on card.")
        else:
            print("fx is stable across models, so it is being measured rather")
            print("than fitted. Use the most constrained row with a good RMS.")


if __name__ == "__main__":
    main()
