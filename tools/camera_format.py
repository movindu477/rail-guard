import cv2

def fourcc_str(v):
    v = int(v)
    return "".join([chr((v >> 8*i) & 0xFF) for i in range(4)])

for backend, name in [(cv2.CAP_DSHOW, "DSHOW"), (cv2.CAP_MSMF, "MSMF")]:
    cap = cv2.VideoCapture(1, backend)
    if not cap.isOpened():
        print(f"{name}: could not open")
        continue
    print(f"{name} default format: {fourcc_str(cap.get(cv2.CAP_PROP_FOURCC))}")
    ok = cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    print(f"{name} set MJPG returned: {ok}")
    print(f"{name} format after set: {fourcc_str(cap.get(cv2.CAP_PROP_FOURCC))}")
    cap.release()
