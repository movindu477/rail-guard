"""Report what is actually inside a RailSem19 download, before converting it.

    python training/railsem19_probe.py --dir data/dataset/railsem19

RailSem19 is described as 8,500 ego-perspective railway frames from 38
countries with both dense semantic segmentation and geometric annotations.
What it does NOT have is a ready-made obstacle benchmark, and the exact
layout of a download varies by release. This script reads the folder and
prints its real structure so the converter is written against the data in
hand rather than against a remembered format.

It writes nothing and changes nothing.
"""

import argparse
import collections
import json
import os

# The project's classes, for working out what RailSem19 can actually supply.
NAMES = ["person", "car", "motorcycle", "bus", "truck", "cow", "elephant"]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", required=True, help="the unpacked RailSem19 folder")
    ap.add_argument("--samples", type=int, default=3, help="JSON files to print in full")
    args = ap.parse_args()

    root = os.path.abspath(args.dir)
    if not os.path.isdir(root):
        raise SystemExit(f"Not a folder: {root}")

    print(f"== {root}\n")

    print("-- top level --")
    for name in sorted(os.listdir(root))[:40]:
        p = os.path.join(root, name)
        if os.path.isdir(p):
            n = sum(len(f) for _, _, f in os.walk(p))
            print(f"   {name}/  ({n} files)")
        else:
            print(f"   {name}  ({os.path.getsize(p)} bytes)")

    exts = collections.Counter()
    jsons, images = [], []
    for dirpath, _, files in os.walk(root):
        for f in files:
            ext = os.path.splitext(f)[1].lower()
            exts[ext] += 1
            full = os.path.join(dirpath, f)
            if ext == ".json":
                jsons.append(full)
            elif ext in (".jpg", ".jpeg", ".png"):
                images.append(full)
    print("\n-- file types --")
    for ext, n in exts.most_common(12):
        print(f"   {ext or '(none)'}: {n}")
    print(f"\n   {len(images)} images, {len(jsons)} json files")

    if not jsons:
        print("\nNo JSON annotations found. The converter will have to work from "
              "the dense segmentation masks instead; say so before writing it.")
        return

    # What annotation keys and labels actually appear, across the whole set.
    keys = collections.Counter()
    labels = collections.Counter()
    geom = collections.Counter()
    for jf in jsons:
        try:
            with open(jf, encoding="utf8") as f:
                d = json.load(f)
        except Exception as e:
            print(f"   unreadable: {jf}: {e}")
            continue
        if not isinstance(d, dict):
            continue
        keys.update(d.keys())
        for o in d.get("objects", []) or []:
            if isinstance(o, dict):
                labels[o.get("label", "(no label)")] += 1
                for g in ("boundingbox", "polygon", "polyline", "bbox"):
                    if g in o:
                        geom[g] += 1

    print("\n-- top-level JSON keys --")
    for k, n in keys.most_common(20):
        print(f"   {k}: {n}")

    print("\n-- object labels, with counts --")
    for lab, n in labels.most_common(40):
        mark = "  <= maps to one of ours" if lab.lower() in NAMES else ""
        print(f"   {lab}: {n}{mark}")

    print("\n-- geometry kinds on objects --")
    for g, n in geom.most_common():
        print(f"   {g}: {n}")

    usable = {lab: n for lab, n in labels.items() if lab.lower() in NAMES}
    print("\n-- what RailSem19 can supply for this project --")
    if usable:
        for lab, n in sorted(usable.items(), key=lambda x: -x[1]):
            print(f"   {lab}: {n} objects")
    else:
        print("   No object label matches our 7 classes directly. The mapping will "
              "need deciding by hand from the label list above.")

    print(f"\n-- {min(args.samples, len(jsons))} sample files in full --")
    for jf in jsons[:args.samples]:
        print(f"\n   === {os.path.relpath(jf, root)}")
        with open(jf, encoding="utf8") as f:
            text = json.dumps(json.load(f), indent=2)
        print("\n".join("   " + ln for ln in text.splitlines()[:60]))

    print("\nSend this output back before the converter is written.")


if __name__ == "__main__":
    main()
