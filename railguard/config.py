"""Pipeline configuration: every tunable in one place."""

import os
from dataclasses import dataclass
from typing import Optional

from .core.alerts import braking_distance_m
from .core.geometry import focal_from_fov
from .detection.classes import ALLOWED_NAMES

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@dataclass
class PipelineConfig:
    # ---- Models ----
    yolo_weights: str = os.path.join(REPO_ROOT, "models", "railguard_best.pt")
    tepnet_model: str = "chromatic-laughter-5"   # weights folder name in the TEP-Net repo
    device: str = "cuda"
    tepnet_device: Optional[str] = None          # None = same as device

    # ---- Detection ----
    class_names: frozenset = frozenset(ALLOWED_NAMES)
    conf_threshold: float = 0.25
    imgsz: int = 1280
    max_det: int = 300

    # ---- Corridor ----
    expand_factor: float = 3.0   # corridor half-width, in half rail spacings
    segment_every: int = 1       # run TEP-Net on every Nth frame, reuse the corridor in between

    # ---- Ranging ----
    fx: Optional[float] = None       # calibrated focal length in px; None = derive from assumed_hfov_deg
    assumed_hfov_deg: float = 60.0   # used only while fx is None

    # ---- Alerts ----
    speed_kmh: float = 60.0                    # line speed; fixed until a live speed input exists
    brake_distance_m: Optional[float] = None   # None = braking distance for speed_kmh

    def focal_px(self, frame_width):
        """Focal length in pixels: calibrated fx when set, else from the assumed FOV."""
        return self.fx if self.fx is not None else focal_from_fov(frame_width, self.assumed_hfov_deg)

    def braking_distance(self):
        """Distance inside which an on-track threat is BRAKE NOW."""
        if self.brake_distance_m is not None:
            return self.brake_distance_m
        return braking_distance_m(self.speed_kmh)
