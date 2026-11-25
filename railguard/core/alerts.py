"""Threat selection, tiered alerts, hysteresis and minimum hold."""

import time

from .corridor import foot_point, in_corridor
from .distance import estimate_distance_m

CAUTION = "CAUTION"
BRAKE_NOW = "BRAKE NOW"
_RANK = {None: 0, CAUTION: 1, BRAKE_NOW: 2}


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


class TrackHysteresis:
    """Require `confirm_frames` consecutive opposite verdicts to flip track validity.

    First frame adopts the raw verdict immediately (never claims a valid track on
    startup if none is seen). Subsequent single-frame glitches do not flip state.
    """

    def __init__(self, confirm_frames=3):
        self.confirm_frames = max(1, int(confirm_frames))
        self.valid = None
        self._streak = 0

    def update(self, raw_valid: bool) -> bool:
        raw_valid = bool(raw_valid)
        if self.valid is None:
            self.valid = raw_valid
            self._streak = 0
            return self.valid
        if raw_valid == self.valid:
            self._streak = 0
            return self.valid
        self._streak += 1
        if self._streak >= self.confirm_frames:
            self.valid = raw_valid
            self._streak = 0
        return self.valid


class AlertHold:
    """Hold a raised alert for at least `min_hold_s` before clearing or stepping down.

    Raising and escalating (None -> CAUTION -> BRAKE NOW) happen immediately on
    the first frame; hysteresis applies only to clearing / de-escalating.
    """

    def __init__(self, min_hold_s=2.0, clock=time.monotonic):
        self.min_hold_s = max(0.0, float(min_hold_s))
        self.clock = clock
        self.alert = None
        self.threat = None
        self._hold_until = 0.0

    def update(self, raw_alert, raw_threat):
        now = self.clock()
        raw_rank = _RANK.get(raw_alert, 0)
        cur_rank = _RANK.get(self.alert, 0)

        if raw_rank > cur_rank:
            # Raise or escalate immediately — never delay an alert.
            self.alert = raw_alert
            self.threat = raw_threat
            self._hold_until = now + self.min_hold_s
            return self.alert, self.threat

        if raw_rank == cur_rank and raw_alert is not None:
            # Condition still active: refresh threat and keep hold alive.
            self.threat = raw_threat
            self._hold_until = now + self.min_hold_s
            return self.alert, self.threat

        if cur_rank > 0 and now < self._hold_until:
            # Condition cleared or stepped down, but minimum hold has not elapsed.
            return self.alert, self.threat

        # Hold expired (or already clear): adopt raw state.
        self.alert = raw_alert
        self.threat = raw_threat if raw_alert is not None else None
        self._hold_until = now + self.min_hold_s if raw_alert is not None else 0.0
        return self.alert, self.threat
