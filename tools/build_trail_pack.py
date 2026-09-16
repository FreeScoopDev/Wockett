#!/usr/bin/env python3
"""
build_trail_pack.py — Wockett trail region-pack builder.

Turns public trail data (OSM via osmium, USGS National Digital Trails, NPS, state GIS)
into a single versioned SQLite "region pack" the app ships or downloads.

Design rules this script exists to enforce:
  * No third-party API is called at runtime. Everything is baked here, on the Mac.
  * One normalized schema regardless of source. Source is recorded per row.
  * Attribution travels WITH the data, in the pack, so it can never drift from it.
  * Every pack is stamped with a schema version and a build date.

Dependencies: none. Python 3.9+ standard library only.

Typical use (after the osmium steps in the Notion card):

    python3 tools/build_trail_pack.py \
        --region nc \
        --region-name "North Carolina" \
        --input nc-trails.geojsonseq:osm \
        --out packs/nc.wktpack

Multiple sources merge into one pack:

    python3 tools/build_trail_pack.py --region nc --region-name "North Carolina" \
        --input nc-trails.geojsonseq:osm \
        --input usgs-nc-trails.geojson:usgs \
        --out packs/nc.wktpack

Inspect a finished pack:

    python3 tools/build_trail_pack.py --inspect packs/nc.wktpack
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sqlite3
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Iterable, Iterator, Optional, Sequence

# ---------------------------------------------------------------------------
# Versioning. Bump SCHEMA_VERSION whenever the table layout changes in a way the
# app must know about; the app refuses packs whose schema it does not understand.
# ---------------------------------------------------------------------------

SCHEMA_VERSION = 1
BUILDER_VERSION = "1.0.0"

# ---------------------------------------------------------------------------
# Source registry. Attribution lives here and is copied into every pack, so a
# pack is always self-describing and the app never hardcodes a credit string.
# ---------------------------------------------------------------------------

SOURCES: dict[str, dict[str, str]] = {
    "osm": {
        "name": "OpenStreetMap",
        "attribution": "© OpenStreetMap contributors",
        "license": "ODbL 1.0",
        "url": "https://www.openstreetmap.org/copyright",
        "requires_attribution": "1",
    },
    "usgs": {
        "name": "USGS National Digital Trails",
        "attribution": "Trail data courtesy of the U.S. Geological Survey",
        "license": "Public domain",
        "url": "https://www.usgs.gov/national-digital-trails",
        "requires_attribution": "0",
    },
    "nps": {
        "name": "National Park Service",
        "attribution": "Park information courtesy of the U.S. National Park Service",
        "license": "Public domain",
        "url": "https://www.nps.gov/subjects/developer/",
        "requires_attribution": "0",
    },
    "ridb": {
        "name": "Recreation.gov (RIDB)",
        "attribution": "Recreation data courtesy of Recreation.gov",
        "license": "Public domain",
        "url": "https://ridb.recreation.gov/",
        "requires_attribution": "0",
    },
    "state": {
        "name": "State / county open GIS",
        "attribution": "Includes data from state and county open GIS sources",
        "license": "Varies — verify per dataset",
        "url": "",
        "requires_attribution": "1",
    },
}

# ---------------------------------------------------------------------------
# Dog access. The differentiator, so it gets its own vocabulary and a recorded
# provenance for every value — "we inferred this" is not the same as "the data
# said so", and the UI needs to be able to tell the user which it was.
# ---------------------------------------------------------------------------

DOG_OFF_LEASH = "offLeashAllowed"
DOG_LEASHED = "leashRequired"
DOG_NOT_PERMITTED = "notPermitted"
DOG_UNKNOWN = "unknown"

_TRUE_ISH = {"yes", "permissive", "designated", "official", "public", "true", "1"}
_FALSE_ISH = {"no", "private", "prohibited", "false", "0"}


def derive_dog_access(tags: dict[str, str]) -> tuple[str, str]:
    """Return (dog_access, provenance).

    provenance is one of: tagged | inferred | default — so the app can show
    "dogs allowed" confidently and "probably fine" cautiously.
    """
    dog = (tags.get("dog") or "").strip().lower()
    if dog in {"unleashed", "off-leash", "off_leash"}:
        return DOG_OFF_LEASH, "tagged"
    if dog in {"leashed", "on_leash", "on-leash"}:
        return DOG_LEASHED, "tagged"
    if dog in _FALSE_ISH:
        return DOG_NOT_PERMITTED, "tagged"
    if dog in _TRUE_ISH:
        # "dog=yes" means dogs are allowed but says nothing about leashing.
        # Leash-required is the safe reading and the legally safer one to show.
        return DOG_LEASHED, "tagged"

    if (tags.get("leisure") or "").strip().lower() == "dog_park":
        return DOG_OFF_LEASH, "tagged"

    # A path nobody may enter is a path dogs may not enter.
    access = (tags.get("access") or "").strip().lower()
    foot = (tags.get("foot") or "").strip().lower()
    if access in _FALSE_ISH and foot not in _TRUE_ISH:
        return DOG_NOT_PERMITTED, "inferred"

    return DOG_UNKNOWN, "default"


# ---------------------------------------------------------------------------
# Geometry helpers. All standard library — no shapely, no geopandas, so the
# script runs anywhere with a bare Python and never breaks on a dependency bump.
# ---------------------------------------------------------------------------

_EARTH_RADIUS_M = 6_371_008.8


def haversine_m(a: Sequence[float], b: Sequence[float]) -> float:
    """Distance in metres between two (lon, lat) points."""
    lon1, lat1 = math.radians(a[0]), math.radians(a[1])
    lon2, lat2 = math.radians(b[0]), math.radians(b[1])
    dlon, dlat = lon2 - lon1, lat2 - lat1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * _EARTH_RADIUS_M * math.asin(math.sqrt(min(1.0, h)))


def line_length_m(coords: Sequence[Sequence[float]]) -> float:
    return sum(haversine_m(coords[i], coords[i + 1]) for i in range(len(coords) - 1))


def _perpendicular_distance(
    point: Sequence[float], start: Sequence[float], end: Sequence[float]
) -> float:
    """Approximate perpendicular distance in degrees, latitude-corrected.

    Good enough for simplification tolerances; we are shrinking a file, not
    surveying a boundary.
    """
    lat_scale = math.cos(math.radians(point[1])) or 1e-9
    px, py = point[0] * lat_scale, point[1]
    sx, sy = start[0] * lat_scale, start[1]
    ex, ey = end[0] * lat_scale, end[1]

    dx, dy = ex - sx, ey - sy
    if dx == 0 and dy == 0:
        return math.hypot(px - sx, py - sy)
    t = ((px - sx) * dx + (py - sy) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    return math.hypot(px - (sx + t * dx), py - (sy + t * dy))


def simplify(coords: list[list[float]], tolerance_deg: float) -> list[list[float]]:
    """Iterative Douglas-Peucker. Iterative, not recursive, because some OSM
    ways are long enough to blow Python's recursion limit."""
    if tolerance_deg <= 0 or len(coords) < 3:
        return coords

    keep = [False] * len(coords)
    keep[0] = keep[-1] = True
    stack = [(0, len(coords) - 1)]

    while stack:
        first, last = stack.pop()
        if last <= first + 1:
            continue
        max_dist, index = 0.0, first
        for i in range(first + 1, last):
            d = _perpendicular_distance(coords[i], coords[first], coords[last])
            if d > max_dist:
                max_dist, index = d, i
        if max_dist > tolerance_deg:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))

    return [c for c, k in zip(coords, keep) if k]


def encode_polyline(coords: Sequence[Sequence[float]], precision: int = 5) -> str:
    """Google encoded-polyline format. Roughly 5x smaller than raw JSON floats,
    and iOS can decode it in a few lines."""
    factor = 10 ** precision
    out: list[str] = []
    prev_lat = prev_lon = 0

    for lon, lat in coords:
        lat_i = int(round(lat * factor))
        lon_i = int(round(lon * factor))
        for delta in (lat_i - prev_lat, lon_i - prev_lon):
            v = ~(delta << 1) if delta < 0 else (delta << 1)
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1F)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        prev_lat, prev_lon = lat_i, lon_i

    return "".join(out)


def decode_polyline(encoded: str, precision: int = 5) -> list[list[float]]:
    """Inverse of encode_polyline. Here so the pack can be verified in one
    process rather than trusted — see verify_pack()."""
    factor = 10 ** precision
    coords: list[list[float]] = []
    index = lat = lon = 0

    while index < len(encoded):
        for axis in range(2):
            result, shift = 0, 0
            while True:
                b = ord(encoded[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            delta = ~(result >> 1) if result & 1 else (result >> 1)
            if axis == 0:
                lat += delta
            else:
                lon += delta
        coords.append([lon / factor, lat / factor])

    return coords


# ---------------------------------------------------------------------------
# Normalized record
# ---------------------------------------------------------------------------


@dataclass
class Trail:
    source_id: str
    source_ref: str
    name: Optional[str]
    polyline: str
    point_count: int
    length_m: float
    min_lat: float
    min_lon: float
    max_lat: float
    max_lon: float
    surface: Optional[str]
    difficulty: Optional[str]
    dog_access: str
    dog_access_provenance: str
    allows_foot: int
    allows_bike: int
    allows_horse: int
    is_loop: int
    tags_json: str


@dataclass
class Stats:
    read: int = 0
    written: int = 0
    skipped_geometry: int = 0
    skipped_short: int = 0
    skipped_duplicate: int = 0
    points_before: int = 0
    points_after: int = 0
    dog: dict[str, int] = field(default_factory=dict)


# OSM tags worth carrying into the pack. Everything else is dropped — a pack is
# a shipping artifact, not an archive, and every retained tag costs bytes on a
# user's phone.
KEPT_TAGS = (
    "highway", "route", "surface", "smoothness", "sac_scale", "trail_visibility",
    "width", "incline", "dog", "access", "foot", "bicycle", "horse", "leisure",
    "operator", "network", "ref", "oneway", "lit", "wheelchair",
)

_BIKE_OK = _TRUE_ISH | {"dismount"}


def _yes_no(value: Optional[str], default: int) -> int:
    if value is None:
        return default
    v = value.strip().lower()
    if v in _TRUE_ISH:
        return 1
    if v in _FALSE_ISH:
        return 0
    return default


def normalize_feature(
    feature: dict[str, Any],
    source_id: str,
    tolerance_deg: float,
    stats: Stats,
) -> Optional[Trail]:
    geom = feature.get("geometry") or {}
    gtype = geom.get("type")
    raw = geom.get("coordinates") or []

    if gtype == "LineString":
        lines = [raw]
    elif gtype == "MultiLineString":
        lines = raw
    else:
        stats.skipped_geometry += 1
        return None

    coords: list[list[float]] = []
    for line in lines:
        coords.extend(line)

    coords = [c[:2] for c in coords if isinstance(c, (list, tuple)) and len(c) >= 2]
    if len(coords) < 2:
        stats.skipped_geometry += 1
        return None

    stats.points_before += len(coords)
    simplified = simplify(coords, tolerance_deg)
    stats.points_after += len(simplified)

    props = {k: v for k, v in (feature.get("properties") or {}).items() if v is not None}
    tags = {k: str(v) for k, v in props.items()}

    length_m = line_length_m(simplified)

    # osmium's geojsonseq export puts the object id at the FEATURE level
    # ("id": "w12345"), not inside properties — check there first or every
    # OSM feature falls through to the fallback below.
    # The fallback must be a stable digest, not hash(): Python randomizes
    # string hashing per process, so hash() would give a trail a different
    # id on every build and break identity across pack versions.
    source_ref = str(
        feature.get("id")
        or props.get("@id")
        or props.get("id")
        or props.get("osm_id")
        or props.get("TRLNAME")
        or f"{source_id}:{hashlib.sha1(encode_polyline(simplified).encode()).hexdigest()[:16]}"
    )

    name = props.get("name") or props.get("TRLNAME") or props.get("trail_name")
    dog_access, provenance = derive_dog_access(tags)

    lats = [c[1] for c in simplified]
    lons = [c[0] for c in simplified]

    start, end = simplified[0], simplified[-1]
    is_loop = 1 if haversine_m(start, end) < 50 and length_m > 200 else 0

    highway = (tags.get("highway") or "").lower()
    kept = {k: tags[k] for k in KEPT_TAGS if k in tags}

    return Trail(
        source_id=source_id,
        source_ref=source_ref,
        name=str(name) if name else None,
        polyline=encode_polyline(simplified),
        point_count=len(simplified),
        length_m=round(length_m, 1),
        min_lat=min(lats), min_lon=min(lons), max_lat=max(lats), max_lon=max(lons),
        surface=tags.get("surface"),
        difficulty=tags.get("sac_scale"),
        dog_access=dog_access,
        dog_access_provenance=provenance,
        allows_foot=_yes_no(tags.get("foot"), 0 if highway == "cycleway" else 1),
        allows_bike=1 if (tags.get("bicycle", "").lower() in _BIKE_OK
                          or highway == "cycleway") else 0,
        allows_horse=1 if (tags.get("horse", "").lower() in _TRUE_ISH
                           or highway == "bridleway") else 0,
        is_loop=is_loop,
        tags_json=json.dumps(kept, separators=(",", ":"), sort_keys=True),
    )


# ---------------------------------------------------------------------------
# Input readers
# ---------------------------------------------------------------------------


def read_features(path: str) -> Iterator[dict[str, Any]]:
    """Read either GeoJSON Text Sequence (osmium -f geojsonseq) or a plain
    GeoJSON FeatureCollection. Detected by content, not by file extension."""
    with open(path, "r", encoding="utf-8") as handle:
        first = handle.readline()
        handle.seek(0)

        stripped = first.strip().lstrip("\x1e")
        looks_like_collection = '"FeatureCollection"' in first or stripped in {"{", ""}

        if looks_like_collection:
            try:
                doc = json.load(handle)
            except json.JSONDecodeError:
                handle.seek(0)
                yield from _read_sequence(handle)
                return
            for feature in doc.get("features", []):
                yield feature
            return

        yield from _read_sequence(handle)


def _read_sequence(handle) -> Iterator[dict[str, Any]]:
    for line in handle:
        line = line.strip().lstrip("\x1e")
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


# ---------------------------------------------------------------------------
# Pack writing
# ---------------------------------------------------------------------------

DDL = """
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;

CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE attribution (
    source_id            TEXT PRIMARY KEY,
    name                 TEXT NOT NULL,
    attribution          TEXT NOT NULL,
    license              TEXT NOT NULL,
    url                  TEXT,
    requires_attribution INTEGER NOT NULL
);

CREATE TABLE trails (
    id                     INTEGER PRIMARY KEY,
    source_id              TEXT NOT NULL,
    source_ref             TEXT NOT NULL,
    name                   TEXT,
    polyline               TEXT NOT NULL,
    point_count            INTEGER NOT NULL,
    length_m               REAL NOT NULL,
    min_lat                REAL NOT NULL,
    min_lon                REAL NOT NULL,
    max_lat                REAL NOT NULL,
    max_lon                REAL NOT NULL,
    surface                TEXT,
    difficulty             TEXT,
    dog_access             TEXT NOT NULL,
    dog_access_provenance  TEXT NOT NULL,
    allows_foot            INTEGER NOT NULL,
    allows_bike            INTEGER NOT NULL,
    allows_horse           INTEGER NOT NULL,
    is_loop                INTEGER NOT NULL,
    tags_json              TEXT NOT NULL,
    UNIQUE (source_id, source_ref)
);

CREATE VIRTUAL TABLE trails_rtree USING rtree(
    id, min_lat, max_lat, min_lon, max_lon
);

CREATE INDEX idx_trails_dog    ON trails (dog_access);
CREATE INDEX idx_trails_length ON trails (length_m);
CREATE INDEX idx_trails_name   ON trails (name);
"""


def build_pack(
    inputs: list[tuple[str, str]],
    out_path: str,
    region: str,
    region_name: str,
    tolerance_deg: float,
    min_length_m: float,
) -> Stats:
    if os.path.exists(out_path):
        os.remove(out_path)
    parent = os.path.dirname(os.path.abspath(out_path))
    os.makedirs(parent, exist_ok=True)

    conn = sqlite3.connect(out_path)
    conn.executescript(DDL)

    stats = Stats()
    seen: set[tuple[str, str]] = set()
    used_sources: set[str] = set()
    next_id = 1

    for path, source_id in inputs:
        if source_id not in SOURCES:
            raise SystemExit(
                f"Unknown source '{source_id}'. Known: {', '.join(sorted(SOURCES))}"
            )
        used_sources.add(source_id)

        batch: list[tuple] = []
        rtree_batch: list[tuple] = []

        for feature in read_features(path):
            stats.read += 1
            trail = normalize_feature(feature, source_id, tolerance_deg, stats)
            if trail is None:
                continue
            if trail.length_m < min_length_m:
                stats.skipped_short += 1
                continue

            key = (trail.source_id, trail.source_ref)
            if key in seen:
                stats.skipped_duplicate += 1
                continue
            seen.add(key)
            stats.dog[trail.dog_access] = stats.dog.get(trail.dog_access, 0) + 1

            batch.append((
                next_id, trail.source_id, trail.source_ref, trail.name, trail.polyline,
                trail.point_count, trail.length_m, trail.min_lat, trail.min_lon,
                trail.max_lat, trail.max_lon, trail.surface, trail.difficulty,
                trail.dog_access, trail.dog_access_provenance, trail.allows_foot,
                trail.allows_bike, trail.allows_horse, trail.is_loop, trail.tags_json,
            ))
            rtree_batch.append(
                (next_id, trail.min_lat, trail.max_lat, trail.min_lon, trail.max_lon)
            )
            next_id += 1
            stats.written += 1

            if len(batch) >= 5000:
                _flush(conn, batch, rtree_batch)
                batch, rtree_batch = [], []

        _flush(conn, batch, rtree_batch)

    for source_id in sorted(used_sources):
        s = SOURCES[source_id]
        conn.execute(
            "INSERT INTO attribution VALUES (?,?,?,?,?,?)",
            (source_id, s["name"], s["attribution"], s["license"], s["url"],
             int(s["requires_attribution"])),
        )

    for key, value in {
        "schema_version": str(SCHEMA_VERSION),
        "builder_version": BUILDER_VERSION,
        "region": region,
        "region_name": region_name,
        "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "trail_count": str(stats.written),
        "simplify_tolerance_deg": str(tolerance_deg),
        "min_length_m": str(min_length_m),
        "sources": ",".join(sorted(used_sources)),
    }.items():
        conn.execute("INSERT INTO meta VALUES (?,?)", (key, value))

    conn.commit()
    conn.execute("VACUUM")
    conn.close()
    return stats


def _flush(conn: sqlite3.Connection, batch: list, rtree_batch: list) -> None:
    if not batch:
        return
    conn.executemany(
        "INSERT INTO trails VALUES (" + ",".join("?" * 20) + ")", batch
    )
    conn.executemany("INSERT INTO trails_rtree VALUES (?,?,?,?,?)", rtree_batch)


# ---------------------------------------------------------------------------
# Verification — a pack that has not been queried has not been tested.
# ---------------------------------------------------------------------------


def verify_pack(path: str) -> bool:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    ok = True

    meta = {r["key"]: r["value"] for r in conn.execute("SELECT * FROM meta")}
    if meta.get("schema_version") != str(SCHEMA_VERSION):
        print(f"  FAIL schema_version = {meta.get('schema_version')!r}")
        ok = False

    trails = conn.execute("SELECT COUNT(*) FROM trails").fetchone()[0]
    rtree = conn.execute("SELECT COUNT(*) FROM trails_rtree").fetchone()[0]
    if trails != rtree:
        print(f"  FAIL trails={trails} but rtree={rtree} — index out of sync")
        ok = False

    if trails and not conn.execute("SELECT COUNT(*) FROM attribution").fetchone()[0]:
        print("  FAIL pack has trails but no attribution rows")
        ok = False

    # A real spatial query through the R*Tree, the way the app will do it.
    row = conn.execute("SELECT * FROM trails LIMIT 1").fetchone()
    if row:
        pad = 0.01
        hits = conn.execute(
            "SELECT COUNT(*) FROM trails_rtree WHERE max_lat >= ? AND min_lat <= ? "
            "AND max_lon >= ? AND min_lon <= ?",
            (row["min_lat"] - pad, row["max_lat"] + pad,
             row["min_lon"] - pad, row["max_lon"] + pad),
        ).fetchone()[0]
        if hits < 1:
            print("  FAIL R*Tree bbox query returned nothing for a known trail")
            ok = False

        decoded = decode_polyline(row["polyline"])
        if len(decoded) != row["point_count"]:
            print(f"  FAIL polyline round-trip: {len(decoded)} != {row['point_count']}")
            ok = False
        elif not (row["min_lat"] - 1e-4 <= decoded[0][1] <= row["max_lat"] + 1e-4):
            print("  FAIL decoded polyline falls outside its own bounding box")
            ok = False

    conn.close()
    return ok


def inspect_pack(path: str) -> None:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    print(f"\n{path}  ({os.path.getsize(path) / 1e6:.2f} MB)")
    print("-" * 60)
    for row in conn.execute("SELECT * FROM meta ORDER BY key"):
        print(f"  {row['key']:<24} {row['value']}")
    print("\n  dog access:")
    for row in conn.execute(
        "SELECT dog_access, COUNT(*) n FROM trails GROUP BY dog_access ORDER BY n DESC"
    ):
        print(f"    {row['dog_access']:<18} {row['n']:>8,}")
    print("\n  attribution:")
    for row in conn.execute("SELECT * FROM attribution"):
        print(f"    [{row['source_id']}] {row['attribution']}  ({row['license']})")
    conn.close()
    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_input(spec: str) -> tuple[str, str]:
    if ":" not in spec:
        raise SystemExit(
            f"--input needs PATH:SOURCE (e.g. nc-trails.geojsonseq:osm), got {spec!r}"
        )
    path, source_id = spec.rsplit(":", 1)
    if not os.path.exists(path):
        raise SystemExit(f"Input file not found: {path}")
    return path, source_id


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build a Wockett trail region pack from public trail data.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--input", action="append", default=[], metavar="PATH:SOURCE",
                        help="Input file and its source id. Repeatable. "
                             f"Sources: {', '.join(sorted(SOURCES))}")
    parser.add_argument("--out", help="Output pack path (e.g. packs/nc.wktpack)")
    parser.add_argument("--region", help="Short region code, e.g. nc")
    parser.add_argument("--region-name", help='Display name, e.g. "North Carolina"')
    parser.add_argument("--simplify", type=float, default=0.00002,
                        help="Douglas-Peucker tolerance in degrees "
                             "(default 0.00002, roughly 2 m). 0 disables.")
    parser.add_argument("--min-length", type=float, default=30.0,
                        help="Drop trails shorter than this many metres (default 30)")
    parser.add_argument("--inspect", metavar="PACK", help="Print a pack's metadata and exit")

    args = parser.parse_args(argv)

    if args.inspect:
        inspect_pack(args.inspect)
        return 0

    missing = [f for f in ("input", "out", "region", "region_name")
               if not getattr(args, f)]
    if missing:
        parser.error("missing required: " + ", ".join("--" + m.replace("_", "-")
                                                      for m in missing))

    inputs = [parse_input(spec) for spec in args.input]

    started = time.time()
    stats = build_pack(inputs, args.out, args.region, args.region_name,
                       args.simplify, args.min_length)
    elapsed = time.time() - started

    size_mb = os.path.getsize(args.out) / 1e6
    reduction = (
        100 * (1 - stats.points_after / stats.points_before)
        if stats.points_before else 0.0
    )

    print(f"\nBuilt {args.out}")
    print(f"  features read      {stats.read:,}")
    print(f"  trails written     {stats.written:,}")
    print(f"  skipped geometry   {stats.skipped_geometry:,}")
    print(f"  skipped too short  {stats.skipped_short:,}")
    print(f"  skipped duplicate  {stats.skipped_duplicate:,}")
    print(f"  points {stats.points_before:,} -> {stats.points_after:,} "
          f"({reduction:.1f}% removed)")
    print(f"  dog access         " + ", ".join(
        f"{k}={v:,}" for k, v in sorted(stats.dog.items(), key=lambda x: -x[1])))
    print(f"  pack size          {size_mb:.2f} MB")
    print(f"  elapsed            {elapsed:.1f}s")

    print("\nVerifying...")
    if not verify_pack(args.out):
        print("  VERIFICATION FAILED — do not ship this pack.")
        return 1
    print("  OK — schema, R*Tree index, attribution and polyline round-trip all pass.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
