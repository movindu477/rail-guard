import subprocess
from ultralytics import YOLO

print("Exporting PyTorch model to ONNX format...")
model = YOLO("ml/detection/railguard_best.pt")
onnx_file = model.export(format="onnx", imgsz=640)
print(f"Exported ONNX model: {onnx_file}")

print("Converting ONNX to TFLite format using onnx2tf...")
cmd = [
    "onnx2tf",
    "-i", "ml/detection/railguard_best.onnx",
    "-o", "ml/detection/railguard_best_saved_model"
]
subprocess.run(cmd, check=True)
print("Done. TFLite models exported in ml/detection/railguard_best_saved_model/")
