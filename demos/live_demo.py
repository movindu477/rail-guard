"""Run the RailGuard pipeline on the live camera. Press Q to quit.

    python demos/live_demo.py
    python demos/live_demo.py --calib camera/calibration/elp_wide.npz --camera 1
    python demos/live_demo.py --publish             # also send BRAKE NOW hazards to Firestore

Same drawing as demos/offline_video.py; frames come from
railguard.camera.capture.open_camera(). Without --calib, distances use an
assumed field of view and every frame says so.
"""

import argparse
import os
import threading
import time

import cv2

from railguard.camera.capture import open_camera
from railguard.config import PipelineConfig
from railguard.core.alerts import BRAKE_NOW
from railguard.pipeline import RailGuardPipeline

from draw import draw, put_label  # demos/draw.py

ALERT_WAV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets", "alert.wav")
BEEP_COOLDOWN_S = 1.0
DISPLAY_WIDTH = 1280

try:
    import winsound

    def beep():
        threading.Thread(target=winsound.PlaySound, args=(ALERT_WAV, winsound.SND_FILENAME),
                         daemon=True).start()
except ImportError:
    def beep():
        print("\a", end="", flush=True)


def main():
    ap = argparse.ArgumentParser(description="RailGuard: live camera demo (Q quits)")
    ap.add_argument("--camera", type=int, default=1, help="camera index")
    ap.add_argument("--width", type=int, default=1920, help="capture width")
    ap.add_argument("--height", type=int, default=1080, help="capture height")
    ap.add_argument("--calib", help="calibration .npz from camera/calibration/calibrate.py")
    ap.add_argument("--segment-every", type=int, default=1, help="run TEP-Net every Nth frame")
    ap.add_argument("--publish", action="store_true",
                    help="send BRAKE NOW hazards to Firestore for the driver app (needs the phone app running)")
    ap.add_argument("--unit", default="unit-01", help="train unit id, same as the phone app's RAILGUARD_UNIT")
    ap.add_argument("--firebase-key", help="service-account key (default: ~/.railguard/firebase-key.json)")
    args = ap.parse_args()

    opts = dict(segment_every=args.segment_every)
    config = PipelineConfig.from_calibration(args.calib, **opts) if args.calib else PipelineConfig(**opts)
    print("Loading models...")
    pipeline = RailGuardPipeline(config)
    print(f"Detecting: {[pipeline.model.names[i] for i in pipeline.keep_ids]}")

    publisher = None
    if args.publish:
        from railguard.alerts.publisher import HazardPublisher
        publisher = HazardPublisher(args.unit, key_path=args.firebase_key)
        print(f"Publishing BRAKE NOW hazards to Firestore as {args.unit}")

    cap = open_camera(args.camera, args.width, args.height)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print(f"Camera {args.camera}: {w}x{h}")
    print(f"Focal length: {config.focal_px(w):.0f} px"
          f"{f' (from {args.calib})' if args.calib else ''}")
    print("Press Q in the window to quit.")

    last_beep, fps, t_prev = 0.0, 0.0, time.time()
    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                print("Camera read failed.")
                break
            res = pipeline.process_frame(frame)
            if publisher:
                publisher.on_frame(res)
            draw(frame, res, calibrated=args.calib is not None, persist=config.persist_frames)

            now = time.time()
            inst = 1.0 / max(now - t_prev, 1e-6)
            fps = inst if fps == 0 else 0.9 * fps + 0.1 * inst  # smoothed
            t_prev = now
            s = frame.shape[1] / 1920
            put_label(frame, f"{fps:.1f} FPS", frame.shape[1] - int(200 * s),
                      frame.shape[0] - int(15 * s), (255, 255, 0), 0.8 * s, max(1, int(2 * s)))

            cooldown = BEEP_COOLDOWN_S if res.alert == BRAKE_NOW else BEEP_COOLDOWN_S * 2
            if res.alert is not None and now - last_beep > cooldown:
                beep()
                last_beep = now

            disp_h = int(DISPLAY_WIDTH * frame.shape[0] / frame.shape[1])
            cv2.imshow("RailGuard LIVE", cv2.resize(frame, (DISPLAY_WIDTH, disp_h)))
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break
    finally:
        cap.release()
        cv2.destroyAllWindows()
        if publisher:
            publisher.close()


if __name__ == "__main__":
    main()
