"""TEP-Net ego-path model: locating the submodule and loading weights."""

import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# TEP-Net (irtrailenium/train-ego-path-detection) is a git submodule.
TEPNET_ROOT = os.path.join(REPO_ROOT, "third_party", "train-ego-path-detection")
DEFAULT_MODEL = "chromatic-laughter-5"


def load_tepnet(model_name=DEFAULT_MODEL, device="cuda"):
    """Load a TEP-Net detector by weights folder name.

    Its .detect(pil_image) returns the ego-path as (left_rail, right_rail)
    point lists for 'regression' models, or None when no path is found.
    """
    if not os.path.isdir(os.path.join(TEPNET_ROOT, "src")):
        raise FileNotFoundError(
            f"TEP-Net code not found at {TEPNET_ROOT}. "
            "Run: git submodule update --init")
    weights = os.path.join(TEPNET_ROOT, "weights", model_name)
    if not os.path.isfile(os.path.join(weights, "best.pt")):
        raise FileNotFoundError(
            f"TEP-Net weights '{model_name}' not found at {weights}. "
            "See third_party/README.md for the download.")
    if TEPNET_ROOT not in sys.path:
        sys.path.insert(0, TEPNET_ROOT)
    from src.utils.interface import Detector

    return Detector(weights, None, "pytorch", device)
