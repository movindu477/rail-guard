import subprocess
from ultralytics import YOLO

print("Exporting PyTorch model to ONNX format...")
model = YOLO("models/railguard_best.pt")
onnx_file = model.export(format="onnx", imgsz=640)
print(f"Exported ONNX model: {onnx_file}")

print("Converting ONNX to TFLite format using onnx2tf...")
cmd = [
    "onnx2tf",
    "-i", "models/railguard_best.onnx",
    "-o", "models/railguard_best_saved_model"
]
subprocess.run(cmd, check=True)
print("Done. TFLite models exported in models/railguard_best_saved_model/")
