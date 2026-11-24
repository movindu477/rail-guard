"""Replace the labels of frames already merged into a test set.

    python training/relabel_merged.py --from data/dataset/testset_manual_c --dry-run
    python training/relabel_merged.py --from data/dataset/testset_manual_c

Why this exists
---------------
A batch that has already been merged cannot be merged again: merge_testset.py
would append all its frames a second time under new numbers, silently
duplicating every box and corrupting every count built on the set.

But a batch sometimes needs re-labelling after the merge. On 24 Nov 2026
batch C was accepted, then its per-band recall was found to be 16 out of 16 in
the two larger size bands where the established rates were 0.48 and 0.69 - the
signature of only the easily-visible objects having been labelled. The frames
were right; the labels were incomplete.

This copies corrected labels onto the frames already in the destination,
matching them by IMAGE CONTENT, not by position in a sorted list. A filename
offset worked out by hand is the obvious way to do this and the easy way to
put every label on the wrong frame; a hash comparison cannot drift.

Every source frame must be found exactly once in the destination, or nothing
is written.
"""

import argparse
import glob
import hashlib
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.join(ROOT, "data", "dataset", "testset_manual")
NAMES = ["person", "car", "motorcycle", "bus", "truck", "cow", "elephant"]


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def count_boxes(path):
    if not os.path.exists(path):
        return None
    return len([l for l in open(path).read().splitlines() if l.strip()])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="src", required=True)
    ap.add_argument("--into", default=DEST)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    src_imgs = sorted(glob.glob(os.path.join(args.src, "images", "*.jpg")))
    dst_imgs = sorted(glob.glob(os.path.join(args.into, "images", "*.jpg")))
    if not src_imgs:
        raise SystemExit(f"no images in {args.src}")

    print(f"hashing {len(dst_imgs)} destination frames...")
    by_hash = {}
    for p in dst_imgs:
        by_hash.setdefault(digest(p), []).append(p)

    plan, problems = [], []
    for s in src_imgs:
        d = by_hash.get(digest(s), [])
        if len(d) == 0:
            problems.append(f"{os.path.basename(s)}: not found in {args.into}")
        elif len(d) > 1:
            problems.append(f"{os.path.basename(s)}: matches {len(d)} destination frames")
        else:
            plan.append((s, d[0]))

    if problems:
        print(f"\nREFUSED, {len(problems)} problem(s). Nothing written:")
        for p in problems[:20]:
            print("   " + p)
        raise SystemExit(1)

    changed, before, after = [], 0, 0
    for s, d in plan:
        s_lab = os.path.join(args.src, "labels",
                             os.path.splitext(os.path.basename(s))[0] + ".txt")
        d_lab = os.path.join(args.into, "labels",
                             os.path.splitext(os.path.basename(d))[0] + ".txt")
        if not os.path.exists(s_lab):
            raise SystemExit(f"{s_lab} is missing: a frame with no label file is "
                             "not a frame with nothing in it")
        nb, na = count_boxes(d_lab) or 0, count_boxes(s_lab)
        before += nb
        after += na
        if nb != na:
            changed.append((os.path.basename(d), nb, na))

    print(f"{len(plan)} frames matched by image content")
    print(f"boxes: {before} -> {after}  ({after - before:+d})")
    if changed:
        print(f"{len(changed)} frames change:")
        for name, nb, na in changed[:40]:
            print(f"   {name}  {nb} -> {na}")
        if len(changed) > 40:
            print(f"   ... and {len(changed) - 40} more")
    else:
        print("no frame changes")

    if args.dry_run:
        print("\ndry run: nothing written")
        return

    for s, d in plan:
        s_lab = os.path.join(args.src, "labels",
                             os.path.splitext(os.path.basename(s))[0] + ".txt")
        d_lab = os.path.join(args.into, "labels",
                             os.path.splitext(os.path.basename(d))[0] + ".txt")
        shutil.copy2(s_lab, d_lab)
    print(f"\nreplaced labels for {len(plan)} frames in {args.into}")
    print("Next: re-run eval_precision.py and compare_models.py.")


if __name__ == "__main__":
    main()
