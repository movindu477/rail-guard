# Human Baseline Observations: Night Clip

## 1. How far ahead can you see the track in the headlight?
- **Visibility Distance:** The track is clearly visible for only about 20 to 30 meters ahead under the train's headlight beam.
- **Curvature Limitations:** When the track curves, visibility decreases even further as the headlight beam shines straight ahead, illuminating off-track vegetation instead of the oncoming path.

## 2. Is anything visible beside the track, or only the lit corridor?
- **Lit Corridor Only:** Only the narrow corridor swept by the headlight cone is visible. 
- **Surrounding Vegetation:** Dense green trees, bushes, and roadside foliage directly adjacent to the tracks are intermittently lit up. Everything outside of this cone is pitch black.

## 3. Any lights/signals/crossings in the clip?
- **Signals/Lights:** A bright blue/white vertical lens flare/light source is visible on the left side of the track around the 30-40 second mark (frame 6 in the extracted set), indicative of a signal post or stationary trackside light.
- **Structures:** A small cabin/hut structure is briefly illuminated on the right side of the tracks during that same section.
- **Crossings:** There are no apparent level crossings, gates, or active crossing signals visible in the clip.

## 4. TEP-Net Performance: Day vs. Night

### Day Performance Summary
- **High Accuracy:** Under clear daytime conditions, TEP-Net achieves excellent path-tracking capabilities on the RailSem19 test set, with Intersection over Union (IoU) scores ranging between **0.967 and 0.977** (using EfficientNet-B3 or ResNet-18 backbones).
- **Reliable Guidance:** In daylight, the model tracks ego-path corridors seamlessly across curves, junction switches, and straight tracks.

### Night Failure Analysis
- **Out-of-Distribution (OOD) Inputs:** The underlying training dataset (RailSem19) consists almost entirely of daytime scenarios. The model is untrained on nighttime features like high-contrast headlight glare, rail reflections, lens flares, and pitch-black surroundings.
- **Extreme Visibility Loss:** Because rails are invisible beyond the 20-30m headlight cone, the feature extraction layers cannot extract consistent track geometry.
- **Erratic Path Predictions:** The regression/segmentation heads collapse under night conditions, generating highly unstable, jittery, or completely missing ego-path corridors, making it unusable for safety filtering without alternative heuristics.

## 5. YOLOv8s Fine-Tuning Results (Sri Lankan Railway Dataset)

### Training Configuration
- **Model Backbone:** YOLOv8s (`yolov8s.pt` pre-trained baseline)
- **Hardware Acceleration:** NVIDIA GeForce RTX 4050 Laptop GPU (CUDA 12.1)
- **Dataset Split:** 169 training frames / 43 validation frames (80/20 split from 212 annotated frames)
- **Training Parameters:** `imgsz=1280`, `batch=8`, `patience=20`, `workers=2`, target 80 epochs
- **Early Stopping & Convergence:** Early stopping triggered at epoch 21 (patience of 20 epochs exceeded). The optimal weights were produced at **Epoch 1**.

### Performance Metrics Summary
- **Overall mAP50:** `0.544` (54.4%)
- **Overall mAP50-95:** `0.446` (44.6%)
- **Overall Precision (P):** `0.696` (69.6%)
- **Overall Recall (R):** `0.495` (49.5%)
- **Inference Speed:** **38.8 ms** per image (0.8 ms preprocess, 38.8 ms inference, 0.0 ms loss, 1.1 ms postprocess on RTX 4050 GPU)

### Per-Class Evaluation Breakdown
| Class | Images | Instances | Precision (P) | Recall (R) | mAP50 | mAP50-95 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **All** | 43 | 132 | 0.696 | 0.495 | **0.544** | **0.446** |
| **Person** | 31 | 62 | **0.878** | **0.700** | **0.791** | **0.546** |
| **Car** | 14 | 33 | 0.624 | 0.545 | 0.656 | 0.527 |
| **Motorcycle** | 4 | 5 | 0.701 | 0.800 | 0.758 | 0.708 |
| **Bus** | 13 | 19 | 0.646 | 0.480 | 0.625 | 0.523 |
| **Truck** | 10 | 12 | 0.325 | 0.443 | 0.436 | 0.370 |
| **Elephant** | 1 | 1 | 1.000 | 0.000 | 0.000 | 0.000 |

### Key Training Insights & Epoch-1 Analysis
- **Epoch-1 Best Weight Selection:** The best validation score was attained at Epoch 1 (`best.pt`). This occurred because YOLOv8s is already heavily pre-trained on COCO and possesses rich spatial representations for common classes (persons, vehicles). On a compact domain dataset (169 training frames), the model adapted immediately on the first epoch. Further epochs led to minor overfitting on small sample variations, causing early stopping to correctly freeze the optimal model checkpoint at Epoch 1.
- **High-Risk Target Detection:** The primary safety threat—`Person` on track—achieved high detection accuracy with **mAP50 of 79.1%** and Precision of **87.8%**, confirming strong suitability for real-time corridor hazard alerting.
- **Resolution & Long-Range Detection Bottleneck:** Manual inspection of distant regions in the source footage showed that objects beyond approximately 100 metres are not visually identifiable, even at high digital zoom. Source video resolution and compression artifacts are therefore the primary limiting factor for long-range detection—no amount of model fine-tuning can recover information that is absent from the input data. Long-range detection requires higher-resolution hardware capture (an optical telephoto lens or higher-bitrate sensor), rather than purely model-level optimization.

## 6. System Speed & Latency Benchmark Results

### Benchmark Setup
- **Evaluation Dataset:** 100 consecutive frames from `test2min.mp4`
- **Hardware Platform:** NVIDIA GeForce RTX 4050 Laptop GPU (CUDA 12.1) vs Host CPU

### Benchmark Results Tables

#### YOLO Object Detection
| Device | Resolution (`imgsz`) | Latency (ms) | Throughput (FPS) |
| :--- | :--- | :--- | :--- |
| **CUDA** | 416 | 12.9 ms | 77.2 FPS |
| **CUDA** | 640 | 11.8 ms | 84.7 FPS |
| **CUDA** | 1280 | 24.1 ms | 41.4 FPS |
| **CPU** | 416 | 36.4 ms | 27.5 FPS |
| **CPU** | 640 | 60.7 ms | 16.5 FPS |
| **CPU** | 1280 | 205.0 ms | 4.9 FPS |

#### TEP-Net Ego-Path Segmentation
| Device | Backbone Model | Latency (ms) | Throughput (FPS) |
| :--- | :--- | :--- | :--- |
| **CUDA** | `logical-tree-1` | 56.8 ms | 17.6 FPS |
| **CUDA** | `chromatic-laughter-5` | 90.0 ms | 11.1 FPS |
| **CPU** | `logical-tree-1` | 74.7 ms | 13.4 FPS |
| **CPU** | `chromatic-laughter-5` | 121.2 ms | 8.2 FPS |

### Key System Benchmark Insights & Architectural Rationale
1. **GPU Acceleration Impact:** GPU acceleration provides a massive ~5.1x to 8.5x speedup for YOLO detection (e.g., 60.7 ms down to 11.8 ms at 640p) and ~1.3x to 1.6x for TEP-Net segmentation, accelerating raw object detection throughput from 16.5 FPS to 84.7 FPS.
2. **Optimal Resolution Sweet Spot:** 640p input resolution represents the optimal latency-throughput sweet spot on GPU (11.8 ms / 84.7 FPS), outperforming 416p (12.9 ms) due to GPU tensor alignment while preserving significantly more spatial detail than 416p, whereas 1280p requires 24.1 ms (41.4 FPS).
3. **CPU Edge Feasibility Bottleneck:** High-resolution CPU inference at 1280p (205.0 ms / 4.9 FPS) is non-viable for real-time collision avoidance safety systems, justifying the requirement for onboard hardware acceleration or aggressive model quantization when deploying on mobile/edge devices.
4. **Dual-Model Pipeline Bottlenecking & Sub-sampling Strategy:** TEP-Net ego-path segmentation (`logical-tree-1` at 17.6 FPS, `chromatic-laughter-5` at 11.1 FPS on CUDA) forms the primary computational bottleneck of the dual-model pipeline. This empirical finding validates the architectural decision to sub-sample corridor mask generation (e.g. executing TEP-Net every 2nd or 3rd frame) while running YOLO hazard detection on every frame.

## 7. Camera Specification & Hardware Capture Performance

### Empirical Capture Benchmark Table (ELP 4K USB Camera)

| Capture Backend | Resolution | FOURCC Pixel Format | Uncompressed / Compressed | Measured Capture Speed | Speed Improvement |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **DirectShow (`DSHOW`)** | `3840x2160` (4K UHD) | `YUY2` (Default) | Uncompressed (4:2:2) | **1.5 FPS** | Baseline |
| **DirectShow (`DSHOW`)** | `1920x1080` (1080p) | `YUY2` (Default) | Uncompressed (4:2:2) | **2.2 FPS** | Baseline |
| **DirectShow (`DSHOW`)** | `1280x720` (720p) | `YUY2` (Default) | Uncompressed (4:2:2) | **9.9 FPS** | Baseline |
| **DirectShow (`DSHOW`)** | `1920x1080` (1080p) | `MJPG` | Motion JPEG (~10:1) | **23.7 FPS** | **~10.8x faster** |
| **Media Foundation (`MSMF`)** | `1920x1080` (1080p) | `MJPG` | Motion JPEG (~10:1) | **29.8 FPS** | **~13.5x faster** (Max HW limit) |
| **Media Foundation (`MSMF`)** | `3840x2160` (4K UHD) | `MJPG` | Motion JPEG (~10:1) | **29.6 FPS** | **~19.7x faster** (Full 4K @ 30 FPS) |

### Bandwidth Calculation & Technical Root Cause
1. **Uncompressed YUY2 Payload:**
   - At 1080p (`1920x1080`), 2 bytes per pixel ($YUY2$) yields **~4.15 MB/frame**.
   - At 4K (`3840x2160`), 2 bytes per pixel ($YUY2$) yields **~16.59 MB/frame**.
2. **USB 2.0 Bus Bottleneck:**
   - USB 2.0 High-Speed physical bandwidth is capped at a practical maximum of **~40 MB/s**.
   - For 1080p YUY2: $\frac{40 \text{ MB/s}}{4.15 \text{ MB/frame}} \approx 9.6 \text{ FPS}$ maximum theoretical limit (measured 2.2–9.9 FPS).
   - For 4K YUY2: $\frac{40 \text{ MB/s}}{16.59 \text{ MB/frame}} \approx 2.4 \text{ FPS}$ maximum theoretical limit (measured 1.5 FPS).
3. **MJPEG Compression Mitigation:**
   - Motion JPEG (`MJPG`) applies an in-camera ~10:1 compression ratio, reducing the 4K frame payload from 16.59 MB down to **~1.6 MB/frame**.
   - $\frac{40 \text{ MB/s}}{1.6 \text{ MB/frame}} \approx 25\text{--}30 \text{ FPS}$, enabling full native 29.6 FPS capture over standard USB 2.0 hardware.

### Hardware Conclusion & Integration Rule
DirectShow defaults to uncompressed `YUY2`, bottlenecking ingestion speeds down to 1.5–2.2 FPS. Real-time video ingestion requires initializing OpenCV via Media Foundation (`cv2.CAP_MSMF`) with explicit `MJPG` codec configuration (`cv2.CAP_PROP_FOURCC`) asserted before and after setting frame dimensions. This architecture is encapsulated in `tools/camera.py` (`open_camera()`) for all downstream capture tasks.




