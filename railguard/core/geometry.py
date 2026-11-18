"""Shared track geometry: rail gauge, focal length, per-row rail spacing."""

import math
import numpy as np

GAUGE_M = 1.676          # Sri Lanka broad gauge (metres)
MIN_RAIL_WIDTH_PX = 4.0  # floor on rail spacing so far rows never collapse to zero


def focal_from_fov(frame_width, hfov_deg=60.0):
    """Focal length in pixels from an ASSUMED horizontal field of view.

    A stand-in until the camera is calibrated: once a calibrated fx exists,
    pass that to distance.estimate_distance_m instead of calling this.
    """
    return (frame_width / 2.0) / math.tan(math.radians(hfov_deg / 2.0))


def rail_points(egopath):
    """TEP-Net ego-path -> [(y, centre_x, rail_width_px)], one per rail point pair.

    Returns [] when there is no usable path (None, or fewer than 2 pairs).
    Raises TypeError when egopath is not a (left_rail, right_rail) pair, e.g.
    the output of a TEP-Net model that is not a 'regression' one.
    """
    if egopath is None:
        return []
    try:
        left, right = egopath
    except (TypeError, ValueError):
        raise TypeError(
            "egopath must be a (left_rail, right_rail) pair of point lists, "
            f"got {type(egopath).__name__}") from None
    pts = []
    for (lx, ly), (rx, ry) in zip(left, right):
        lx, ly, rx, ry = float(lx), float(ly), float(rx), float(ry)
        pts.append(((ly + ry) / 2.0, (lx + rx) / 2.0,
                    max(abs(rx - lx), MIN_RAIL_WIDTH_PX)))
    return pts if len(pts) >= 2 else []


def _track_by_row(egopath, h):
    """Per-row (centre_x, rail_width_px); both 0 on rows where the track is unseen."""
    centre = np.zeros(h, dtype=np.float32)
    width = np.zeros(h, dtype=np.float32)
    for y, cx, w in rail_points(egopath):
        yi = int(np.clip(y, 0, h - 1))
        if w >= width[yi]:
            width[yi] = w
            centre[yi] = cx
    # fill gaps by interpolation between known rows
    known = np.where(width > 0)[0]
    if len(known) >= 2:
        all_rows = np.arange(h)
        centre = np.interp(all_rows, known, centre[known], left=0, right=0).astype(np.float32)
        width = np.interp(all_rows, known, width[known], left=0, right=0).astype(np.float32)
    return centre, width


MAX_RAIL_CONVERGENCE = 0.5   # far / near rail spacing must be below this for a real track


def rail_convergence(width_by_row):
    """Far rail spacing / near rail spacing (top-most over bottom-most known row),
    or None when there is no track.

    Perspective makes real rails get closer with distance, so a real track gives
    a value well below 1 (0.02-0.4 on the cab-ride footage). TEP-Net always
    returns two rails, even when it cannot see the track; a path whose rails stay
    apart or spread out (>= MAX_RAIL_CONVERGENCE) cannot be the track.
    """
    rows = np.flatnonzero(width_by_row > 0)
    if rows.size < 2:
        return None
    near = float(width_by_row[rows[-1]])
    return float(width_by_row[rows[0]]) / near if near > 0 else None


def track_plausible(width_by_row, max_convergence=MAX_RAIL_CONVERGENCE):
    """True if the ego-path is a perspective-correct track. Necessary, not
    sufficient: it rejects impossible shapes but cannot prove the rails are real."""
    c = rail_convergence(width_by_row)
    return c is not None and c < max_convergence


def rail_width_by_row(egopath, h):
    """Pixel distance between the rails at every image row (0 where unknown)."""
    return _track_by_row(egopath, h)[1]


def track_centre_by_row(egopath, h):
    """Track centre-line x at every image row; only valid where rail width > 0."""
    return _track_by_row(egopath, h)[0]
