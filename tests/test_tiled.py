"""Tiled inference: tile geometry, coordinate mapping, and duplicate merging.

These are the failure modes that would be invisible in a recall number: a box
found in a tile but reported at the tile's coordinates instead of the frame's
would still be a detection, just in the wrong place, and the corridor gate
would then accept or reject it for the wrong reason.
"""

import numpy as np
import pytest

from railguard.config import PipelineConfig
from railguard.detection.tiled import detect, tile_rects

W = H = 400


class Box:
    def __init__(self, xyxy, cls=0, conf=0.9):
        self.xyxy, self.cls, self.conf = [xyxy], [cls], [conf]


class CropBlindYolo:
    """Returns the same box for every crop: models an object seen in each tile."""

    names = {0: "person"}

    def __init__(self, xyxy):
        self.xyxy = xyxy
        self.calls = 0

    def predict(self, img, *_a, **_k):
        self.calls += 1
        return [type("R", (), {"boxes": [Box(list(self.xyxy))]})()]


class EmptyYolo:
    names = {0: "person"}

    def __init__(self):
        self.calls = 0

    def predict(self, img, *_a, **_k):
        self.calls += 1
        return [type("R", (), {"boxes": []})()]


def cfg(**kw):
    return PipelineConfig(device="cpu", fx=350.0, **kw)


def frame():
    return np.zeros((H, W, 3), np.uint8)


# ---- tile geometry ----

def test_tiles_cover_the_whole_frame():
    rects = tile_rects(W, H, 2, 2, 0.2)
    covered = np.zeros((H, W), bool)
    for x0, y0, x1, y1 in rects:
        covered[y0:y1, x0:x1] = True
    assert covered.all(), "a pixel in no tile is a pixel the detector never sees"


def test_tiles_overlap_so_objects_on_a_seam_are_whole_somewhere():
    plain = tile_rects(W, H, 2, 2, 0.0)
    grown = tile_rects(W, H, 2, 2, 0.2)
    assert all((g[2] - g[0]) > (p[2] - p[0]) for p, g in zip(plain, grown))


def test_tile_count_matches_the_grid():
    assert len(tile_rects(W, H, 2, 2, 0.2)) == 4
    assert len(tile_rects(W, H, 3, 3, 0.2)) == 9


# ---- passes ----

def test_tiled_runs_the_full_frame_plus_every_tile():
    m = EmptyYolo()
    detect(m, frame(), cfg(tiled=True, tile_cols=2, tile_rows=2), [0])
    assert m.calls == 5, "full frame plus 4 tiles"


def test_untiled_runs_once():
    m = EmptyYolo()
    detect(m, frame(), cfg(tiled=False), [0])
    assert m.calls == 1


# ---- coordinates and merging ----

def test_duplicates_across_tiles_are_merged():
    """The same object seen in the full frame and in several tiles is one object."""
    m = CropBlindYolo([190, 330, 210, 390])
    out = detect(m, frame(), cfg(tiled=True), [0])
    assert m.calls == 5
    assert len(out) < 5, "unmerged tiles would report the same person once per pass"


def test_box_from_a_tile_is_reported_in_frame_coordinates():
    """A box at a tile's own origin must come back at the tile's position."""
    m = CropBlindYolo([0, 0, 10, 10])
    out = detect(m, frame(), cfg(tiled=True, tile_overlap=0.0), [0])
    corners = {(round(x1), round(y1)) for x1, y1, _, _, _, _ in out}
    assert (0, 0) in corners                      # the full-frame pass
    assert any(c != (0, 0) for c in corners), \
        "every box at (0,0) means tile offsets were not added"
    assert (200, 200) in corners, "the bottom-right tile starts at (200, 200)"


def test_class_and_confidence_survive():
    m = CropBlindYolo([190, 330, 210, 390])
    out = detect(m, frame(), cfg(tiled=True), [0])
    assert all(c == 0 for *_, c, _ in out)
    assert all(conf == pytest.approx(0.9) for *_, conf in out)


def test_untiled_returns_the_box_unshifted():
    m = CropBlindYolo([190, 330, 210, 390])
    out = detect(m, frame(), cfg(tiled=False), [0])
    assert len(out) == 1
    x1, y1, x2, y2, _, _ = out[0]
    assert (x1, y1, x2, y2) == (190.0, 330.0, 210.0, 390.0)
