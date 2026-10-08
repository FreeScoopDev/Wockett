#!/usr/bin/env python3
"""Checks a freshly built region pack and writes its release manifest.

`make_region.sh` runs this after the builder. It is the part of shipping a
region that used to be done by eye and by hand:

  * gates — the pack opens and verifies, sits inside the extract it came
    from, has named trails near the region's main city, stays under the size
    budget; a failed gate exits 1 and nothing is written;
  * the version — the next packVersion after the last one published for the
    region (recorded in WORK/published/<region>.json by the publish step),
    stamped into the pack's own meta so the file says which version it is;
  * the manifest — every field the CloudKit TrailRegionPack record needs,
    computed from the pack, never typed: region, regionName, schemaVersion,
    packVersion, builtAt, trailCount, sizeBytes, plus sha256 and the source
    extract's md5;
  * what changed — counts and names added or removed against the last
    published pack, to support "republish only when the data materially
    changed".

Stdlib only, like the builder.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(__file__))
import build_trail_pack as btp  # noqa: E402
import pack_quality  # noqa: E402

SIZE_BUDGET_BYTES = 150_000_000      # well under CloudKit's asset limit; a big state is 2-4x NC's 19 MB
PROBE_RADIUS_M = 25_000.0
BBOX_MARGIN_DEG = 0.05               # ways that cross the state line poke out a little
MIN_PIECES = 100


def load_regions(path: str) -> dict:
    with open(path) as f:
        return {k: v for k, v in json.load(f).items() if not k.startswith("_")}


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def pack_bbox(conn) -> tuple[float, float, float, float]:
    return conn.execute(
        "select min(min_lat), min(min_lon), max(max_lat), max(max_lon) from trails").fetchone()


def named_near(conn, lat: float, lon: float, radius_m: float) -> int:
    dlat = radius_m / pack_quality.M_PER_DEG_LAT
    dlon = dlat / max(0.01, math.cos(math.radians(lat)))
    return conn.execute(
        "select count(*) from trails t join trails_rtree r on r.id = t.id "
        "where t.name is not null and r.max_lat >= ? and r.min_lat <= ? "
        "and r.max_lon >= ? and r.min_lon <= ?",
        (lat - dlat, lat + dlat, lon - dlon, lon + dlon)).fetchone()[0]


def gates(pack: str, region: dict, extract_bbox) -> list[str]:
    """Every failed gate, as a sentence. Empty means the pack may ship."""
    failures = []
    if not btp.verify_pack(pack):
        return ["the pack failed the builder's verify (schema, index, attribution or polyline round-trip)"]
    conn = sqlite3.connect(f"file:{pack}?mode=ro", uri=True)
    pieces = conn.execute("select count(*) from trails").fetchone()[0]
    if pieces < MIN_PIECES:
        failures.append(f"only {pieces} trails (expected at least {MIN_PIECES})")
    if extract_bbox:
        mnlon, mnlat, mxlon, mxlat = extract_bbox
        a = pack_bbox(conn)
        m = BBOX_MARGIN_DEG
        if a[0] < mnlat - m or a[1] < mnlon - m or a[2] > mxlat + m or a[3] > mxlon + m:
            failures.append(f"trails reach outside the extract's bounds: pack {a}, extract {extract_bbox}")
    p = region["probe"]
    near = named_near(conn, p["lat"], p["lon"], PROBE_RADIUS_M)
    if near == 0:
        failures.append(f"no named trails within {PROBE_RADIUS_M / 1000:.0f} km of {p['place']}")
    conn.close()
    size = os.path.getsize(pack)
    if size > SIZE_BUDGET_BYTES:
        failures.append(f"{size / 1e6:.0f} MB is over the {SIZE_BUDGET_BYTES / 1e6:.0f} MB budget")
    return failures


def names(path: str) -> set[str]:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    out = {r[0] for r in conn.execute("select distinct name from trails where name is not null")}
    conn.close()
    return out


def diff(previous_pack: str | None, pack: str, quality: dict) -> dict:
    if not previous_pack or not os.path.exists(previous_pack):
        return {"previous": None}
    prev_q = pack_quality.report(previous_pack)
    a, b = names(previous_pack), names(pack)
    return {
        "previous": previous_pack,
        "pieces": quality["pieces"] - prev_q["pieces"],
        "named_trails": quality["named_trails"] - prev_q["named_trails"],
        "named_trails_in_pieces": quality["named_trails_in_pieces"] - prev_q["named_trails_in_pieces"],
        "names_added": len(b - a),
        "names_removed": len(a - b),
        "sample_added": sorted(b - a)[:10],
        "sample_removed": sorted(a - b)[:10],
    }


def stamp_meta(pack: str, values: dict) -> None:
    conn = sqlite3.connect(pack)
    conn.executemany("insert or replace into meta (key, value) values (?, ?)",
                     [(k, str(v)) for k, v in values.items()])
    conn.commit()
    conn.close()


def main(argv=None) -> int:
    here = os.path.dirname(__file__)
    ap = argparse.ArgumentParser(description="Gate a built region pack and write its release manifest.")
    ap.add_argument("region")
    ap.add_argument("--pack", required=True)
    ap.add_argument("--work", required=True, help="the trail work directory (holds published/ and release/)")
    ap.add_argument("--extract-md5", default="")
    ap.add_argument("--extract-bbox", default="", help="minlon,minlat,maxlon,maxlat from osmium fileinfo")
    ap.add_argument("--regions", default=os.path.join(here, "regions.json"))
    args = ap.parse_args(argv)

    regions = load_regions(args.regions)
    if args.region not in regions:
        print(f"Unknown region '{args.region}'. Add it to {args.regions}.", file=sys.stderr)
        return 2
    region = regions[args.region]
    bbox = tuple(float(x) for x in args.extract_bbox.split(",")) if args.extract_bbox else None

    failures = gates(args.pack, region, bbox)
    quality = pack_quality.report(args.pack)
    print(f"\nQuality — {region['name']}")
    pack_quality.main([args.pack])
    if failures:
        print("\nGATES FAILED — do not publish:")
        for f in failures:
            print(f"  • {f}")
        return 1

    published_path = os.path.join(args.work, "published", f"{args.region}.json")
    previous = None
    if os.path.exists(published_path):
        with open(published_path) as f:
            previous = json.load(f)
    pack_version = (previous["packVersion"] + 1) if previous else 1

    stamp_meta(args.pack, {"pack_version": pack_version, "source_extract_md5": args.extract_md5})
    conn = sqlite3.connect(f"file:{args.pack}?mode=ro", uri=True)
    meta = dict(conn.execute("select key, value from meta"))
    trail_count = conn.execute("select count(*) from trails").fetchone()[0]
    conn.close()

    manifest = {
        "region": args.region,
        "regionName": region["name"],
        "schemaVersion": int(meta["schema_version"]),
        "packVersion": pack_version,
        "builtAt": meta["built_at"],
        "trailCount": trail_count,
        "sizeBytes": os.path.getsize(args.pack),
        "sha256": sha256(args.pack),
        "sourceExtractMd5": args.extract_md5,
        "builderVersion": meta.get("builder_version"),
        "pack": os.path.abspath(args.pack),
        "quality": quality,
        "changes": diff(previous.get("pack") if previous else None, args.pack, quality),
    }
    os.makedirs(os.path.join(args.work, "release"), exist_ok=True)
    out = os.path.join(args.work, "release", f"{args.region}-v{pack_version}.json")
    with open(out, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"\nGates passed. Release manifest: {out}")
    c = manifest["changes"]
    if c.get("previous"):
        print(f"Against v{pack_version - 1}: pieces {c['pieces']:+}, named trails {c['named_trails']:+}, "
              f"names +{c['names_added']} / -{c['names_removed']}")
    else:
        print("First release for this region.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
