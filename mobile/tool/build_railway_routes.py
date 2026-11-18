"""Build assets/railway_routes.json from assets/railway_line.json.

Joins fragments whose endpoints are within 20 m into continuous routes,
reversing point order where needed. Where three or more fragments meet
(a junction), routes end there and start new ones (no guessing).

Output format:
{
  "source": ...,
  "routes": [
    {
      "id": "r0",
      "points": [[lat, lon, chainage_m], ...],
      "length_m": ...
    },
    ...
  ]
}
"""

import json
import math
import os
import statistics
import sys
from collections import defaultdict

EARTH_RADIUS_M = 6371008.8
JUNCTION_TOLERANCE_M = 20.0


def distance_m(p1, p2):
    """Haversine distance in metres matching warning.dart."""
    lat1, lon1 = math.radians(p1[0]), math.radians(p1[1])
    lat2, lon2 = math.radians(p2[0]), math.radians(p2[1])
    dp, dl = lat2 - lat1, lon2 - lon1
    h = math.sin(dp / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(min(1.0, h)))


def build_routes(src_path, dst_path):
    with open(src_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    raw_lines = data.get('lines', [])
    n_frags = len(raw_lines)

    # Each fragment i has two endpoints:
    # 2*i + 0 -> start (raw_lines[i][0])
    # 2*i + 1 -> end   (raw_lines[i][-1])
    endpoints = []
    for i, line in enumerate(raw_lines):
        endpoints.append((i, 0, line[0]))
        endpoints.append((i, 1, line[-1]))

    # Find all pairs of endpoints within 20 m from different fragments
    adj = defaultdict(list)
    for i in range(len(endpoints)):
        for j in range(i + 1, len(endpoints)):
            if endpoints[i][0] == endpoints[j][0]:
                continue
            if distance_m(endpoints[i][2], endpoints[j][2]) <= JUNCTION_TOLERANCE_M:
                adj[i].append(j)
                adj[j].append(i)

    # Find connected components of endpoints
    visited_ep = set()
    clusters = []
    for i in range(len(endpoints)):
        if i not in visited_ep and adj[i]:
            comp = []
            q = [i]
            visited_ep.add(i)
            for u in q:
                comp.append(u)
                for v in adj[u]:
                    if v not in visited_ep:
                        visited_ep.add(v)
                        q.append(v)
            clusters.append(comp)

    # An unambiguous join only occurs when exactly 2 fragments meet.
    # Where 3 or more meet (a junction), routes end there (no guessing).
    join_partner = {}
    for c in clusters:
        if len(c) == 2:
            u, v = c[0], c[1]
            join_partner[u] = v
            join_partner[v] = u

    # Trace chains of joined fragments
    used_frags = set()
    routes_raw = []  # list of (chain_frags, list_of_pts)

    for i in range(n_frags):
        if i in used_frags:
            continue

        # Trace forward from end (2*i + 1)
        chain_forward = [i]
        used_frags.add(i)
        pts_forward = list(raw_lines[i])

        curr_ep = 2 * i + 1
        while curr_ep in join_partner:
            nxt_ep = join_partner[curr_ep]
            nxt_frag = nxt_ep // 2
            nxt_is_end = nxt_ep % 2
            if nxt_frag in used_frags:
                break
            used_frags.add(nxt_frag)
            chain_forward.append(nxt_frag)
            nxt_pts = list(raw_lines[nxt_frag])
            if nxt_is_end == 1:
                nxt_pts = nxt_pts[::-1]
                curr_ep = 2 * nxt_frag
            else:
                curr_ep = 2 * nxt_frag + 1

            if nxt_pts[0] == pts_forward[-1]:
                pts_forward.extend(nxt_pts[1:])
            else:
                pts_forward.extend(nxt_pts)

        # Trace backward from start (2*i + 0)
        curr_ep = 2 * i + 0
        pts_backward = []
        chain_backward = []
        while curr_ep in join_partner:
            nxt_ep = join_partner[curr_ep]
            nxt_frag = nxt_ep // 2
            nxt_is_end = nxt_ep % 2
            if nxt_frag in used_frags:
                break
            used_frags.add(nxt_frag)
            chain_backward.append(nxt_frag)
            nxt_pts = list(raw_lines[nxt_frag])
            if nxt_is_end == 0:
                nxt_pts = nxt_pts[::-1]
                curr_ep = 2 * nxt_frag + 1
            else:
                curr_ep = 2 * nxt_frag

            if pts_backward:
                if nxt_pts[-1] == pts_backward[0]:
                    pts_backward = nxt_pts[:-1] + pts_backward
                else:
                    pts_backward = nxt_pts + pts_backward
            else:
                if nxt_pts[-1] == pts_forward[0]:
                    pts_forward = nxt_pts[:-1] + pts_forward
                else:
                    pts_forward = nxt_pts + pts_forward

        full_chain = chain_backward[::-1] + chain_forward
        routes_raw.append((full_chain, pts_forward))

    # Construct routes with cumulative chainage
    routes_out = []
    lengths_m = []

    for idx, (chain_frags, pts) in enumerate(routes_raw):
        route_id = f"r{idx}"
        pts_with_chainage = []
        cum_dist = 0.0
        for k, p in enumerate(pts):
            if k == 0:
                pts_with_chainage.append([round(p[0], 5), round(p[1], 5), 0.0])
            else:
                d = distance_m(pts[k - 1], p)
                cum_dist += d
                pts_with_chainage.append([round(p[0], 5), round(p[1], 5), round(cum_dist, 1)])
        route_len = round(cum_dist, 1)
        lengths_m.append(route_len)
        routes_out.append({
            "id": route_id,
            "points": pts_with_chainage,
            "length_m": route_len,
        })

    out_data = {
        "source": data.get("source", "OpenStreetMap contributors"),
        "routes": routes_out,
    }

    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    with open(dst_path, 'w', encoding='utf-8') as f:
        json.dump(out_data, f, separators=(',', ':'))

    # Summary statistics
    total_km = sum(lengths_m) / 1000.0
    longest_km = max(lengths_m) / 1000.0
    median_m = statistics.median(lengths_m)
    joined_frags = sum(len(cf) for cf, _ in routes_raw if len(cf) > 1)
    unjoined_frags = sum(1 for cf, _ in routes_raw if len(cf) == 1)

    print("================ Railway Routes Stitching Summary ================")
    print(f"Input OSM fragments:           {n_frags}")
    print(f"Continuous routes created:     {len(routes_out)}")
    print(f"Total railway network length:  {total_km:.1f} km")
    print(f"Longest route:                 {longest_km:.1f} km ({max(lengths_m):.1f} m)")
    print(f"Median route length:           {median_m:.1f} m")
    print(f"Fragments joined into routes:  {joined_frags} fragments ({len([1 for cf, _ in routes_raw if len(cf) > 1])} routes)")
    print(f"Fragments not joined:          {unjoined_frags} fragments")
    print("==================================================================")
    return out_data


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else None
    dst = sys.argv[2] if len(sys.argv) > 2 else None

    if not src:
        if os.path.exists('assets/railway_line.json'):
            src = 'assets/railway_line.json'
            dst = 'assets/railway_routes.json'
        elif os.path.exists('mobile/assets/railway_line.json'):
            src = 'mobile/assets/railway_line.json'
            dst = 'mobile/assets/railway_routes.json'
        else:
            print("Error: Could not find assets/railway_line.json", file=sys.stderr)
            sys.exit(1)

    build_routes(src, dst)


if __name__ == '__main__':
    main()
