"""Find why the camera is slow: property order, requested fps, or exposure.

    python camera/benchmarks/camera_diagnose.py

Measured on the ELP on 25 Nov 2026: 1.5 fps at 4K, 2.2 at 1080p, 9.9 at 720p,
with DSHOW reporting MJPG after the fourcc was set. MJPG at 1080p over USB 3
should give 30 fps, so something else is throttling it. The three candidates
behave differently and this separates them:

  property order   some DirectShow drivers reset the pixel format when the
                   frame size changes, so a fourcc set BEFORE the size is
                   silently dropped while still reading back as MJPG.
  requested fps    the driver may sit at a low default until asked.
  auto-exposure    indoors a camera stretches exposure to 1/2 s and the frame
                   rate falls to match. This is the one that looks like a
                   bandwidth problem and is not: it goes away in daylight.

Reads back the real fourcc after each attempt, because the property returning
MJPG is not proof that MJPG frames are arriving.
"""

import time

import cv2


def fourcc_str(v):
    v = int(v)
    return "".join(chr((v >> (8 * i)) & 0xFF) for i in range(4))


def measure(cap, n=60):
    for _ in range(5):
        cap.read()
    t0, got = time.time(), 0
    while got < n:
        ok, _ = cap.read()
        if not ok:
            break
        got += 1
        if time.time() - t0 > 20:
            break
    dt = time.time() - t0
    return got / dt if dt > 0 else 0.0, dt


def attempt(label, w, h, order, want_fps=None, manual_exposure=None):
    cap = cv2.VideoCapture(1, cv2.CAP_DSHOW)
    if not cap.isOpened():
        print(f"{label:<44} could not open")
        return
    mjpg = cv2.VideoWriter_fourcc(*"MJPG")
    if order == "fourcc_first":
        cap.set(cv2.CAP_PROP_FOURCC, mjpg)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, w)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, h)
    elif order == "size_first":
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, w)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, h)
        cap.set(cv2.CAP_PROP_FOURCC, mjpg)
    elif order == "fourcc_both":
        cap.set(cv2.CAP_PROP_FOURCC, mjpg)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, w)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, h)
        cap.set(cv2.CAP_PROP_FOURCC, mjpg)
    if want_fps:
        cap.set(cv2.CAP_PROP_FPS, want_fps)
    if manual_exposure is not None:
        # DSHOW: 0.25 selects manual exposure, 0.75 auto. Exposure is a power
        # of two: -6 is 1/64 s, short enough that exposure cannot cap frame rate.
        cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.25)
        cap.set(cv2.CAP_PROP_EXPOSURE, manual_exposure)

    fps, dt = measure(cap)
    aw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    ah = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fcc = fourcc_str(cap.get(cv2.CAP_PROP_FOURCC))
    exp = cap.get(cv2.CAP_PROP_EXPOSURE)
    cap.release()
    print(f"{label:<44} {aw}x{ah} {fcc}  {fps:5.1f} fps  (exposure {exp:g}, {dt:.0f}s)")


def main():
    print("ELP on index 1, DSHOW. Each row is 60 frames or 20 s, whichever first.\n")
    for w, h in ((1280, 720), (1920, 1080)):
        print(f"--- {w}x{h} ---")
        attempt("fourcc before size (what we did)", w, h, "fourcc_first")
        attempt("size before fourcc", w, h, "size_first")
        attempt("fourcc, size, fourcc again", w, h, "fourcc_both")
        attempt("fourcc both + request 30 fps", w, h, "fourcc_both", want_fps=30)
        attempt("fourcc both + 30 fps + manual exposure", w, h, "fourcc_both",
                want_fps=30, manual_exposure=-6)
        print()

    print("Reading it:")
    print("  a row jumps to ~30 fps      -> that is the fix, use those settings")
    print("  only the manual-exposure    -> the room is dark; it will be fine")
    print("    row is fast                  outdoors, and -6 is usable indoors")
    print("  all rows stay slow          -> USB bandwidth: try a USB 3 port,")
    print("                                 no hub, and a different cable")


if __name__ == "__main__":
    main()
