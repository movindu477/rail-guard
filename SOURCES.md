# Footage sources

Video used for development and evaluation, where it came from, and what it may
be used to claim. The videos themselves are not in the repository (`data/` is
gitignored) and are not redistributed; rights stay with their creators. They
are used for non-commercial academic research only.

**Rule for footage from an unknown camera:** the focal length, mounting height
and pitch are not known, so pixel sizes cannot be turned into metres.
Results from such footage are limited to **detection and track results**
(whether objects and the track are found, recall, plausibility, pixel extent).
**No distance claims** are made from it.

## Night cab ride (E4a, illumination)

| Field | Value |
|---|---|
| URL | https://www.youtube.com/watch?v=-fM6i43dgNw |
| Channel | Train Enthusiast |
| Title | Fast Night Cab Ride in Sri Lanka Railways with Class M11 |
| Upload date | *to fill in: shown under the video on YouTube; not readable from the page fetch* |
| Downloaded | 12 Nov 2026 |
| Local file | `data/videos/raw/srilanka_night_full.mp4` |
| Format | 2520 x 1080, 30 fps, 13,652 frames (7.6 min) |
| Viewpoint | Forward-facing from the cab, centred on the track, lit by the train's headlight. Checked on 9 frames spread across the clip (12 Nov 2026). |
| Camera | Unknown: **detection and track results only, no distance claims** |
| Used in | `experiments/e4_illumination/day_vs_night.py` (E4a), `track_gate.py`; the night test set `data/dataset/testset_night/` (24 frames, 5–449 s, re-extracted 12 Nov 2026; its `provenance.csv` names this source) |

## Daytime ride (training data, manual test set, E1, E3, E4a)

| Field | Value |
|---|---|
| URL | **Not recoverable.** Downloaded from YouTube on 21 July 2026; the browser history no longer reaches back that far and the file carries no source metadata (checked 20 Nov 2026: the container holds only `creation_time`, no `purl`, title, artist or comment atom). No URL is given rather than a guessed one. |
| Channel | Not recoverable, as above |
| Title | Not recoverable, as above |
| Upload date | Not recoverable, as above |
| Downloaded | 21 July 2026, 11:13 Sri Lanka time (container `creation_time` 2026-07-21T05:43:20Z) |
| Local file | `data/videos/raw/srilanka_clean_full.mp4` (1886 x 934, 30 fps, 36,097 frames, 20.1 min, 1,141,477,769 bytes) |
| SHA-256 | `8505c46c81e6065d05a9de130e772def1779d8ac7fdf4b84c1da4f678edbe8cb` |
| Provenance status | **Unverifiable.** The file is held and every result from it is reproducible from it, and the checksum above identifies that exact file, but the footage cannot be independently re-obtained by a reader. Any claim resting on this footage is reported with that limitation stated. |
| Derived clips | `data/videos/processed/`: `test2min.mp4`, `test5min.mp4`, `trimmed_8min.mp4`, `full_20min.mp4` (1906 x 928) |
| Regeneration commands | `full_20min.mp4`: `ffmpeg -ss 00:00:05 -i data/videos/raw/srilanka_clean_full.mp4 -t 00:19:55 -c:v libx264 -crf 18 -c:a aac data/videos/processed/full_20min.mp4`<br>`trimmed_8min.mp4`: `ffmpeg -ss 00:00:00 -i data/videos/raw/srilanka_clean_full.mp4 -t 00:07:50 -vf "scale=1906:928" -c:v libx264 -crf 18 -c:a aac data/videos/processed/trimmed_8min.mp4` |
| Viewpoint | Forward-facing from the cab |
| Camera | Unknown: **detection and track results only, no distance claims**. Any metre figure computed from this footage (e.g. the E3 ranging limit) uses an *assumed* 60° field of view and is indicative only. |
| Used in | Task 02 dataset frames, the hand-labelled daytime test set (`data/dataset/testset_manual/`), E1 corridor, E3 range limit, E4a day side |

## Superseded: earlier night ride

| Field | Value |
|---|---|
| Source | *to fill in* |
| Original file | `data/videos/raw/srilanka_night_full.mp4`, **overwritten on 12 Nov 2026** by the night cab ride above (same file name). The earlier video is no longer on disk. |
| Surviving clip | `data/videos/processed/night5min.mp4` (1818 x 928, 3,363 frames), cut from the earlier video |
| Viewpoint | **Not forward-facing:** filmed from a side door or window; about a third of the frame is the carriage body (checked 12 Nov 2026) |
| Status | Replaced for E4a, so viewpoint is not mixed with illumination. |
| Old night test set | The first night test set (24 frames, never labelled) came from this **earlier** video. It was moved to `data/dataset/testset_night_old_sidedoor/` and replaced by a set from the cab ride (12 Nov 2026). Its `provenance.csv` names `srilanka_night_full.mp4`, a file name that now holds the cab ride. |

## Own recordings

| Footage | Camera | Notes |
|---|---|---|
| Calibration videos and images (`camera/calibration/`) | ELP USB camera, wide (5 mm) lens | Calibrated: fx = 2062 px (`calib_wide.npz`) |
| Blender renders (`simulation/renders/`) | Virtual camera, exact | Ground truth known: distance claims valid in simulation |

## Training data from public datasets (Task 02 retraining, from 21 Nov 2026)

No annotated Sri Lankan railway dataset exists, so training data is drawn from
public railway and general-object datasets. A domain gap therefore remains
between training and deployment conditions. **All reported accuracy comes from
the hand-labelled Sri Lankan test sets, never from these datasets.**

| Dataset | What it supplies | Licence | Annotation provenance |
|---|---|---|---|
| **OSDaR23** v1.2.0 | Railway-context persons and vehicles, Hamburg, Germany. 45 sequences, 1,534 multi-sensor frames, 204,091 annotations over 20 classes | Annotations CC0 1.0; sensor data CC BY-SA 3.0 DE | Hand-annotated for driverless train operation |
| **Open Images V7** | Real cow and elephant photographs, the two classes absent from our own data (audit found 0 cow, 1 elephant) | Annotations CC BY 4.0; images CC BY 2.0 | Google's own boxes |
| RailSem19 (pending access) | Railway viewpoint diversity, 38 countries | CC BY-NC 4.0 | Rail geometry hand-drawn; **dense object labels machine-generated by a pre-trained InplaceABN model — training only, never evaluation** |

OSDaR23 citation: Tilly, R.; Neumaier, P.; Schwalbe, K.; Klasek, P.; Tagiew, R.;
Denzler, P.; Klockau, T.; Boekhoff, M.; Koeppel, M. (2023). *Open Sensor Data for
Rail 2023* [Data set]. TIB. https://doi.org/10.57806/9mv146r0

Images from these datasets are not redistributed with this repository
(`data/` is gitignored). OSDaR23 sensor data is share-alike, so its frames are
not committed and are reproduced in the report only with attribution.

**Splitting rule.** OSDaR23 is split by named sequence, never by frame:
consecutive frames in a sequence are near-identical, and a frame-level split
already produced a leak once in this project (33 of 43 validation frames
neighboured a training frame).
