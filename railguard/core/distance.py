"""Gauge-referenced distance estimation."""

import math

import numpy as np

from .geometry import GAUGE_M


def depth_to_ground(depth_m, pitch_deg, cam_height_m):
    """Line-of-sight depth -> ground distance along the track.

    The gauge formula gives the depth Z of the rails along the camera's optical
    axis. With the camera mounted cam_height_m above the rail tops and pitched
    pitch_deg (negative = pointing down), a rail point at ground distance Y
    has Z = Y*cos(a) + h*sin(a), with a = -pitch the downward tilt, so

        Y = (Z - h*sin(a)) / cos(a)

    Identity at pitch 0. The correction is largest close up: at 6 deg down it
    is -3.2% at 5 m, -1.4% at 10 m and -0.2% at 100 m.
    """
    if not pitch_deg:
        return depth_m
    a = math.radians(-pitch_deg)
    return (depth_m - cam_height_m * math.sin(a)) / math.cos(a)


def estimate_distance_m(row_y, width_by_row, fx, pitch_deg=0.0, cam_height_m=0.0):
    """Ground distance along the track to an object standing at image row row_y.

    The rails are GAUGE_M apart, so their pixel spacing at that row gives the
    line-of-sight depth fx * GAUGE_M / spacing; depth_to_ground() turns that
    into distance along the track for a pitched camera (no change at pitch 0).
    fx is the focal length in pixels: a calibrated value when one exists,
    otherwise geometry.focal_from_fov(). Returns None where the rail spacing
    is unknown.
    """
    y = int(np.clip(row_y, 0, len(width_by_row) - 1))
    wpx = width_by_row[y]
    if wpx <= 1:
        return None
    return depth_to_ground((fx * GAUGE_M) / wpx, pitch_deg, cam_height_m)
