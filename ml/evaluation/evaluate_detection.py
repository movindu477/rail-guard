"""Detection accuracy evaluation — produces mAP, precision, recall per class."""
from ultralytics import YOLO
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODEL = os.path.join(ROOT, "ml", "detection", "railguard_best.pt")
DATA = os.path.join(ROOT, "data", "dataset", "yolo", "railguard.yaml")

def main():
    model = YOLO(MODEL)
    metrics = model.val(
        data=DATA,
        imgsz=1280,
        device=0,
        split="val",
        plots=True,
        project=os.path.join(ROOT, "results"),
        name="eval_detection",
    )

    print("\n=== RESULTS ===")
    print(f"mAP50      : {metrics.box.map50:.4f}")
    print(f"mAP50-95   : {metrics.box.map:.4f}")
    print(f"Precision  : {metrics.box.mp:.4f}")
    print(f"Recall     : {metrics.box.mr:.4f}")

    names = model.names
    print("\nPer class:")
    for i, c in enumerate(metrics.box.ap_class_index):
        print(f"  {names[c]:12s} AP50={metrics.box.ap50[i]:.4f}  AP50-95={metrics.box.ap[i]:.4f}")

if __name__ == "__main__":
    main()
