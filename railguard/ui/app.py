"""Main window, startup settings dialog, and recording lifecycle for RailGuard.
Flat, high-contrast cab display. Left: live annotated video. Right (320 px):
quiet status reference rows above a timestamped event log. Bottom: Start, Stop,
Record, and elapsed recording time. No mute button, no modal popups while
running, and explicit fail-safe / uncalibrated states at all times.
"""
import csv
from datetime import datetime
import json
import math
import os
import cv2
import numpy as np
from PyQt5.QtCore import Qt, QTimer
from PyQt5.QtGui import QFont, QImage, QPixmap
from PyQt5.QtWidgets import (
    QAction, QCheckBox, QComboBox, QDialog, QFileDialog, QFormLayout, QFrame,
    QHBoxLayout, QLabel, QLineEdit, QMainWindow, QPlainTextEdit, QPushButton,
    QSizePolicy, QSpinBox, QVBoxLayout, QWidget,
)
from railguard.config import REPO_ROOT, PipelineConfig
from railguard.core.alerts import BRAKE_NOW, CAUTION, braking_distance_m
from railguard.ui.worker import PipelineWorker, RunSettings, probe_cameras
STYLE = """
QMainWindow, QDialog, QWidget { background-color: #121212; color: #e6e6e6; font-family: "Segoe UI", sans-serif; font-size: 13px; }
QLabel { background: transparent; }
QPushButton { background-color: #242424; color: #f0f0f0; border: 1px solid #444444; padding: 7px 18px; font-weight: 600; }
QPushButton:hover:enabled { background-color: #323232; border-color: #666666; }
QPushButton:disabled { background-color: #181818; color: #555555; border-color: #282828; }
QLineEdit, QComboBox, QSpinBox, QPlainTextEdit { background-color: #1a1a1a; color: #e6e6e6; border: 1px solid #383838; padding: 5px 8px; }
QMenuBar { background-color: #161616; color: #cccccc; border-bottom: 1px solid #282828; }
QMenuBar::item:selected, QMenu::item:selected { background-color: #2c2c2c; }
QMenu { background-color: #1a1a1a; color: #e6e6e6; border: 1px solid #383838; }
"""

def inspect_calibration(path: str):
    """Read (fx, width, height, implied_hfov_deg) from a calibrate.py .npz file."""
    with np.load(path) as calib:
        fx = float(calib["fx"])
        w, h = int(calib["image_size"][0]), int(calib["image_size"][1])
    return fx, w, h, 2.0 * math.degrees(math.atan((w / 2.0) / fx))

def format_duration(seconds: float) -> str:
    hrs, rem = divmod(max(0, int(seconds)), 3600)
    mins, secs = divmod(rem, 60)
    return f"{hrs:02d}:{mins:02d}:{secs:02d}" if hrs else f"{mins:02d}:{secs:02d}"

class SettingsDialog(QDialog):
    """Pre-run configuration dialog. Settings are locked once Start is pressed."""
    def __init__(self, settings: RunSettings, parent=None):
        super().__init__(parent)
        self.setWindowTitle("RailGuard — Run Setup")
        self.setModal(True)
        self.setMinimumWidth(520)
        self.settings = RunSettings(**vars(settings))
        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 20, 20, 20)
        layout.setSpacing(14)
        title = QLabel("Configure Run Before Starting")
        title.setStyleSheet("font-size: 16px; font-weight: 700; color: #ffffff;")
        layout.addWidget(title)
        form = QFormLayout()
        form.setSpacing(12)
        cam_row = QHBoxLayout()
        self.cam_combo = QComboBox()
        self.cam_combo.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        cam_row.addWidget(self.cam_combo)
        cam_row.addWidget(QPushButton("Probe 0–3", clicked=self._populate_cameras))
        form.addRow("Camera", cam_row)
        calib_box = QVBoxLayout()
        calib_row = QHBoxLayout()
        self.calib_edit = QLineEdit(self.settings.calib_file or "", readOnly=True)
        self.calib_edit.setPlaceholderText("none — distances will be estimates")
        calib_row.addWidget(self.calib_edit)
        calib_row.addWidget(QPushButton("Browse…", clicked=self._pick_calib))
        calib_row.addWidget(QPushButton("Clear", clicked=self._clear_calib))
        self.calib_info = QLabel()
        calib_box.addLayout(calib_row)
        calib_box.addWidget(self.calib_info)
        form.addRow("Calibration file", calib_box)
        self.unit_edit = QLineEdit(self.settings.unit_id)
        form.addRow("Unit ID", self.unit_edit)
        self.publish_chk = QCheckBox("Publish BRAKE NOW hazards to Firestore", checked=self.settings.publish)
        form.addRow("Publish hazards", self.publish_chk)
        speed_row = QHBoxLayout()
        self.speed_spin = QSpinBox(minimum=10, maximum=160, singleStep=5, suffix=" km/h", value=int(self.settings.speed_kmh))
        self.speed_spin.valueChanged.connect(self._update_braking_label)
        self.brake_label = QLabel()
        self.brake_label.setStyleSheet("color: #bbbbbb; padding-left: 10px;")
        speed_row.addWidget(self.speed_spin)
        speed_row.addWidget(self.brake_label)
        speed_row.addStretch()
        form.addRow("Line speed", speed_row)
        layout.addLayout(form)
        btn_row = QHBoxLayout()
        btn_row.addStretch()
        btn_row.addWidget(QPushButton("Cancel", clicked=self.reject))
        start_btn = QPushButton("Start", default=True, clicked=self._accept_settings)
        start_btn.setStyleSheet("QPushButton { background-color: #1f6f3f; color: #ffffff; border: 1px solid #2ea05a; padding: 8px 26px; } QPushButton:hover { background-color: #26874d; }")
        btn_row.addWidget(start_btn)
        layout.addLayout(btn_row)
        self._populate_cameras()
        self._update_calib_info()
        self._update_braking_label()
    def _populate_cameras(self):
        self.cam_combo.clear()
        detected = {idx: (w, h, fcc) for idx, w, h, fcc in probe_cameras()}
        sel = 0
        for idx in range(4):
            if idx in detected:
                w, h, fcc = detected[idx]
                self.cam_combo.addItem(f"Camera {idx} — {w}x{h} ({fcc})", (idx, w, h))
            else:
                self.cam_combo.addItem(f"Camera {idx} — not detected (1920x1080 default)", (idx, 1920, 1080))
            if idx == self.settings.camera_index:
                sel = idx
        self.cam_combo.setCurrentIndex(sel)
    def _pick_calib(self):
        start_dir = os.path.join(REPO_ROOT, "camera", "calibration")
        path, _ = QFileDialog.getOpenFileName(self, "Select Calibration File", start_dir if os.path.isdir(start_dir) else REPO_ROOT, "NumPy calibration (*.npz)")
        if path:
            self.calib_edit.setText(path)
            self._update_calib_info()
    def _clear_calib(self):
        self.calib_edit.clear()
        self._update_calib_info()
    def _update_calib_info(self):
        path = self.calib_edit.text().strip()
        if not path:
            self.calib_info.setText("none — distances will be estimates (ASSUMED 60° FOV)")
            self.calib_info.setStyleSheet("color: #f59e0b; font-size: 12px;")
            return
        try:
            fx, w, h, hfov = inspect_calibration(path)
            self.calib_info.setText(f"fx {fx:.0f} px at {w}x{h} — implies {hfov:.1f}° horizontal FOV")
            self.calib_info.setStyleSheet("color: #4ade80; font-size: 12px;")
        except Exception as e:
            self.calib_info.setText(f"invalid calibration file ({e}) — distances will be estimates")
            self.calib_info.setStyleSheet("color: #ef4444; font-size: 12px;")
    def _update_braking_label(self):
        self.brake_label.setText(f"Braking distance: {braking_distance_m(float(self.speed_spin.value())):.0f} m")
    def _accept_settings(self):
        idx, w, h = self.cam_combo.currentData()
        calib = self.calib_edit.text().strip() or None
        if calib:
            try:
                inspect_calibration(calib)
            except Exception:
                calib = None
        self.settings = RunSettings(
            camera_index=idx, width=w, height=h, calib_file=calib,
            unit_id=self.unit_edit.text().strip() or "unit-01",
            publish=self.publish_chk.isChecked(),
            speed_kmh=float(self.speed_spin.value()),
            segment_every=self.settings.segment_every,
            firebase_key=self.settings.firebase_key,
        )
        self.accept()

class VideoPanel(QLabel):
    """Left video display. Preserves aspect ratio and shows loading stages cleanly."""
    def __init__(self, parent=None):
        super().__init__(parent, alignment=Qt.AlignCenter)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setMinimumSize(640, 360)
        self.setStyleSheet("background-color: #080808; color: #cccccc; font-size: 20px; font-weight: 600; border: 1px solid #262626;")
        self._pixmap = None
        self.set_stage("Idle — press Start to configure and begin run")
    def set_stage(self, text: str):
        self._pixmap = None
        self.clear()
        self.setText(text)
    def set_frame(self, bgr_frame: np.ndarray):
        rgb = cv2.cvtColor(bgr_frame, cv2.COLOR_BGR2RGB)
        h, w, ch = rgb.shape
        self._pixmap = QPixmap.fromImage(QImage(rgb.data, w, h, ch * w, QImage.Format_RGB888).copy())
        self._rescale()
    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._rescale()
    def _rescale(self):
        if self._pixmap is not None:
            super().setPixmap(self._pixmap.scaled(self.size(), Qt.KeepAspectRatio, Qt.SmoothTransformation))

class MainWindow(QMainWindow):
    def __init__(self, initial_settings: RunSettings):
        super().__init__()
        self.settings = initial_settings
        self.worker = self._run_started_at = self._current_fx = None
        self._last_fps = 0.0
        self._actual_res = (initial_settings.width, initial_settings.height)
        self._rec_dir = self._rec_writer = self._rec_csv_file = self._rec_csv_writer = self._rec_started_at = None
        self.setWindowTitle("RailGuard")
        self.resize(1360, 820)
        self.setStyleSheet(STYLE)
        self._build_menu()
        self._build_ui()
        self._clock = QTimer(self, interval=1000, timeout=self._tick_timers)
    def _build_menu(self):
        file_menu = self.menuBar().addMenu("&File")
        self.act_start = QAction("&Start Run…", self, triggered=self.prompt_and_start)
        self.act_stop = QAction("S&top Run", self, enabled=False, triggered=self.stop_run)
        file_menu.addActions([self.act_start, self.act_stop])
        file_menu.addSeparator()
        file_menu.addAction(QAction("&Quit", self, triggered=self.close))
    def _build_ui(self):
        root = QWidget(self)
        self.setCentralWidget(root)
        outer = QVBoxLayout(root)
        outer.setContentsMargins(10, 10, 10, 10)
        outer.setSpacing(10)
        self.alert_banner = QLabel("STANDBY", alignment=Qt.AlignVCenter | Qt.AlignLeft)
        self.alert_banner.setFixedHeight(52)
        self._set_banner_idle()
        outer.addWidget(self.alert_banner)
        mid = QHBoxLayout()
        mid.setSpacing(12)
        self.video_panel = VideoPanel()
        mid.addWidget(self.video_panel, stretch=1)
        right_col = QFrame()
        right_col.setFixedWidth(320)
        right_col.setStyleSheet("QFrame { background-color: #161616; border: 1px solid #282828; }")
        right_layout = QVBoxLayout(right_col)
        right_layout.setContentsMargins(14, 14, 14, 14)
        right_layout.setSpacing(12)
        status_form = QFormLayout()
        status_form.setHorizontalSpacing(14)
        status_form.setVerticalSpacing(9)
        self.lbl_camera = self._status_val("—")
        self.lbl_fps = self._status_val("—")
        self.lbl_distances = self._status_val("—")
        self.lbl_track = self._status_val("—")
        self.lbl_on_track = self._status_val("0")
        self.lbl_publishing = self._status_val("off")
        self.lbl_running_for = self._status_val("00:00")
        for title, widget in (
            ("Camera", self.lbl_camera), ("Frame rate", self.lbl_fps), ("Distances", self.lbl_distances),
            ("Track", self.lbl_track), ("On track now", self.lbl_on_track),
            ("Publishing", self.lbl_publishing), ("Running for", self.lbl_running_for),
        ):
            k = QLabel(title)
            k.setStyleSheet("color: #8a8a8a; border: none;")
            status_form.addRow(k, widget)
        right_layout.addLayout(status_form)
        log_header = QLabel("Event log")
        log_header.setStyleSheet("color: #8a8a8a; font-weight: 600; border: none;")
        right_layout.addWidget(log_header)
        self.log_view = QPlainTextEdit(readOnly=True)
        self.log_view.setFont(QFont("Consolas", 10))
        self.log_view.setStyleSheet("QPlainTextEdit { background-color: #0e0e0e; color: #d4d4d4; border: 1px solid #262626; padding: 6px; }")
        right_layout.addWidget(self.log_view, stretch=1)
        mid.addWidget(right_col, stretch=0)
        outer.addLayout(mid, stretch=1)
        ctrl = QHBoxLayout()
        ctrl.setSpacing(10)
        self.btn_start = QPushButton("Start", clicked=self.prompt_and_start)
        self.btn_stop = QPushButton("Stop", enabled=False, clicked=self.stop_run)
        self.btn_record = QPushButton("Record", enabled=False, clicked=self.toggle_recording)
        self.lbl_rec_time = QLabel("")
        self.lbl_rec_time.setStyleSheet("color: #ef4444; font-weight: 700; padding-left: 8px;")
        self.lbl_locked_summary = QLabel("")
        self.lbl_locked_summary.setStyleSheet("color: #777777;")
        for w in (self.btn_start, self.btn_stop, self.btn_record, self.lbl_rec_time):
            ctrl.addWidget(w)
        ctrl.addStretch()
        ctrl.addWidget(self.lbl_locked_summary)
        outer.addLayout(ctrl)
    def _status_val(self, text: str) -> QLabel:
        lbl = QLabel(text, wordWrap=True)
        lbl.setStyleSheet("color: #e6e6e6; font-weight: 600; border: none;")
        return lbl
    def _set_banner(self, text: str, bg: str, fg: str, border: str, size: int = 15, weight: int = 600):
        self.alert_banner.setText(f"  {text}")
        self.alert_banner.setStyleSheet(f"background-color: {bg}; color: {fg}; font-size: {size}px; font-weight: {weight}; padding-left: 14px; border: 2px solid {border};")
    def _set_banner_idle(self):
        self._set_banner("STANDBY — not running", "#1a1a1a", "#888888", "#2a2a2a")
    def _update_banner(self, res=None, camera_lost=False):
        if camera_lost:
            self._set_banner("CAMERA LOST — RECONNECTING (displaying stale frame)", "#7c2d12", "#ffffff", "#f97316", 18, 700)
        elif res is not None and res.alert == BRAKE_NOW:
            w = res.worst_threat
            if w is not None and w.distance_m is None:
                msg = f"BRAKE NOW — {w.cls_name.upper()} ON TRACK, DISTANCE ? (FAIL-SAFE: unmeasurable distance)"
            elif w is not None:
                msg = f"BRAKE NOW — {w.cls_name.upper()} ON TRACK, {w.distance_m:.0f} m"
            else:
                msg = "BRAKE NOW"
            self._set_banner(msg, "#dc2626", "#ffffff", "#ffffff", 22, 800)
        elif res is not None and res.alert == CAUTION:
            w = res.worst_threat
            dist = "?" if (w is None or w.distance_m is None) else f"{w.distance_m:.0f} m"
            cls = w.cls_name.upper() if w is not None else "OBJECT"
            self._set_banner(f"CAUTION — {cls} ON TRACK, {dist}", "#d97706", "#000000", "#fbbf24", 19, 800)
        elif not self.settings.calib_file:
            self._set_banner("MONITORING — UNCALIBRATED (distances use ASSUMED focal length)", "#1c1917", "#fbbf24", "#78350f", 14, 600)
        else:
            fx_str = f"fx {self._current_fx:.0f}" if self._current_fx else "calibrated"
            self._set_banner(f"MONITORING — calibrated ({fx_str})", "#161616", "#9ca3af", "#282828", 14, 600)
    def _set_running_controls(self, running: bool):
        for w in (self.btn_start, self.act_start):
            w.setEnabled(not running)
        for w in (self.btn_stop, self.act_stop, self.btn_record):
            w.setEnabled(running)
    def prompt_and_start(self):
        if self.worker is not None and self.worker.isRunning():
            return
        dlg = SettingsDialog(self.settings, self)
        if dlg.exec_() == QDialog.Accepted:
            self.settings = dlg.settings
            self.start_run()
    def start_run(self):
        if self.worker is not None and self.worker.isRunning():
            return
        s = self.settings
        self._set_running_controls(True)
        brake_m = braking_distance_m(s.speed_kmh)
        cal_summary = f"calibrated ({os.path.basename(s.calib_file)})" if s.calib_file else "ASSUMED focal length"
        self.lbl_locked_summary.setText(f"Locked: cam {s.camera_index} · {cal_summary} · {s.speed_kmh:.0f} km/h (brake {brake_m:.0f} m) · {s.unit_id}")
        self.lbl_camera.setText(f"{s.camera_index}, {s.width}x{s.height}")
        self.lbl_fps.setText("—")
        if s.calib_file:
            self._current_fx, _, _, _ = inspect_calibration(s.calib_file)
            self.lbl_distances.setText(f"calibrated (fx {self._current_fx:.0f})")
            self.lbl_distances.setStyleSheet("color: #e6e6e6; font-weight: 600; border: none;")
        else:
            self._current_fx = PipelineConfig().focal_px(s.width)
            self.lbl_distances.setText("ASSUMED focal length")
            self.lbl_distances.setStyleSheet("color: #f59e0b; font-weight: 700; border: none;")
        self.lbl_track.setText("—")
        self.lbl_on_track.setText("0")
        self.lbl_publishing.setText(f"{s.unit_id} connecting…" if s.publish else "off")
        self.lbl_running_for.setText("00:00")
        self._update_banner()
        self._run_started_at = datetime.now()
        self._clock.start()
        self.worker = PipelineWorker(s, self)
        self.worker.stage_changed.connect(lambda st: self.video_panel.set_stage(st) if st != "Ready" else None)
        self.worker.frame_ready.connect(self._on_frame)
        self.worker.stale_frame.connect(self._on_stale_frame)
        self.worker.camera_state.connect(self._on_camera_state)
        self.worker.publish_state.connect(self.lbl_publishing.setText)
        self.worker.log_event.connect(self.append_log)
        self.worker.fatal_error.connect(self._on_fatal_error)
        self.worker.start()
    def stop_run(self):
        if self._rec_writer is not None:
            self._stop_recording()
        self._clock.stop()
        if self.worker is not None:
            self.worker.stop()
            self.worker.wait(5000)
            self.worker = None
        self._set_running_controls(False)
        self.lbl_locked_summary.setText("")
        self._set_banner_idle()
        self.video_panel.set_stage("Stopped — press Start to configure and begin run")
        self.append_log("run stopped")
    def _on_camera_state(self, connected: bool, w: int, h: int, fx: float):
        self._actual_res, self._current_fx = (w, h), fx
        if connected:
            self.lbl_camera.setText(f"{self.settings.camera_index}, {w}x{h}")
            self.lbl_camera.setStyleSheet("color: #e6e6e6; font-weight: 600; border: none;")
            if self.settings.calib_file:
                self.lbl_distances.setText(f"calibrated (fx {fx:.0f})")
                self.lbl_distances.setStyleSheet("color: #e6e6e6; font-weight: 600; border: none;")
            else:
                self.lbl_distances.setText("ASSUMED focal length")
                self.lbl_distances.setStyleSheet("color: #f59e0b; font-weight: 700; border: none;")
        else:
            self.lbl_camera.setText("camera lost — reconnecting")
            self.lbl_camera.setStyleSheet("color: #ef4444; font-weight: 700; border: none;")
            self._update_banner(camera_lost=True)
    def _on_frame(self, frame: np.ndarray, res, fps: float):
        try:
            self._last_fps = fps
            self.video_panel.set_frame(frame)
            self.lbl_fps.setText(f"{fps:.1f} fps")
            if res.track_valid:
                self.lbl_track.setText("detected")
                self.lbl_track.setStyleSheet("color: #e6e6e6; font-weight: 600; border: none;")
            else:
                why = "no track found" if res.rail_convergence is None else "rails do not converge"
                self.lbl_track.setText(f"not detected — {why}")
                self.lbl_track.setStyleSheet("color: #f59e0b; font-weight: 700; border: none;")
            n_on = len(res.threats)
            self.lbl_on_track.setText(str(n_on))
            self.lbl_on_track.setStyleSheet("color: #ef4444; font-weight: 700; border: none;" if n_on > 0 else "color: #e6e6e6; font-weight: 600; border: none;")
            self._update_banner(res=res, camera_lost=False)
            if self._rec_writer is not None:
                self._rec_writer.write(frame)
        finally:
            if self.worker is not None:
                self.worker.mark_painted()
    def _on_stale_frame(self, stale_frame: np.ndarray, age_s: float):
        self.video_panel.set_frame(stale_frame)
        self.lbl_camera.setText(f"camera lost — reconnecting ({age_s:.0f} s)")
        self._update_banner(camera_lost=True)
        if self._rec_writer is not None:
            self._rec_writer.write(stale_frame)
    def _on_fatal_error(self, msg: str):
        self.append_log(msg)
        self.stop_run()
        self.video_panel.set_stage(msg)
    def append_log(self, message: str):
        ts = datetime.now().strftime("%H:%M:%S")
        self.log_view.appendPlainText(f"{ts}  {message}")
        sb = self.log_view.verticalScrollBar()
        sb.setValue(sb.maximum())
        if self._rec_csv_writer is not None:
            self._rec_csv_writer.writerow([ts, message])
            self._rec_csv_file.flush()
    def toggle_recording(self):
        self._start_recording() if self._rec_writer is None else self._stop_recording()
    def _start_recording(self):
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self._rec_dir = os.path.join(REPO_ROOT, "outputs", "runs", stamp)
        os.makedirs(self._rec_dir, exist_ok=True)
        w, h = self._actual_res
        fps = round(self._last_fps, 1) if self._last_fps >= 1.0 else 10.0
        self._rec_writer = cv2.VideoWriter(os.path.join(self._rec_dir, "video.mp4"), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
        self._rec_csv_file = open(os.path.join(self._rec_dir, "events.csv"), "w", newline="", encoding="utf-8")
        self._rec_csv_writer = csv.writer(self._rec_csv_file)
        self._rec_csv_writer.writerow(["timestamp", "event"])
        s = self.settings
        run_meta = {
            "timestamp": stamp, "camera": s.camera_index, "resolution": [w, h],
            "calibrated": bool(s.calib_file), "calibration_file": s.calib_file,
            "fx": round(self._current_fx, 2) if self._current_fx else None,
            "distances": "calibrated" if s.calib_file else "ASSUMED focal length (uncalibrated)",
            "unit_id": s.unit_id, "publish_hazards": s.publish,
            "line_speed_kmh": s.speed_kmh, "braking_distance_m": braking_distance_m(s.speed_kmh),
        }
        with open(os.path.join(self._rec_dir, "run.json"), "w", encoding="utf-8") as f:
            json.dump(run_meta, f, indent=2)
        self._rec_started_at = datetime.now()
        self.btn_record.setText("Stop Recording")
        self.btn_record.setStyleSheet("QPushButton { background-color: #7f1d1d; color: #ffffff; border: 1px solid #ef4444; }")
        self.lbl_rec_time.setText("Recording 00:00")
        self.append_log(f"recording started — outputs/runs/{stamp}")
    def _stop_recording(self):
        rel_dir = os.path.relpath(self._rec_dir, REPO_ROOT) if self._rec_dir else "outputs/runs"
        if self._rec_writer is not None:
            self._rec_writer.release()
            self._rec_writer = None
        if self._rec_csv_file is not None:
            self._rec_csv_file.close()
            self._rec_csv_file = self._rec_csv_writer = None
        self._rec_started_at = None
        self.btn_record.setText("Record")
        self.btn_record.setStyleSheet("")
        self.lbl_rec_time.setText("")
        self.append_log(f"recording saved — {rel_dir}")
    def _tick_timers(self):
        now = datetime.now()
        if self._run_started_at is not None:
            self.lbl_running_for.setText(format_duration((now - self._run_started_at).total_seconds()))
        if self._rec_started_at is not None:
            self.lbl_rec_time.setText(f"Recording {format_duration((now - self._rec_started_at).total_seconds())}")
    def closeEvent(self, event):
        self.stop_run()
        super().closeEvent(event)
