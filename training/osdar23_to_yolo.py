"""Convert OSDaR23 (OpenLABEL) into YOLO boxes for the project's 7 classes.

    python training/osdar23_to_yolo.py
    python training/osdar23_to_yolo.py --stream rgb_highres_center --keep-png

Reads every `*_labels.json` in data/dataset/osdar23 and writes
data/dataset/osdar23_yolo/{images,labels}/ plus provenance.csv and
splits by sequence.

What OSDaR23 can and cannot supply (measured on the 10 downloaded sequences,
rgb_center stream):

    person        3,423 boxes  -> person        kept
    road_vehicle    510 boxes  -> car           kept (attribute type=car or van)
    animal          295 boxes  -> NOT MAPPED    species=otherAnimal, size=small.
                                                These are not cattle or elephants;
                                                mapping them would poison those
                                                classes. Real cow and elephant
                                                images come from Open Images
                                                (training/fetch_openimages.py).
    crowd             0 boxes  -> NOT MAPPED    one box around many people, which
                                                breaks the one-box-per-object rule
                                                in training/manual_testset_rules.md
    catenary_pole, signal_pole, buffer_stop, flame, signal, track, train,
    switch, transition, bicycle, group_of_bicycles -> not our classes

So these sequences give person and car only. No truck, bus, cow or elephant.

Heavily occluded boxes are dropped by default: an object 75% hidden teaches the
detector to fire on a sliver. --max-occlusion changes the cut.

OSDaR23 sensor data is CC BY-SA 3.0 DE and annotations CC0 1.0; see SOURCES.md.
Nothing here is hand-labelled by us, and none of it is used for evaluation.
"""

import argparse
import collections
import csv
import json
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "data", "dataset", "osdar23")
OUT = os.path.join(ROOT, "data", "dataset", "osdar23_yolo")

NAMES = ["person", "car", "motorcycle", "bus", "truck", "cow", "elephant"]
IDS = {n: i for i, n in enumerate(NAMES)}

# OSDaR23 road_vehicle carries a text attribute "type".
ROAD_VEHICLE_TO_OURS = {
    "car": "car",
    "van": "car",          # a van is nearer a car than a lorry at these sizes
    "truck": "truck",
    "bus": "bus",
    "motorcycle": "motorcycle",
}

# Occlusion buckets, worst last.
OCCLUSION_ORDER = ["0-25 %", "25-50 %", "50-75 %", "75-99 %", "100 %"]

# Which sequences are held out. Split is by sequence, never by frame:
# consecutive frames are near-identical and a frame split leaked once already.
VAL_PREFIXES = ("2_station", "5_station", "11_main", "21_station")


def text_attr(bbox, name):
    for t in (bbox.get("attributes") or {}).get("text", []):
        if t.get("name") == name:
            return t.get("val")
    return None


def our_class(obj_type, bbox):
    """The project class for this annotation, or None to drop it."""
    if obj_type == "person":
        return "person"
    if obj_type == "road_vehicle":
        return ROAD_VEHICLE_TO_OURS.get((text_attr(bbox, "type") or "").lower())
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default=SRC)
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--stream", default="rgb_center",
                    help="camera to convert (rgb_center or rgb_highres_center)")
    ap.add_argument("--max-occlusion", default="50-75 %", choices=OCCLUSION_ORDER,
                    help="drop boxes more occluded than this")
    ap.add_argument("--keep-png", action="store_true",
                    help="copy PNGs as-is instead of re-encoding to JPEG")
    args = ap.parse_args()

    cut = OCCLUSION_ORDER.index(args.max_occlusion)
    scenes = sorted(f for f in os.listdir(args.src) if f.endswith("_labels.json"))
    if not scenes:
        raise SystemExit(f"No *_labels.json in {args.src}")

    img_dir = os.path.join(args.out, "images")
    lbl_dir = os.path.join(args.out, "labels")
    for d in (img_dir, lbl_dir):
        os.makedirs(d, exist_ok=True)

    from PIL import Image

    rows, counts = [], collections.Counter()
    dropped = collections.Counter()
    split_files = {"train": [], "val": []}

    for scene_file in scenes:
        seq = scene_file[: -len("_labels.json")]
        split = "val" if seq.startswith(VAL_PREFIXES) else "train"
        with open(os.path.join(args.src, scene_file), encoding="utf8") as f:
            data = json.load(f)
        root = data.get("openlabel", data)
        objects = root.get("objects", {})

        for fidx, frame in sorted(root.get("frames", {}).items(), key=lambda x: int(x[0])):
            streams = (frame.get("frame_properties") or {}).get("streams") or {}
            uri = (streams.get(args.stream) or {}).get("uri")
            if not uri:
                dropped["frame: stream missing"] += 1
                continue
            src_img = os.path.join(args.src, uri.lstrip("/\\").replace("/", os.sep))
            if not os.path.exists(src_img):
                dropped["frame: image file missing"] += 1
                continue

            lines = []
            for uid, od in (frame.get("objects") or {}).items():
                otype = (objects.get(uid) or {}).get("type")
                for bbox in ((od.get("object_data") or {}).get("bbox") or []):
                    if bbox.get("coordinate_system") != args.stream:
                        continue
                    cls = our_class(otype, bbox)
                    if cls is None:
                        dropped[f"class not mapped: {otype}"] += 1
                        continue
                    occ = text_attr(bbox, "occlusion")
                    if occ in OCCLUSION_ORDER and OCCLUSION_ORDER.index(occ) > cut:
                        dropped[f"occluded {occ}"] += 1
                        continue
                    cx, cy, w, h = bbox["val"]
                    lines.append((IDS[cls], cx, cy, w, h))
                    counts[cls] += 1

            # A frame with no boxes is still a frame the detector must not fire
            # on, so it is kept with an empty label file.
            base = f"{seq}__{os.path.splitext(os.path.basename(src_img))[0]}"
            ext = ".png" if args.keep_png else ".jpg"
            dst_img = os.path.join(img_dir, base + ext)
            if args.keep_png:
                shutil.copy2(src_img, dst_img)
                W, H = Image.open(src_img).size
            else:
                im = Image.open(src_img).convert("RGB")
                W, H = im.size
                im.save(dst_img, "JPEG", quality=92)

            with open(os.path.join(lbl_dir, base + ".txt"), "w", encoding="utf8") as f:
                for cid, cx, cy, w, h in lines:
                    f.write(f"{cid} {cx / W:.6f} {cy / H:.6f} {w / W:.6f} {h / H:.6f}\n")

            split_files[split].append(os.path.abspath(dst_img))
            rows.append({"image": base + ext, "sequence": seq, "split": split,
                         "frame": fidx, "stream": args.stream, "boxes": len(lines),
                         "source_uri": uri})

    for split, paths in split_files.items():
        with open(os.path.join(args.out, f"{split}.txt"), "w", encoding="utf8") as f:
            f.write("\n".join(paths) + ("\n" if paths else ""))

    with open(os.path.join(args.out, "provenance.csv"), "w", newline="", encoding="utf8") as f:
        w = csv.DictWriter(f, fieldnames=["image", "sequence", "split", "frame",
                                          "stream", "boxes", "source_uri"])
        w.writeheader()
        w.writerows(rows)

    with open(os.path.join(args.out, "dataset.yaml"), "w", encoding="utf8") as f:
        f.write(f"path: {os.path.abspath(args.out)}\n")
        f.write("train: train.txt\nval: val.txt\n\nnames:\n")
        for i, n in enumerate(NAMES):
            f.write(f"  {i}: {n}\n")

    print(f"\n{len(rows)} frames -> {args.out}")
    print(f"  train {len(split_files['train'])}, val {len(split_files['val'])} "
          f"(split by sequence)")
    print("\nboxes kept:")
    for n in NAMES:
        print(f"  {n:12s} {counts.get(n, 0)}")
    print("\ndropped:")
    for k, v in dropped.most_common(12):
        print(f"  {k:34s} {v}")
    print("\nNo truck, bus, cow or elephant in these sequences. Cow and elephant "
          "come from training/fetch_openimages.py; truck and bus remain COCO-only.")


if __name__ == "__main__":
    main()
