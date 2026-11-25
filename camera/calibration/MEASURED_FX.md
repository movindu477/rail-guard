# Focal length of the ELP camera, wide end

**fx = 1820 px at 1920x1080, horizontal field of view 55.6 degrees, +/- 3%.**

Saved as `elp_wide_measured.npz`, readable by `PipelineConfig.from_calibration`.

## Why this is a direct measurement and not an OpenCV calibration

`calibrateCamera` was attempted five times on 25 Nov 2026 and failed every
time. The failures were informative and are worth recording:

| Attempt | fx | Implied FOV | Why it failed |
|---|---|---|---|
| stills, 20 photos | 1934 | 52.8 deg | RMS 1.32 px, cy 109 px off centre |
| stills, mixed sessions | 2940 | 36.1 deg | 4 photos from an earlier zoom setting mixed in |
| video, close + tilted | 6257 | 17.4 deg | screen coverage 2/9 |
| video, more tilt | 24225 | 4.6 deg | screen coverage 1/9, k1 = -17.3 |

The pattern: with the board always near the centre of the frame, the solver
cannot separate focal length from board distance, so it runs away to a long
focal length with extreme distortion that fits the photos well and describes
no real lens. Coverage of the frame corners is what constrains it, and that
proved hard to achieve by hand with an A4 board.

Compounding it, the lens is a 5-50 mm varifocal whose zoom ring turns under
light pressure. Three sessions measured 5.4 mm, 8.2 mm and 17.5 mm of focal
length - the ring was in a different place each time, and the ring position,
not the method, explains most of the variation between attempts.

## The method used instead

A pinhole camera obeys one relation:

    pixels_across / fx = metres_across / distance

With the checkerboard square to the camera at a measured distance, fx follows
from the pixel span of the corner grid. No optimiser, no distortion model,
nothing that can trade one parameter against another.

Two sessions, board square to within 2-3%, after the zoom ring settled at the
wide stop:

| Session | Stable readings | FOV |
|---|---|---|
| 13:25 | 1808 - 1820 | 55.6 - 55.9 deg |
| 15:20 | 1815 - 1830 | 55.4 - 55.8 deg |

Both agree on fx = 1820 +/- about 3%. The 3% covers the distance being
measured to the camera body rather than the sensor plane, and the board being
hand-held rather than fixed.

Within each session, readings drifted while the operator moved: the corner
grid shrank from 228 to 219 px over twenty samples as the camera drifted
backwards, and because the script assumes a fixed distance, the computed fx
fell with it. Only the stable stretches are quoted.

## What this does and does not give

**Gives:** fx and fy, which is what `D = fx * 1.676 / w` needs.

**Does not give:** lens distortion, or the principal point. The saved file sets
the principal point to the image centre and distortion to zero. Those are
assumptions, not measurements, and are stated here rather than left implied by
zeros that look like results.

Consequence: distance error grows toward the edges of the frame, where radial
distortion is largest and uncorrected. Objects on the track sit near the centre
of the image, where it is smallest, so the effect on the ranging that matters
is modest - but it is a real limitation and the error has not been quantified.

## What changes in the project

The pipeline assumed a 60 degree field of view, giving fx = 1663 at 1920 px.

**Measured fx is 9.5% higher, so every distance previously reported was 9.5%
too short.** The Task 01 crop experiment's median ranging reach of 61.5 m is
about 67 m. The size-band distance table in `training/manual_testset_rules.md`
shifts by the same factor.

## The rule that must survive this document

**The zoom ring must not move.** This number describes the lens at its wide
stop. If the ring is turned, the calibration describes a camera that no longer
exists, and every distance becomes wrong with nothing in the output to show it.
Tape the ring, mark it, and check the mark before each session.
