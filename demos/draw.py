"""Drawing a RailGuard FrameResult onto a frame. Shared by the demos."""

import cv2

from railguard.core.alerts import BRAKE_NOW, CAUTION

# BGR
CORRIDOR = (0, 180, 0)
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
        overlay = frame.copy()
        cv2.fillPoly(overlay, [res.corridor_polygon], CORRIDOR)
        cv2.addWeighted(overlay, 0.25, frame, 0.75, 0, dst=frame)

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
        dist = "distance unknown" if worst.distance_m is None else f"{worst.distance_m:.0f} m"
        cv2.rectangle(frame, (0, 0), (w, int(80 * s)), BANNER[res.alert], -1)
        cv2.putText(frame, f"{res.alert}: {worst.cls_name} on track, {dist}",
                    (int(25 * s), int(55 * s)), FONT, 1.5 * s, (255, 255, 255),
                    max(2, int(4 * s)), cv2.LINE_AA)

    note = "distances: calibrated" if calibrated else "distances: ASSUMED focal length (uncalibrated)"
    put_label(frame, note, int(15 * s), h - int(15 * s), (255, 255, 255), 0.8 * s, max(1, int(2 * s)))
