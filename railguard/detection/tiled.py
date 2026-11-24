"""Tiled (sliced) inference: run the detector on overlapping crops of the frame.

MEASURED AND NOT ADOPTED. Kept because the result is worth reproducing, and
because the measurement is the point. Enable with PipelineConfig(tiled=True).

What it does
------------
Runs the detector on the whole frame and then on a grid of overlapping crops,
so a 30 px object arrives at the network at roughly the size of a 120 px one,
then merges the boxes (IoU, plus containment to kill tile-edge fragments).

Why it was rejected
-------------------
On the 57-frame hand-labelled Sri Lankan day set, yolov8s, 24 November 2026.
Those labels are exhaustive, so a prediction matching no label is a genuine
false positive rather than an unlabelled object:

    mode                       preds  hits  recall  precision  FP/frame
    single pass                  120    39   0.386      0.325      1.42
    2x2 tiled, IoU merge only    188    43   0.426      0.229      2.54
    2x2 tiled, + containment     168    43   0.426      0.256      2.19

48 extra predictions to find 4 extra objects: 92% of what tiling adds is wrong.
Precision falls further than recall rises. For a braking system that is the
wrong trade: a missed hazard is dangerous once, but an alarm that is usually
wrong gets the system switched off, and then every hazard is missed.

Containment suppression removed 20 junk boxes at no cost to recall, so tile-edge
fragments were real but minor. The rest are spurious objects -- trackside clutter
read as hazards -- which no merging rule can fix.

What tiling did buy, before precision was measured
--------------------------------------------------
It was the only lever that moved the distant-object band, where input resolution
and model capacity both did nothing:

    resolution  1280 / 1536 / 1920   -> 20-50 px recall 0.083 / 0.042 / 0.083
    capacity    yolov8 s / m / l / x -> 20-50 px recall 0.083 / 0.042 / 0.042 / 0.083
    2x2 tiling  yolov8s / yolov8x    -> 20-50 px recall 0.167 / 0.167

That gain is real but rests on 24 boxes, and it is not worth the false-alarm
rate it costs. 3x3 was also tried and is worse than 2x2 (0.455 vs 0.475 overall):
smaller tiles lose context and cut objects more often than they help.

Cost on an RTX 4050 at imgsz 1280: yolov8s 26 ms plain, 91 ms tiled (11 fps).
"""


def tile_rects(w, h, cols, rows, overlap):
    """Tile rectangles in pixels, each grown by `overlap` of a tile side."""
    tw, th = w / cols, h / rows
    ox, oy = tw * overlap, th * overlap
    return [(max(0, int(c * tw - ox)), max(0, int(r * th - oy)),
             min(w, int((c + 1) * tw + ox)), min(h, int((r + 1) * th + oy)))
            for r in range(rows) for c in range(cols)]


def _nms(dets, thresh, contain=0.8):
    """dets: [(x1,y1,x2,y2,cls,conf)] in pixels. Greedy, within each class.

    Two suppression rules, not one:

    IoU >= thresh      the same object found in more than one pass.
    containment        this box lies `contain` or more inside a box already
                       kept. An object cut by a tile edge produces a PARTIAL
                       box, and half an object has LOW IoU with the whole one,
                       so plain IoU-NMS lets the fragment through as a separate
                       detection. Measured 24 Nov 2026: 2x2 tiling added 68
                       predictions to gain 4 true ones on the hand-labelled day
                       set, and fragments are the suspected source.
    """
    keep = []
    for d in sorted(dets, key=lambda d: d[5], reverse=True):
        x1, y1, x2, y2, cls, _ = d
        area = max(1e-9, (x2 - x1) * (y2 - y1))
        for kx1, ky1, kx2, ky2, kcls, _ in keep:
            if kcls != cls:
                continue
            iw = max(0.0, min(x2, kx2) - max(x1, kx1))
            ih = max(0.0, min(y2, ky2) - max(y1, ky1))
            inter = iw * ih
            if inter <= 0:
                continue
            union = (x2 - x1) * (y2 - y1) + (kx2 - kx1) * (ky2 - ky1) - inter
            if (union > 0 and inter / union >= thresh) or inter / area >= contain:
                break
        else:
            keep.append(d)
    return keep


def detect(model, frame, cfg, keep_ids):
    """Hazard detections for one frame as [(x1, y1, x2, y2, cls_id, conf)].

    Plain single-pass when cfg.tiled is False, otherwise the full frame plus a
    cfg.tile_cols x cfg.tile_rows grid, merged with NMS. The return shape is the
    same either way, so the pipeline does not branch.
    """
    h, w = frame.shape[:2]
    kw = dict(conf=cfg.conf_threshold, imgsz=cfg.imgsz, max_det=cfg.max_det,
              classes=keep_ids, device=cfg.device, verbose=False)

    crops = [(frame, 0, 0)]
    if cfg.tiled:
        crops += [(frame[y0:y1, x0:x1], x0, y0)
                  for x0, y0, x1, y1 in tile_rects(w, h, cfg.tile_cols, cfg.tile_rows,
                                                   cfg.tile_overlap)]

    dets = []
    for crop, ox, oy in crops:
        if crop.size == 0:
            continue
        r = model.predict(crop, **kw)[0]
        # Per-box access, not r.boxes.xyxy: iterating works for an ultralytics
        # Boxes object and for any stand-in that is just a list of boxes.
        for box in r.boxes:
            x1, y1, x2, y2 = box.xyxy[0]
            dets.append((float(x1) + ox, float(y1) + oy, float(x2) + ox, float(y2) + oy,
                         int(box.cls[0]), float(box.conf[0])))

    return _nms(dets, cfg.tile_nms_iou, cfg.tile_containment) if cfg.tiled else dets
