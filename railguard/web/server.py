"""FastAPI backend for the RailGuard web UI.

    python demos/web_server.py
    then: cd web && npm run dev

Serves on 127.0.0.1 only. The camera, the GPU and the pipeline all live on
this machine, so the backend has to as well; a hosted frontend cannot reach a
USB camera, and a page served over HTTPS from elsewhere is blocked by the
browser from calling http://localhost. Running both locally avoids both
problems and keeps the video off the network entirely.

  GET  /api/cameras   camera indices that open, with their resolutions
  POST /api/start     begin a run
  POST /api/stop      end it
  GET  /api/status    one snapshot: state, alert, counts, fps, calibration
  GET  /api/events    log lines since an index
  GET  /video         MJPEG stream of the annotated frames

MJPEG rather than WebRTC: an <img> tag renders it with no client code, no
negotiation and no extra dependency. Latency over loopback is a frame or two,
which is below what the 3-frame persistence rule already costs.
"""

import glob
import os

import cv2
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from railguard.web.runner import Runner

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

app = FastAPI(title="RailGuard")
# The Vite dev server runs on another port on this machine, so the browser
# treats it as a different origin. Localhost only - this is never public.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_methods=["*"], allow_headers=["*"],
)

runner = Runner()


class StartRequest(BaseModel):
    camera: int = 1
    width: int = 1920
    height: int = 1080
    calib: str | None = None
    unit_id: str = "unit-01"
    publish: bool = False
    speed_kmh: float = 60.0


@app.get("/api/cameras")
def cameras():
    """Indices 0-3 that open, with the resolutions they actually deliver."""
    found = []
    for idx in range(4):
        cap = cv2.VideoCapture(idx, cv2.CAP_DSHOW)
        if not cap.isOpened():
            cap.release()
            continue
        modes = []
        for w, h in ((1920, 1080), (1280, 720)):
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, w)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, h)
            aw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            ah = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            if (aw, ah) not in modes:
                modes.append((aw, ah))
        cap.release()
        found.append({"index": idx, "modes": [f"{w}x{h}" for w, h in modes]})
    return {"cameras": found}


@app.get("/api/calibrations")
def calibrations():
    """Calibration files, with the focal length each one holds."""
    import numpy as np
    out = []
    for p in sorted(glob.glob(os.path.join(ROOT, "camera", "calibration", "*.npz"))):
        try:
            with np.load(p) as c:
                fx = float(c["fx"])
                w = int(c["image_size"][0])
            out.append({"path": os.path.relpath(p, ROOT).replace("\\", "/"),
                        "name": os.path.basename(p), "fx": round(fx), "width": w})
        except Exception:                           # noqa: BLE001
            continue
    return {"calibrations": out}


@app.post("/api/start")
def start(req: StartRequest):
    calib = os.path.join(ROOT, req.calib) if req.calib else None
    ok, msg = runner.start(camera=req.camera, width=req.width, height=req.height,
                           calib=calib, unit_id=req.unit_id,
                           publish=req.publish, speed_kmh=req.speed_kmh)
    return {"ok": ok, "message": msg}


@app.post("/api/stop")
def stop():
    runner.stop()
    return {"ok": True}


@app.get("/api/status")
def status():
    return runner.snapshot()


@app.get("/api/events")
def events(since: int = 0):
    items, total = runner.events_since(since)
    return {"events": items, "total": total}


def _frames():
    import time
    boundary = b"--frame\r\nContent-Type: image/jpeg\r\n\r\n"
    while True:
        jpeg = runner.jpeg()
        if jpeg is None:
            time.sleep(0.05)
            continue
        yield boundary + jpeg + b"\r\n"
        time.sleep(0.02)


@app.get("/video")
def video():
    return StreamingResponse(_frames(),
                             media_type="multipart/x-mixed-replace; boundary=frame")
