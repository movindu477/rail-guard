"""Opening the ELP USB camera.

The property order matters more than anything else here, and gets it wrong
silently. Measured on the ELP, index 1, Windows, 25 Nov 2026:

    backend  order                      format   1080p fps
    DSHOW    fourcc, then size           YUY2         2.3
    DSHOW    size, then fourcc           MJPG        30.2
    DSHOW    fourcc, size, fourcc        MJPG        30.2
    DSHOW    + cap.set(CAP_PROP_FPS,30)  YUY2         2.3
    MSMF     any                         -      cannot set MJPG at all

Three things that are easy to get wrong:

1. **Setting the frame size resets the pixel format.** A fourcc set before the
   size is dropped, so the camera streams uncompressed YUY2 and the frame rate
   collapses. The format property still reads back MJPG afterwards, so a
   read-back is not proof: only the frame rate tells you.

2. **Asking for a frame rate prevents getting one.** cap.set(CAP_PROP_FPS, 30)
   resets the format to YUY2 and drops 1080p to 2.3 fps. The frame rate is not
   requested here, deliberately.

3. **MSMF cannot negotiate MJPG on this camera**, whatever the order. An
   earlier version of this file used MSMF on the belief that it was the only
   path to 4K at 30 fps; that is not what this camera does now.

1920x1080 is the default because it is both the fastest mode measured (30.2
fps, ahead of 720p at 23.7) and the most pixels across the rail gauge, which is
what distance estimation is measured from. 4K runs at 1.5 fps and is not usable
live.
"""

import cv2

MJPG = cv2.VideoWriter_fourcc(*"MJPG")


def fourcc_str(value):
    v = int(value)
    return "".join(chr((v >> (8 * i)) & 0xFF) for i in range(4))


def open_camera(index=1, width=1920, height=1080, backend=cv2.CAP_DSHOW,
                require_mjpg=True):
    """Opens the camera in MJPG at the given size.

    Raises RuntimeError if the camera will not open, or if `require_mjpg` and
    the stream is not MJPG: silently falling back to YUY2 costs a factor of
    thirteen in frame rate, which is worth stopping for rather than
    discovering later in a frame-rate figure nobody checked.
    """
    cap = cv2.VideoCapture(index, backend)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open camera index {index}")

    # Size FIRST, then the format: the other way round, the size change
    # silently resets the format to YUY2. Do not set CAP_PROP_FPS.
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FOURCC, MJPG)

    got = fourcc_str(cap.get(cv2.CAP_PROP_FOURCC))
    aw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    ah = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    if require_mjpg and got != "MJPG":
        cap.release()
        raise RuntimeError(
            f"camera {index} is streaming {got!r}, not MJPG, at {aw}x{ah}. "
            "Uncompressed video caps this camera at about 2 fps. Check the "
            "backend and that the frame size is set before the fourcc.")
    if (aw, ah) != (width, height):
        print(f"WARNING: asked for {width}x{height}, got {aw}x{ah}")
    return cap
