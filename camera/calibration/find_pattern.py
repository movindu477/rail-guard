"""Work out the checkerboard's inner-corner grid, from one frame on request.

    python camera/calibration/find_pattern.py

Live preview. Hold the board flat and square, filling most of the frame, then
press SPACE. Searching happens on that one frame, not on every frame: a full
grid search costs a good fraction of a second per candidate at 1080p, and
doing it continuously freezes the window (which it did, on 25 Nov 2026).

Why bother at all: --pattern is the number of INNER corners, not squares, so a
board of 7x9 squares is 6x8 inner corners. Guess wrong and capture_calib.py
finds nothing - or worse, locks onto a smaller sub-grid, calibrates against a
pattern that is not the one you measured, and returns a plausible fx that is
quietly wrong.

Keys: SPACE search this frame   ESC quit
"""

import cv2

from railguard.camera.capture import open_camera

# Largest first: a sub-grid of the true board will also match, so finding 6x8
# before trying 5x7 avoids reporting the smaller one.
CANDIDATES = sorted([(c, r) for c in range(3, 12) for r in range(3, 14) if c < r],
                    key=lambda cr: -(cr[0] * cr[1]))
FLAGS = (cv2.CALIB_CB_ADAPTIVE_THRESH + cv2.CALIB_CB_NORMALIZE_IMAGE)


def search(gray):
    """Returns every grid that matches, largest first."""
    hits = []
    for cols, rows in CANDIDATES:
        ok, _ = cv2.findChessboardCorners(gray, (cols, rows), FLAGS)
        if ok:
            hits.append((cols, rows))
    return hits


def main():
    cap = open_camera()
    print("Hold the board flat, square to the camera, filling most of the frame.")
    print("SPACE to search this frame.  ESC to quit.\n")
    status = "SPACE to search"
    colour = (255, 255, 255)
    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                continue
            show = cv2.resize(frame, (1280, 720))
            # Mean brightness: a black frame is the commonest reason nothing
            # is found, and it is not obvious on a dim laptop screen.
            mean = int(cv2.cvtColor(show, cv2.COLOR_BGR2GRAY).mean())
            cv2.putText(show, status, (20, 50), cv2.FONT_HERSHEY_SIMPLEX, 1.0, colour, 2)
            cv2.putText(show, f"brightness {mean}/255" + ("  TOO DARK" if mean < 40 else ""),
                        (20, 90), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                        (0, 0, 255) if mean < 40 else (200, 200, 200), 2)
            cv2.imshow("find pattern", show)

            key = cv2.waitKey(1) & 0xFF
            if key == 27:
                break
            if key == 32:
                status, colour = "searching...", (0, 200, 255)
                cv2.putText(show, status, (20, 50), cv2.FONT_HERSHEY_SIMPLEX, 1.0, colour, 2)
                cv2.imshow("find pattern", show)
                cv2.waitKey(1)
                gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
                hits = search(gray)
                if hits:
                    c, r = hits[0]
                    print(f"FOUND {c}x{r} inner corners  =  {c+1}x{r+1} squares")
                    print(f"   use:  --pattern {c}x{r}")
                    if len(hits) > 1:
                        print(f"   (sub-grids also matched: "
                              f"{', '.join(f'{a}x{b}' for a, b in hits[1:])} - "
                              f"the largest is the real board)")
                    status, colour = f"{c}x{r} inner corners = {c+1}x{r+1} squares", (0, 220, 0)
                else:
                    print("nothing found. Flatten the board, fill more of the "
                          "frame, add light, keep it square to the camera.")
                    status, colour = "nothing found - see console", (0, 0, 255)
    finally:
        cap.release()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
