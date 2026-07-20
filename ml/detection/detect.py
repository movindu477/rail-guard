from ultralytics import YOLO

model = YOLO("yolov8n.pt")

results = model.predict(
    source="data/videos/test2min.mp4",
    save=True,
    conf=0.25,
    imgsz=1280,
    classes=[0, 2, 3, 5, 7, 19, 20],
    project="runs",
)

print("Done!")
