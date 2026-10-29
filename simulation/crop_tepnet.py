"""Software zoom: does TEP-Net reach further on a cropped, upscaled image?

    python simulation/crop_tepnet.py                                   # rows 500-620 of wide_pitch_p0
    python simulation/crop_tepnet.py --view wide_pitch_p0 --rows 480 700

Crops the given image rows (centred on --cx, keeping the 16:9 shape), upscales
the crop to 1920x1080, runs TEP-Net on it, maps the rails back to the
original image's pixels and scores them against the render's truth exactly as
validate_tepnet.py does (same formula, same fx, original pixels).

Outputs: outputs/evaluation/tepnet_sim_{view}_crop{y0}-{y1}.csv,
         outputs/figures/tepnet_sim_{view}_crop{y0}-{y1}.png (on the original image)
"""

import argparse

import cv2
from PIL import Image

from railguard.segmentation.tepnet import DEFAULT_MODEL, load_tepnet
from validate_tepnet import compare, load_render   # simulation/validate_tepnet.py

OUT_W, OUT_H = 1920, 1080


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--view", default="wide_pitch_p0")
    ap.add_argument("--rows", nargs=2, type=int, default=(500, 620), metavar=("Y0", "Y1"))
    ap.add_argument("--cx", type=float, default=960.0, help="crop centre column")
    args = ap.parse_args()

    bgr = load_render(args.view)
    h, w = bgr.shape[:2]
    y0, y1 = args.rows
    crop_h = y1 - y0
    crop_w = round(crop_h * OUT_W / OUT_H)
    x0 = int(round(min(max(args.cx - crop_w / 2, 0), w - crop_w)))
    crop = bgr[y0:y1, x0:x0 + crop_w]
    big = cv2.resize(crop, (OUT_W, OUT_H), interpolation=cv2.INTER_CUBIC)
    sx, sy = crop_w / OUT_W, crop_h / OUT_H
    print(f"Crop x {x0}-{x0 + crop_w}, y {y0}-{y1} ({crop_w}x{crop_h}) upscaled {OUT_W / crop_w:.1f}x")

    tepnet = load_tepnet(DEFAULT_MODEL, "cuda")
    ego = tepnet.detect(Image.fromarray(cv2.cvtColor(big, cv2.COLOR_BGR2RGB)))
    back = None
    if ego is not None:   # crop-upscaled pixels -> original pixels
        back = tuple([(x0 + float(x) * sx, y0 + float(y) * sy) for x, y in rail] for rail in ego)
    compare(args.view, back, h, tag=f"{args.view}_crop{y0}-{y1}", image=bgr)
    cv2.imwrite(__import__("os").path.join(__import__("os").path.dirname(__file__), "..", "outputs", "figures",
                                           f"tepnet_sim_{args.view}_crop{y0}-{y1}_input.png"), big)


if __name__ == "__main__":
    main()
