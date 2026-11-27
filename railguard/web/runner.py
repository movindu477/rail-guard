"""Camera + pipeline on a background thread, with no UI toolkit attached.

railguard/ui/worker.py does the same job for the PyQt application, but it is a
QThread and carries Qt signals. The web backend needs the same loop without
Qt, so this is a plain threading version. Both draw with railguard.ui.overlay,
so what the browser shows and what the desktop window shows cannot drift.

Only the newest frame is kept. A browser that falls behind gets the current
frame, never a backlog: on a safety display a late frame is worse than a
missing one, because the driver cannot tell it is late.
"""

import threading
import time

import cv2

from railguard.camera.capture import open_camera
from railguard.config import PipelineConfig
from railguard.pipeline import RailGuardPipeline
from railguard.ui.overlay import draw

CAMERA_LOST_AFTER_S = 2.0
RECONNECT_EVERY_S = 1.0


class Runner:
    """Owns the camera and the pipeline. Start it, read .snapshot()."""

    def __init__(self):
        self._lock = threading.Lock()
        self.camera_lock = threading.Lock()   # serialize DirectShow open/probe calls
        self._thread = None
        self._stop = threading.Event()
        self.state = "idle"        # idle | loading | running | camera_lost | error
        self.message = ""
        self.settings = {}
        self._jpeg = None          # latest annotated frame, encoded
        self._result = None        # latest FrameResult as plain data
        self._fps = 0.0
        self._started_at = None
        self._last_frame_at = None
        self._events = []          # (timestamp, text), newest last
        self._publisher = None

    # ---------------------------------------------------------------- events

    def _log(self, text):
        stamp = time.strftime("%H:%M:%S")
        with self._lock:
            self._events.append((stamp, text))
            del self._events[:-200]

    def events_since(self, n):
        with self._lock:
            return [{"time": t, "text": x} for t, x in self._events[n:]], len(self._events)

    # ----------------------------------------------------------------- start

    def start(self, camera=1, width=1920, height=1080, calib=None,
              unit_id="unit-01", publish=False, speed_kmh=60.0):
        if self._thread and self._thread.is_alive():
            return False, "already running"
        self._stop.clear()
        with self._lock:
            self._jpeg = None
            self._result = None
        self._fps = 0.0
        self._started_at = None
        self._last_frame_at = None
        self.settings = dict(camera=camera, width=width, height=height, calib=calib,
                             unit_id=unit_id, publish=publish, speed_kmh=speed_kmh)
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        return True, "starting"

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)
        self.state = "idle"
        self._log("stopped")

    # ------------------------------------------------------------------ loop

    def _open_camera(self, index, width, height, retries=3):
        """Open the camera under camera_lock with brief retry for DirectShow release lag."""
        last_err = None
        for attempt in range(retries):
            with self.camera_lock:
                try:
                    return open_camera(index, width, height)
                except RuntimeError as e:
                    last_err = e
            if attempt + 1 < retries:
                time.sleep(0.5)
        raise last_err

    def _run(self):
        s = self.settings
        try:
            self.state, self.message = "loading", "loading models"
            cfg = (PipelineConfig.from_calibration(s["calib"], speed_kmh=s["speed_kmh"])
                   if s["calib"] else PipelineConfig(speed_kmh=s["speed_kmh"]))
            pipeline = RailGuardPipeline(cfg)
            self._log("models loaded")

            if s["publish"]:
                from railguard.alerts.publisher import HazardPublisher
                self._publisher = HazardPublisher(s["unit_id"])
                self._log(f"publishing as {s['unit_id']}")

            self.message = "opening camera"
            cap = self._open_camera(s["camera"], s["width"], s["height"])
            w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            fx = cfg.focal_px(w)
            self._log(f"ready - camera {s['camera']}, {w}x{h}, fx {fx:.0f}")
        except Exception as e:                      # noqa: BLE001
            self.state, self.message = "error", str(e)
            self._log(f"ERROR: {e}")
            return

        self.state, self.message = "running", ""
        self._started_at = time.time()
        calibrated = s["calib"] is not None
        prev_alert, prev_valid, confirmed_seen = None, True, set()
        t_prev, lost_logged, last_retry = time.time(), False, 0.0

        while not self._stop.is_set():
            ok, frame = cap.read()
            now = time.time()

            if not ok:
                if self._last_frame_at and now - self._last_frame_at > CAMERA_LOST_AFTER_S:
                    if not lost_logged:
                        self.state = "camera_lost"
                        self._log("camera lost - reconnecting")
                        lost_logged = True
                    if now - last_retry > RECONNECT_EVERY_S:
                        last_retry = now
                        try:
                            cap.release()
                            cap = self._open_camera(s["camera"], s["width"], s["height"], retries=1)
                            self.state, lost_logged = "running", False
                            self._log("camera back")
                        except Exception:           # noqa: BLE001
                            pass
                time.sleep(0.05)
                continue

            self._last_frame_at = now
            res = pipeline.process_frame(frame)
            if self._publisher:
                self._publisher.on_frame(res)
            draw(frame, res, calibrated=calibrated, persist=cfg.persist_frames)

            inst = 1.0 / max(now - t_prev, 1e-6)
            self._fps = inst if self._fps == 0 else 0.9 * self._fps + 0.1 * inst
            t_prev = now

            # Transitions only, after pipeline hysteresis and alert hold.
            if res.alert != prev_alert:
                if res.alert:
                    wt = res.worst_threat
                    if wt is not None:
                        d = "unknown distance" if wt.distance_m is None else f"{wt.distance_m:.0f} m"
                        self._log(f"{res.alert} - {wt.cls_name}, {d}")
                    else:
                        self._log(res.alert)
                else:
                    self._log("alert cleared")
                prev_alert = res.alert
            if res.track_valid != prev_valid:
                self._log("track detected" if res.track_valid else
                          f"track not detected - {'no track' if res.rail_convergence is None else f'rails do not converge ({res.rail_convergence:.2f})'}")
                prev_valid = res.track_valid
            for d in res.confirmed_threats:
                key = (d.cls_name, round(d.x1 / 50), round(d.y1 / 50))
                if key not in confirmed_seen:
                    confirmed_seen.add(key)
                    dist = "?" if d.distance_m is None else f"{d.distance_m:.0f} m"
                    self._log(f"{d.cls_name} confirmed on track, {dist}")

            ok_enc, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
            with self._lock:
                if ok_enc:
                    self._jpeg = buf.tobytes()
                self._result = self._as_dict(res, w, h, fx, calibrated)

        cap.release()
        if self._publisher:
            self._publisher.close()
            self._publisher = None

    # ----------------------------------------------------------------- views

    def _as_dict(self, res, w, h, fx, calibrated):
        wt = res.worst_threat
        return {
            "alert": res.alert,
            "alert_threat": (
                None if not (res.alert and wt) else {
                    "cls": str(wt.cls_name),
                    "distance_m": None if wt.distance_m is None else round(float(wt.distance_m), 1),
                }
            ),
            "track_valid": bool(res.track_valid),
            "rail_convergence": None if res.rail_convergence is None else round(float(res.rail_convergence), 3),
            "on_track": int(len(res.threats)),
            "confirmed": int(len(res.confirmed_threats)),
            "detections": [
                {"cls": str(d.cls_name), "conf": round(float(d.conf), 2),
                 "on_track": bool(d.on_track), "confirmed": bool(d.confirmed),
                 "hits": int(d.track_hits),
                 "distance_m": None if d.distance_m is None else round(float(d.distance_m), 1)}
                for d in res.detections
            ],
            "fps": round(float(self._fps), 1),
            "width": int(w), "height": int(h), "fx": int(round(float(fx))),
            "calibrated": bool(calibrated),
            "uptime_s": 0 if not self._started_at else int(time.time() - self._started_at),
        }

    def jpeg(self):
        with self._lock:
            return self._jpeg

    def snapshot(self):
        with self._lock:
            data = dict(self._result) if self._result else {}
        data.update(state=self.state, message=self.message,
                    unit_id=self.settings.get("unit_id"),
                    publishing=bool(self.settings.get("publish")),
                    camera=self.settings.get("camera"))
        return data
