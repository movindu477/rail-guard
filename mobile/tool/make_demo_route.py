"""Build assets/demo_route.json for the app's simulated-GPS demo mode.

    python tool/make_demo_route.py      (from mobile/)

A 3.6 km southbound run on the Coastal Line out of Colombo (Kollupitiya
towards Wellawatte), taken from assets/railway_line.json and resampled every
5 m, plus a hazard point on the track 3.1 km from the start. The app's demo
build (--dart-define=RAILGUARD_SIM=true) drives along it; the hazard is added
to Firestore separately (it must be a real report, so the real alert path runs).
"""

import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "assets")
R = 6371008.8

START_FROM_FORT_M = 2300   # start near Kollupitiya
RUN_M = 3600
HAZARD_AT_M = 3100
STEP_M = 5.0


def dist(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    h = (math.sin((p2 - p1) / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(math.radians(b[1] - a[1]) / 2) ** 2)
    return 2 * R * math.asin(math.sqrt(h))


def point_at(line, s):
    """Point s metres along the polyline."""
    for a, b in zip(line, line[1:]):
        seg = dist(a, b)
        if s <= seg:
            t = s / seg if seg else 0
            return [a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])]
        s -= seg
    return line[-1]


def main():
    lines = json.load(open(os.path.join(ASSETS, "railway_line.json"), encoding="utf-8"))["lines"]
    fort = (6.9336, 79.8485)
    # The coastal line: the longest line ending at Colombo Fort; run it southbound.
    line = max((l for l in lines if min(dist(p, fort) for p in (l[0], l[-1])) < 300),
               key=lambda l: sum(dist(a, b) for a, b in zip(l, l[1:])))
    if dist(line[0], fort) > dist(line[-1], fort):
        line = line[::-1]
    route = [point_at(line, START_FROM_FORT_M + k * STEP_M) for k in range(int(RUN_M / STEP_M) + 1)]
    hazard = point_at(line, START_FROM_FORT_M + HAZARD_AT_M)
    out = {
        "note": "Simulated drive for the demo build only. Coastal Line, southbound. "
                "(c) OpenStreetMap contributors, ODbL.",
        "step_m": STEP_M,
        "hazard": [round(hazard[0], 6), round(hazard[1], 6)],
        "hazard_distance_m": HAZARD_AT_M,
        "route": [[round(p[0], 6), round(p[1], 6)] for p in route],
    }
    with open(os.path.join(ASSETS, "demo_route.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"route {len(route)} points, start {route[0]}, hazard {out['hazard']} "
          f"({HAZARD_AT_M} m along)")


if __name__ == "__main__":
    main()
