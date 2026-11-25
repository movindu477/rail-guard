"""Launch the RailGuard PyQt5 desktop cab application.
    python demos/live_app.py
    python demos/live_app.py --calib camera/calibration/elp_wide_measured.npz --camera 1
Opens the pre-run settings dialog before starting so the driver or operator can
verify the camera, calibration file, unit ID, hazard publishing, and line speed.
Pass --auto-start to skip the startup dialog and begin immediately.
"""
import argparse
import sys
from PyQt5.QtCore import QTimer
from PyQt5.QtWidgets import QApplication
from railguard.ui.app import MainWindow
from railguard.ui.worker import RunSettings

def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="RailGuard desktop application (PyQt5)")
    ap.add_argument("--camera", type=int, default=1, help="default camera index")
    ap.add_argument("--width", type=int, default=1920, help="capture width")
    ap.add_argument("--height", type=int, default=1080, help="capture height")
    ap.add_argument("--calib", help="calibration .npz file path")
    ap.add_argument("--unit", default="unit-01", help="train unit ID")
    ap.add_argument("--publish", action="store_true", help="publish BRAKE NOW hazards to Firestore")
    ap.add_argument("--speed", type=float, default=60.0, help="line speed in km/h")
    ap.add_argument("--segment-every", type=int, default=1, help="run TEP-Net every Nth frame")
    ap.add_argument("--firebase-key", help="Firestore service-account key path")
    ap.add_argument("--auto-start", action="store_true", help="start immediately without setup dialog")
    return ap.parse_args(argv)

def main(argv=None):
    args = parse_args(argv)
    settings = RunSettings(
        camera_index=args.camera,
        width=args.width,
        height=args.height,
        calib_file=args.calib,
        unit_id=args.unit,
        publish=args.publish,
        speed_kmh=args.speed,
        segment_every=args.segment_every,
        firebase_key=args.firebase_key,
    )
    app = QApplication(sys.argv if argv is None else [sys.argv[0], *argv])
    win = MainWindow(settings)
    win.show()
    if args.auto_start:
        QTimer.singleShot(0, win.start_run)
    else:
        QTimer.singleShot(0, win.prompt_and_start)
    return app.exec_()

if __name__ == "__main__":
    raise SystemExit(main())
