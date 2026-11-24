# Manual test sets: labelling rules

These rules define the ground truth for the two hand-labelled test sets. They
are part of the evaluation methodology and go in the report. They were fixed
before the first box was drawn and are not changed during labelling.

| Set | Folder | Frames | Source |
|---|---|---|---|
| Daytime | `data/dataset/testset_manual/` | 57 | day ride, the two validation stretches (86–204 s, 1034–1194 s), one frame every 5 s |
| Night (E4) | `data/dataset/testset_night/` | 24 | night **cab ride** (YouTube `-fM6i43dgNw`, see `SOURCES.md`), 5–449 s, one frame every 19.3 s across the whole ride |

**Night set re-extracted (12 Nov 2026), before any labelling.** The first night
set came from a ride filmed through a side door, not from the cab, so it mixed
viewpoint with illumination; its source video has since been overwritten. It is
kept, unlabelled, in `data/dataset/testset_night_old_sidedoor/` and is not used.
The new set is spread across the whole ride so stations, level crossings and
open track are all represented.

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

## Amendment after the first scoring review (10 Nov 2026)

The first score of the 25 labelled daytime frames gave implausibly low recall
(stock COCO found 31% of objects over 100 px tall). Overlaying labels on the
model's boxes (`training/overlay_manual.py`) showed the cause: several labels
put **one box around a group** of people or cars, where the detector draws one
box per object, so no single detection overlapped the group box by IoU 0.5.
Scoring at IoU 0.3 raised large-object recall from 0.31 to 0.69, confirming it
was box geometry, not the model.

The Crowds and tight-box rules above already required one tight box per object;
these labels did not follow them. The rule is restated here so it cannot be
misread, and the affected frames are re-labelled before any result is used:

> **One tight box per object.** Never one box around a group. Four people
> walking together are four boxes, not one. Draw each box to the object's
> visible edges, not loosely around it.

Frames corrected (status: **done, 12 Nov 2026**): group boxes split in
`manual_000`, `manual_002`, `manual_003`, `manual_006`, `manual_021`, `manual_023`;
loose boxes tightened in `manual_002`, `manual_005`, `manual_007`, `manual_018`,
`manual_046`, `manual_052`, `manual_053`, `manual_054`; a missed car added in
`manual_013`. A final check of all 57 files found no label with two or more
detected objects inside it. No result from the first labelling is reported.

## Amendment after the night set review (21 Nov 2026)

Night set confidence rule (21 Nov 2026). A box is drawn only where the object is identifiable from the frame as extracted, without brightening, zooming beyond 200%, or using neighbouring frames. A shape that is only recognisable because its position suggests what it should be gets no box. A first pass on 21 Nov 2026 was reviewed and discarded: six of the six largest boxes contained no identifiable object.


## Amendment: daytime set extended (24 Nov 2026)

**Why.** At 57 frames / 101 boxes the set could not separate any two models.
Every comparison run on 24 Nov 2026 — four input resolutions, four model
sizes, two tiling configurations, two fine-tuned models — returned confidence
intervals that overlapped. The limit was the sample size, not the detectors.
A Wilson interval on 101 boxes is roughly +/-0.09 wide; at ~200 boxes it is
about a third narrower, which is the difference between "cannot distinguish"
and a ranking.

**What changed.** Frames added from three further stretches of the same day
ride, chosen to spread across parts not previously sampled:

| Stretch | Seconds | Interval |
|---|---|---|
| New A | 260-380 | one frame every 8 s |
| New B | 520-640 | one frame every 8 s |
| New C | 820-940 | one frame every 8 s |

48 frames extracted. Of these, `provenance.csv` records that the nearest
training-dataset frame is in the **train** split for 23 of them and is
**unused** for the other 25 — so just over half sit beside footage no model
has ever trained on.

Extracted to `data/dataset/testset_manual_b/`, labelled under the rules above
without exception, then merged into the daytime set. The original 57 frames
are untouched; `data/dataset/testset_manual_BACKUP/` holds them as extracted
and labelled before the merge.

**What did NOT change.** Classes, box rules, minimum size, occlusion, crowd
and tight-box rules, the tool (makesense.ai, no model pre-labels), and the
scoring method are all as fixed above. Only the frame count changed.

**The independence caveat, stated plainly.** The original stretches were the
VALIDATION stretches of the Task 02 split. These three new stretches fall in
TRAINING stretches of that split. For every model this project actually uses
this makes no difference: stock COCO was trained on COCO and has never seen
any Sri Lankan footage, so the whole ride is unseen data to it. The two
fine-tuned models that did train on those stretches were measured and rejected
on 24 Nov 2026 and are not used.

But the caveat has to travel with the data: **any future model fine-tuned on
the day ride must exclude these frames from its training split, or results on
the extended set are contaminated.** `extract_manual_testset.py` records the
nearest training frame and its split for every frame in `provenance.csv`, so
the overlap is visible per frame and cannot be lost.

Results measured on the original 57 frames are reported as such, with their
own sample size, and are never silently pooled with results from the extended
set.
