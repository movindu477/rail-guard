"""Threat selection and tiered alerts."""

from .corridor import foot_point, in_corridor
from .distance import estimate_distance_m

CAUTION = "CAUTION"
BRAKE_NOW = "BRAKE NOW"


def braking_distance_m(speed_kmh):
    """Distance the train needs to stop from the given line speed."""
    if speed_kmh < 60:
        return 300.0
    if speed_kmh <= 80:
        return 400.0
    return 500.0


def classify_threats(boxes, corridor, width_by_row, fx):
    """Mark which detections stand on the track and how far away they are.

    boxes: list of (x1, y1, x2, y2, cls_name).
    Returns (annotated, worst): annotated is a list of
    (x1, y1, x2, y2, cls_name, on_track, distance_m), where distance_m is
    None for off-track objects and for on-track ones that cannot be ranged;
    worst is the smallest known on-track distance, or None.
    """
    out = []
    worst = None
    for (x1, y1, x2, y2, cls_name) in boxes:
        gx, gy = foot_point(x1, y1, x2, y2)
        on_track = in_corridor(corridor, gx, gy)
        d = estimate_distance_m(gy, width_by_row, fx) if on_track else None
        if on_track and d is not None and (worst is None or d < worst):
            worst = d
        out.append((x1, y1, x2, y2, cls_name, on_track, d))
    return out, worst


def alert_level(threat_distances, brake_distance_m):
    """Alert tier for the objects on the track.

    threat_distances: distance_m of every on-track object, None where it
    could not be measured. brake_distance_m: what the train needs to stop.

    Fail-safe: an on-track object at unknown distance is BRAKE_NOW, because
    it cannot be ruled out that it is close. Returns None with no threats.
    """
    distances = list(threat_distances)
    if not distances:
        return None
    if any(d is None or d <= brake_distance_m for d in distances):
        return BRAKE_NOW
    return CAUTION
