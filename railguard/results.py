"""What the pipeline returns for one frame."""

from dataclasses import dataclass
from typing import Optional

import numpy as np


@dataclass(frozen=True)
class Detection:
    """One detected hazard-class object."""
    x1: int
    y1: int
    x2: int
    y2: int
    cls_name: str
    conf: float
    on_track: bool                # foot point lies inside the corridor
    distance_m: Optional[float]   # None when off-track, or on-track but not rangeable


@dataclass(eq=False)
class FrameResult:
    """Everything RailGuardPipeline.process_frame() found in one frame."""
    egopath: Optional[tuple]                # TEP-Net (left_rail, right_rail) points; None = no track found
    corridor_polygon: Optional[np.ndarray]  # (N, 2) int32 corridor outline; None = no track found
    corridor: np.ndarray                    # uint8 mask, 255 inside the corridor
    width_by_row: np.ndarray                # rail spacing in px at each image row (0 = unknown)
    detections: list                        # every Detection, on-track or not
    alert: Optional[str]                    # None, alerts.CAUTION or alerts.BRAKE_NOW

    @property
    def threats(self):
        """Detections standing on the track."""
        return [d for d in self.detections if d.on_track]

    @property
    def worst_threat(self):
        """The threat that drives the alert: one at unknown distance first
        (fail-safe), otherwise the closest. None when the track is clear."""
        threats = self.threats
        if not threats:
            return None
        return min(threats, key=lambda d: -1.0 if d.distance_m is None else d.distance_m)
