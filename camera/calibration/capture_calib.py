"""Capture checkerboard photos for camera calibration, with on-screen guidance.

    python camera/calibration/capture_calib.py --out camera/calibration/images_wide --auto
    python camera/calibration/capture_calib.py --out camera/calibration/images_tele --auto --lens tele
    python camera/calibration/capture_calib.py --out camera/calibration/images_wide   # manual: SPACE saves

--auto walks through 20 steps, each a board position and angle (straight on,
turned left / right, tilted top / bottom, in the corners). The window shows
the current step, a target box, and a hint saying what to change. When the
board matches the step and is held still, the photo saves by itself.

Keys: SPACE save now   S skip this step   ESC quit

A lens check estimates the field of view from the photos taken so far and
warns when it does not match --lens (wide ~ zoom ring at W, tele ~ at T).

Photos continue the numbering already in --out, so nothing is overwritten;
steps already satisfied by photos in --out are ticked off at the start.
Saved photos are the clean camera frame, without any overlay.
"""
import argparse
import glob
import math
import os
import re
import threading
import time

import cv2
import numpy as np

from railguard.camera.capture import open_camera

GREEN, AMBER, RED, WHITE, CYAN, GREY = (0, 200, 0), (0, 170, 255), (0, 0, 255), (255, 255, 255), (255, 220, 0), (150, 150, 150)
FONT = cv2.FONT_HERSHEY_SIMPLEX
DISPLAY_W = 1280
DETECT_SCALE = 0.75     # live detection runs on a 3/4-size frame
TILT = 0.09             # foreshortening that counts as "tilted" (~25 degrees)
FLAT = 0.10             # more than this is not "straight on"
HOLD_S = 0.6            # seconds the board must be still before saving

# (x, y) target centre as a share of the frame, required tilt, instruction
STEPS = [
    (0.50, 0.50, None, "CENTRE, facing the camera straight on"),
    (0.50, 0.50, "left", "CENTRE, turn the board so its LEFT side is further away"),
    (0.50, 0.50, "right", "CENTRE, turn the board so its RIGHT side is further away"),
    (0.50, 0.50, "top", "CENTRE, tilt the board so its TOP edge is further away"),
    (0.50, 0.50, "bottom", "CENTRE, tilt the board so its BOTTOM edge is further away"),
    (0.25, 0.27, None, "TOP-LEFT of the screen, straight on"),
    (0.75, 0.27, None, "TOP-RIGHT of the screen, straight on"),
    (0.25, 0.73, None, "BOTTOM-LEFT of the screen, straight on"),
    (0.75, 0.73, None, "BOTTOM-RIGHT of the screen, straight on"),
    (0.25, 0.50, "right", "LEFT of the screen, RIGHT side of the board further away"),
    (0.75, 0.50, "left", "RIGHT of the screen, LEFT side of the board further away"),
    (0.50, 0.27, "bottom", "TOP of the screen, BOTTOM edge further away"),
    (0.50, 0.73, "top", "BOTTOM of the screen, TOP edge further away"),
    (0.25, 0.27, "right", "TOP-LEFT, RIGHT side further away"),
    (0.75, 0.27, "left", "TOP-RIGHT, LEFT side further away"),
    (0.25, 0.73, "top", "BOTTOM-LEFT, TOP edge further away"),
    (0.75, 0.73, "top", "BOTTOM-RIGHT, TOP edge further away"),
    (0.50, 0.50, "left", "CENTRE, LEFT side further away, a bit closer than before"),
    (0.50, 0.50, "top", "CENTRE, TOP edge further away, a bit closer than before"),
    (0.50, 0.50, None, "CENTRE, straight on, further back than before"),
]


# ---------------- board geometry ----------------

def find_board(gray, rows, cols, flags):
    """(found, corners, pattern). Tries the board both ways round; pattern is
    the (points per row, rows) that matched, as findChessboardCorners uses it."""
    for pattern in ((cols, rows), (rows, cols)):
        found, c = cv2.findChessboardCorners(gray, pattern, flags=flags)
        if found:
            return True, c, pattern
    return False, None, None


def measure(c, pattern, w, h):
    """Board position, size and tilt in the frame, independent of which way
    round the board was detected."""
    per_row, n_rows = pattern
    p = c.reshape(n_rows, per_row, 2).astype(np.float64)
    xs, ys = p[..., 0], p[..., 1]
    n = np.linalg.norm
    # The board's four outer edges, taken from the grid itself so they never
    # collapse: "ends" are the first/last column, "sides" the first/last row.
    ends = (p[:, 0], p[:, -1])
    sides = (p[0], p[-1])
    def pair(edges):        # (midpoints, lengths) of two opposite edges
        return [e.mean(0) for e in edges], [max(n(e[-1] - e[0]), 1e-6) for e in edges]
    (m_e, l_e), (m_s, l_s) = pair(ends), pair(sides)
    # whichever pair is separated more horizontally holds the left/right edges
    if abs(m_e[1][0] - m_e[0][0]) >= abs(m_s[1][0] - m_s[0][0]):
        (m_lr, l_lr), (m_tb, l_tb) = (m_e, l_e), (m_s, l_s)
    else:
        (m_lr, l_lr), (m_tb, l_tb) = (m_s, l_s), (m_e, l_e)
    left, right = (l_lr[0], l_lr[1]) if m_lr[0][0] <= m_lr[1][0] else (l_lr[1], l_lr[0])
    top, bottom = (l_tb[0], l_tb[1]) if m_tb[0][1] <= m_tb[1][1] else (l_tb[1], l_tb[0])
    # square size along the two grid directions -> foreshortening
    step_a = n(np.diff(p, axis=1), axis=-1).mean()
    step_b = n(np.diff(p, axis=0), axis=-1).mean()
    va = (p[:, -1] - p[:, 0]).mean(0)
    sq_h, sq_v = (step_a, step_b) if abs(va[0]) >= abs(va[1]) else (step_b, step_a)
    return {
        "cx": float(xs.mean()) / w, "cy": float(ys.mean()) / h,
        "width": float(xs.max() - xs.min()) / w,
        "yaw": max(0.0, 1 - sq_h / max(sq_v, 1e-6)),     # turned left/right: horizontal squeezed
        "pitch": max(0.0, 1 - sq_v / max(sq_h, 1e-6)),   # tilted top/bottom: vertical squeezed
        "lr": math.log(left / right),   # < 0: left side further away
        "tb": math.log(top / bottom),   # < 0: top edge further away
    }


def check_step(m, step, min_width):
    """(matches, hint) for a measured board against a step."""
    tx, ty, tilt, _ = step
    if m["width"] < min_width:
        return False, "Bring the board CLOSER to the camera"
    dx, dy = tx - m["cx"], ty - m["cy"]
    if max(abs(dx), abs(dy)) > 0.14:
        if abs(dx) >= abs(dy):
            return False, f"Move the board to the {'RIGHT' if dx > 0 else 'LEFT'} of the screen"
        return False, f"Move the board {'DOWN' if dy > 0 else 'UP'} on the screen"
    if tilt is None:
        if max(m["yaw"], m["pitch"]) > FLAT:
            return False, "Face the board straight at the camera"
        return True, ""
    amount, sign, want = ((m["yaw"], m["lr"], -1 if tilt == "left" else 1) if tilt in ("left", "right")
                          else (m["pitch"], m["tb"], -1 if tilt == "top" else 1))
    side = {"left": "LEFT side", "right": "RIGHT side", "top": "TOP edge", "bottom": "BOTTOM edge"}[tilt]
    if amount < TILT:
        return False, f"Tilt MORE: {side} further away from the camera"
    if abs(sign) > 0.02 and (sign > 0) != (want > 0):
        return False, f"Wrong way round: the {side} should be further away"
    return True, ""


def object_grid(pattern):
    per_row, n_rows = pattern
    g = np.zeros((per_row * n_rows, 3), np.float32)
    g[:, :2] = np.mgrid[0:per_row, 0:n_rows].T.reshape(-1, 2)
    return g


def estimate_fov(views, w, h):
    """Rough horizontal field of view (deg) from saved views, with a simple
    camera model (no distortion, centred). None until a tilted view exists."""
    if len(views) < 3 or not any(max(m["yaw"], m["pitch"]) >= TILT for _, _, m in views):
        return None
    k = np.array([[w, 0, w / 2], [0, w, h / 2], [0, 0, 1]], np.float64)
    flags = (cv2.CALIB_USE_INTRINSIC_GUESS | cv2.CALIB_FIX_PRINCIPAL_POINT | cv2.CALIB_FIX_ASPECT_RATIO
             | cv2.CALIB_ZERO_TANGENT_DIST | cv2.CALIB_FIX_K1 | cv2.CALIB_FIX_K2 | cv2.CALIB_FIX_K3)
    try:
        _, k, *_ = cv2.calibrateCamera([object_grid(pat) for _, pat, _ in views],
                                       [c.astype(np.float32) for c, _, _ in views],
                                       (w, h), k, np.zeros(5), flags=flags)
    except cv2.error:
        return None
    return math.degrees(2 * math.atan(w / 2 / k[0, 0]))


# ---------------- live detection in the background ----------------

class Detector(threading.Thread):
    """Finds the board in the newest frame without blocking the preview.
    A fast check runs every frame; full detection (needed for softer, dim
    boards, ~0.5-1 s when there is no board) at most twice a second."""

    def __init__(self, rows, cols):
        super().__init__(daemon=True)
        self.rows, self.cols = rows, cols
        self._frame, self._lock = None, threading.Lock()
        self.result = None      # (frame, corners or None, pattern, timestamp)
        self.running = True

    def submit(self, frame):
        with self._lock:
            self._frame = frame

    def run(self):
        last_full = 0.0
        while self.running:
            with self._lock:
                frame, self._frame = self._frame, None
            if frame is None:
                time.sleep(0.005)
                continue
            gray = cv2.resize(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY), None,
                              fx=DETECT_SCALE, fy=DETECT_SCALE)
            found, c, pat = find_board(gray, self.rows, self.cols, cv2.CALIB_CB_FAST_CHECK)
            if not found and time.time() - last_full > 0.5:
                found, c, pat = find_board(gray, self.rows, self.cols, None)
                last_full = time.time()
            self.result = (frame, c / DETECT_SCALE if found else None, pat, time.time())


# ---------------- drawing ----------------

def text(img, s, org, scale, colour, thick=2):
    cv2.putText(img, s, org, FONT, scale, (0, 0, 0), thick + 4, cv2.LINE_AA)
    cv2.putText(img, s, org, FONT, scale, colour, thick, cv2.LINE_AA)


def next_index(out):
    nums = [int(m.group(1)) for f in glob.glob(os.path.join(out, "calib_*.jpg"))
            if (m := re.search(r"calib_(\d+)\.jpg$", f))]
    return max(nums) + 1 if nums else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="folder to save photos into")
    ap.add_argument("--auto", action="store_true", help="guided automatic capture")
    ap.add_argument("--lens", choices=("wide", "tele"),
                    help="zoom setting being calibrated (default: from the folder name)")
    ap.add_argument("--pattern", default="6x8", help="inner corners, rows x cols")
    ap.add_argument("--min-width", type=float, default=0.15,
                    help="smallest board width, as a share of the frame width")
    ap.add_argument("--camera", type=int, default=1)
    args = ap.parse_args()
    rows, cols = (int(n) for n in args.pattern.lower().split("x"))
    lens = args.lens or ("tele" if "tele" in args.out.lower() else "wide")
    os.makedirs(args.out, exist_ok=True)

    count = next_index(args.out)
    done, views = set(), []     # finished steps; (corners, pattern, measure) of every photo
    for f in sorted(glob.glob(os.path.join(args.out, "calib_*.jpg"))):
        g = cv2.cvtColor(cv2.imread(f), cv2.COLOR_BGR2GRAY)
        ok, c, pat = find_board(g, rows, cols, None)
        if ok:
            m = measure(c, pat, g.shape[1], g.shape[0])
            views.append((c, pat, m))
            hit = next((i for i, s in enumerate(STEPS)
                        if i not in done and check_step(m, s, args.min_width)[0]), None)
            if hit is not None:
                done.add(hit)
    skipped = set()
    print(f"{len(views)} photos already in {args.out}; next is calib_{count:03d}.jpg")

    cap = open_camera(args.camera)
    det = Detector(rows, cols)
    if args.auto:
        det.start()
    prev_c, still_since, last_save, last_res_t = None, None, 0.0, 0.0
    fov, flash = estimate_fov(views, 1920, 1080), 0.0
    hint, hint_col = "Looking for the board...", RED

    while True:
        ok, frame = cap.read()
        if not ok:                       # USB dropped: wait and reopen instead of quitting
            cap.release()
            print("Camera lost - check the USB cable. Retrying...")
            blank = np.zeros((720, DISPLAY_W, 3), np.uint8)
            text(blank, "CAMERA DISCONNECTED - check the USB cable", (40, 360), 1.1, RED)
            cv2.imshow("calibration capture", blank)
            if cv2.waitKey(1000) & 0xFF == 27:
                break
            try:
                cap = open_camera(args.camera)
            except RuntimeError:
                pass
            continue
        h, w = frame.shape[:2]
        k = DISPLAY_W / w
        disp = cv2.resize(frame, (DISPLAY_W, int(h * k)))
        step_i = next((i for i in range(len(STEPS)) if i not in done and i not in skipped), None)

        if args.auto:
            det.submit(frame)
            res = det.result
            if res is not None and res[3] > last_res_t:      # a new detection result
                last_res_t = res[3]
                rframe, c, pat, _ = res
                if c is None:
                    hint, hint_col, prev_c, still_since = "No board seen - show the WHOLE board to the camera", RED, None, None
                else:
                    try:
                        m = measure(c, pat, w, h)
                    except (ValueError, ZeroDivisionError, FloatingPointError):
                        m = None
                if c is not None and m is None:
                    hint, hint_col, prev_c, still_since = "Board at an odd angle - turn it back a little", AMBER, None, None
                elif c is not None:
                    moving = (prev_c is None or prev_c.shape != c.shape or
                              np.linalg.norm(c - prev_c, axis=-1).mean() > max(1.5, 0.006 * m["width"] * w))
                    prev_c = c
                    still_since = None if moving else (still_since or time.time())
                    if step_i is None:
                        hint, hint_col = "All steps done - press ESC", GREEN
                    else:
                        match, why = check_step(m, STEPS[step_i], args.min_width)
                        if not match:
                            hint, hint_col, still_since = why, AMBER, None
                        elif still_since is None or time.time() - still_since < HOLD_S:
                            hint, hint_col = "Good - HOLD STILL", GREEN
                        elif time.time() - last_save > 1.0:
                            g = cv2.cvtColor(rframe, cv2.COLOR_BGR2GRAY)
                            ok_full, cf, patf = find_board(g, rows, cols, None)
                            if not ok_full:
                                hint, hint_col = "Too blurry - hold the board still", AMBER
                            else:
                                name = f"calib_{count:03d}.jpg"
                                cv2.imwrite(os.path.join(args.out, name), rframe)
                                views.append((cf, patf, measure(cf, patf, w, h)))
                                done.add(step_i)
                                count += 1
                                last_save, flash, still_since = time.time(), time.time(), None
                                fov = estimate_fov(views, w, h)
                                print(f"Saved {name} (step {step_i + 1}: {STEPS[step_i][3]})")
                                hint, hint_col = f"SAVED {name}", GREEN
            # board corners from the latest detection
            if res is not None and res[1] is not None:
                cv2.drawChessboardCorners(disp, res[2], (res[1] * k).astype(np.float32), True)

            # target box for the current step
            if step_i is not None:
                tx, ty = STEPS[step_i][0] * DISPLAY_W, STEPS[step_i][1] * disp.shape[0]
                bw, bh = 0.26 * DISPLAY_W, 0.36 * disp.shape[0]
                cv2.rectangle(disp, (int(tx - bw / 2), int(ty - bh / 2)), (int(tx + bw / 2), int(ty + bh / 2)), CYAN, 2)
                text(disp, "put the board here", (int(tx - bw / 2) + 6, int(ty - bh / 2) - 8), 0.55, CYAN, 1)

            # hold-still progress bar
            if still_since is not None and hint_col == GREEN and step_i is not None:
                frac = min(1.0, (time.time() - still_since) / HOLD_S)
                cv2.rectangle(disp, (40, 150), (40 + int(400 * frac), 170), GREEN, -1)
                cv2.rectangle(disp, (40, 150), (440, 170), WHITE, 1)

            # header: step and hint
            cv2.rectangle(disp, (0, 0), (DISPLAY_W, 135), (30, 30, 30), -1)
            if step_i is None:
                text(disp, f"ALL STEPS DONE: {len(views)} photos. Press ESC to finish.", (20, 45), 0.95, GREEN)
            else:
                text(disp, f"STEP {len(done) + len(skipped) + 1}/{len(STEPS)}:  {STEPS[step_i][3]}", (20, 45), 0.8, WHITE)
            text(disp, hint, (20, 95), 0.95, hint_col)
            if time.time() - flash < 0.4:
                cv2.rectangle(disp, (0, 0), (DISPLAY_W - 1, disp.shape[0] - 1), GREEN, 12)

        # footer: counts, lens check, keys
        fy = disp.shape[0] - 70
        cv2.rectangle(disp, (0, fy - 30), (DISPLAY_W, disp.shape[0]), (30, 30, 30), -1)
        n_tilted = sum(max(m["yaw"], m["pitch"]) >= TILT for _, _, m in views)
        text(disp, f"Photos: {len(views)}   tilted: {n_tilted}   skipped steps: {len(skipped)}", (20, fy), 0.65, WHITE, 1)
        if fov is None:
            lens_msg, lens_col = f"Lens check ({lens.upper()}): needs a few photos incl. a tilted one", GREY
        elif (lens == "wide" and fov >= 30) or (lens == "tele" and fov <= 15):
            lens_msg, lens_col = f"Lens check: ~{fov:.0f} deg view - looks right for {lens.upper()}", GREEN
        else:
            ring = "W" if lens == "wide" else "T"
            lens_msg, lens_col = f"Lens check: ~{fov:.0f} deg view - does NOT look like {lens.upper()}: set the zoom ring to {ring}", RED
        text(disp, lens_msg, (20, fy + 30), 0.65, lens_col, 1)
        text(disp, "SPACE save now    S skip step    ESC quit", (DISPLAY_W - 470, fy + 30), 0.6, GREY, 1)
        cv2.imshow("calibration capture", disp)

        key = cv2.waitKey(1) & 0xFF
        if key == 27:
            break
        if key == 32:
            name = f"calib_{count:03d}.jpg"
            cv2.imwrite(os.path.join(args.out, name), frame)
            g = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            ok_full, cf, patf = find_board(g, rows, cols, None)
            if ok_full:
                views.append((cf, patf, measure(cf, patf, w, h)))
                fov = estimate_fov(views, w, h)
            if step_i is not None:
                done.add(step_i)
            count += 1
            flash = time.time()
            print(f"Saved {name} [manual]{'' if ok_full else ' - no board found in it'}")
        elif key in (ord("s"), ord("S")) and step_i is not None:
            skipped.add(step_i)
            print(f"Skipped step {step_i + 1}: {STEPS[step_i][3]}")

    det.running = False
    cap.release()
    cv2.destroyAllWindows()
    print(f"{len(views)} photos with a board in {args.out}"
          + (f"; lens check ~{fov:.0f} deg" if fov else ""))


if __name__ == "__main__":
    main()
