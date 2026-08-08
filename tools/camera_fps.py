import cv2, time

for w, h in [(3840, 2160), (1920, 1080), (1280, 720)]:
    cap = cv2.VideoCapture(1, cv2.CAP_DSHOW)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, w)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, h)
    for _ in range(10):
        cap.read()
    t0, n = time.time(), 0
    while n < 120:
        ok, f = cap.read()
        if ok:
            n += 1
    dt = time.time() - t0
    print(f"{f.shape[1]}x{f.shape[0]}: {n/dt:.1f} fps measured over {dt:.1f}s")
    cap.release()
