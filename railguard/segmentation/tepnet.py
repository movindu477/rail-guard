"""TEP-Net ego-path model: locating the external repo and loading weights."""

import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# TEP-Net (irtrailenium/train-ego-path-detection) is cloned next to this repo.
TEPNET_ROOT = os.path.join(os.path.dirname(REPO_ROOT), "train-ego-path-detection")
DEFAULT_MODEL = "chromatic-laughter-5"


def load_tepnet(model_name=DEFAULT_MODEL, device="cuda"):
    """Load a TEP-Net detector by weights folder name.

    Its .detect(pil_image) returns the ego-path as (left_rail, right_rail)
    point lists for 'regression' models, or None when no path is found.
    """
    if not os.path.isdir(TEPNET_ROOT):
        raise FileNotFoundError(f"TEP-Net repo not found at {TEPNET_ROOT}")
    if TEPNET_ROOT not in sys.path:
        sys.path.insert(0, TEPNET_ROOT)
    from src.utils.interface import Detector

    return Detector(os.path.join(TEPNET_ROOT, "weights", model_name), None, "pytorch", device)
