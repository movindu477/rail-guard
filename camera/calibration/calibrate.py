"""Calibrate a camera from checkerboard photos.

    python camera/calibration/calibrate.py --images camera/calibration/images \
        --out camera/calibration/elp_wide.npz

--pattern is the number of INNER corners, rows x cols (a board of 7x9 squares
has 6x8 inner corners). --square is the side of one square in metres.
"""
import argparse
import glob
import os
import sys

import cv2
import numpy as np

MIN_IMAGES = 10
CRITERIA = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001)


def object_grid(cols, rows, square):
    """Board corners in metres on the z = 0 plane, in findChessboardCorners order."""
    objp = np.zeros((rows * cols, 3), np.float32)
    objp[:, :2] = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2)
    return objp * square


def find_corners(gray, cols, rows):
    """Corners for a (cols, rows) board, trying the rotated orientation too.

    Returns (corners, pattern) where pattern is the (cols, rows) that matched,
    or (None, None). The object grid must be built for the matched pattern,
    or the corners get paired with the wrong board points.
    """
    for pattern in ((cols, rows), (rows, cols)):
        ok, corners = cv2.findChessboardCorners(gray, pattern, None)
        if ok:
            return cv2.cornerSubPix(gray, corners, (11, 11), (-1, -1), CRITERIA), pattern
    return None, None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--images", required=True, help="folder of checkerboard photos")
    ap.add_argument("--out", required=True, help="output .npz path")
    ap.add_argument("--pattern", default="6x8", help="inner corners, rows x cols")
    ap.add_argument("--square", type=float, default=0.025, help="square size in metres")
    args = ap.parse_args()

    rows, cols = (int(n) for n in args.pattern.lower().split("x"))

    files = sorted(f for ext in ("jpg", "jpeg", "png")
                   for f in glob.glob(os.path.join(args.images, f"*.{ext}")))
    files = sorted(set(files))  # Windows glob is case-insensitive: *.jpg and *.JPG overlap
    if not files:
        sys.exit(f"ERROR: no images in {args.images}")

    objpoints, imgpoints, names = [], [], []
    image_size = None
    for path in files:
        name = os.path.basename(path)
        img = cv2.imread(path)
        if img is None:
            print(f"SKIP {name} (unreadable)")
            continue
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        size = gray.shape[::-1]  # (width, height)
        if image_size is None:
            image_size = size
        elif size != image_size:
            # One calibration describes one resolution and orientation.
            print(f"SKIP {name} (size {size[0]}x{size[1]}, expected "
                  f"{image_size[0]}x{image_size[1]})")
            continue

        corners, pattern = find_corners(gray, cols, rows)
        if corners is None:
            print(f"SKIP {name} (no {rows}x{cols} board found)")
            continue
        objpoints.append(object_grid(*pattern, args.square))
        imgpoints.append(corners)
        names.append(name)
        print(f"OK   {name}{'  (rotated board)' if pattern != (cols, rows) else ''}")

    if len(objpoints) < MIN_IMAGES:
        sys.exit(f"ERROR: only {len(objpoints)}/{len(files)} images usable, "
                 f"need at least {MIN_IMAGES}. Not calibrating.")

    rms, mtx, dist, rvecs, tvecs = cv2.calibrateCamera(
        objpoints, imgpoints, image_size, None, None)

    # Per-image RMS reprojection error, in pixels.
    per_image = []
    for i in range(len(objpoints)):
        projected, _ = cv2.projectPoints(objpoints[i], rvecs[i], tvecs[i], mtx, dist)
        err = np.linalg.norm(imgpoints[i].reshape(-1, 2) - projected.reshape(-1, 2), axis=1)
        per_image.append(float(np.sqrt(np.mean(err ** 2))))
    mean_error = float(np.mean(per_image))

    fx, fy, cx, cy = mtx[0, 0], mtx[1, 1], mtx[0, 2], mtx[1, 2]
    print()
    print("Per-image reprojection error (px):")
    for name, e in zip(names, per_image):
        print(f"  {name:30s} {e:.3f}{'   <-- high' if e > 2 * mean_error else ''}")
    print()
    print(f"Images used:          {len(objpoints)}/{len(files)}")
    print(f"Image size:           {image_size[0]} x {image_size[1]}")
    print(f"Reprojection error:   {mean_error:.3f} px (mean of per-image RMS)")
    print(f"Overall RMS:          {rms:.3f} px")
    print("Camera matrix:")
    print(np.array2string(mtx, precision=2, suppress_small=True))
    print(f"fx = {fx:.2f}   fy = {fy:.2f}   cx = {cx:.2f}   cy = {cy:.2f}")
    print(f"Distortion:           {np.array2string(dist.ravel(), precision=4)}")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    np.savez(args.out, camera_matrix=mtx, dist=dist,
             fx=fx, fy=fy, image_size=np.array(image_size),
             reproj_error=mean_error, n_images=len(objpoints))
    print(f"\nSaved {args.out}")


if __name__ == "__main__":
    main()
