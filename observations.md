# Human Baseline Observations: Night Clip

## 1. How far ahead can you see the track in the headlight?
- **Visibility Distance:** The track is clearly visible for only about 20 to 30 meters ahead under the train's headlight beam.
- **Curvature Limitations:** When the track curves, visibility decreases even further as the headlight beam shines straight ahead, illuminating off-track vegetation instead of the oncoming path.

## 2. Is anything visible beside the track, or only the lit corridor?
- **Lit Corridor Only:** Only the narrow corridor swept by the headlight cone is visible. 
- **Surrounding Vegetation:** Dense green trees, bushes, and roadside foliage directly adjacent to the tracks are intermittently lit up. Everything outside of this cone is pitch black.

## 3. Any lights/signals/crossings in the clip?
- **Signals/Lights:** A bright blue/white vertical lens flare/light source is visible on the left side of the track around the 30-40 second mark (frame 6 in the extracted set), indicative of a signal post or stationary trackside light.
- **Structures:** A small cabin/hut structure is briefly illuminated on the right side of the tracks during that same section.
- **Crossings:** There are no apparent level crossings, gates, or active crossing signals visible in the clip.

## 4. TEP-Net Performance: Day vs. Night

### Day Performance Summary
- **High Accuracy:** Under clear daytime conditions, TEP-Net achieves excellent path-tracking capabilities on the RailSem19 test set, with Intersection over Union (IoU) scores ranging between **0.967 and 0.977** (using EfficientNet-B3 or ResNet-18 backbones).
- **Reliable Guidance:** In daylight, the model tracks ego-path corridors seamlessly across curves, junction switches, and straight tracks.

### Night Failure Analysis
- **Out-of-Distribution (OOD) Inputs:** The underlying training dataset (RailSem19) consists almost entirely of daytime scenarios. The model is untrained on nighttime features like high-contrast headlight glare, rail reflections, lens flares, and pitch-black surroundings.
- **Extreme Visibility Loss:** Because rails are invisible beyond the 20-30m headlight cone, the feature extraction layers cannot extract consistent track geometry.
- **Erratic Path Predictions:** The regression/segmentation heads collapse under night conditions, generating highly unstable, jittery, or completely missing ego-path corridors, making it unusable for safety filtering without alternative heuristics.
