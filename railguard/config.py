"""Pipeline configuration: every tunable in one place."""

import os
from dataclasses import dataclass, field
from typing import Optional

import numpy as np

from .core.alerts import braking_distance_m
from .core.geometry import GAUGE_M, focal_from_fov
from .detection.classes import ALLOWED_NAMES

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Camera pitch that gave TEP-Net the longest accurate range in the Blender
# pitch sweep (simulation/validate_tepnet.py --sweep). Negative = pointing down.
# Used by PipelineConfig.for_mounting(); the plain default stays at 0 because
# recorded footage was filmed at an unknown angle.
RECOMMENDED_MOUNTING = {
    "wide": {"pitch_deg": -3.0, "sim_valid_range_m": (5, 73)},    # 5 mm; worst over-read +7.2%, covered by distance_margin
    "tele": {"pitch_deg": -1.0, "sim_valid_range_m": (35, 610)},  # 50 mm; straight or gently curved track only
}


@dataclass
class PipelineConfig:
    # ---- Models ----
    # Stock COCO YOLOv8s. On human-labelled wildlife elephants it reaches 77% recall
    # at conf 0.25 vs 3% for the fine-tuned railguard_best.pt (Task 02). All seven
    # hazard classes are COCO classes; class_ids() filters them by name.
    yolo_weights: str = os.path.join(REPO_ROOT, "models", "yolov8s.pt")
    tepnet_model: str = "chromatic-laughter-5"   # weights folder name in the TEP-Net repo
    device: str = "cuda"
    tepnet_device: Optional[str] = None          # None = same as device

    # ---- Detection ----
    class_names: frozenset = frozenset(ALLOWED_NAMES)
    conf_threshold: float = 0.25
    imgsz: int = 1280
    max_det: int = 300

    # ---- Corridor ----
    envelope_factor: float = 1.9    # rolling-stock width / gauge: 3.2 m Sri Lankan stock / 1.676 m
    safety_margin_m: float = 0.5    # clearance added each side of the train envelope
    segment_every: int = 1       # run TEP-Net on every Nth frame, reuse the corridor in between

    # ---- Ranging ----
    calib_file: Optional[str] = None   # .npz from camera/calibration/calibrate.py
    calib_fx: Optional[float] = None   # fx measured at calib_width, set by from_calibration()
    calib_width: Optional[int] = None  # image width the calibration was done at
    fx: Optional[float] = None         # manual focal length in px, used when there is no calibration
    assumed_hfov_deg: float = 60.0     # last resort: fx derived from an assumed field of view
    camera_pitch_deg: float = 0.0      # camera tilt, negative = pointing down; 0 = no correction
    camera_height_m: float = 1.805     # camera height above the rail tops (pitch correction only)

    # ---- Alerts ----
    persist_frames: int = 3   # an on-track object must be seen in this many processed frames to alert
    track_max_age: int = 5    # frames an on-track object may go unseen before its track is dropped
    speed_kmh: float = 60.0                    # line speed; fixed until a live speed input exists
    brake_distance_m: Optional[float] = None   # None = braking distance for speed_kmh
    # Safety margin on distance before the braking comparison: an object is treated
    # as (1 - margin) x its measured distance, so a detector that over-reads by up to
    # the margin still alerts in time. Displayed distances are not changed.
    distance_margin: float = 0.10

    _warned_uncalibrated: bool = field(default=False, init=False, repr=False, compare=False)

    @classmethod
    def for_mounting(cls, lens, **kwargs):
        """Config for a recommended camera mounting: RECOMMENDED_MOUNTING[lens]
        sets the pitch (see the README, "Camera mounting")."""
        return cls(camera_pitch_deg=RECOMMENDED_MOUNTING[lens]["pitch_deg"], **kwargs)

    @classmethod
    def from_calibration(cls, path, **kwargs):
        """Config whose focal length comes from a calibrate.py .npz file."""
        with np.load(path) as calib:
            fx = float(calib["fx"])
            width = int(calib["image_size"][0])
        return cls(calib_file=path, calib_fx=fx, calib_width=width, **kwargs)

    def focal_px(self, frame_width):
        """Focal length in pixels for frames frame_width wide.

        In order of preference: the calibrated fx rescaled to this width, then
        a manually set fx, then one derived from the assumed field of view.
        The rescale assumes the frame is the calibration image resized, not
        cropped: same camera, same aspect ratio.
        """
        if self.calib_fx is not None:
            return self.calib_fx * (frame_width / self.calib_width)
        if self.fx is not None:
            return self.fx
        if not self._warned_uncalibrated:
            print(f"WARNING: camera not calibrated. Focal length assumes a "
                  f"{self.assumed_hfov_deg:g} deg field of view, so every distance "
                  f"is an uncalibrated estimate.")
            self._warned_uncalibrated = True
        return focal_from_fov(frame_width, self.assumed_hfov_deg)

    def corridor_half_width_m(self):
        """Corridor half-width either side of the track centre: half the train
        envelope plus the safety margin (0.838 x 1.9 + 0.5 = 2.09 m by default)."""
        return GAUGE_M / 2.0 * self.envelope_factor + self.safety_margin_m

    def braking_distance(self):
        """Distance inside which an on-track threat is BRAKE NOW."""
        if self.brake_distance_m is not None:
            return self.brake_distance_m
        return braking_distance_m(self.speed_kmh)
