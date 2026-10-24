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
    track_hits: int = 0           # frames this on-track object's track has been seen in (0 off-track)
    confirmed: bool = False       # track_hits >= PipelineConfig.persist_frames


@dataclass(eq=False)
class FrameResult:
    """Everything RailGuardPipeline.process_frame() found in one frame."""
    egopath: Optional[tuple]                # TEP-Net (left_rail, right_rail) points; None = no track found
    corridor_polygon: Optional[np.ndarray]  # (N, 2) int32 corridor outline; None = no track found
    corridor: np.ndarray                    # uint8 mask, 255 inside the corridor
    width_by_row: np.ndarray                # rail spacing in px at each image row (0 = unknown)
    detections: list                        # every Detection, on-track or not
    alert: Optional[str]                    # None, alerts.CAUTION or alerts.BRAKE_NOW (confirmed threats only)

    @property
    def threats(self):
        """Detections standing on the track, confirmed or not."""
        return [d for d in self.detections if d.on_track]

    @property
    def confirmed_threats(self):
        """On-track detections that persisted long enough to raise an alert."""
        return [d for d in self.detections if d.confirmed]

    @property
    def worst_threat(self):
        """The confirmed threat that drives the alert: one at unknown distance
        first (fail-safe), otherwise the closest. None when nothing is confirmed."""
        threats = self.confirmed_threats
        if not threats:
            return None
        return min(threats, key=lambda d: -1.0 if d.distance_m is None else d.distance_m)
