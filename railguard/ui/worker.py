"""Background worker thread running camera capture and RailGuardPipeline.
process_frame() takes ~150 ms. Running it on a background QThread keeps the UI
responsive. If the UI is still painting the previous frame when a new one
finishes, the frame is dropped rather than queued.
"""
from dataclasses import dataclass
import os
import threading
import time
from typing import Optional
import cv2
from PyQt5.QtCore import QThread, pyqtSignal
from railguard.camera.capture import fourcc_str, open_camera
from railguard.config import REPO_ROOT, PipelineConfig
from railguard.core.alerts import BRAKE_NOW
import railguard.pipeline as pipeline_mod
from railguard.pipeline import RailGuardPipeline
from railguard.ui.overlay import draw, draw_stale
ALERT_WAV = os.path.join(REPO_ROOT, "demos", "assets", "alert.wav")
BEEP_COOLDOWN_S = 1.0
CAMERA_LOST_S = 2.0
RETRY_INTERVAL_S = 1.0
try:
    import winsound
    def beep():
        fn = winsound.PlaySound if os.path.isfile(ALERT_WAV) else winsound.MessageBeep
        args = (ALERT_WAV, winsound.SND_FILENAME) if os.path.isfile(ALERT_WAV) else ()
        threading.Thread(target=fn, args=args, daemon=True).start()
except ImportError:
    def beep():
        print("\a", end="", flush=True)

@dataclass
class RunSettings:
    camera_index: int = 1
    width: int = 1920
    height: int = 1080
    calib_file: Optional[str] = None
    unit_id: str = "unit-01"
    publish: bool = False
    speed_kmh: float = 60.0
    segment_every: int = 1
    firebase_key: Optional[str] = None

def probe_cameras(indices=(0, 1, 2, 3), width=1920, height=1080):
    """Probe camera indices 0-3 and return [(index, width, height, fourcc)]."""
    found = []
    for idx in indices:
        cap = None
        try:
            cap = cv2.VideoCapture(idx, cv2.CAP_DSHOW)
            if not cap.isOpened():
                continue
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
            aw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)) or width
            ah = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)) or height
            fcc = fourcc_str(cap.get(cv2.CAP_PROP_FOURCC)).strip() or "RAW"
            found.append((idx, aw, ah, fcc))
        except Exception:
            pass
        finally:
            if cap is not None:
                cap.release()
    return found

class PipelineWorker(QThread):
    stage_changed = pyqtSignal(str)
    frame_ready = pyqtSignal(object, object, float)   # (annotated_frame, FrameResult, fps)
    stale_frame = pyqtSignal(object, float)           # (stale_frame, age_s)
    camera_state = pyqtSignal(bool, int, int, float)  # (connected, width, height, fx)
    publish_state = pyqtSignal(str)
    log_event = pyqtSignal(str)
    fatal_error = pyqtSignal(str)
    def __init__(self, settings: RunSettings, parent=None):
        super().__init__(parent)
        self.settings = settings
        self._running = True
        self._ui_busy = False
        self._prev_alert = None
        self._prev_track_valid = True
    def stop(self):
        self._running = False
    def mark_painted(self):
        self._ui_busy = False
    def _load_pipeline(self, config: PipelineConfig) -> RailGuardPipeline:
        self.stage_changed.emit("Loading detector…")
        real_load_tepnet = pipeline_mod.load_tepnet
        def _staged_load_tepnet(*args, **kwargs):
            self.stage_changed.emit("Loading track model…")
            return real_load_tepnet(*args, **kwargs)
        pipeline_mod.load_tepnet = _staged_load_tepnet
        try:
            return RailGuardPipeline(config)
        finally:
            pipeline_mod.load_tepnet = real_load_tepnet
    def _setup_publisher(self):
        s = self.settings
        if not s.publish:
            self.publish_state.emit("off")
            return None
        try:
            from railguard.alerts.publisher import HazardPublisher
            pub = HazardPublisher(s.unit_id, key_path=s.firebase_key)
            pub._log = lambda msg: self.log_event.emit(f"publish ({s.unit_id}) — {msg}")
            self.publish_state.emit(f"{s.unit_id} connected")
            self.log_event.emit(f"publishing enabled — {s.unit_id} connected")
            return pub
        except Exception as e:
            self.publish_state.emit(f"{s.unit_id} error")
            self.log_event.emit(f"publishing failed to start — {e}")
            return None
    def _try_open_camera(self):
        s = self.settings
        try:
            return open_camera(s.camera_index, s.width, s.height, require_mjpg=True)
        except RuntimeError as e:
            if "not MJPG" in str(e):
                cap = open_camera(s.camera_index, s.width, s.height, require_mjpg=False)
                self.log_event.emit(f"camera {s.camera_index} opened without MJPG (low frame rate)")
                return cap
            raise
    def _log_transitions(self, res, persist_frames: int):
        for d in res.detections:
            if d.on_track and d.confirmed and d.track_hits == persist_frames:
                dist = "? m" if d.distance_m is None else f"{d.distance_m:.0f} m"
                self.log_event.emit(f"{d.cls_name} confirmed on track, {dist}")
        if res.alert != self._prev_alert:
            if res.alert is None:
                self.log_event.emit("alert cleared")
            else:
                w = res.worst_threat
                if w is not None:
                    dist = "? m (fail-safe: distance unknown)" if w.distance_m is None else f"{w.distance_m:.0f} m"
                    self.log_event.emit(f"{res.alert} — {w.cls_name}, {dist}")
                else:
                    self.log_event.emit(res.alert)
            self._prev_alert = res.alert
        if res.track_valid != self._prev_track_valid:
            if not res.track_valid:
                why = "no track found" if res.rail_convergence is None else f"rails do not converge ({res.rail_convergence:.2f})"
                self.log_event.emit(f"track not detected — {why}")
            else:
                self.log_event.emit("track detected")
            self._prev_track_valid = res.track_valid
    def run(self):
        s = self.settings
        calibrated = bool(s.calib_file)
        try:
            opts = dict(segment_every=s.segment_every, speed_kmh=s.speed_kmh)
            config = PipelineConfig.from_calibration(s.calib_file, **opts) if calibrated else PipelineConfig(**opts)
            pipeline = self._load_pipeline(config)
        except Exception as e:
            self.fatal_error.emit(f"Model load failed: {e}")
            return
        if not self._running:
            return
        publisher = self._setup_publisher()
        self.stage_changed.emit("Opening camera…")
        cap, w, h = None, s.width, s.height
        fx = config.focal_px(w)
        try:
            cap = self._try_open_camera()
            w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)) or s.width
            h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)) or s.height
            fx = config.focal_px(w)
            self.camera_state.emit(True, w, h, fx)
            self.stage_changed.emit("Ready")
            fx_note = f"fx {fx:.0f}" if calibrated else f"fx {fx:.0f} (ASSUMED focal length)"
            self.log_event.emit(f"ready — camera {s.camera_index}, {w}x{h}, {fx_note}")
        except Exception as e:
            self.camera_state.emit(False, w, h, fx)
            self.stage_changed.emit("Camera lost — reconnecting")
            self.log_event.emit(f"camera error — {e}; retrying every second")
        last_ok = time.monotonic() if cap is not None else (time.monotonic() - CAMERA_LOST_S - 1.0)
        last_retry, last_beep, fps, t_prev = time.monotonic(), 0.0, 0.0, time.monotonic()
        last_clean_frame, camera_lost = None, (cap is None)
        try:
            while self._running:
                ok, frame = (cap.read() if cap is not None else (False, None))
                now = time.monotonic()
                if ok and frame is not None:
                    if camera_lost:
                        camera_lost = False
                        w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)) or w
                        h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)) or h
                        fx = config.focal_px(w)
                        self.camera_state.emit(True, w, h, fx)
                        self.stage_changed.emit("Ready")
                        self.log_event.emit(f"camera recovered — camera {s.camera_index}, {w}x{h}")
                    last_ok = now
                    res = pipeline.process_frame(frame)
                    if publisher is not None:
                        publisher.on_frame(res)
                    self._log_transitions(res, config.persist_frames)
                    cooldown = BEEP_COOLDOWN_S if res.alert == BRAKE_NOW else BEEP_COOLDOWN_S * 2
                    if res.alert is not None and (now - last_beep) > cooldown:
                        beep()
                        last_beep = now
                    draw(frame, res, calibrated=calibrated, persist=config.persist_frames)
                    last_clean_frame = frame.copy()
                    inst_fps = 1.0 / max(now - t_prev, 1e-6)
                    fps = inst_fps if fps == 0.0 else (0.9 * fps + 0.1 * inst_fps)
                    t_prev = now
                    if not self._ui_busy:
                        self._ui_busy = True
                        self.frame_ready.emit(frame, res, fps)
                else:
                    silence = now - last_ok
                    if silence >= CAMERA_LOST_S:
                        if not camera_lost:
                            camera_lost = True
                            self.camera_state.emit(False, w, h, fx)
                            self.log_event.emit("camera lost — reconnecting")
                        if last_clean_frame is not None and not self._ui_busy:
                            stale = last_clean_frame.copy()
                            draw_stale(stale, silence)
                            self.stale_frame.emit(stale, silence)
                        if (now - last_retry) >= RETRY_INTERVAL_S:
                            last_retry = now
                            if cap is not None:
                                cap.release()
                                cap = None
                            try:
                                cap = self._try_open_camera()
                            except Exception:
                                cap = None
                    time.sleep(0.05)
        finally:
            if cap is not None:
                cap.release()
            if publisher is not None:
                publisher.close()
