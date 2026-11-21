"""Fetch real cow and elephant images from Open Images V7 as YOLO boxes.

    python training/fetch_openimages.py --per-class 1500
    python training/fetch_openimages.py --classes cow elephant person --per-class 800

Why only animals by default: the stock COCO weights already carry tens of
thousands of real person, car, motorcycle, bus and truck instances, and they
beat our fine-tune on human labels (0.386 vs 0.327). The measured gap in our
own data is animals: the audit found 0 cow and 1 elephant instance, and the
composited animals used instead reached 98% recall on synthetic images but
31% on real photographs. Real animal photographs are what is missing.

Output: data/dataset/openimages/{images,labels}/ in YOLO format, with class
ids in the project's order (see NAMES), plus provenance.csv and LICENCE.md.
Nothing here is hand-labelled; the boxes are Open Images' own.

Needs: pip install fiftyone
"""

import argparse
import csv
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data", "dataset", "openimages")

# The project's class order. Ids must match data/dataset/*/labels.txt.
NAMES = ["person", "car", "motorcycle", "bus", "truck", "cow", "elephant"]

# Open Images' own class names -> ours. "Cattle" is Open Images' cow class.
OI_TO_OURS = {
    "Person": "person",
    "Car": "car",
    "Motorcycle": "motorcycle",
    "Bus": "bus",
    "Truck": "truck",
    "Cattle": "cow",
    "Elephant": "elephant",
}
OURS_TO_OI = {v: k for k, v in OI_TO_OURS.items()}

LICENCE = """# Open Images V7 subset

Images: Flickr, CC BY 2.0, rights with their photographers.
Annotations: Google LLC, CC BY 4.0.
Source: https://storage.googleapis.com/openimages/web/index.html

Used here for non-commercial academic research. Images are not redistributed
with this repository (`data/` is gitignored). Re-fetch with
`python training/fetch_openimages.py`.
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--classes", nargs="*", default=["cow", "elephant"],
                    choices=NAMES, help="which of our classes to fetch (default: the two we lack)")
    ap.add_argument("--per-class", type=int, default=1500,
                    help="max images per class per split")
    ap.add_argument("--splits", nargs="*", default=["train", "validation"])
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    import fiftyone as fo
    import fiftyone.zoo as foz

    oi_classes = [OURS_TO_OI[c] for c in args.classes]
    print(f"Fetching {oi_classes} from Open Images V7, "
          f"up to {args.per_class} images per split")

    parts = []
    for split in args.splits:
        ds = foz.load_zoo_dataset(
            "open-images-v7",
            split=split,
            label_types=["detections"],
            classes=oi_classes,
            max_samples=args.per_class,
            dataset_name=f"oi7-{'-'.join(args.classes)}-{split}",
            overwrite=True,
        )
        parts.append((split, ds))

    # Rename Open Images labels to our names and drop every other class, so a
    # cow image carrying a "Dog" box does not bring an unlabelled object in.
    rows = []
    merged = fo.Dataset(name="railguard-openimages", overwrite=True)
    for split, ds in parts:
        for sample in ds:
            dets = sample["ground_truth"].detections if sample["ground_truth"] else []
            keep = []
            for d in dets:
                ours = OI_TO_OURS.get(d.label)
                if ours in args.classes:
                    d.label = ours
                    keep.append(d)
            if not keep:
                continue
            sample["ground_truth"] = fo.Detections(detections=keep)
            merged.add_sample(sample.copy())
            rows.append({
                "image": os.path.basename(sample.filepath),
                "split": split,
                "boxes": len(keep),
                "classes": " ".join(sorted({d.label for d in keep})),
                "source": "Open Images V7 (CC BY 4.0 annotations, CC BY 2.0 images)",
            })

    if os.path.isdir(args.out):
        shutil.rmtree(args.out)
    merged.export(
        export_dir=args.out,
        dataset_type=fo.types.YOLOv5Dataset,
        label_field="ground_truth",
        classes=NAMES,            # fixes ids to the project's order
        split="train",
    )

    with open(os.path.join(args.out, "provenance.csv"), "w", newline="", encoding="utf8") as f:
        w = csv.DictWriter(f, fieldnames=["image", "split", "boxes", "classes", "source"])
        w.writeheader()
        w.writerows(rows)
    with open(os.path.join(args.out, "LICENCE.md"), "w", encoding="utf8") as f:
        f.write(LICENCE)

    per_class = {c: 0 for c in args.classes}
    for r in rows:
        for c in r["classes"].split():
            per_class[c] += 1
    print(f"\n{len(rows)} images -> {args.out}")
    print("images containing each class:", per_class)
    print("Class ids follow NAMES:", {i: n for i, n in enumerate(NAMES)})
    print("\nNext: python training/audit_dataset.py to check the counts, then merge "
          "into the training split by video/source, never by frame.")


if __name__ == "__main__":
    main()
