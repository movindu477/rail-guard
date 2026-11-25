"""Measure fx directly from a board at a measured distance.

    python camera/calibration/measure_fx.py --distance 1.00 --square 0.025
    python camera/calibration/measure_fx.py --distance 1.50 --square 0.025 \
        --save camera/calibration/elp_wide_measured.npz

Repeat at two or three distances before saving: a focal length that comes out
the same at 0.5 m, 1.0 m and 1.5 m is measuring the lens. One that drifts with
distance means the board is not square to the camera, or the distance is being
measured to the wrong point.

Completely independent of calibrateCamera. A pinhole camera obeys

    pixels_across / focal_px = metres_across / distance

so with the board face-on at a known distance, fx falls straight out of how
many pixels the corner grid spans. No optimiser, no distortion model, no
multiple views: nothing that can trade one parameter against another.

Worth having because calibration can be internally consistent and still wrong.
On 25 Nov 2026 three captures of one lens each returned a stable focal length
and the three disagreed by a factor of three (5.4 mm, 8.2 mm, 17.5 mm implied).
A single honest measurement says which, if any, is right.

Accuracy depends on holding the board square to the camera and measuring the
distance from the SENSOR, not the front of the lens. Good to a few percent,
which is far more than enough to tell 1900 px from 6200 px.

Keys: SPACE measure   ESC quit
"""

import argparse
import math
import os
import statistics

import cv2
import numpy as np

from railguard.camera.capture import open_camera


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--distance", type=float, required=True,
                    help="camera to board, metres, measured from the camera body")
    ap.add_argument("--square", type=float, default=0.025, help="square size in metres")
    ap.add_argument("--pattern", default="6x8", help="inner corners, cols x rows")
    ap.add_argument("--save", help="write an .npz PipelineConfig.from_calibration can read")
    args = ap.parse_args()
    cols, rows = (int(v) for v in args.pattern.split("x"))

    # The corner grid spans (cols-1) squares across and (rows-1) down: the
    # outermost INNER corners sit one square in from each edge of the board.
    span_w = (cols - 1) * args.square
    span_h = (rows - 1) * args.square
    print(f"board corner grid: {span_w*1000:.0f} x {span_h*1000:.0f} mm "
          f"at {args.distance:.2f} m")
    print("Hold the board SQUARE to the camera, filling a good part of the frame.")
    print("SPACE to measure, ESC to quit.\n")

    cap = open_camera()
    samples = []
    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                continue
            show = cv2.resize(frame, (1280, 720))
            # A black frame is the commonest reason nothing is found, and on a
            # dim laptop screen it is not always obvious that it IS black.
            mean = int(cv2.cvtColor(show, cv2.COLOR_BGR2GRAY).mean())
            cv2.putText(show, "SPACE to measure", (20, 50),
                        cv2.FONT_HERSHEY_SIMPLEX, 1.0, (255, 255, 255), 2)
            cv2.putText(show, f"brightness {mean}/255" +
                        ("   LENS CAP? IRIS CLOSED? POINTING AT SOMETHING DARK?"
                         if mean < 25 else "   too dark" if mean < 40 else ""),
                        (20, 90), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                        (0, 0, 255) if mean < 40 else (200, 200, 200), 2)
            cv2.imshow("measure fx", show)
            key = cv2.waitKey(1) & 0xFF
            if key == 27:
                break
            if key != 32:
                continue

            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            found, c = cv2.findChessboardCorners(
                gray, (cols, rows),
                cv2.CALIB_CB_ADAPTIVE_THRESH + cv2.CALIB_CB_NORMALIZE_IMAGE)
            if not found:
                print("no board found")
                continue
            cv2.cornerSubPix(gray, c, (11, 11), (-1, -1),
                             (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001))
            pts = c.reshape(rows, cols, 2)

            # Mean span of each row of corners, and of each column.
            row_px = np.mean([np.linalg.norm(pts[r, -1] - pts[r, 0]) for r in range(rows)])
            col_px = np.mean([np.linalg.norm(pts[-1, k] - pts[0, k]) for k in range(cols)])
            fx = row_px * args.distance / span_w
            fy = col_px * args.distance / span_h
            h, w = frame.shape[:2]
            fov_x = 2 * math.degrees(math.atan(w / (2 * fx)))

            # Squareness: if the board is turned away, one side is shorter than
            # the other and the answer is an underestimate.
            left = np.linalg.norm(pts[-1, 0] - pts[0, 0])
            right = np.linalg.norm(pts[-1, -1] - pts[0, -1])
            skew = abs(left - right) / max(left, right) * 100

            print(f"corner grid {row_px:.0f} x {col_px:.0f} px  ->  "
                  f"fx {fx:.0f}  fy {fy:.0f}  horizontal FOV {fov_x:.1f} deg")
            if skew > 6:
                print(f"   board is turned ({skew:.0f}% side difference) - "
                      f"square it up and measure again; this reads LOW. Not counted.")
                continue
            print(f"   board is square to within {skew:.0f}%")
            samples.append((fx, fy, w, h))
            if len(samples) >= 3:
                fxs = [s[0] for s in samples]
                med = statistics.median(fxs)
                spread = (max(fxs) - min(fxs)) / med * 100
                print(f"   {len(samples)} samples: median fx {med:.0f}, spread {spread:.1f}%"
                      + ("  <- still moving, hold steady" if spread > 3 else "  <- steady"))
    finally:
        cap.release()
        cv2.destroyAllWindows()

    if not samples:
        print("\nno usable measurements")
        return
    fxs = [s[0] for s in samples]
    fys = [s[1] for s in samples]
    w, h = samples[-1][2], samples[-1][3]
    med_fx, med_fy = statistics.median(fxs), statistics.median(fys)
    spread = (max(fxs) - min(fxs)) / med_fx * 100
    print(f"\n{len(samples)} measurements at {args.distance:.2f} m")
    print(f"   fx {med_fx:.0f}   fy {med_fy:.0f}   spread {spread:.1f}%")
    print(f"   horizontal FOV {2*math.degrees(math.atan(w/(2*med_fx))):.1f} deg")

    if args.save:
        if spread > 5:
            print(f"\nNOT saved: {spread:.1f}% spread is too much to call it measured.")
            return
        # Same keys calibrate.py writes, so PipelineConfig.from_calibration
        # reads this without knowing where it came from. The principal point is
        # the image centre and distortion is zero: this method measures a focal
        # length and nothing else, which is stated here rather than implied by
        # zeros that look like a result.
        os.makedirs(os.path.dirname(os.path.abspath(args.save)), exist_ok=True)
        np.savez(args.save,
                 fx=med_fx, fy=med_fy, cx=w / 2.0, cy=h / 2.0,
                 camera_matrix=np.array([[med_fx, 0, w / 2.0],
                                         [0, med_fy, h / 2.0],
                                         [0, 0, 1.0]]),
                 dist=np.zeros(5),
                 image_size=np.array([w, h]),
                 method="direct board measurement, no distortion model",
                 distance_m=args.distance, square_m=args.square,
                 samples=len(samples), spread_pct=spread)
        print(f"\nSaved {args.save}")
        print("   fx and fy only. Principal point assumed at the image centre,")
        print("   distortion assumed zero - this method cannot measure either.")


if __name__ == "__main__":
    main()
