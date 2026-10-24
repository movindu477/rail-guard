"""Safety corridor around the ego-track, and the on-track test."""

import cv2
import numpy as np

from .geometry import GAUGE_M, rail_points


def corridor_polygon(egopath, shape, half_width_m):
    """Corridor outline: half_width_m either side of the track centre-line,
    as an (N, 2) int32 array of x, y. None with no usable path.

    The rails are GAUGE_M apart, so at each row the rail spacing in pixels
    gives the pixels-per-metre scale there.
    """
    h, w = shape[:2]
    pts = rail_points(egopath)
    if not pts:
        return None
    exp_left, exp_right = [], []
    for y, cx, width in pts:
        e = half_width_m * width / GAUGE_M
        exp_left.append((int(cx - e), int(y)))
        exp_right.append((int(cx + e), int(y)))
    polygon = np.array(exp_left + exp_right[::-1], dtype=np.int32)
    polygon[:, 0] = np.clip(polygon[:, 0], 0, w - 1)
    polygon[:, 1] = np.clip(polygon[:, 1], 0, h - 1)
    return polygon


def polygon_mask(polygon, shape):
    """Filled uint8 mask (255 inside) for a corridor polygon; zeros for None."""
    mask = np.zeros(shape[:2], dtype=np.uint8)
    if polygon is not None:
        cv2.fillPoly(mask, [polygon], 255)
    return mask


def build_corridor(egopath, shape, half_width_m):
    """Perspective-aware corridor mask. All zeros when there is no usable path."""
    return polygon_mask(corridor_polygon(egopath, shape, half_width_m), shape)


def foot_point(x1, y1, x2, y2):
    """Where a detection touches the ground: bottom-centre of its box."""
    return (x1 + x2) // 2, y2


def in_corridor(corridor, x, y):
    """True when image point (x, y) lies inside the corridor mask."""
    h, w = corridor.shape[:2]
    gx = int(np.clip(x, 0, w - 1))
    gy = int(np.clip(y, 0, h - 1))
    return bool(corridor[gy, gx] > 0)
