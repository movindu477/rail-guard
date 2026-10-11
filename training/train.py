import argparse
from ultralytics import YOLO

def main():
    # Defaults reproduce the mobile (YOLOv8n) run; override for other experiments, e.g.
    #   python training/train.py --model models/yolov8s.pt \
    #       --data data/dataset/yolo/railguard_animals.yaml --name railguard_animals
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="models/yolov8n.pt")
    ap.add_argument("--data", default="data/dataset/yolo/railguard.yaml")
    ap.add_argument("--name", default="railguard_mobile")
    ap.add_argument("--epochs", type=int, default=80)
    ap.add_argument("--imgsz", type=int, default=1280)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--patience", type=int, default=20)
    args = ap.parse_args()

    model = YOLO(args.model)
    model.train(
        data=args.data,
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        patience=args.patience,
        device=0,
        workers=2,
        name=args.name,
    )
    print(f"Done. Model in runs/detect/{args.name}/weights/best.pt")

if __name__ == '__main__':
    main()
