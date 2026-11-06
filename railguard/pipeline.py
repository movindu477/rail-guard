"""RailGuard per-frame pipeline: ego-path -> corridor -> detection -> ranging -> alert.

Returns data only. Drawing, display and file writing belong to the callers
(demos/, experiments/), so the same pipeline runs with or without a screen.
"""

import cv2
from PIL import Image

from .config import PipelineConfig
from .core.alerts import alert_level
from .core.corridor import corridor_polygon, foot_point, in_corridor, polygon_mask
from .core.distance import estimate_distance_m
from .core.tracking import PersistenceTracker
from .core.geometry import rail_width_by_row
from .detection.classes import class_ids
from .detection.model import load_yolo
from .results import Detection, FrameResult
from .segmentation.tepnet import load_tepnet


class RailGuardPipeline:
    def __init__(self, config: PipelineConfig):
        self.config = config
        self.model = load_yolo(config.yolo_weights)
        self.keep_ids = class_ids(self.model, config.class_names)
        self.tepnet = load_tepnet(config.tepnet_model, config.tepnet_device or config.device)
        self._frame_idx = 0
        self._last_egopath = None
        self._track = None   # (polygon, corridor mask, width_by_row) for _last_egopath
        self._persistence = PersistenceTracker(max_age=config.track_max_age)

    def _update_track(self, frame):
        """Run TEP-Net and rebuild the corridor from its ego-path."""
        h, w = frame.shape[:2]
        rgb = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        egopath = self.tepnet.detect(rgb)
        polygon = corridor_polygon(egopath, frame.shape, self.config.corridor_half_width_m())
        self._last_egopath = egopath
        self._track = (polygon, polygon_mask(polygon, frame.shape), rail_width_by_row(egopath, h))

    def process_frame(self, frame) -> FrameResult:
        cfg = self.config
        h, w = frame.shape[:2]

        # 1-3. Ego-path, rail spacing per row, corridor. TEP-Net runs on every
        # segment_every-th frame; the frames in between reuse its corridor.
        if self._track is None or self._frame_idx % cfg.segment_every == 0:
            self._update_track(frame)
        polygon, corridor, width_by_row = self._track

        # 4. Detection, hazard classes only.
        result = self.model.predict(frame, conf=cfg.conf_threshold, imgsz=cfg.imgsz,
                                    max_det=cfg.max_det, classes=self.keep_ids,
                                    device=cfg.device, verbose=False)[0]

        # 5. Corridor gate first, then range only what is on the track.
        fx = cfg.focal_px(w)
        found = []
        for box in result.boxes:
            x1, y1, x2, y2 = map(int, box.xyxy[0])
            gx, gy = foot_point(x1, y1, x2, y2)
            on_track = in_corridor(corridor, gx, gy)
            # ground distance along the track (pitch-corrected), which is what braking distance is measured in
            distance = (estimate_distance_m(gy, width_by_row, fx, cfg.camera_pitch_deg, cfg.camera_height_m)
                        if on_track else None)
            found.append(((x1, y1, x2, y2), self.model.names[int(box.cls[0])],
                          float(box.conf[0]), on_track, distance))

        # 6. Persistence: count the frames each on-track object has been seen in.
        on_boxes = [b for b, _, _, on, _ in found if on]
        counts = iter(self._persistence.update(on_boxes))
        detections = []
        for (x1, y1, x2, y2), name, conf, on_track, distance in found:
            n = next(counts) if on_track else 0
            detections.append(Detection(x1, y1, x2, y2, cls_name=name, conf=conf,
                                        on_track=on_track, distance_m=distance,
                                        track_hits=n, confirmed=n >= cfg.persist_frames))

        # 7. Alert from confirmed on-track objects only, each treated as
        # distance_margin closer than measured. Fail-safe kept: a confirmed
        # threat at unknown distance is still BRAKE NOW.
        keep = 1.0 - cfg.distance_margin
        alert = alert_level([None if d.distance_m is None else d.distance_m * keep
                             for d in detections if d.confirmed],
                            cfg.braking_distance())

        self._frame_idx += 1
        return FrameResult(
            egopath=self._last_egopath,
            corridor_polygon=polygon,
            corridor=corridor,
            width_by_row=width_by_row,
            detections=detections,
            alert=alert)
