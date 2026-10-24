# Manual test sets: labelling rules

These rules define the ground truth for the two hand-labelled test sets. They
are part of the evaluation methodology and go in the report. They were fixed
before the first box was drawn and are not changed during labelling.

| Set | Folder | Frames | Source |
|---|---|---|---|
| Daytime | `data/dataset/testset_manual/` | 57 | day ride, the two validation stretches (86–204 s, 1034–1194 s), one frame every 5 s |
| Night (E4) | `data/dataset/testset_night/` | 24 | night ride, 0–118 s, one frame every 5 s |

Each folder has `provenance.csv` (source video and timestamp of every frame).

**Independence of the daytime set.** Neither stock COCO nor any RailGuard model
trained on these stretches. They are the validation stretches of the Task 02
split, so the fine-tuned model's best epoch was *selected* on frames from the
same stretches. That favours the fine-tune, not COCO. No daytime footage exists
that is unused: the 598 dataset frames cover the whole ride, one every ~2 s.

## Process

- Boxes are drawn by hand, from scratch. No model pre-labels, no auto-label pass,
  and no model output open while labelling.
- Tool: makesense.ai (browser, no install). Load `labels.txt` from the set's
  folder as the label list so class ids come out in the order below; export
  YOLO format into the set's `labels/` folder.
- Every frame gets a label file; a frame with nothing to label gets an empty file.
- Frames are labelled at full resolution, as extracted.
- The test sets are never used for training, validation, threshold tuning or
  model selection.

## Classes

| id | class | includes | excludes |
|---|---|---|---|
| 0 | person | anyone standing, walking, sitting, cycling | people inside a car, bus or truck cabin |
| 1 | car | cars, vans, jeeps, SUVs | |
| 2 | motorcycle | motorcycles, scooters, **three-wheelers (tuk-tuks)** | bicycles |
| 3 | bus | buses of any size | |
| 4 | truck | lorries, pickups, tractors | |
| 5 | cow | cattle, buffalo | goats, dogs |
| 6 | elephant | elephants | |

- A rider on a motorcycle or three-wheeler gets two boxes: person and motorcycle
  (the driver of an enclosed three-wheeler is not labelled separately).
- Dogs, goats, bicycles, carts, trains and wagons are not labelled.

**Decision: three-wheelers are labelled `motorcycle`.** They are common in this
footage, are real obstacles, and have no COCO class. Leaving them unlabelled
would count every model's correct detection of one as a false positive. No
class fits exactly, and models call them motorcycle, car or truck, which costs
class-aware scores but not the class-agnostic one (see Scoring). The alert
logic uses only `on_track` and distance, never the class, so for safety the
class of a three-wheeler does not matter.

## Box rules

- **Minimum size.** Label an object only if its box is at least 12 px tall
  (or 12 px wide, for vehicles seen side-on). Smaller objects cannot be
  identified reliably by eye at this resolution. For scale: a 1.7 m person is
  about 47 px tall at 60 m with the assumed focal length.
- **Occlusion.** Label an object if its class can be identified and roughly 30%
  or more of it is visible. The box covers only the visible part.
- **Frame edge.** Objects cut off by the frame edge follow the same 30% rule.
  The box stops at the edge.
- **Location.** Label every object in the frame wherever it is: on the track,
  beside it, on a platform, on a road. This tests detection; whether an object
  is a threat is decided by the corridor and tested separately.
- **Crowds.** One box per person where people can be separated; where a group
  cannot be separated, box the people that can and skip the rest.
- Reflections, posters and pictures of people or vehicles are not labelled.
- Boxes are tight: edges touch the outermost visible pixels of the object.
- **Night set.** Label from the frame as shown, without brightening it. The
  night set measures detection of objects a person can make out in the footage.

## Scoring (for the report)

Both sets are scored two ways, at the pipeline's confidence threshold of 0.25
and IoU 0.5:

- **Class-aware recall**: the box is found with the right class. Conventional
  detection performance.
- **Class-agnostic recall** (headline): the box is found by any hazard-class
  detection. This is what the system needs: an obstacle that is detected at
  all reaches the corridor gate and can raise an alert.
- **Class-agnostic recall by size band**: the same, split by the labelled box's
  height in pixels. Aggregate recall hides the question that matters, which is
  whether an obstacle is seen far enough away to stop. Box heights come from
  the label files, so nothing extra is recorded while labelling.

| Band (box height) | A 1.7 m person at roughly | A 1.5 m car at roughly |
|---|---|---|
| < 20 px | beyond 140 m | beyond 120 m |
| 20–50 px | 55–140 m | 50–120 m |
| 50–100 px | 28–55 m | 25–50 m |
| > 100 px | under 28 m | under 25 m |

Distances use distance = fx × object height / box height with the *assumed*
focal length (60° field of view, fx ≈ 1630 px at 1886 px wide), so they are
indicative until the camera is calibrated, and they apply to the daytime ride
only. Compare with Task 01: the pipeline can range up to 61.5 m (median), so
the 50–100 px band and above is where ranging and detection overlap.

## Record

Write down for the report: who labelled, when, how many frames and boxes per
class, and any frame where a rule was hard to apply (frame name + reason).
