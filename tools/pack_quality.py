#!/usr/bin/env python3
"""Quality report for a Wockett trail pack (.wktpack).

Grades how a pack will read in the app, not just whether it opens:
how much of it is named, how many named trails arrive in several pieces,
and how much is short unnamed clutter. `make_region.sh` runs it on every
build and fails the build when a gate is missed.

A "trail" here is what the app shows as one row: pieces with the same name
whose bounding boxes sit within JOIN_GAP_M of each other (the app's
`TrailList.joinGapMeters`, 400 m). Pieces = rows in the pack.

Stdlib only, like the builder.
"""
from __future__ import annotations

import argparse
import json
import math
import sqlite3
import sys
from collections import defaultdict

JOIN_GAP_M = 400.0          # keep in step with TrailList.joinGapMeters
SHORT_M = 100.0
M_PER_DEG_LAT = 111_320.0


def bbox_gap_m(a, b) -> float:
    """Gap in metres between two (min_lat, min_lon, max_lat, max_lon) boxes; 0 if they overlap."""
    lat0 = math.radians((a[0] + a[2] + b[0] + b[2]) / 4)
    dlat = max(0.0, max(a[0], b[0]) - min(a[2], b[2])) * M_PER_DEG_LAT
    dlon = max(0.0, max(a[1], b[1]) - min(a[3], b[3])) * M_PER_DEG_LAT * math.cos(lat0)
    return math.hypot(dlat, dlon)


def clusters(boxes: list) -> list[list[int]]:
    """Union pieces of one name whose boxes are within JOIN_GAP_M."""
    parent = list(range(len(boxes)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    order = sorted(range(len(boxes)), key=lambda i: boxes[i][1])
    pad = JOIN_GAP_M / M_PER_DEG_LAT * 2  # generous in degrees of longitude
    for k, i in enumerate(order):
        for j in order[k + 1:]:
            if boxes[j][1] - boxes[i][3] > pad:
                break
            if bbox_gap_m(boxes[i], boxes[j]) <= JOIN_GAP_M:
                parent[find(i)] = find(j)
    groups = defaultdict(list)
    for i in range(len(boxes)):
        groups[find(i)].append(i)
    return list(groups.values())


def report(path: str) -> dict:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    meta = dict(conn.execute("select key, value from meta"))
    rows = conn.execute(
        "select name, length_m, min_lat, min_lon, max_lat, max_lon, tags_json from trails"
    ).fetchall()
    total = len(rows)
    named = [r for r in rows if r[0]]
    unnamed = [r for r in rows if not r[0]]
    derived = sum(1 for r in named if '"name_source":"derived_road"' in (r[6] or ""))

    by_name = defaultdict(list)
    for r in named:
        by_name[r[0]].append(r)
    logical = []  # (name, pieces, total_length_m)
    for name, members in by_name.items():
        for c in clusters([m[2:6] for m in members]):
            logical.append((name, len(c), sum(members[i][1] for i in c)))
    multi = [t for t in logical if t[1] > 1]
    pieces_in_multi = sum(t[1] for t in multi)

    out = {
        "region": meta.get("region"),
        "built_at": meta.get("built_at"),
        "builder_version": meta.get("builder_version"),
        "pieces": total,
        "named_pieces": len(named),
        "named_share": round(len(named) / total, 3) if total else 0,
        "derived_name_pieces": derived,
        "named_trails": len(logical),
        "named_trails_in_pieces": len(multi),
        "named_trails_in_pieces_share": round(len(multi) / len(logical), 3) if logical else 0,
        "avg_pieces_when_split": round(pieces_in_multi / len(multi), 2) if multi else 0,
        "max_pieces": max((t[1] for t in logical), default=0),
        "short_pieces_share": round(sum(1 for r in rows if r[1] < SHORT_M) / total, 3) if total else 0,
        "unnamed_pieces": len(unnamed),
        "unnamed_short_share": round(sum(1 for r in unnamed if r[1] < SHORT_M) / len(unnamed), 3) if unnamed else 0,
        "most_split": [
            {"name": n, "pieces": p, "km": round(l / 1000, 1)}
            for n, p, l in sorted(multi, key=lambda t: -t[1])[:10]
        ],
    }
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("pack")
    ap.add_argument("--json", action="store_true", help="print JSON only")
    args = ap.parse_args(argv)
    r = report(args.pack)
    if args.json:
        print(json.dumps(r, indent=2))
        return 0
    print(f"{r['region']}  built {r['built_at']}  builder {r['builder_version']}")
    print(f"  pieces            {r['pieces']:>8}   named {r['named_share']:.0%}  ({r['derived_name_pieces']} named from a road)")
    print(f"  named trails      {r['named_trails']:>8}   split into pieces: {r['named_trails_in_pieces']} ({r['named_trails_in_pieces_share']:.0%}),"
          f" avg {r['avg_pieces_when_split']} pieces, worst {r['max_pieces']}")
    print(f"  short (<100 m)    {r['short_pieces_share']:.0%} of all pieces;  unnamed pieces {r['unnamed_pieces']}, {r['unnamed_short_share']:.0%} of them short")
    print("  most split:")
    for t in r["most_split"]:
        print(f"    {t['pieces']:>4} pieces  {t['km']:>6} km  {t['name']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
