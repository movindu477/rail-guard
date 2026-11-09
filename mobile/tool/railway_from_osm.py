"""Build assets/railway_line.json from OpenStreetMap railway data.

1. Download Sri Lanka's running lines (no sidings or yards) from Overpass:

    curl -A "railguard-student-project/1.0" -X POST https://overpass-api.de/api/interpreter \
      --data-urlencode 'data=[out:json][timeout:150];area["ISO3166-1"="LK"][admin_level=2]->.a;way(area.a)["railway"="rail"][!"service"];out geom;' \
      -o lk_rail.json

2. python tool/railway_from_osm.py lk_rail.json assets/railway_line.json

OSM splits a line into many short ways. They are joined end to end into long
lines, then simplified (Douglas-Peucker, 8 m tolerance): curves keep their
points, straight track drops them. Output: {"source": ..., "lines": [[[lat, lon], ...], ...]}
with 5 decimals (about 1 m). Data (c) OpenStreetMap contributors, ODbL.
"""

import json
import math
import sys
from collections import defaultdict

TOLERANCE_M = 8.0


def xy(p, lat0):
    """Local metres (equirectangular), fine at track scale."""
    return (math.radians(p[1]) * 6371008.8 * math.cos(math.radians(lat0)),
            math.radians(p[0]) * 6371008.8)


def seg_dist(p, a, b):
    (px, py), (ax, ay), (bx, by) = p, a, b
    dx, dy = bx - ax, by - ay
    if dx == dy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def simplify(pts, tol):
    """Douglas-Peucker, iterative."""
    if len(pts) < 3:
        return pts
    lat0 = pts[0][0]
    m = [xy(p, lat0) for p in pts]
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        best, k = 0.0, -1
        for n in range(i + 1, j):
            d = seg_dist(m[n], m[i], m[j])
            if d > best:
                best, k = d, n
        if best > tol:
            keep[k] = True
            stack += [(i, k), (k, j)]
    return [p for p, kp in zip(pts, keep) if kp]


def join(ways):
    """Join ways that meet end to end where exactly two ways meet (not at junctions)."""
    ways = [w for w in ways if len(w) > 1]
    ends = defaultdict(list)
    for i, w in enumerate(ways):
        ends[w[0]].append(i)
        ends[w[-1]].append(i)
    used, lines = set(), []
    for i in range(len(ways)):
        if i in used:
            continue
        used.add(i)
        line = list(ways[i])
        for forward in (True, False):
            while True:
                tip = line[-1] if forward else line[0]
                nxt = [j for j in ends[tip] if j not in used]
                if len(ends[tip]) != 2 or len(nxt) != 1:
                    break
                j = nxt[0]
                used.add(j)
                if forward:   # w must start at the tip
                    w = ways[j] if ways[j][0] == tip else ways[j][::-1]
                    line = line + w[1:]
                else:         # w must end at the tip
                    w = ways[j] if ways[j][-1] == tip else ways[j][::-1]
                    line = w[:-1] + line
        lines.append(line)
    return lines


def main(src, dst):
    data = json.load(open(src, encoding="utf-8"))
    ways = [[(round(g["lat"], 7), round(g["lon"], 7)) for g in el["geometry"]]
            for el in data["elements"] if el.get("type") == "way" and el.get("geometry")]
    lines = join(ways)
    out = [[[round(p[0], 5), round(p[1], 5)] for p in simplify(l, TOLERANCE_M)] for l in lines]
    n_in = sum(len(w) for w in ways)
    n_out = sum(len(l) for l in out)
    with open(dst, "w", encoding="utf-8") as f:
        json.dump({"source": "(c) OpenStreetMap contributors, ODbL; railway=rail without service=*",
                   "lines": out}, f, separators=(",", ":"))
    print(f"{len(ways)} ways, {n_in} points -> {len(out)} lines, {n_out} points; wrote {dst}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
