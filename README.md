# rail-guard

## Setup

```
python -m venv venv
venv\Scripts\pip install -e .
git submodule update --init
```

`pip install -e .` makes `import railguard` work from any folder. TEP-Net weights are not in git; see `third_party/README.md`.

## Camera mounting

Recommended: **telephoto (50 mm) tilted 0.5–1° below horizontal.** TEP-Net finds the track best when the horizon sits high in the frame, so a slight downward tilt extends its range; tilting up shortens it.

Accurate range (TEP-Net's distance error within ±10%) in the Blender pitch sweep:

| Lens | Pitch | Accurate range | Median error |
|---|---|---|---|
| Telephoto 50 mm | 0.5° down | 42–490 m | +1.5% |
| Telephoto 50 mm | 1.0° down | 35–610 m | −3.1% |
| Telephoto 50 mm | level | 53–194 m | −1.8% |
| Wide 5 mm | 3° down | 5–73 m | +0.6% |
| Wide 5 mm | level | 5–29 m | −5.9% |

Simulation only (clean single-track renders, `simulation/validate_tepnet.py --sweep`); not yet confirmed on real ELP footage. Braking distance is 300–500 m, so only the telephoto settings reach it.

Set the pitch in the config so distances are measured along the track, not along the camera's line of sight (`railguard.core.distance.depth_to_ground`):

```python
PipelineConfig.for_mounting("wide")            # 3 deg down
PipelineConfig.for_mounting("tele")            # 0.75 deg down
PipelineConfig(camera_pitch_deg=-1.0, camera_height_m=1.805)   # measured values
```

`PipelineConfig()` keeps pitch 0 (no correction), for footage filmed at an unknown angle. `camera_height_m` is the camera's height above the rail tops.
