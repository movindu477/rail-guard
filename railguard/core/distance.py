"""Gauge-referenced distance estimation."""

import numpy as np

from .geometry import GAUGE_M


def estimate_distance_m(row_y, width_by_row, fx):
    """Distance from the camera to an object standing at image row row_y.

    The rails are GAUGE_M apart, so their pixel spacing at that row gives range.
    fx is the focal length in pixels: a calibrated value when one exists,
    otherwise geometry.focal_from_fov(). Returns None where the rail spacing
    is unknown.
    """
    y = int(np.clip(row_y, 0, len(width_by_row) - 1))
    wpx = width_by_row[y]
    if wpx <= 1:
        return None
    return (fx * GAUGE_M) / wpx
