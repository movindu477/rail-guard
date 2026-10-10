# RailGuard — Project Progress Summary

*Status as of 10 October 2026 · Branch `main` @ `99e9d52`*

---

## 1. What RailGuard Is

RailGuard is a vision-based **train collision-warning system** for Sri Lankan railways. A single forward-facing camera watches the track ahead. The system:

1. **Detects hazards** such as people, vehicles and animals using a fine-tuned YOLOv8 detector.
2. **Finds the train's own path** (the "ego-path", i.e. the rails the train will actually run on) using TEP-Net.
3. **Fuses the two**, so that only objects *inside the train's path* count as threats. Objects beside the track are ignored.
4. **Estimates the distance** to each threat, using the known rail gauge as a ruler.
5. **Raises tiered alerts**: `CAUTION` for threats far away and `!! BRAKE NOW !!` for threats within 100 m, with an audible alarm.

The project has three parts:
- a **desktop / GPU pipeline** (Python): the full system;
- a **mobile app** (Flutter / Android): on-device detection;
- **camera hardware work**: real-time 4K capture from a USB camera.

---

## 2. Status at a Glance

| Area | Status | Notes |
| :--- | :--- | :--- |
| Data collection & frame extraction | ✅ Done | 2 raw ride videos (day + night), 5 processed clips, 598 extracted frames |
| Auto-labeling + manual review | ✅ Done | YOLOv8m bootstrap labels → manually reviewed; 212 frames contain objects |
| Detector fine-tuning (desktop) | ✅ Done | YOLOv8s @ 1280 px: **mAP50 0.544**; Person **mAP50 0.791** |
| Detector fine-tuning (mobile) | ✅ Done | YOLOv8n @ 1280 px: mAP50 0.493 (exported at 320 px) |
| Ego-path detection (TEP-Net) | ✅ Integrated | Pretrained RailSem19 weights. Strong by day, unreliable at night |
| Fusion v4 (corridor + distance + tiered alerts) | ✅ Working | Verified on the 2-min and 20-min Sri Lanka clips |
| Live real-time demo (threaded, audio alerts) | ✅ Working | Runs on a video file; live-camera input not yet connected |
| Evaluation (accuracy + speed benchmarks) | ✅ Done | GPU vs CPU, 3 resolutions, 2 TEP-Net backbones |
| Camera hardware (ELP 4K USB) | ✅ Characterised | 4K @ 29.6 FPS via MSMF + MJPEG; reusable `open_camera()` |
| Mobile app (Flutter, Android) | 🟡 Partial | Camera + on-device TFLite detection works. No ego-path, distance or alerts yet. Box-drawing bug (see §11) |
| Backend / server | ⬜ Not started | `backend/` folder is an empty placeholder |
| Custom segmentation model | ⬜ Not started | `ml/segmentation/` is an empty placeholder; TEP-Net is used instead |

---

## 3. System Architecture

```
                       ┌──────────────────────────────┐
  Camera / video ───►  │  Frame (BGR, e.g. 1920x1080) │
                       └──────────────┬───────────────┘
                 ┌────────────────────┴────────────────────┐
                 ▼                                         ▼
   ┌──────────────────────────┐             ┌──────────────────────────┐
   │ TEP-Net (ego-path)       │             │ YOLOv8 (fine-tuned)      │
   │ left/right rail polylines│             │ boxes: person, car,      │
   │ (every 2nd–3rd frame)    │             │ motorcycle, bus, truck,  │
   └────────────┬─────────────┘             │ cow, elephant            │
                ▼                           └────────────┬─────────────┘
   ┌──────────────────────────┐                          │
   │ Corridor builder         │                          │
   │ • widen rails ×3 around  │                          │
   │   centre-line            │                          │
   │ • per-row rail width (px)│                          │
   └────────────┬─────────────┘                          │
                └──────────────────┬─────────────────────┘
                                   ▼
               ┌──────────────────────────────────────┐
               │ Fusion / threat classifier           │
               │ • foot point = bottom-centre of box  │
               │ • inside corridor? → THREAT          │
               │ • distance = f · 1.676 m / width_px  │
               └──────────────────┬───────────────────┘
                                  ▼
               ┌──────────────────────────────────────┐
               │ Tiered alert                         │
               │ ≤100 m → "!! BRAKE NOW !!" + alarm   │
               │ >100 m → "CAUTION" + softer beep     │
               │ off-track objects → grey, ignored    │
               └──────────────────────────────────────┘
```

---

## 4. Repository Contents

### 4.1 Tracked in git

```
rail-guard/
├── README.md                      # placeholder (title only)
├── observations.md                # research log: night analysis, training, benchmarks, camera
├── PROGRESS_SUMMARY.md            # this document
├── screenshots/                   # fusion demo evidence
│   ├── brake_now.png              #   person on track at ~22 m → BRAKE NOW
│   ├── caution.png                #   distant threat → CAUTION
│   └── ignored_objs.png           #   people beside the track are correctly ignored
├── ml/
│   ├── detection/
│   │   ├── detect.py              # baseline: pretrained YOLOv8n on night clip
│   │   ├── split_dataset.py       # 80/20 train/val split + railguard.yaml
│   │   ├── train.py               # fine-tuning script (currently set to the mobile YOLOv8n run)
│   │   ├── export_tflite.py       # railguard_best.pt → ONNX(640) → TFLite
│   │   └── export_mobile.py       # mobile model → ONNX(320) → TFLite
│   ├── fusion/
│   │   ├── auto_label.py          # YOLOv8m auto-labeling (COCO → 7 RailGuard classes)
│   │   ├── fusion.py              # Fusion v4: offline video processing
│   │   ├── live_demo.py           # Live Demo v2: threaded real-time + audio alerts
│   │   ├── railguard_core.py      # shared fusion functions (corridor, distance, threats)
│   │   └── alert.wav              # alarm sound
│   └── evaluation/
│       ├── evaluate_detection.py  # mAP / precision / recall per class
│       └── benchmark_speed.py     # YOLO + TEP-Net latency, GPU vs CPU
├── tools/                         # USB camera investigation
│   ├── camera.py                  # ★ reusable open_camera() (MSMF + MJPEG)
│   ├── camera_check.py            # probe indices & supported resolutions
│   ├── camera_format.py           # report default FOURCC per backend
│   ├── camera_fps.py              # DSHOW FPS at 4K/1080p/720p
│   ├── camera_fps_mjpg.py         # DSHOW vs MSMF at 1080p MJPEG
│   └── camera_4k_benchmark.py     # MSMF 4K MJPEG throughput
└── mobile-app/railguard_app/      # Flutter app (see §9)
    ├── lib/main.dart              # camera screen, inference loop, overlay
    ├── lib/detector.dart          # YUV→RGB, preprocessing, output parsing, NMS
    ├── assets/labels.txt          # 7 class names
    └── android/ …                 # TFLite packaging config, permissions
```

### 4.2 Local only (git-ignored, large files)

| Location | Contents |
| :--- | :--- |
| `data/videos/raw/` | `srilanka_clean_full.mp4` (~1.1 GB, daytime ride), `srilanka_night_full.mp4` (~89 MB) |
| `data/videos/processed/` | `test2min`, `test5min`, `trimmed_8min`, `full_20min`, `night5min` clips |
| `data/videos/results/` | Output videos: `fusion_finetuned_2min(_smooth)`, `fusion_v4_2min_smooth`, `fusion_full_20min_smooth`, `tepnet_test2min`, `tepnet_night5min`, `yolo_640/1280/night` |
| `data/frames/` | 12 night frames used for the human-baseline study |
| `data/dataset/` | 598 frames + labels (with `labels_backup`, `labels_v1_backup`, `labels_reviewed`), and the `yolo/` train/val split |
| `results/` | `training_run1/` (YOLOv8s curves, weights), `eval_detection/`, `eval_detection-2/` |
| `ml/detection/` | `railguard_best.pt` (YOLOv8s, 22.6 MB), `railguard_best_320.onnx`, two TFLite `saved_model` folders |
| `mobile-app/.../assets/` | `railguard_mobile_320_float32.tflite` (12 MB, used by the app), `railguard_best_320_float32.tflite` (44.6 MB, unused) |
| repo root | `yolov8n.pt`, `yolov8s.pt`, `yolov8m.pt`, `yolo26n.pt`, `ffmpeg.exe`, `venv/` |
| `C:\Users\USER\runs\detect\` | `railguard_finetune`, `railguard_mobile` (mobile YOLOv8n weights) |
| `../train-ego-path-detection/` | **External dependency**: TEP-Net repo (irtrailenium), with weights `logical-tree-1`, `chromatic-laughter-5` and others |

---

## 5. Data Pipeline

1. **Source footage**: front-cab ride videos of Sri Lankan railways (a full daytime ride and a night ride), trimmed with `ffmpeg` into 2-, 5-, 8- and 20-minute working clips.
2. **Frame extraction**: 598 frames sampled into `data/dataset/images/`.
3. **Auto-labeling** (`ml/fusion/auto_label.py`): YOLOv8m (COCO) runs at 1280 px, conf 0.25. Its COCO classes are remapped to the 7 RailGuard classes:

   | RailGuard ID | 0 | 1 | 2 | 3 | 4 | 5 | 6 |
   | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
   | Class | person | car | motorcycle | bus | truck | cow | elephant |
   | COCO ID | 0 | 2 | 3 | 5 | 7 | 19 | 20 |

4. **Manual review**: the auto labels were corrected by hand, with backups kept at each stage (`labels_backup`, `labels_v1_backup`, `labels_reviewed`).
5. **Split** (`ml/detection/split_dataset.py`): only frames with at least one object are kept (212 frames). These are shuffled with seed 42 into **169 train / 43 val**, and `railguard.yaml` is generated.

---

## 6. Object Detection

### 6.1 Baseline
`detect.py` ran the stock COCO YOLOv8n on the night clip (1280 px, RailGuard classes only) to establish out-of-the-box behaviour.

### 6.2 Fine-tuned desktop model: `railguard_best.pt` (YOLOv8s)
- Hardware: RTX 4050 Laptop GPU (CUDA 12.1). Settings: `imgsz=1280`, `batch=8`, `patience=20`, 80 epochs planned.
- Early stopping at epoch 21; the **best weights came from epoch 1**. The COCO pre-training already covers these classes, and further epochs over-fitted the small dataset.

| Class | Val instances | Precision | Recall | mAP50 | mAP50-95 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **All** | 132 | 0.696 | 0.495 | **0.544** | **0.446** |
| Person | 62 | 0.878 | 0.700 | **0.791** | 0.546 |
| Car | 33 | 0.624 | 0.545 | 0.656 | 0.527 |
| Motorcycle | 5 | 0.701 | 0.800 | 0.758 | 0.708 |
| Bus | 19 | 0.646 | 0.480 | 0.625 | 0.523 |
| Truck | 12 | 0.325 | 0.443 | 0.436 | 0.370 |
| Elephant | 1 | 1.000 | 0.000 | 0.000 | 0.000 |

The most important safety class, **Person, reaches mAP50 0.79 with 0.88 precision.** Cow has no validation instances and Elephant only one, so the animal classes are effectively untested.

### 6.3 Fine-tuned mobile model: `railguard_mobile` (YOLOv8n)
- Same dataset and settings, using the smaller YOLOv8n so it can run on a phone.
- Best mAP50 **0.493** (mAP50-95 0.322) at epoch 21; early-stopped at epoch 43.
- Exported via `export_mobile.py`: PyTorch → ONNX (320×320) → `onnx2tf` → **float32 TFLite (12 MB)**.
  - Input: `[1, 320, 320, 3]`. Output: `[1, 11, 2100]`, i.e. 4 box values plus 7 class scores for 2100 anchors.

### 6.4 Long-range limitation
Manual inspection shows that objects beyond about **100 m are not identifiable** in the source footage, even when zoomed in. The limit comes from the video resolution and compression, not the model, which is why the 4K camera work (§10) matters.

---

## 7. Ego-Path Detection (TEP-Net)

- RailGuard uses **TEP-Net** ("Train Ego-Path Detection on Railway Tracks Using End-to-End Deep Learning", arXiv 2403.13094). The code is in the sibling folder `../train-ego-path-detection` and is loaded through `src.utils.interface.Detector`.
- Weights used: `chromatic-laughter-5` (more accurate, used offline) and `logical-tree-1` (faster, used in the live demo).
- TEP-Net returns the **left and right rail polylines** of the track the train is on.
- **Day**: excellent. Published IoU is 0.967–0.977 on RailSem19, and our clips show stable corridors through curves and junctions.
- **Night** (findings recorded in `observations.md`):
  - The headlight lights only about 20–30 m of track, and even less on curves.
  - RailSem19 is almost entirely daytime, so night frames are out-of-distribution for the model.
  - As a result, the predicted path jitters or disappears. **Night corridor detection is currently not reliable.**

---

## 8. Fusion Pipeline: How It Works

Version history:
- **v1** (`a7b0269`): baseline YOLO + TEP-Net overlay.
- **v2/v3** (`68ea8b5`): a perspective-aware corridor.
- **v4** (`e06f933`): adds distance estimation and tiered alerts, and was later switched to the fine-tuned model (`c156312`, `489b77a`).

### 8.1 Corridor construction (`build_corridor_and_rails`)
For each pair of left/right rail points from TEP-Net:
- Compute the centre-line and the half-gauge width in pixels.
- **Widen it ×3** (`EXPAND_FACTOR = 3.0`) to get a safety corridor. This covers the train body and the clearance envelope, not just the rails. The corridor narrows naturally with perspective as the track recedes.
- Record the **rail width in pixels for every image row**, and interpolate between rows where TEP-Net gives no points.
- Fill the resulting polygon to get a binary mask, shown as the green overlay.

### 8.2 Threat test
- Each detection's **foot point** is the bottom-centre of its box, i.e. where the object touches the ground.
- If the foot point lies inside the corridor mask, the object is a **THREAT** (red box). Otherwise it is drawn grey and ignored (see `screenshots/ignored_objs.png`).

### 8.3 Distance estimation
Sri Lanka uses **broad gauge, 1.676 m between the rails**. At the image row where an object stands, the rail spacing in pixels acts as a ruler:

```
focal_px   = (frame_width / 2) / tan(HFOV / 2)     # HFOV assumed 60°
distance_m = focal_px × 1.676 / rail_width_px(row)
```

### 8.4 Alerts
- The closest threat in the frame sets the banner:
  - within **100 m** → **"!! BRAKE NOW !! (Xm)"** in red;
  - otherwise → **"CAUTION (Xm)"** in orange.
- The live demo also plays `alert.wav`, with a 1 s cooldown for BRAKE and 2 s for CAUTION.

### 8.5 Two runtime modes

| | `fusion.py` (offline) | `live_demo.py` (real-time) |
| :--- | :--- | :--- |
| Purpose | Render annotated output video | Live on-screen demo |
| Detector | `railguard_best.pt`, 1280 px, CUDA | `yolov8n.pt` (stock COCO), 416 px, max 10 dets |
| TEP-Net | `chromatic-laughter-5`, CUDA | `logical-tree-1`, CPU |
| Scheduling | Both models every 2nd frame | Background worker thread; TEP-Net every 3rd cycle; display paced to the source FPS so playback stays smooth |
| Output | `data/videos/results/*.mp4` | OpenCV window with inference FPS and audio |

`railguard_core.py` contains the same logic as importable functions: `load_models`, `build_corridor_and_rails`, `focal_from_fov`, `estimate_distance_m`, `classify_threats`.

### 8.6 Evidence
- `screenshots/brake_now.png`: a person standing between the rails at ~22 m triggers BRAKE NOW, while the people on the left track are correctly ignored.
- `screenshots/caution.png` and `screenshots/ignored_objs.png`: further examples.
- Full processed rides: `fusion_full_20min_smooth.mp4` and `fusion_v4_2min_smooth.mp4`.

---

## 9. Mobile App (Flutter / Android)

### 9.1 Stack
- Flutter (Dart SDK ^3.12), targeting **Android** (the iOS and desktop scaffolding is the Flutter default).
- Packages used: `camera`, `tflite_flutter`, `image`, `permission_handler`.
- Declared but **not yet used**: `audioplayers` (for alerts) and `geolocator` (for location).
- Android config:
  - camera, fine-location and internet permissions;
  - `.tflite` files are stored uncompressed;
  - the duplicate `tensorflow-lite-api/gpu` modules are excluded;
  - `androidx.core` is pinned to 1.12.0 for dependency compatibility.

### 9.2 How it works (`lib/main.dart` + `lib/detector.dart`)
1. **Startup**: requests camera and location permissions, then loads `railguard_mobile_320_float32.tflite` and `labels.txt` from the assets.
2. **Camera**: opens the first camera at `ResolutionPreset.low` and streams YUV420 frames.
3. **Throttling**: only **every 8th frame** is processed, and a frame is skipped if the previous inference is still running.
4. **Pre-processing**: YUV420 → RGB conversion, pixel by pixel in Dart, then a resize to 320×320, a rotation to make the frame upright (sensor vs device orientation), and normalisation to 0–1.
5. **Inference**: `Interpreter.run` produces the `[1, 11, 2100]` tensor.
6. **Post-processing**:
   - keep the best class score per anchor, with confidence ≥ 0.35;
   - convert centre/size to corner coordinates;
   - per-class NMS at IoU 0.45, keeping at most 20 boxes.
7. **UI**: a full-screen camera preview with red boxes and labels on top, plus a "RAILGUARD" HUD showing the detection count, inference time, FPS and frames processed.

### 9.3 What the app does *not* do yet
- No ego-path corridor (TEP-Net is not on the phone), so it **cannot tell on-track threats from off-track objects**.
- No distance estimation and no BRAKE/CAUTION alerts or sound.
- No GPS or location use, even though the permission is requested.

---

## 10. Camera Hardware (ELP 4K USB)

The `tools/` scripts show that OpenCV's default **DirectShow** backend captures uncompressed YUY2. That saturates USB 2.0 (~40 MB/s), giving only 1.5 FPS at 4K and 2.2 FPS at 1080p.

| Backend | Resolution | Format | Measured FPS |
| :--- | :--- | :--- | :--- |
| DSHOW | 4K | YUY2 | 1.5 |
| DSHOW | 1080p | MJPG | 23.7 |
| **MSMF** | 1080p | MJPG | **29.8** |
| **MSMF** | **4K** | MJPG | **29.6** |

**Rule:** open the camera with Media Foundation (`cv2.CAP_MSMF`) and set the `MJPG` FOURCC both before and after setting the resolution. `tools/camera.py → open_camera()` wraps this. The result is **full 4K at ~30 FPS**, which addresses the long-range resolution limit from §6.4.

---

## 11. Evaluation Results

### 11.1 Speed (100 frames of `test2min.mp4`, RTX 4050 vs CPU)

| Model | Device | Setting | Latency | FPS |
| :--- | :--- | :--- | :--- | :--- |
| YOLO | CUDA | 640 px | 11.8 ms | 84.7 |
| YOLO | CUDA | 1280 px | 24.1 ms | 41.4 |
| YOLO | CPU | 416 px | 36.4 ms | 27.5 |
| YOLO | CPU | 1280 px | 205.0 ms | 4.9 |
| TEP-Net | CUDA | logical-tree-1 | 56.8 ms | 17.6 |
| TEP-Net | CUDA | chromatic-laughter-5 | 90.0 ms | 11.1 |
| TEP-Net | CPU | logical-tree-1 | 74.7 ms | 13.4 |

Takeaways:
- **TEP-Net is the bottleneck.** This is why it runs every 2nd–3rd frame while YOLO runs on every frame.
- **640 px is the GPU sweet spot.**
- 1280 px on CPU is too slow for real-time use.

### 11.2 Accuracy
See §6.2. The full curves and confusion matrices are in `results/eval_detection/` and `results/training_run1/`.

---

## 12. Known Issues & Gaps (found while preparing this summary)

| # | Issue | Where | Impact |
| :--- | :--- | :--- | :--- |
| 1 | ✅ **Fixed (in code; still to test on a phone).** The TFLite boxes are in pixels (0–320) but were treated as 0–1. Changes: `parseOutput` now divides by `inputSize` and clamps; frames are rotated upright using the sensor and device orientation before inference; the overlay is drawn as `CameraPreview`'s child at the true aspect ratio; the output buffer is sized from the model's tensor shape. | `detector.dart`, `main.dart` | Covered by `test/detector_test.dart` (6 tests). |
| 2 | ✅ **Fixed.** Fusion v4 filtered with *COCO* IDs `[0,2,3,5,7,19,20]`, but `railguard_best.pt` uses 0–6, so car, truck and elephant were silently dropped. Filtering now goes by class name (`railguard_core.ALLOWED_NAMES` + `class_ids()`). Re-run on `test2min`: 1,383 car and 187 truck detections now appear. | `fusion.py`, `live_demo.py`, `railguard_core.py` | Outputs regenerated as `fusion_v5_*.mp4`. Older `fusion_finetuned_*` videos still have the bug. |
| 3 | The live demo uses stock COCO `yolov8n.pt`, not the fine-tuned model. | `live_demo.py` | The live demo does not reflect the fine-tuning work. |
| 4 | The fusion logic is copy-pasted in three files; `railguard_core.py` exists but is not imported. | `fusion.py`, `live_demo.py` | Changes can drift between the scripts. |
| 5 | Distance relies on an **assumed 60° HFOV**, not a calibrated camera. | fusion | Absolute distances are approximate until the ELP camera is calibrated. |
| 6 | The live demo reads a video file; the 4K camera is not connected yet. | `live_demo.py` | `open_camera()` is ready but unused. |
| 7 | Night ego-path is unreliable. | TEP-Net | No reliable corridor at night, so threats cannot be filtered. |
| 8 | Small dataset: 43 val images. Only **one** elephant is labeled in the whole dataset (`frame_0050`), and the model scores it at just 0.07 confidence. There are no cow labels. | data | The model cannot reliably detect elephants or cows yet; more animal data is needed. |
| 9 | Pixel-by-pixel YUV→RGB in Dart is CPU-heavy. | `detector.dart` | Forces the 8-frame skip and caps the mobile FPS. |
| 10 | Mobile housekeeping (the failing default `widget_test.dart` and stale 640/8400 comments are now fixed): the unused 44.6 MB TFLite file bloats the APK; the app ID is `com.example.*` and release builds are signed with the debug key. | mobile app | Cleanup needed before any release build. |
| 11 | Reproducibility: no `requirements.txt` for rail-guard; absolute paths in `export_mobile.py`; TEP-Net lives outside the repo (with a modified `requirements.txt`); the README is empty. | repo | Hard to set up on another machine. |

---

## 13. Recommended Next Steps

1. **Quick fixes:** issues #1 (mobile box scale) and #2 (fusion class filter), then re-render the demo videos.
2. **Consolidate** `fusion.py` and `live_demo.py` onto `railguard_core.py`, and switch the live demo to the fine-tuned model.
3. **Connect the ELP camera** to the live demo via `open_camera()`, and **calibrate it** to replace the assumed 60° HFOV.
4. **Mobile phase 2:**
   - port the corridor logic, possibly with a lightweight TEP-Net TFLite export or a simpler track-region heuristic;
   - add distance estimation and BRAKE/CAUTION alerts using `audioplayers`;
   - use `geolocator` for location and speed logging;
   - move the YUV conversion to native code or the GPU delegate.
5. **Night performance:**
   - collect and label night frames;
   - consider fine-tuning TEP-Net on night data, or a fallback corridor when TEP-Net confidence is low.
6. **Grow the dataset**, especially animals (cow, elephant) and trucks, and re-evaluate.
7. **Repo hygiene:** a proper README, `requirements.txt`, setup instructions for the TEP-Net dependency, and an updated widget test.
8. **Backend** (planned folder): decide on scope, e.g. incident logging or fleet dashboard, or remove the folder.
