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

## Amendment: second extension, and a spot-check of empty frames (24 Nov 2026)

52 further frames from four more stretches of the same day ride, chosen to
reach parts still unsampled after the first extension:

| Stretch | Seconds | Interval |
|---|---|---|
| New D | 20-84 | one frame every 8 s |
| New E | 400-520 | one frame every 8 s |
| New F | 660-780 | one frame every 8 s |
| New G | 950-1030 | one frame every 8 s |

`provenance.csv` records the nearest training-dataset frame as **unused** for
36 of the 52, **train** for 15 and **val** for 1.

### Spot-check, and why it was run

This batch came out at 25% of frames carrying a box, against 50% for the
previous batch, and 24 boxes against 59 — labelled in roughly a third of the
time. That is consistent with the stretches being open track rather than
stations, and equally consistent with frames being scanned too fast to catch
objects near the 12 px minimum.

The distinction is not cosmetic. **An object missed in labelling does not only
lower recall: a model that detects it is charged a false positive.** The
precision figure (0.320, 1.46 FP/frame) is the headline result of this project
and it rests entirely on these sets being exhaustive.

**Method.** Eight of the 39 frames labelled empty were re-examined at full
zoom, spread across all four stretches: `manual_005`, `manual_012`,
`manual_019`, `manual_024`, `manual_031`, `manual_038`, `manual_044`,
`manual_050`. The detector was NOT used to choose or find candidates. Labels
drawn where a model points make every one of its detections a true positive by
construction, which is the circular-evaluation fault already caught and
discarded once in this project (see the night-set amendment of 21 Nov 2026).

**Result.** One of the eight (`manual_044`) contained a missed object: a car
of about 28 x 22 px, in the 20-50 px band. It was labelled and the batch was
accepted. The other seven were confirmed empty.

**What this means for the numbers.** One miss in eight re-examined frames is a
wide interval on a small sample and cannot be read as a precise error rate. It
is recorded because it is a known, measured limitation of this set rather than
an assumed-clean one: a small number of further missed objects in the empty
frames of this batch is possible, each of which would slightly understate
precision and recall alike. Results are reported with this caveat attached, not
as though the set were proven exhaustive.

### Duplicate frame removed (24 Nov 2026)

The second extension used 400-520 s while the first had used 520-640 s. The
extractor includes both ends of a range, so t = 520.0 s was extracted twice and
the same frame entered the set as `manual_073` and `manual_129`. Both carried
zero boxes, so no box was double-counted, but the frame count and the
empty-frame count were both one too high.

`manual_129` was removed, along with its row in `provenance.csv`. The set has
156 distinct frames. Frame numbering is not contiguous after this and does not
need to be; every tool here works from the files present.

It was caught by `relabel_merged.py`, which matches frames by image content
hash rather than by filename offset and refuses when one source frame matches
two destination frames. A filename-offset version of the same tool would have
matched them silently and written labels onto the wrong frames.

### Second pass on batch C, and a known inconsistency (24 Nov 2026)

The spot-check and the per-band recall both pointed at batch C having been
labelled too quickly, so all 51 remaining frames were re-examined. Eight
further boxes were found across five frames (`manual_107`, `manual_111`,
`manual_112`, `manual_113`, `manual_134`).

**Every one of the eight was missed by the detector.** Precision was unchanged
by the correction (0.365 before and after) and recall fell from 0.492 to
0.472. That is the signature of genuinely hard objects being added, not of
easy ones: an object that no model detects cannot create a false positive, so
it moves recall and leaves precision alone.

Labels were written onto the already-merged frames with
`training/relabel_merged.py`, which matches source to destination by image
content hash. Re-running `merge_testset.py` would have appended all 51 frames
a second time and duplicated every box.

**Known inconsistency at the small end.** Six of the eight new boxes fall
below 20 px. The `< 20 px` band across the whole set is now 8 boxes, of which
6 are from batch C:

| Band share | Batches A+B | Batch C |
|---|---|---|
| < 20 px | 2 of 160 (1.2%) | 6 of 33 (18%) |

The rules permit a box down to 12 px, but A+B were in practice labelled as if
the floor were 20 px, and batch C after its second pass was not. The set is
therefore not homogeneous below 20 px.

Consequences, stated rather than corrected:

- **Precision is unaffected.** Objects this small are detected by no model
  tested here, so they produce no false positives. The precision figures are
  comparable across batches.
- **Recall is depressed** by roughly the six extra boxes, which no model finds.
- Per-band recall is reported throughout, so a reader can drop the `< 20 px`
  band and compare the remaining bands on consistent ground. The headline
  class-agnostic recall includes them.

Correcting this properly means re-examining all 105 frames of A+B at the 12 px
floor. That is not done, and the numbers are reported with this limitation
attached.

### False positives are driven by scene clutter, not by the detector

Subtracting the 105-frame run from the 156-frame run isolates batch C, whose
four stretches are open track where the earlier batches were station areas and
level crossings:

| | A+B, 105 frames | Batch C, 51 frames |
|---|---|---|
| Predictions | 225 | 24 |
| False positives | 153 | 5 |
| **False positives per frame** | **1.46** | **0.10** |

Same model, same confidence threshold, same image size: a fifteen-fold
difference in false-alarm rate between station areas and open line. The
detector's false alarms come from trackside clutter - poles, signs, platform
furniture, parked vehicles - and not from any property of the model.

This matters operationally. False alarms concentrate where trains are slow and
the driver is already alert, and nearly vanish on open line where the train is
fast and a warning carries most weight.

## Amendment: night set extended to 81 frames (24 Nov 2026)

The night set held 24 frames and 2 boxes, which supported no statement at all:
every night figure read "too few boxes to rank models". 57 further frames were
extracted across the whole ride (4-452 s, one every 8 s, against the original
19.3 s), giving 81 frames and 11 boxes.

Labelled under the night confidence rule of 21 Nov 2026 without exception: a
box only where the object is identifiable from the frame as extracted, with no
brightening, no zoom beyond 200%, and no use of neighbouring frames.

The denser sample found objects at twice the rate of the first pass (0.16
boxes per frame against 0.08), which is consistent with the 8 s interval
catching more of the lit sections - stations, level crossings, signals - where
anything is identifiable at all.

### The finding: the detector is nearly silent at night

| | Day, 156 frames | Night, 81 frames |
|---|---|---|
| Predictions | 249 | **7** |
| Predictions per frame | 1.60 | **0.09** |
| False positives per frame | 1.01 | 0.06 |
| Objects found | 91 of 193 | **2 of 11** |

Stock COCO yolov8s, same weights, same confidence threshold of 0.25, same
image size. The detector produces roughly eighteen times fewer detections per
frame at night than in daylight.

**The low night false-alarm rate is not accuracy.** It is a detector that has
stopped producing output. Read on its own, 0.06 FP/frame at night against 1.01
by day looks like better behaviour; read next to the prediction count it is the
opposite.

**What rests on what.** The prediction count (7 across 81 frames) needs no
labels and no assumptions: it is what the model did. The recall figure rests on
11 boxes with a 95% interval of [0.051, 0.477] and must be reported as "2 of 11
identifiable objects were detected", never as a rate of 0.18.

### Operational reading

RailGuard as built is a daylight system. Night is when a driver's own eyes are
worst and an automatic aid would be worth most, and it is precisely where this
pipeline contributes least. That limitation is stated rather than hidden, and
it is a property of a visible-light camera and a COCO-trained detector, not of
the corridor-gating or gauge-ranging methods, which are unaffected by
illumination once an object is detected at all.

A thermal or near-infrared camera is the direct answer and is out of scope
here; OSDaR23 ships synchronised infrared streams, so the question is testable
in future work without new footage.

### Resolution of the sub-20 px inconsistency (25 Nov 2026)

Two options were considered. Raising the documented floor to 20 px and deleting
the 8 boxes below it would have made the set consistent in minutes — and would
have raised class-agnostic recall from 0.472 to 0.492 purely by removing from
the denominator objects that no model detects. Deleting labelled data after
seeing the results, in the direction that flatters the figure, is not
defensible however good the reason sounds.

**Nothing was deleted.** Instead `eval_manual.py` now reports an explicit
`>=20 px` row: the subset of each test set labelled to a consistent standard,
since above 20 px every batch followed the same rule. The `all` row is kept
beside it, including the inconsistent band, so the difference between the two
is visible rather than quietly resolved.

**For the report:** compare models on the `>=20 px` row, quote the `all` row
next to it, and state that the two differ because of a labelling floor applied
inconsistently in one batch of 51 frames.

### Two boxes removed from manual_113 (27 Nov 2026)

`check_manual_labels.py` flagged two person boxes of 6 x 11 and 7 x 11 px,
both below the 12 px floor. They were the last two of eight people in a line
receding down the track, 21, 19, 19, 16, 10, 10, 11, 11 px tall.

Inspected at 8x and 16x magnification - eight times past the 200% the night
rule allows, and used here only to decide whether to keep an existing label,
never to place one. At 16x both remained an unresolvable blur: light and dark
vertical smears consistent with a person and not identifiable as one. A shape
not identifiable at 16x is not identifiable at the permitted magnification.

What made them look right was the line itself: the eighth shape sits where a
person would be if the row continued. That is the reasoning the night-set rule
of 21 Nov 2026 exists to forbid - *a shape that is only recognisable because
its position suggests what it should be gets no box*. The rule was written for
the night set; it applies to any object at the limit of resolution, and is
treated as general from here.

Both boxes removed. The day set is 156 frames, **191 boxes**. The two boxes
ahead of them, 10 x 19 and 10 x 36 px, were kept: the floor is 12 px of
height for a person, and both clear it.

No other label in either set is below the floor.
