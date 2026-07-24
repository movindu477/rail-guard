from ultralytics import YOLO

def main():
    model = YOLO("yolov8n.pt")
    model.train(
        data="data/dataset/yolo/railguard.yaml",
        epochs=80,
        imgsz=1280,
        batch=8,
        patience=20,
        device=0,
        workers=2,
        name="railguard_mobile",
    )
    print("Done. Model in runs/detect/railguard_mobile/weights/best.pt")

if __name__ == '__main__':
    main()
