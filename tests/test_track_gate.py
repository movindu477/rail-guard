"""Tests for the track plausibility gate (geometry + pipeline), no models needed.

    python -m pytest tests/test_track_gate.py
"""

import numpy as np

from railguard.config import PipelineConfig
from railguard.core.alerts import BRAKE_NOW
from railguard.core.geometry import rail_convergence, rail_width_by_row, track_plausible
from railguard.core.tracking import PersistenceTracker
from railguard.pipeline import RailGuardPipeline

H = W = 400

# Ego-paths: (left_rail, right_rail), points bottom to top.
CONVERGING = ([(150, 399), (170, 300), (190, 200)], [(250, 399), (230, 300), (210, 200)])
PARALLEL = ([(150, 399), (150, 300), (150, 200)], [(250, 399), (250, 300), (250, 200)])
DIVERGING = ([(180, 399), (160, 300), (100, 200)], [(220, 399), (240, 300), (300, 200)])


# ---- geometry ---------------------------------------------------------------

def test_converging_rails_are_a_track():
    w = rail_width_by_row(CONVERGING, H)
    assert rail_convergence(w) == 20 / 100     # far 20 px, near 100 px
    assert track_plausible(w)


def test_parallel_or_diverging_rails_are_not():
    for path in (PARALLEL, DIVERGING):
        w = rail_width_by_row(path, H)
        assert rail_convergence(w) >= 1
        assert not track_plausible(w)


def test_no_track_is_not_plausible():
    w = rail_width_by_row(None, H)
    assert rail_convergence(w) is None
    assert not track_plausible(w)


def test_threshold_is_strict():
    w = np.zeros(H, np.float32)
    w[200], w[399] = 50, 100                  # exactly 0.5
    assert not track_plausible(w)
    assert track_plausible(w, max_convergence=0.6)


# ---- pipeline, with fake TEP-Net and detector -------------------------------

class FakeTepnet:
    def __init__(self, egopath):
        self.egopath = egopath

    def detect(self, _img):
        return self.egopath


class Box:
    def __init__(self, xyxy, cls=0, conf=0.9):
        self.xyxy, self.cls, self.conf = [xyxy], [cls], [conf]


class FakeYolo:
    names = {0: "person"}

    def predict(self, *_a, **_k):
        # a person standing in the middle of the track, foot point at (200, 390)
        return [type("R", (), {"boxes": [Box([190, 330, 210, 390])]})()]


def pipeline(egopath, **cfg):
    p = RailGuardPipeline.__new__(RailGuardPipeline)   # skip loading real models
    p.config = PipelineConfig(device="cpu", fx=350.0, **cfg)
    p.model, p.keep_ids, p.tepnet = FakeYolo(), [0], FakeTepnet(egopath)
    p._frame_idx, p._last_egopath, p._track = 0, None, None
    p._persistence = PersistenceTracker(max_age=p.config.track_max_age)
    return p


def run(p, frames=3):
    frame = np.zeros((H, W, 3), np.uint8)
    return [p.process_frame(frame) for _ in range(frames)][-1]


def test_valid_track_measures_distance():
    res = run(pipeline(CONVERGING))
    assert res.track_valid and res.rail_convergence == 0.2
    d = res.detections[0]
    assert d.on_track and d.distance_m is not None


def test_failed_gate_makes_distance_unknown_and_brakes():
    res = run(pipeline(PARALLEL))
    assert not res.track_valid and res.rail_convergence >= 1
    d = res.detections[0]
    assert d.on_track and d.confirmed
    assert d.distance_m is None          # never a distance from a track that is not there
    assert res.alert == BRAKE_NOW        # fail-safe: confirmed threat at unknown distance


def test_gate_can_be_switched_off():
    res = run(pipeline(PARALLEL, track_check=False))
    assert res.track_valid
    assert res.detections[0].distance_m is not None
