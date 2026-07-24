import os
import sys
import subprocess
from ultralytics import YOLO

PT_MODEL = r"C:\Users\USER\runs\detect\railguard_mobile\weights\best.pt"
OUT_DIR = r"c:\Users\USER\Desktop\GitHub Projects\rail-guard\ml\detection\railguard_mobile_320_saved_model"

print(f"Exporting PyTorch model {PT_MODEL} to ONNX at 320x320...")
model = YOLO(PT_MODEL)
onnx_path = model.export(format="onnx", imgsz=320)

print("Converting ONNX to TFLite 320x320 using onnx2tf...")
cmd = [
    sys.executable, "-m", "onnx2tf",
    "-i", onnx_path,
    "-o", OUT_DIR
]
subprocess.run(cmd, check=True)
print("Done. TFLite models exported in ml/detection/railguard_mobile_320_saved_model/")
