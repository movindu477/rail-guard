"""Record a calibration video: move the checkerboard slowly in front of the camera.

    python camera/calibration/capture_video.py --out camera/calibration/videos/wide.avi
    python camera/calibration/capture_video.py --out camera/calibration/videos/tele.avi

Then pick the best frames with extract_calib_frames.py.

The video is written as high-quality MJPEG (.avi): .mp4 (mp4v) compresses
each frame much harder and smears the corner detail calibration measures.
The preview shows whether the board is visible; the saved video has no overlay.
ESC (or --seconds) stops the recording.
"""
import argparse
import os
import time

import cv2

from railguard.camera.capture import open_camera


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="output video (.avi recommended)")
    ap.add_argument("--seconds", type=float, default=0, help="stop after this long (0 = until ESC)")
    ap.add_argument("--camera", type=int, default=1)
    ap.add_argument("--pattern", default="6x8", help="inner corners, rows x cols (for the preview check)")
    args = ap.parse_args()
    rows, cols = (int(n) for n in args.pattern.lower().split("x"))
    if os.path.exists(args.out):
        raise SystemExit(f"{args.out} already exists; choose another name or move it first.")
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)

    cap = open_camera(args.camera)
    w, h = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    mjpg = args.out.lower().endswith(".avi")
    out = cv2.VideoWriter(args.out, cv2.VideoWriter_fourcc(*("MJPG" if mjpg else "mp4v")), fps, (w, h))
    if mjpg:
        out.set(cv2.VIDEOWRITER_PROP_QUALITY, 95)
    print(f"Recording {w}x{h} to {args.out}. Move the board SLOWLY. ESC stops.")

    t0, n, seen = time.time(), 0, False
    while True:
        ok, frame = cap.read()
        if not ok:
            print("Camera read failed - stopping; the video so far is kept.")
            break
        out.write(frame)
        n += 1
        if n % 5 == 0:   # cheap board check for the preview, every 5th frame
            small = cv2.cvtColor(cv2.resize(frame, (w // 2, h // 2)), cv2.COLOR_BGR2GRAY)
            seen = any(cv2.findChessboardCorners(small, p, flags=cv2.CALIB_CB_FAST_CHECK)[0]
                       for p in ((cols, rows), (rows, cols)))
        elapsed = time.time() - t0
        disp = cv2.resize(frame, (1280, int(1280 * h / w)))
        cv2.circle(disp, (30, 30), 10, (0, 0, 255), -1)
        for text, y, colour in ((f"REC {elapsed:4.0f} s", 40, (255, 255, 255)),
                                ("board visible" if seen else "board NOT visible", 80,
                                 (0, 200, 0) if seen else (0, 0, 255)),
                                ("Move SLOWLY: straight on, tilt L/R/up/down, every corner. ESC stops.",
                                 disp.shape[0] - 20, (255, 255, 255))):
            cv2.putText(disp, text, (50, y), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 0), 5, cv2.LINE_AA)
            cv2.putText(disp, text, (50, y), cv2.FONT_HERSHEY_SIMPLEX, 0.9, colour, 2, cv2.LINE_AA)
        cv2.imshow("calibration video", disp)
        if (cv2.waitKey(1) & 0xFF) == 27 or (args.seconds and elapsed >= args.seconds):
            break

    cap.release()
    out.release()
    cv2.destroyAllWindows()
    print(f"Saved {n} frames ({time.time() - t0:.0f} s) to {args.out}")


if __name__ == "__main__":
    main()
