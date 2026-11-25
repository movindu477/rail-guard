"""Drawing a RailGuard FrameResult onto a video frame.
Shared by the PyQt5 desktop application (railguard/ui/app.py) and the CLI demos
(demos/live_demo.py, demos/offline_video.py via demos/draw.py).
"""
import cv2
from railguard.core.alerts import BRAKE_NOW, CAUTION
# BGR colours
CORRIDOR = (0, 180, 0)
CORRIDOR_BAD = (0, 0, 200)  # corridor from a track that failed the plausibility gate
ON_TRACK = (0, 140, 255)    # orange
OFF_TRACK = (160, 160, 160)
UNKNOWN = (0, 0, 255)       # red: on the track, distance unknown
BANNER = {BRAKE_NOW: (0, 0, 220), CAUTION: (0, 140, 255)}
FONT = cv2.FONT_HERSHEY_SIMPLEX

def put_label(frame, text, x, y, colour, scale, thick):
    """Text with its baseline at (x, y), on a dark box so it reads on any background."""
    (tw, th), base = cv2.getTextSize(text, FONT, scale, thick)
    x = max(0, min(x, frame.shape[1] - tw - 6))
    y = max(th + 6, y)
    cv2.rectangle(frame, (x, y - th - 6), (x + tw + 6, y + base), (0, 0, 0), -1)
    cv2.putText(frame, text, (x + 3, y - 3), FONT, scale, colour, thick, cv2.LINE_AA)

def draw(frame, res, calibrated, persist=3):
    """Annotate frame in place with one FrameResult. persist: PipelineConfig.persist_frames."""
    h, w = frame.shape[:2]
    s = w / 1920  # scale text and lines with the frame size
    if res.corridor_polygon is not None:
        if res.track_valid:
            overlay = frame.copy()
            cv2.fillPoly(overlay, [res.corridor_polygon], CORRIDOR)
            cv2.addWeighted(overlay, 0.25, frame, 0.75, 0, dst=frame)
        else:
            # Invalid corridor is meaningless: thin outline only so it never obscures the video.
            cv2.polylines(frame, [res.corridor_polygon], True, CORRIDOR_BAD,
                          max(1, int(2 * s)), cv2.LINE_AA)
    # On-track last and confirmed last of all, so their labels sit on top.
    for d in sorted(res.detections, key=lambda d: (d.on_track, d.confirmed)):
        if d.on_track:
            # thick once confirmed (it can alert); thin with a counter until then
            colour, thick = ON_TRACK, max(2, int((4 if d.confirmed else 2) * s))
            wait = "" if d.confirmed else f" ({d.track_hits}/{persist})"
            if d.distance_m is None:
                label, text_colour = f"{d.cls_name} ? m{wait}", UNKNOWN
            else:
                label, text_colour = f"{d.cls_name} {d.distance_m:.1f} m{wait}", ON_TRACK
        else:
            colour, thick, label, text_colour = OFF_TRACK, max(1, int(2 * s)), d.cls_name, OFF_TRACK
        cv2.rectangle(frame, (d.x1, d.y1), (d.x2, d.y2), colour, thick)
        put_label(frame, label, d.x1, d.y1 - int(4 * s), text_colour,
                  (0.9 if d.on_track else 0.6) * s, max(1, int(2 * s)))
    if res.alert is not None:
        worst = res.worst_threat
        dist = "? m (fail-safe: distance unknown)" if worst.distance_m is None else f"{worst.distance_m:.0f} m"
        cv2.rectangle(frame, (0, 0), (w, int(80 * s)), BANNER[res.alert], -1)
        cv2.putText(frame, f"{res.alert}: {worst.cls_name} on track, {dist}",
                    (int(25 * s), int(55 * s)), FONT, 1.4 * s, (255, 255, 255),
                    max(2, int(4 * s)), cv2.LINE_AA)
    if not res.track_valid:
        # Never show a confident wrong corridor: say the track is not seen.
        y0 = int(80 * s) if res.alert is not None else 0
        cv2.rectangle(frame, (0, y0), (w, y0 + int(56 * s)), (0, 0, 0), -1)
        why = ("no track found" if res.rail_convergence is None
               else f"rails do not converge ({res.rail_convergence:.2f})")
        cv2.putText(frame, f"TRACK NOT DETECTED: {why}. Corridor unreliable, distances ?",
                    (int(25 * s), y0 + int(38 * s)), FONT, 0.9 * s, (0, 200, 255),
                    max(1, int(2 * s)), cv2.LINE_AA)
    note = "distances: calibrated" if calibrated else "distances: ASSUMED focal length (uncalibrated)"
    put_label(frame, note, int(15 * s), h - int(15 * s), (255, 255, 255), 0.8 * s, max(1, int(2 * s)))

def draw_stale(frame, age_s):
    """Mark a retained frame as stale in place when the camera has stopped delivering frames."""
    h, w = frame.shape[:2]
    s = w / 1920
    # Dim the image slightly and draw a stark border + central warning bar so a
    # driver can never mistake a frozen frame for live track ahead.
    cv2.rectangle(frame, (0, 0), (w - 1, h - 1), (0, 140, 255), max(4, int(10 * s)))
    bar_h = int(76 * s)
    y0 = (h - bar_h) // 2
    cv2.rectangle(frame, (0, y0), (w, y0 + bar_h), (0, 0, 0), -1)
    cv2.rectangle(frame, (0, y0), (w, y0 + bar_h), (0, 140, 255), max(2, int(3 * s)))
    msg = f"STALE FRAME ({age_s:.0f} s old) — camera lost, reconnecting..."
    cv2.putText(frame, msg, (int(30 * s), y0 + int(50 * s)),
                FONT, 1.2 * s, (0, 200, 255), max(2, int(3 * s)), cv2.LINE_AA)
