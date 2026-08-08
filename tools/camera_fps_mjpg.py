import cv2, time

for backend_name, backend in [("DSHOW", cv2.CAP_DSHOW), ("MSMF", cv2.CAP_MSMF)]:
    print(f"\n--- Testing Backend: {backend_name} ---")
    cap = cv2.VideoCapture(1, backend)
    if not cap.isOpened():
        print(f"{backend_name}: could not open")
        continue

    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))

    for _ in range(10):
        cap.read()
    t0, n = time.time(), 0
    while n < 100:
        ok, f = cap.read()
        if ok:
            n += 1
    if n > 0 and f is not None:
        print(f"{backend_name} 1080p: {f.shape[1]}x{f.shape[0]}: {n/(time.time()-t0):.1f} fps")
    cap.release()
