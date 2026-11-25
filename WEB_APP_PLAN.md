# RailGuard Web Application — Design and Implementation Plan

A browser interface for the RailGuard pipeline, run with `npm run dev`, plus a
live view of the trains and hazards the mobile app reports.

Status at the time of writing: the Python backend is built and untested by the
browser. The React frontend does not exist yet.

---

## 1. Why the backend is local and not hosted

The obvious shape — a React app on Vercel — cannot work for the camera, for
three independent reasons:

1. **No GPU.** TEP-Net and YOLO need CUDA. Vercel's functions have no GPU and
   a few seconds of execution time; a frame takes about 150 ms and the run
   lasts hours.
2. **No camera.** The ELP is on USB on this laptop. A server elsewhere cannot
   read it.
3. **Mixed content.** Even with the pipeline local, a page served over HTTPS
   from Vercel is blocked by the browser from calling `http://localhost`.

So the backend runs where the camera and the GPU are. The frontend runs on the
same machine, and both speak plain HTTP over loopback. The video never leaves
the laptop.

**What a hosted deployment could still do:** the control-room view in §6 reads
Firestore, not the camera, and would deploy to Vercel unchanged. That is worth
doing later; it is out of scope here.

---

## 2. Architecture

```
ELP camera --USB--> laptop
                      |
         RailGuardPipeline (TEP-Net + YOLO, CUDA)
                      |
         railguard/web/runner.py      capture + process on a thread
                      |
         railguard/web/server.py      FastAPI on 127.0.0.1:8000
                      |            /video  MJPEG
                      |            /api/*  JSON
                      v
         web/  React + Vite on 127.0.0.1:5173
                      |
                      +--> Firestore (train positions, hazards from the phones)
```

Two processes, started separately. The browser page is the only thing the user
looks at.

**MJPEG, not WebRTC.** An `<img src="/video">` renders it with no client code,
no negotiation, no extra dependency. Over loopback the latency is a frame or
two, well under the delay the 3-frame persistence rule already imposes.

**Only the newest frame is kept.** A browser that falls behind gets the current
frame, never a backlog. On a safety display a late frame is worse than a
missing one, because the viewer cannot tell that it is late.

---

## 3. Files

Already written:

| File | Lines | Purpose |
|---|---|---|
| `railguard/web/runner.py` | ~190 | Camera + pipeline on a plain thread. Newest-frame-only, camera loss and reconnect, event log of state changes |
| `railguard/web/server.py` | ~140 | FastAPI: `/api/cameras`, `/api/calibrations`, `/api/start`, `/api/stop`, `/api/status`, `/api/events`, `/video` |
| `demos/web_server.py` | ~30 | Entry point |

To be written:

```
web/
  index.html
  package.json
  vite.config.js
  src/
    main.jsx
    App.jsx
    api.js            fetch helpers, one place that knows the backend URL
    firebase.js       Firestore init and subscriptions
    components/
      SetupPanel.jsx     camera, calibration, unit, publish, line speed
      LiveView.jsx       the video and the alert banner
      StatusPanel.jsx    the reference column
      EventLog.jsx       timestamped lines
      TrainList.jsx      other trains from Firestore
      HazardList.jsx     active hazards from Firestore
    styles.css
```

**Budget: under 800 lines of JSX and CSS.** If a part needs a state library, a
component framework or a build plugin, it is the wrong part. No Redux, no
Tailwind, no component library, no router — there is one screen.

---

## 4. The interface

One page. Two states: **setup** before a run, **live** during one.

### Setup

Shown when the backend reports `state: idle`. Fields, all from the backend:

- **Camera** — from `/api/cameras`, with the resolutions each delivers
- **Calibration** — from `/api/calibrations`, each showing its `fx`. Choosing
  none must say in plain words that distances will be estimates
- **Unit ID** — text, remembered in `localStorage`
- **Publish hazards** — checkbox
- **Line speed** — km/h, showing the braking distance it implies

Then **Start**. While the backend loads, show its `message`: loading models,
opening camera, ready. Loading takes several seconds and currently looks like
nothing is happening.

### Live

**The video fills the left, about three quarters of the width.** The overlay —
corridor, boxes, distances — is drawn by the backend, exactly as the desktop
app draws it. The frontend never re-draws detections; one implementation,
no drift.

**The alert banner sits above the video**, full width. Hidden when there is no
alert. When present it names the level, the object and the distance, or the
words "distance unknown". This is the one element allowed to dominate.

**The status column on the right, fixed width.** Label and value, quiet:

| | |
|---|---|
| State | running / camera lost / stopped |
| Camera | index and resolution |
| Frame rate | one decimal |
| Distances | `calibrated — fx 1820` or `ASSUMED focal length` |
| Track | detected, or why not |
| On track now | count, and how many confirmed |
| Publishing | unit id, or off |
| Running for | elapsed |

**The event log below it.** Newest at the bottom, timestamped. Alerts raised
and cleared, objects confirmed with distance, track lost and regained, camera
errors. Nothing per-frame: a log nobody reads is noise.

**A Stop button.** That is the only control during a run.

---

## 5. UI design direction

**Dark, flat, dense.** This is an instrument, not a product page.

- Background near-black, panels one step lighter. The video is the brightest
  thing on screen and should stay that way
- One accent for normal operation, one for caution, one for BRAKE NOW. Nothing
  else carries colour
- Text: a system sans at 13–14 px for the status column, larger only in the
  alert banner. Numbers in a monospaced face so they do not jitter as they
  change
- No gradients, shadows, rounded cards, animation or transitions. A value that
  animates as it updates is a value you cannot read at a glance
- Generous vertical rhythm in the status column; it is read by scanning, not
  by reading
- The whole page fits one screen with no scrolling except inside the event log

**Three states must be unmistakable from the corner of the eye:** running
normally, alerting, and not seeing the track. If a glance cannot tell those
apart, the design has failed regardless of how it looks.

---

## 6. Live link to the mobile app

The phones already write to Firestore in project `railguard-alerts`:

- `train_position/{unitId}` — position, train number, service, timestamp
- `hazards/{id}` — camera and driver reports
- `unit_claims/{unitId}` — which driver owns a unit

The web page reads the same collections with the Firebase JS SDK and
`onSnapshot`, so it updates without polling.

**Needs doing first:** `railguard-alerts` has only an Android app registered.
Add a **Web** app in the Firebase console and copy its config into
`web/src/firebase.js`. The Android `apiKey` is not the web one.

**Rules:** the existing Firestore rules require an authenticated user. The web
page therefore needs either a signed-in user or a rule permitting read of
`train_position` and `hazards` to any authenticated client. Do not loosen the
rules to allow unauthenticated reads: positions of working trains are not
public data.

**What to show:** a list of live units — number, service, how long since the
last fix, distance from this train if known — and active hazards with their
age. A train whose last fix is older than five minutes is shown as dropped,
never silently hidden.

---

## 7. Build order

Each step ends somewhere testable. Do not start the next until the current one
is confirmed working.

1. **Backend by itself.** `python demos/web_server.py`, then in a browser:
   `/api/cameras` returns JSON, `/docs` can start a run, `/video` shows the
   annotated camera feed. **No React until this works.**
2. **Scaffold.** `npm create vite@latest web -- --template react`, strip the
   demo content, confirm `npm run dev` serves an empty page.
3. **Video only.** `<img src="http://127.0.0.1:8000/video">` and a Stop
   button. Confirm the feed appears.
4. **Setup panel.** Camera and calibration from the backend, Start posts to
   `/api/start`, loading messages shown.
5. **Status column.** Poll `/api/status` every 500 ms.
6. **Event log.** Poll `/api/events?since=N`.
7. **Alert banner**, and the three unmistakable states.
8. **Firestore.** Web app registered, trains and hazards listed live.

---

## 8. Files to remove from the project

An audit on 25 Nov 2026 found roughly 24 GB that is not needed. Sorted by how
safe each is to delete.

### Delete — nothing depends on these

| Path | Size | Why |
|---|---|---|
| `mobile/screen_*.png` | 21 MB | 29 emulator screenshots from the two-phone test. Add `screen_*.png` to `mobile/.gitignore` |
| `mobile images/` | 6.8 MB | Duplicate of `mobile/assets/images/`, which is what Flutter bundles |
| `mobile/build/` | 2.1 GB | Flutter build cache, regenerated by `flutter build` |
| `outputs/videos/yolo_640/`, `yolo_1280/`, `yolo_night/` | 3.1 GB | Old detector output videos, superseded |
| `outputs/videos/pipeline_2min_publish.mp4`, `pipeline_publish_700.mp4` | 800 MB | Superseded demo renders |
| `outputs/training/` | 54 MB | Checkpoints and plots from rejected fine-tunes |
| `camera/calibration/videos/` | 688 MB | Raw calibration recordings; `MEASURED_FX.md` records the result |
| `camera/calibration/images_wide*/` (all variants) | 20 MB | Failed calibration attempts, documented in `MEASURED_FX.md` |
| `camera/calibration/calib_wide.npz` | — | Superseded by `elp_wide_measured.npz`. **Delete it** — a stale calibration picked up by mistake silently corrupts every distance |
| `simulation/*.blend1` | 2.2 MB | Blender auto-backups |
| `yolo26n.pt` (repo root) | 5.5 MB | Stray download, unused |
| `models/yolov8n.pt` | 6.6 MB | Never used |
| `.pytest_cache/`, `__pycache__/` | — | Caches |

### Delete, but note it in the report first

| Path | Size | Why it is going |
|---|---|---|
| `models/yolov8m.pt`, `yolov8l.pt`, `yolov8x.pt` | 277 MB | Benchmarked and rejected. The **numbers** are the result, and they are in the commit history and `outputs/evaluation/`. Re-downloadable in one command if ever needed |
| `models/railguard_best.pt` | 22.6 MB | Rejected fine-tune, catastrophic forgetting |
| `runs/detect/railguard_v2`, `railguard_v3` | 104 MB | **Keep the CSVs and plots, delete `weights/*.pt`.** The curves are evidence for the report; the weights are a model that will never be loaded |
| `data/dataset/railguard_v2/` | 2.7 GB | Assembled split for the rejected fine-tune. `build_train_split.py` rebuilds it |
| `data/dataset/openimages/` | 2.3 GB | `fetch_openimages.py` re-fetches it |
| `data/dataset/osdar23_yolo/` | 431 MB | `osdar23_to_yolo.py` regenerates it from `osdar23/` |

### Delete — merged batches and backups

| Path | Size |
|---|---|
| `data/dataset/testset_manual_b/`, `testset_manual_c/`, `testset_night_b/` | 76 MB — merged into the live sets |
| `data/dataset/testset_manual_BACKUP/` | 45 MB — pre-merge copy, the merge is committed |
| `data/dataset/testset_night_old_sidedoor/` | 2.1 MB — discarded, and documented as discarded |
| `data/dataset/coco_cows/`, `wildlife/`, `animal_cutouts/`, `synthetic/`, `yolo/`, `images/`, `yolo_backup_2026-10-23/`, `wildlife_elephants/`, `labels_backup/` | 534 MB — paste-augmentation experiments from the abandoned fine-tuning route |

### Keep

| Path | Why |
|---|---|
| `data/dataset/osdar23/rgb_highres_center/` + `*_labels.json` + `license.md` | The only in-domain railway source, and the licence is what lets it be cited |
| `data/dataset/testset_manual/`, `testset_night/` | The evaluation sets. **Irreplaceable** — hand-labelled, and every result rests on them |
| `data/videos/raw/` | Source footage for any further labelling |
| `outputs/evaluation/` | Every measured result |
| `models/yolov8s.pt` | The detector in use |
| `camera/calibration/elp_wide_measured.npz`, `MEASURED_FX.md` | The calibration and how it was obtained |

**Expected after cleanup: about 11 GB, from roughly 35.**

**Before deleting anything:** confirm the working tree is committed and pushed,
so anything removed in error is recoverable from git for the files git tracks.
The large data folders are gitignored and are **not** recoverable — those are
the ones to be sure about.

---

## 9. Rules this application must not break

- **No control disables the alarm.** No mute, no volume, no setting. Silence
  during testing comes from the computer's volume control
- **Never show a confident wrong state.** Track not detected says so.
  Unmeasurable distance shows `?`, never a plausible number. Uncalibrated says
  so on screen for the whole run
- **Fail-safe must read as deliberate.** A confirmed object at unknown distance
  raises BRAKE NOW; the interface should make that look like the design, not a
  fault
- **Nothing covers the video while running**
- **The backend binds to 127.0.0.1.** The video does not go on the network
- **The frontend never re-implements the overlay.** The backend draws it; the
  browser displays it
