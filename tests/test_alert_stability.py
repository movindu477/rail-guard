"""Tests for track hysteresis, alert minimum hold, and non-obscuring corridor overlay."""

import numpy as np

from railguard.config import PipelineConfig
from railguard.core.alerts import AlertHold, BRAKE_NOW, CAUTION, TrackHysteresis
from railguard.core.tracking import PersistenceTracker
from railguard.pipeline import RailGuardPipeline
from railguard.results import Detection, FrameResult
from railguard.ui.overlay import CORRIDOR_BAD, draw


class FakeClock:
    def __init__(self, t=0.0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, dt):
        self.t += dt


# ---- TrackHysteresis --------------------------------------------------------

def test_track_hysteresis_requires_3_frames_to_lose_and_regain():
    g = TrackHysteresis(confirm_frames=3)
    assert g.update(True) is True
    # 1 or 2 bad frames do not flip state; streak resets on a good frame.
    assert g.update(False) is True
    assert g.update(False) is True
    assert g.update(True) is True
    assert g.update(False) is True
    assert g.update(False) is True
    # 3rd consecutive bad frame flips to False.
    assert g.update(False) is False
    # 1 or 2 good frames do not flip back.
    assert g.update(True) is False
    assert g.update(True) is False
    assert g.update(False) is False
    assert g.update(True) is False
    assert g.update(True) is False
    # 3rd consecutive good frame restores True.
    assert g.update(True) is True


def test_track_hysteresis_adopts_initial_invalid_immediately():
    g = TrackHysteresis(confirm_frames=3)
    assert g.update(False) is False


# ---- AlertHold --------------------------------------------------------------

def test_alert_hold_raises_immediately_and_holds_for_2s():
    clk = FakeClock(10.0)
    hold = AlertHold(min_hold_s=2.0, clock=clk)
    person = Detection(10, 10, 30, 80, "person", 0.9, True, 30.0, 3, True)

    # Immediate raise — never delayed.
    alert, threat = hold.update(BRAKE_NOW, person)
    assert alert == BRAKE_NOW and threat == person

    # Condition clears right away, but alert stays up for at least 2 s.
    clk.advance(0.5)
    alert, threat = hold.update(None, None)
    assert alert == BRAKE_NOW and threat == person

    clk.advance(1.4)  # total 1.9 s
    alert, threat = hold.update(None, None)
    assert alert == BRAKE_NOW and threat == person

    clk.advance(0.2)  # total 2.1 s
    alert, threat = hold.update(None, None)
    assert alert is None and threat is None


def test_alert_hold_escalates_immediately_but_holds_before_step_down():
    clk = FakeClock(0.0)
    hold = AlertHold(min_hold_s=2.0, clock=clk)
    far = Detection(10, 10, 30, 80, "person", 0.9, True, 500.0, 3, True)
    near = Detection(10, 10, 30, 80, "person", 0.9, True, 20.0, 3, True)

    assert hold.update(CAUTION, far) == (CAUTION, far)
    # Immediate escalation from CAUTION to BRAKE NOW.
    clk.advance(0.1)
    assert hold.update(BRAKE_NOW, near) == (BRAKE_NOW, near)
    # Dropping back to CAUTION within 2 s keeps BRAKE NOW.
    clk.advance(1.0)
    assert hold.update(CAUTION, far) == (BRAKE_NOW, near)
    # After 2 s, steps down to CAUTION.
    clk.advance(1.1)
    assert hold.update(CAUTION, far) == (CAUTION, far)


# ---- Pipeline integration ---------------------------------------------------

H = W = 400
CONVERGING = ([(150, 399), (170, 300), (190, 200)], [(250, 399), (230, 300), (210, 200)])
PARALLEL = ([(150, 399), (150, 300), (150, 200)], [(250, 399), (250, 300), (250, 200)])


class SeqTepnet:
    def __init__(self, seq):
        self.seq = list(seq)
        self.i = 0

    def detect(self, _img):
        val = self.seq[min(self.i, len(self.seq) - 1)]
        self.i += 1
        return val


class ToggleYolo:
    names = {0: "person"}

    def __init__(self, active=True):
        self.active = active

    def predict(self, img, *_a, **_k):
        if not self.active or img.shape[0] != H:
            return [type("R", (), {"boxes": []})()]
        box = type("B", (), {"xyxy": [[190, 330, 210, 390]], "cls": [0], "conf": [0.9]})()
        return [type("R", (), {"boxes": [box]})()]


def test_pipeline_holds_alert_and_keeps_worst_threat_safe_for_draw():
    clk = FakeClock(0.0)
    yolo = ToggleYolo(active=True)
    p = RailGuardPipeline.__new__(RailGuardPipeline)
    p.config = PipelineConfig(device="cpu", fx=350.0, alert_hold_s=2.0, track_hysteresis_frames=3)
    p.model, p.keep_ids, p.tepnet = yolo, [0], SeqTepnet([CONVERGING])
    p._frame_idx, p._last_egopath, p._track = 0, None, None
    p._persistence = PersistenceTracker(max_age=p.config.track_max_age)
    p._track_gate = TrackHysteresis(confirm_frames=3)
    p._alert_hold = AlertHold(min_hold_s=2.0, clock=clk)

    frame = np.zeros((H, W, 3), np.uint8)
    for _ in range(3):
        res = p.process_frame(frame)
    assert res.alert == BRAKE_NOW

    # Object disappears; alert stays held for 2 s and draw() does not crash.
    yolo.active = False
    clk.advance(0.5)
    res_held = p.process_frame(frame)
    assert res_held.alert == BRAKE_NOW
    assert res_held.worst_threat is not None
    draw(frame.copy(), res_held, calibrated=True)

    clk.advance(2.1)
    res_clear = p.process_frame(frame)
    assert res_clear.alert is None


# ---- Overlay invalid corridor outline ---------------------------------------

def test_invalid_corridor_draws_thin_outline_not_filled_region():
    poly = np.array([[100, 100], [300, 100], [300, 300], [100, 300]], dtype=np.int32)
    mask = np.zeros((H, W), dtype=np.uint8)
    widths = np.zeros(H, dtype=np.float32)

    valid_img = np.full((H, W, 3), 100, dtype=np.uint8)
    res_valid = FrameResult(None, poly, mask, widths, [], None, track_valid=True, rail_convergence=0.2)
    draw(valid_img, res_valid, calibrated=True)
    # Centre pixel is tinted green when valid.
    assert valid_img[200, 200, 1] > valid_img[200, 200, 0]

    invalid_img = np.full((H, W, 3), 100, dtype=np.uint8)
    res_invalid = FrameResult(None, poly, mask, widths, [], None, track_valid=False, rail_convergence=0.9)
    draw(invalid_img, res_invalid, calibrated=True)
    # Centre pixel inside invalid corridor is completely untouched (not covered).
    assert tuple(invalid_img[200, 200]) == (100, 100, 100)
    # Outline pixel on boundary is drawn in CORRIDOR_BAD red (anti-aliased).
    assert invalid_img[100, 200, 2] > 180 and invalid_img[100, 200, 0] < 30
