# rail-guard

## Setup

```
python -m venv venv
venv\Scripts\pip install -e .
git submodule update --init
```

`pip install -e .` makes `import railguard` work from any folder. TEP-Net weights are not in git; see `third_party/README.md`.

## Camera mounting

Recommended: **telephoto (50 mm) tilted 1° below horizontal, on straight or gently curved track** (see the curve requirement below). TEP-Net finds the track best when the horizon sits high in the frame, so a slight downward tilt extends its range; tilting up shortens it.

Accurate range (TEP-Net's distance error within ±10%) in the Blender pitch sweep, and how often the measured distance was *further* than the truth (the unsafe direction):

| Lens | Pitch | Accurate range | Median error | Readings further than truth |
|---|---|---|---|---|
| **Telephoto 50 mm** | **1.0° down** | **35–610 m** | −3.1% | **0 of 412** |
| Telephoto 50 mm | 0.5° down | 42–490 m | +1.5% | 209 of 242 (worst +3.6%) |
| Telephoto 50 mm | level | 53–194 m | −1.8% | 27 of 142 |
| Wide 5 mm | 3° down | 5–73 m | +0.6% | 147 of 206 (worst +5.1%) |
| Wide 5 mm | level | 5–29 m | −5.9% | 0 of 100 |

Accurate range by track curvature:

| Lens | Straight | 1000 m curve | 500 m curve | 300 m curve |
|---|---|---|---|---|
| Wide 5 mm, 3° down | 5–73 m | 5–39 m (5–51 m)* | 5–19 m (5–32 m)* | 5–19 m (5–32 m)* |
| Telephoto 50 mm, 0.5° down | 42–490 m | 42–82 m | **unsafe: false track**** | **unsafe: false track**** |

Measured with TEP-Net on renders from `simulation/build_scene.py --sweep` (`simulation/validate_tepnet.py`; telephoto curves rendered at 0.5° down, but the curve limit is horizontal and does not depend on pitch).
\* In brackets: the same radius in an earlier, independently built scene. On curves TEP-Net's error sits right at the ±10% cut-off around 20–30 m, so a shift of about 4 percentage points between the two scenes moves the boundary from about 32 m to about 19 m; neither number is wrong. Read it as roughly 20–30 m.
\*\* The right-hand rail is outside the frame from the first visible row, so no rail spacing can be measured — but TEP-Net still returns rails, and they are not the track.

**Safety requirement: the telephoto configuration must not be used on curves tighter than about 500 m radius.** There, track detection fails silently rather than degrading: TEP-Net returns a confident but false ego-path, so the corridor is in the wrong place and the on-track gate filters the wrong region — real obstacles can be excluded and irrelevant ones admitted. Lens selection by curvature (telephoto on straight track, wide on curves) is what the varifocal lens is for, and it is a safety requirement, not an optimisation. On curves tighter than about 500 m radius, track detection reaches roughly 20–30 m whatever the lens.

Simulation only (clean single-track renders); not yet confirmed on real ELP footage. Braking distance is 300–500 m, which only the telephoto reaches, and only on straight track.

Set the pitch in the config so distances are measured along the track, not along the camera's line of sight (`railguard.core.distance.depth_to_ground`):

```python
PipelineConfig.for_mounting("wide")            # 3 deg down
PipelineConfig.for_mounting("tele")            # 1 deg down
PipelineConfig(camera_pitch_deg=-1.0, camera_height_m=1.805)   # measured values
```

`for_mounting("tele")` assumes straight or gently curved track (radius above about 500 m).

`PipelineConfig()` keeps pitch 0 (no correction), for footage filmed at an unknown angle. `camera_height_m` is the camera's height above the rail tops.

### Distance safety margin

`PipelineConfig.distance_margin` (default 0.10) makes the alert treat every object as that much closer than measured: the braking comparison uses `distance × (1 − margin)`; displayed distances are unchanged. An object whose distance is over-read by less than the margin still triggers BRAKE NOW in time.

The worst over-read measured in the simulation (`experiments/e2_distance/distance_accuracy.py`, 5,808 readings over every render) is **+7.2%** (wide, 3° down, straight track, 0–50 m). With a 5% margin, 32 readings were still further than the truth; with 10%, **none are**, for every mounting. The margin sits above 7.2% rather than at it because 7.2% is the worst case of clean single-track renders, not of real footage: real ELP video adds lens distortion, calibration error in fx, vibration and track wear, none of which the simulation contains. At 400 m braking distance, 10% means alerting from about 444 m measured instead of 400 m.
