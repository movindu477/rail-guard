"""Compare straight-line distance vs along-track distance on curved Sri Lankan track.

Quantifies what the straight-line haversine method was getting wrong.
Outputs results to outputs/tables/along_track_vs_straight.csv and prints
a formatted summary table.
"""

import csv
import json
import math
import os
import sys

EARTH_RADIUS_M = 6371008.8


def haversine_m(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(min(1.0, h)))


# 10 curated pairs of points on notable curved sections of the Sri Lankan railway.
# Labeled with neutral, verifiable coordinates (no guessed station names).
CURVED_SECTIONS = [
    {
        "location": "Curve 1 (r7, 6.9565 N 80.6595 E)",
        "route_id": "r7",
        "idx_a": 528,
        "idx_b": 543,
    },
    {
        "location": "Curve 2 (r7, 6.9626 N 80.6592 E)",
        "route_id": "r7",
        "idx_a": 552,
        "idx_b": 582,
    },
    {
        "location": "Curve 3 (r7, 6.9461 N 80.6504 E)",
        "route_id": "r7",
        "idx_a": 488,
        "idx_b": 518,
    },
    {
        "location": "Curve 4 (r7, 6.9035 N 81.0613 E)",
        "route_id": "r7",
        "idx_a": 1328,
        "idx_b": 1338,
    },
    {
        "location": "Curve 5 (r7, 6.8825 N 81.0532 E)",
        "route_id": "r7",
        "idx_a": 1280,
        "idx_b": 1310,
    },
    {
        "location": "Curve 6 (r7, 7.0001 N 80.5368 E)",
        "route_id": "r7",
        "idx_a": 200,
        "idx_b": 230,
    },
    {
        "location": "Curve 7 (r7, 6.9015 N 80.5904 E)",
        "route_id": "r7",
        "idx_a": 400,
        "idx_b": 430,
    },
    {
        "location": "Curve 8 (r7, 6.8278 N 80.8395 E)",
        "route_id": "r7",
        "idx_a": 872,
        "idx_b": 902,
    },
    {
        "location": "Curve 9 (r7, 6.9359 N 80.5541 E)",
        "route_id": "r7",
        "idx_a": 336,
        "idx_b": 351,
    },
    {
        "location": "Curve 10 (r7, 6.9992 N 80.5203 E)",
        "route_id": "r7",
        "idx_a": 240,
        "idx_b": 255,
    },
]


def main():
    routes_path = "assets/railway_routes.json"
    if not os.path.exists(routes_path):
        routes_path = "mobile/assets/railway_routes.json"
    if not os.path.exists(routes_path):
        print(f"Error: {routes_path} not found", file=sys.stderr)
        sys.exit(1)

    with open(routes_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    routes_by_id = {r["id"]: r for r in data["routes"]}

    out_dir = "outputs/tables"
    os.makedirs(out_dir, exist_ok=True)
    csv_path = os.path.join(out_dir, "along_track_vs_straight.csv")

    rows = []
    print("\n================ Along-Track vs Straight-Line Distance on Curved Sri Lankan Track ================\n")
    print(f"{'Section / Landmark':<42} | {'Straight (m)':<12} | {'Along-Track (m)':<15} | {'Under-read (m)':<14} | {'Error %':<8}")
    print("-" * 102)

    for item in CURVED_SECTIONS:
        r = routes_by_id[item["route_id"]]
        pts = r["points"]
        pA = pts[item["idx_a"]]
        pB = pts[item["idx_b"]]

        straight_m = haversine_m(pA[0], pA[1], pB[0], pB[1])
        along_m = abs(pB[2] - pA[2])
        diff_m = along_m - straight_m
        err_pct = (diff_m / straight_m) * 100.0 if straight_m > 0 else 0.0

        rows.append({
            "section": item["location"],
            "route_id": item["route_id"],
            "ptA_lat": pA[0],
            "ptA_lon": pA[1],
            "ptB_lat": pB[0],
            "ptB_lon": pB[1],
            "straight_line_m": round(straight_m, 1),
            "along_track_m": round(along_m, 1),
            "under_read_m": round(diff_m, 1),
            "error_pct": round(err_pct, 1),
        })

        print(f"{item['location']:<42} | {straight_m:10.1f} m | {along_m:13.1f} m | +{diff_m:11.1f} m | +{err_pct:5.1f}%")

    print("-" * 102)

    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "section",
                "route_id",
                "ptA_lat",
                "ptA_lon",
                "ptB_lat",
                "ptB_lon",
                "straight_line_m",
                "along_track_m",
                "under_read_m",
                "error_pct",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)

    print(f"\nSaved CSV to {csv_path} ({len(rows)} sections analyzed).\n")


if __name__ == "__main__":
    main()
