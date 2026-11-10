"""Tests for railguard/alerts/publisher.py, with a fake Firestore (no network).

    python -m pytest tests/test_publisher.py
"""

import math
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

from railguard.alerts.publisher import (HazardPublisher, RateLimiter, destination,
                                        hazard_record, object_type)
from railguard.core.alerts import BRAKE_NOW, CAUTION
from railguard.results import Detection

FORT = (6.9337, 79.8500)   # Colombo Fort


def haversine(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    h = (math.sin((p2 - p1) / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2)
    return 2 * 6371008.8 * math.asin(math.sqrt(h))


def det(cls="elephant", dist=250.0, conf=0.8):
    return Detection(0, 0, 10, 10, cls_name=cls, conf=conf, on_track=True,
                     distance_m=dist, track_hits=3, confirmed=True)


def frame(alert=BRAKE_NOW, threat=None):
    return SimpleNamespace(alert=alert, worst_threat=threat or det())


# ---- fake Firestore -------------------------------------------------------

class FakeDB:
    def __init__(self, position=None):
        self.position = position   # train_position document, or None
        self.added = []

    def collection(self, name):
        db = self

        class Col:
            def document(self, doc_id):
                return SimpleNamespace(get=lambda: SimpleNamespace(
                    exists=db.position is not None, to_dict=lambda: dict(db.position)))

            def add(self, record):
                db.added.append((name, record))
                return None, SimpleNamespace(id=f"h{len(db.added)}")
        return Col()


def position(age_s=3.0, heading=90.0):
    return {"unit_id": "unit-01", "latitude": FORT[0], "longitude": FORT[1], "heading": heading,
            "timestamp": datetime.now(timezone.utc) - timedelta(seconds=age_s)}


def publish(db, *frames):
    p = HazardPublisher("unit-01", db=db, verbose=False)
    started = [p.on_frame(f) for f in frames]
    p.close()
    return p, started


# ---- geometry -------------------------------------------------------------

def test_destination_distance_and_direction():
    for bearing in (0, 90, 180, 270, 45):
        lat, lon = destination(*FORT, bearing, 400)
        assert abs(haversine(*FORT, lat, lon) - 400) < 0.5
    north = destination(*FORT, 0, 1000)
    east = destination(*FORT, 90, 1000)
    assert north[0] > FORT[0] and abs(north[1] - FORT[1]) < 1e-9
    assert east[1] > FORT[1] and abs(east[0] - FORT[0]) < 1e-4


def test_object_types_match_the_app():
    assert object_type("elephant") == "animal"
    assert object_type("cow") == "animal"
    assert object_type("person") == "person"
    assert {object_type(c) for c in ("car", "motorcycle", "bus", "truck")} == {"vehicle"}
    assert object_type("anything else") == "obstruction"


# ---- the record ------------------------------------------------------------

def test_record_ahead_of_train_when_heading_known():
    r = hazard_record(position(heading=90.0), det(dist=300.0), "unit-01", 3.0, "T")
    assert r["placed"] == "ahead_of_train"
    assert abs(haversine(*FORT, r["latitude"], r["longitude"]) - 300) < 0.5
    assert r["longitude"] > FORT[1]          # east, along heading 90
    # same fields as a manual report
    assert r["status"] == "active" and r["object_type"] == "animal" and r["timestamp"] == "T"
    assert r["distance_m"] == 300.0 and r["reported_by"] == "auto" and r["unit_id"] == "unit-01"
    assert r["severity"] == "blocked"   # in the corridor: the app goes to STOP at 1 km
    assert (r["train_latitude"], r["train_longitude"]) == FORT


def test_record_with_numpy_values_is_plain_python():
    """The pipeline gives numpy float32 distances and confidences; Firestore
    rejects them, so every number in the record must be a plain Python float."""
    import numpy as np
    d = Detection(0, 0, 10, 10, cls_name="cow", conf=np.float32(0.71), on_track=True,
                  distance_m=np.float32(38.1), track_hits=3, confirmed=True)
    r = hazard_record(position(heading=np.float64(90.0)), d, "unit-01", 3.0, "T")
    for k, v in r.items():
        assert not isinstance(v, np.generic), f"{k} is {type(v)}"
    assert r["distance_m"] == 38.1


def test_record_at_train_when_heading_unknown():
    r = hazard_record(position(heading=None), det(dist=300.0), "unit-01", 3.0, "T")
    assert r["placed"] == "at_train"
    assert (r["latitude"], r["longitude"]) == FORT


def test_record_at_train_when_distance_unknown():
    r = hazard_record(position(heading=90.0), det(dist=None), "unit-01", 3.0, "T")
    assert r["placed"] == "at_train" and r["distance_m"] is None


# ---- publishing --------------------------------------------------------------

def test_brake_now_publishes_one_hazard():
    db = FakeDB(position())
    p, started = publish(db, frame())
    assert started == [True]
    assert len(db.added) == 1 and db.added[0][0] == "hazards"
    assert p.published == ["h1"]


def test_caution_does_not_publish():
    db = FakeDB(position())
    _, started = publish(db, frame(alert=CAUTION), frame(alert=None))
    assert started == [False, False] and db.added == []


def test_rate_limited_to_one_per_interval():
    db = FakeDB(position())
    _, started = publish(db, *[frame() for _ in range(10)])
    assert started.count(True) == 1 and len(db.added) == 1


def test_rate_limiter_allows_again_after_interval():
    t = [0.0]
    lim = RateLimiter(30, clock=lambda: t[0])
    assert lim.allow()
    t[0] = 29.9
    assert not lim.allow()
    t[0] = 30.0
    assert lim.allow()


def test_stale_position_is_not_used():
    db = FakeDB(position(age_s=300))
    publish(db, frame())
    assert db.added == []


def test_no_phone_position_is_not_used():
    db = FakeDB(None)
    publish(db, frame())
    assert db.added == []


def test_firestore_error_does_not_raise():
    class Broken(FakeDB):
        def collection(self, name):
            raise RuntimeError("network down")
    p, started = publish(Broken(), frame())
    assert started == [True] and p.published == []
