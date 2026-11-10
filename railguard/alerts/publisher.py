"""Publish BRAKE NOW detections to Firestore as hazards for the driver app.

The train unit (laptop: camera + pipeline) has no GPS. The driver's phone
(mobile/) writes where the train is to train_position/<unit_id> every 5 s.
On BRAKE NOW this module reads that position and writes a hazard record to
the same `hazards` collection the app's Report button uses, so every phone
running the app warns about it.

    publisher = HazardPublisher(unit_id="unit-01")   # key: see find_key()
    for frame in ...:
        result = pipeline.process_frame(frame)
        publisher.on_frame(result)                  # never blocks the frame loop
    publisher.close()                               # wait for uploads in flight

Rules:
  - At most one hazard per `min_interval_s` (30 s) per unit, so a held
    BRAKE NOW is one report, not one per frame.
  - The hazard is placed distance_m ahead of the train along its heading.
    Heading unknown (train standing or slow) or distance unknown: at the train.
  - A train position older than `max_position_age_s` (2 min: phone offline or
    app closed) is not used: nothing is published and the reason is printed.
    The driver is still warned on the laptop; only the report to other trains
    is skipped, rather than placing a hazard at a wrong location.

firebase-admin is imported only when publishing starts, so the rest of
railguard does not need it (pip install firebase-admin, or pip install -e .[alerts]).
"""

import math
import os
import threading
import time
from datetime import datetime, timezone
from typing import Optional

from ..core.alerts import BRAKE_NOW

EARTH_RADIUS_M = 6371008.8

# Detector class -> the app's object_type (mobile/lib/ui/theme.dart, hazardTypes).
OBJECT_TYPE = {
    "person": "person",
    "car": "vehicle", "motorcycle": "vehicle", "bus": "vehicle", "truck": "vehicle",
    "cow": "animal", "elephant": "animal",
}

KEY_ENV = "RAILGUARD_FIREBASE_KEY"
DEFAULT_KEY = os.path.join(os.path.expanduser("~"), ".railguard", "firebase-key.json")


def object_type(cls_name):
    """The app's hazard type for a detector class; anything else is an obstruction."""
    return OBJECT_TYPE.get(cls_name, "obstruction")


def destination(lat, lon, bearing_deg, distance_m):
    """Point distance_m from (lat, lon) along bearing_deg (great circle)."""
    d = distance_m / EARTH_RADIUS_M
    p1, l1, b = math.radians(lat), math.radians(lon), math.radians(bearing_deg)
    p2 = math.asin(math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(b))
    l2 = l1 + math.atan2(math.sin(b) * math.sin(d) * math.cos(p1),
                         math.cos(d) - math.sin(p1) * math.sin(p2))
    return math.degrees(p2), (math.degrees(l2) + 540) % 360 - 180


def hazard_record(position, detection, unit_id, position_age_s, timestamp):
    """The Firestore hazard for one confirmed threat.

    position: the train_position document (latitude, longitude, heading).
    detection: railguard.results.Detection. timestamp: what to store as the
    report time (Firestore SERVER_TIMESTAMP in use).
    Same fields as a manual report from the app, plus the camera's details.
    """
    # Plain floats: the pipeline gives numpy values, which Firestore cannot store.
    lat, lon = float(position["latitude"]), float(position["longitude"])
    heading = None if position.get("heading") is None else float(position["heading"])
    dist = None if detection.distance_m is None else float(detection.distance_m)
    if heading is not None and dist is not None:
        h_lat, h_lon = destination(lat, lon, heading, dist)
        placed = "ahead_of_train"
    else:
        h_lat, h_lon = lat, lon
        placed = "at_train"   # heading or distance unknown
    return {
        # same as a manual report
        "latitude": h_lat,
        "longitude": h_lon,
        "timestamp": timestamp,
        "object_type": object_type(detection.cls_name),
        # BRAKE NOW means the object is inside the train's corridor: the line is blocked.
        "severity": "blocked",
        "distance_m": None if dist is None else round(dist, 1),
        "status": "active",
        # automatic report
        "reported_by": "auto",
        "unit_id": unit_id,
        "detected_class": detection.cls_name,
        "confidence": round(float(detection.conf), 3),
        "placed": placed,
        "train_latitude": lat,
        "train_longitude": lon,
        "train_heading": heading,
        "position_age_s": round(position_age_s, 1),
    }


def find_key(path=None):
    """Service-account key: the given path, else $RAILGUARD_FIREBASE_KEY, else
    ~/.railguard/firebase-key.json. Keep it outside the repository."""
    for p in (path, os.environ.get(KEY_ENV), DEFAULT_KEY):
        if p and os.path.isfile(p):
            return p
    raise FileNotFoundError(
        "Firebase service-account key not found. Firebase console > Project settings > "
        f"Service accounts > Generate new private key, save it as {DEFAULT_KEY} "
        f"(or pass its path / set {KEY_ENV}). Never put it in the repository.")


class RateLimiter:
    """At most one event per interval_s."""

    def __init__(self, interval_s, clock=time.monotonic):
        self.interval_s = interval_s
        self.clock = clock
        self._last = None

    def allow(self):
        now = self.clock()
        if self._last is not None and now - self._last < self.interval_s:
            return False
        self._last = now
        return True


class HazardPublisher:
    def __init__(self, unit_id, key_path=None, min_interval_s=30.0,
                 max_position_age_s=120.0, db=None, verbose=True):
        """db: a Firestore client (tests pass a fake); None = connect with the key."""
        self.unit_id = unit_id
        self.max_position_age_s = max_position_age_s
        self.limiter = RateLimiter(min_interval_s)
        self.verbose = verbose
        self.published = []       # ids of hazards written, for reporting
        self._threads = []
        if db is None:
            import firebase_admin
            from firebase_admin import credentials, firestore
            if not firebase_admin._apps:
                firebase_admin.initialize_app(credentials.Certificate(find_key(key_path)))
            db = firestore.client()
            self._server_time = firestore.SERVER_TIMESTAMP
        else:
            self._server_time = "SERVER_TIMESTAMP"
        self.db = db

    def _log(self, msg):
        if self.verbose:
            print(f"[publisher {self.unit_id}] {msg}")

    def on_frame(self, result):
        """Call once per processed frame. On BRAKE NOW (and not rate limited)
        starts publishing the worst threat in the background. True if started."""
        if result.alert != BRAKE_NOW:
            return False
        threat = result.worst_threat
        if threat is None or not self.limiter.allow():
            return False
        t = threading.Thread(target=self._publish, args=(threat,), daemon=True)
        t.start()
        self._threads.append(t)
        return True

    def _publish(self, threat):
        try:
            snap = self.db.collection("train_position").document(self.unit_id).get()
            if not snap.exists:
                self._log("no train_position for this unit: is the phone app running? Not published.")
                return
            pos = snap.to_dict()
            ts = pos.get("timestamp")
            if ts is None or pos.get("latitude") is None:
                self._log("train_position has no time or position yet. Not published.")
                return
            age = (datetime.now(timezone.utc) - ts).total_seconds()
            if age > self.max_position_age_s:
                self._log(f"train position is {age:.0f} s old (phone offline?). Not published.")
                return
            record = hazard_record(pos, threat, self.unit_id, age, self._server_time)
            _, ref = self.db.collection("hazards").add(record)
            self.published.append(ref.id)
            dist = "unknown distance" if threat.distance_m is None else f"{threat.distance_m:.0f} m"
            self._log(f"hazard {ref.id}: {threat.cls_name} at {dist}, "
                      f"{record['latitude']:.5f}, {record['longitude']:.5f} ({record['placed']})")
        except Exception as e:   # never take the detection loop down
            self._log(f"publish failed: {e}")

    def close(self, timeout=15.0):
        """Wait for uploads still in flight (call before the program exits)."""
        for t in self._threads:
            t.join(timeout)
        self._threads.clear()
