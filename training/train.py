"""Fine-tune a YOLO detector for RailGuard.

Defaults are the Task 02 run: YOLOv8s at 1280 px (PipelineConfig.imgsz, so
training and inference resolution match) on railguard_animals.yaml, which has
real frames, negatives and synthetic animals, with cows and elephants in val.

    python training/train.py
    python training/train.py --batch 2          # if batch 4 runs out of GPU memory

The earlier mobile (YOLOv8n) run used:
    python training/train.py --model models/yolov8n.pt --data data/dataset/yolo/railguard.yaml \
        --name railguard_mobile --epochs 80 --batch 8 --patience 20
"""
import argparse
import os

from ultralytics import YOLO

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=os.path.join(ROOT, "models", "yolov8s.pt"))
    ap.add_argument("--data", default=os.path.join(ROOT, "data", "dataset", "yolo",
                                                   "railguard_animals.yaml"))
    ap.add_argument("--name", default="railguard_animals")
    ap.add_argument("--epochs", type=int, default=100)
    ap.add_argument("--imgsz", type=int, default=1280)
    ap.add_argument("--batch", type=int, default=4)
    ap.add_argument("--patience", type=int, default=25)
    args = ap.parse_args()

    model = YOLO(args.model)
    model.train(
        data=args.data,
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        patience=args.patience,
        amp=True,
        mosaic=1.0,
        scale=0.5,
        close_mosaic=10,
        fliplr=0.5,
        device=0,
        workers=2,
        name=args.name,
    )
    print(f"Done. Weights in {model.trainer.save_dir}\\weights\\best.pt")


if __name__ == "__main__":
    main()
