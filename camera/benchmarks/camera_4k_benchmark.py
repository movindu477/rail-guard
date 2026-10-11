import cv2, time

cap = cv2.VideoCapture(1, cv2.CAP_MSMF)
cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 3840)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 2160)
cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))

for _ in range(10):
    cap.read()

t0, n = time.time(), 0
while n < 60:
    ok, f = cap.read()
    if ok:
        n += 1

if n > 0 and f is not None:
    print(f"4K Benchmark Result: {f.shape[1]}x{f.shape[0]}: {n/(time.time()-t0):.1f} fps")
cap.release()
