# On-phone detection (explored alternative, not built)

An earlier version of the app ran object detection on the phone itself: the
phone's camera fed a YOLOv8 model converted to TFLite (320 px input, float32)
and drew boxes over the live preview.

It was dropped when the design settled on a separate train unit doing the
detection (camera, TEP-Net track detection and YOLO on a laptop; see the
repository README). The phone app now only marks hazards with GPS and warns
about hazards ahead.

This folder is outside `lib/`, so none of it is compiled, and
`analysis_options.yaml` excludes it from analysis. It is kept for the report.

| File | What it is |
|---|---|
| `detector.dart` | YUV420 camera frame to RGB, rotation to upright, letterbox to 320 px, and parsing of the YOLO output tensor (confidence filter and NMS) |
| `detector_test.dart` | Unit tests for the above (box parsing, NMS, rotation) |
| `camera_screen.dart` | The last `lib/main.dart` with the camera: preview, frame skipping, TFLite inference and box drawing, alongside the GPS and Firestore code that replaced it |
| `assets/labels.txt` | Class names for the model |
| `assets/railguard_mobile_320_float32.tflite` | The model (12 MB, not in git: `*.tflite` is ignored) |

To run it again: move `detector.dart` back into `lib/` and the test into
`test/`, restore the `camera`, `tflite_flutter`, `image` and
`permission_handler` packages and the `assets/` entry in `pubspec.yaml`, the
CAMERA permission in `AndroidManifest.xml`, and `noCompress += "tflite"` in
`android/app/build.gradle.kts`.
