# Third-party code

## TEP-Net (`train-ego-path-detection/`)

RailGuard uses TEP-Net to find the train's ego-path, the rails the train will run on. It is included as a git submodule of
[irtrailenium/train-ego-path-detection](https://github.com/irtrailenium/train-ego-path-detection)
(MIT licence), and loaded through `railguard/segmentation/tepnet.py`.

### 1. Get the code

A plain `git clone` leaves this folder empty. Either clone with submodules:

```
git clone --recurse-submodules <rail-guard repo url>
```

or, in an existing clone:

```
git submodule update --init
```

### 2. Get the weights

The weights are not in git. Download
[egopath.zip](https://tasv.railenium.eu/egopath.zip) (the link given in the TEP-Net README), extract it, and copy these two folders from `egopath/weights/`:

| Folder | Backbone | Method | Used by |
| :--- | :--- | :--- | :--- |
| `chromatic-laughter-5` | EfficientNet-B3 | Regression | Default: offline video, augmentation, benchmarks |
| `logical-tree-1` | ResNet-18 | Regression | Live demo (faster), benchmarks |

Place them so the layout is:

```
third_party/train-ego-path-detection/weights/
├── chromatic-laughter-5/
│   ├── best.pt
│   └── config.yaml
└── logical-tree-1/
    ├── best.pt
    └── config.yaml
```

Only **regression** models work with RailGuard: the corridor and distance code need the left and right rail lines, which the classification and segmentation models do not return in that form.

The weights and ego-path annotations are licensed
[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) (non-commercial), following the RailSem19 dataset policy.

### 3. Python packages

Do **not** run `pip install -r requirements.txt` from the TEP-Net folder as it stands. Its last four lines (`onnx`, `onnxruntime`, `pycuda`, `tensorrt`) are only for TensorRT inference, which RailGuard does not use, and `pycuda` and `tensorrt` often fail to install on Windows.

RailGuard needs only TEP-Net's basic packages: `numpy`, `Pillow`, `PyYAML`, `torch`, `torchvision`, plus `opencv-python`.

### 4. Check it works

From the repo root:

```
python -c "from railguard.segmentation.tepnet import load_tepnet; load_tepnet('chromatic-laughter-5', 'cpu'); print('TEP-Net OK')"
```

If the code or the weights are missing, the error message says which.
