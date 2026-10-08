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
BUILDER_VERSION = "1.3.1"

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
    # Assigned in input order when the way is read, before any merging, so a
    # trail's id does not depend on whether it was merged or on write order.
    # A merged row takes the smallest id among its members.
    id: int = 0
    # Build-time only — never written to the pack. Which ways may be joined
    # (see join_unnamed_ways) and whether this way is a sidewalk.
    family: str = ""
    surface_class: str = ""
    is_sidewalk: bool = False
    is_crossing: bool = False
    # Explicit "no" for a mode (foot=no, bicycle=no, horse=no, or access=no
    # without a yes for that mode). Different from allows_* = 0, which is also
    # what "the data does not say" looks like. See _merged_row.
    forbids_foot: bool = False
    forbids_bike: bool = False
    forbids_horse: bool = False
    # Length that counts toward the --min-length floor: a merged row's
    # crossings are links, not trail, and do not count (None = length_m).
    floor_length_m: Optional[float] = None
    trail_key: Optional[str] = None


@dataclass
class Stats:
    merged_ways: int = 0
    merge_groups: int = 0
    merge_groups_left: int = 0
    joined_unnamed_ways: int = 0
    unnamed_corridors: int = 0
    derived_names: int = 0
    derived_suppressed_named: int = 0
    derived_side_suffixed: int = 0
    derived_same_side_pairs: int = 0
    skipped_sidewalk: int = 0
    skipped_crossing: int = 0
    skipped_unnamed: int = 0
    generic_names: int = 0
    junction_merges: int = 0
    bridged_gaps: int = 0
    skipped_short_unnamed: int = 0
    trail_keys: int = 0
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


# Names that say what a path is, not which path it is. Listed as trails they
# read as clutter ("Trail" x37, "Service Road" x27, "Connector" x23 in the NC
# pack, 2026-10-08), and a same-name group of them across a park is not one
# trail. Treated as unnamed, they join the unnamed corridors and can take a
# derived name from the road alongside. Exact matches only, case and spacing
# ignored: "Nature Trail" or "Red Trail" are real names inside their park.
GENERIC_NAMES = frozenset({
    "trail", "trails", "path", "paths", "footpath", "foot path", "foot trail",
    "walkway", "walking path", "walking trail", "sidewalk", "service road",
    "connector", "connector trail", "connector path", "multi-use trail",
    "multi-use path", "multiuse trail", "multi use trail", "multi-use",
    "ramp", "stairs", "steps", "driveway", "access", "access trail",
    "beach access", "public beach access", "bike path", "bike trail",
    "greenway", "unnamed", "unnamed trail", "no name",
    # 1.3.1: descriptions found building SC, VA, TN and GA (2026-10-08).
    # "abandoned track" was 46 rows in Georgia, "Logging Road" 37 across
    # four states, "WMA Road" 22: what the way is, not a trail to choose.
    "abandoned track", "abandoned road", "logging road", "wma road",
    "jeep trail", "tank trail", "field road", "access road",
    "forest service road", "fire road", "wildlife planting",
    "shortcut", "short cut", "cut through", "cut-through",
})


def is_generic_name(name: Optional[str]) -> bool:
    return bool(name) and " ".join(str(name).lower().split()) in GENERIC_NAMES


def normalize_feature(
    feature: dict[str, Any],
    source_id: str,
    tolerance_deg: float,
    stats: Stats,
) -> Optional[tuple[Trail, list[list[float]]]]:
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
    if is_generic_name(name):
        stats.generic_names += 1
        name = None
    dog_access, provenance = derive_dog_access(tags)

    lats = [c[1] for c in simplified]
    lons = [c[0] for c in simplified]

    start, end = simplified[0], simplified[-1]
    is_loop = 1 if haversine_m(start, end) < 50 and length_m > 200 else 0

    highway = (tags.get("highway") or "").lower()
    kept = {k: tags[k] for k in KEPT_TAGS if k in tags}

    return (Trail(
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
        family=path_family(highway, tags.get("footway")),
        surface_class=surface_class(tags.get("surface")),
        is_sidewalk=_is_sidewalk(highway, tags.get("footway")),
        is_crossing=_is_crossing(highway, tags),
        forbids_foot=_forbids(tags, "foot"),
        forbids_bike=_forbids(tags, "bicycle"),
        forbids_horse=_forbids(tags, "horse"),
    ), simplified)


def _forbids(tags: dict[str, str], mode: str) -> bool:
    """True only when the data says no for this mode, never by default."""
    value = (tags.get(mode) or "").strip().lower()
    if value in _FALSE_ISH:
        return True
    access = (tags.get("access") or "").strip().lower()
    return access in _FALSE_ISH and value not in _TRUE_ISH and value != "dismount"


# ---------------------------------------------------------------------------
# Kinds of way. Used to decide which unnamed ways may be joined into one
# corridor, and which ways are not trails at all.
# ---------------------------------------------------------------------------

# path, footway and cycleway are one family: mappers tag the same kind of
# shared-use path all three ways, often block by block, and the crossings
# that link a cycleway's pieces are footways. Steps join them too — a flight of steps is part of the
# walk it sits on. Tracks and bridleways are different things to walk on and
# only join their own kind. Sidewalks, when kept, only join sidewalks.
_PATH_FAMILY = {"path", "footway", "cycleway", "steps", "pedestrian"}


def _is_sidewalk(highway: str, footway: Optional[str]) -> bool:
    return highway == "footway" and (footway or "").strip().lower() == "sidewalk"


def _is_crossing(highway: str, tags: dict[str, str]) -> bool:
    """The piece of a path that crosses a road. Not a trail on its own, but
    the link between the two halves of a sidepath either side of a street."""
    return highway in _PATH_FAMILY and any(
        (tags.get(k) or "").strip().lower() == "crossing" for k in ("footway", "cycleway", "path"))


def path_family(highway: str, footway: Optional[str] = None) -> str:
    highway = (highway or "").strip().lower()
    if _is_sidewalk(highway, footway):
        return "sidewalk"
    if highway in _PATH_FAMILY:
        return "path"
    return highway  # track, bridleway, or whatever a non-OSM source says


# Surface classes. Paved and unpaved never join: a greenway and the dirt trail
# that leaves it are two walks. Boardwalks and bridges (wood, metal) sit in
# both kinds of trail, so they are neutral, as is a way with no surface tag.
_PAVED = {
    "paved", "asphalt", "concrete", "concrete:plates", "concrete:lanes",
    "paving_stones", "sett", "cobblestone", "unhewn_cobblestone", "bricks",
    "brick", "chipseal", "rubber", "tartan", "acrylic",
}
_UNPAVED = {
    "unpaved", "gravel", "fine_gravel", "compacted", "dirt", "earth", "ground",
    "grass", "sand", "mud", "rock", "rocks", "stone", "pebblestone", "woodchips",
    "grass_paver", "clay", "shells", "snow", "ice", "dirt/sand", "soil",
}
SURFACE_PAVED, SURFACE_UNPAVED, SURFACE_UNKNOWN = "paved", "unpaved", ""


def surface_class(surface: Optional[str]) -> str:
    s = (surface or "").strip().lower()
    if s in _PAVED:
        return SURFACE_PAVED
    if s in _UNPAVED:
        return SURFACE_UNPAVED
    return SURFACE_UNKNOWN


# ---------------------------------------------------------------------------
# Way merging. OSM maps a long trail as many ways — the Mountains-to-Sea Trail
# is 266 of them, the Appalachian Trail 181 — and a directory that lists a
# trail 266 times is not a directory. Merging happens here, in the builder,
# because baked data is the cheap place to do it: query-time aggregation is
# paid on every device, forever (decided 2026-09-16).
#
# Ways chain through every endpoint that exactly two same-named ways share.
# At a junction — three or more ways meeting — the chain stops and the other
# ways start their own: a park's branching network keeps its branches, while
# the main line of a long trail merges even where a same-named spur hangs off
# it. (The first cut refused any component containing a junction; on real
# data one spur left the Mountains-to-Sea Trail in 151 pieces.) Identity of a
# merged row is the smallest member ref, so a rebuild reassigns nothing.
# ---------------------------------------------------------------------------

# Endpoints within this distance are the same node. OSM ways that meet share a
# node exactly; after simplification the endpoints are untouched, so this only
# needs to absorb float noise. 1e-5 deg is about 1 m.
_ENDPOINT_KEY_DECIMALS = 5


def _endpoint_key(coord: Sequence[float]) -> tuple[float, float]:
    return (round(coord[0], _ENDPOINT_KEY_DECIMALS), round(coord[1], _ENDPOINT_KEY_DECIMALS))


_DOG_CONSERVATIVE_ORDER = (DOG_NOT_PERMITTED, DOG_LEASHED, DOG_OFF_LEASH, DOG_UNKNOWN)


def merge_named_ways(
    members: list[tuple[Trail, list[list[float]]]],
    stats: Stats,
) -> list[tuple[Trail, list[list[float]]]]:
    """Chain one name's ways end to end wherever exactly two of them meet.

    `members` are (trail, simplified coords) for every way sharing a name and
    a source. Returns the rows to write — merged chains plus untouched ways —
    in a deterministic order.
    """
    if len(members) < 2:
        return members

    members = sorted(members, key=lambda m: m[0].source_ref)
    at: dict[tuple[float, float], list[int]] = {}
    for i, (_, coords) in enumerate(members):
        at.setdefault(_endpoint_key(coords[0]), []).append(i)
        at.setdefault(_endpoint_key(coords[-1]), []).append(i)
    if any(len(v) > 2 for v in at.values()):
        stats.merge_groups_left += 1  # has at least one junction

    pairs: dict[tuple[float, float], dict[int, int]] = {}

    def junction_pairs(node: tuple[float, float]) -> dict[int, int]:
        """Where three or more ways of one name meet, which continue into which.

        Builder 1.3.0 (2026-10-08): a trail with a spur or a fork used to stay
        in pieces, every way at the junction left unmerged ("Neuse River
        Trail" in 29). The ways are paired straightest first: two ways join
        through the junction when the turn between them is within
        JUNCTION_MAX_DEFLECTION_DEG (the rule unnamed corridors use), each
        way joins at most one other, and only when the pair is clearly the
        straightest: for both ways, any other way there is at least
        JUNCTION_CLEAR_MARGIN_DEG more of a turn. A symmetric Y has no
        "straight on", so it is not guessed. Spurs and forks stay separate
        rows; the trail key ties them back to the trail.
        """
        if node in pairs:
            return pairs[node]
        ways = at.get(node, [])
        heads = {i: _end_heading(members[i][1], _endpoint_key(members[i][1][0]) == node) for i in ways}
        candidates = sorted(
            (deflection_deg(heads[a], heads[b]), a, b)
            for k, a in enumerate(ways) for b in ways[k + 1:] if a != b
        )
        angle_of = {(a, b): ang for ang, a, b in candidates}
        angle_of.update({(b, a): ang for (a, b), ang in list(angle_of.items())})

        def clearly_best(x: int, partner: int, angle: float) -> bool:
            others = [angle_of[(x, o)] for o in ways if o not in (x, partner) and (x, o) in angle_of]
            return all(o - angle >= JUNCTION_CLEAR_MARGIN_DEG for o in others)

        out: dict[int, int] = {}
        for angle, a, b in candidates:
            if angle > JUNCTION_MAX_DEFLECTION_DEG:
                break
            if a not in out and b not in out and clearly_best(a, b, angle) and clearly_best(b, a, angle):
                out[a], out[b] = b, a
        pairs[node] = out
        return out

    def neighbour(node: tuple[float, float], current: int, used: set[int]) -> Optional[int]:
        """The unused way that continues `current` through `node`: the only
        other way there, or at a junction the one it pairs with."""
        ways = at.get(node, [])
        if len(ways) == 2:
            other = ways[0] if ways[1] == current else ways[1]
        elif len(ways) > 2:
            other = junction_pairs(node).get(current)
            if other is not None and other not in used:
                stats.junction_merges += 1
        else:
            return None
        return None if other is None or other in used or other == current else other

    def oriented(i: int, from_node: tuple[float, float]) -> list[list[float]]:
        c = members[i][1]
        return list(c) if _endpoint_key(c[0]) == from_node else list(reversed(c))

    used: set[int] = set()
    out: list[tuple[Trail, list[list[float]]]] = []
    for seed in range(len(members)):
        if seed in used:
            continue
        used.add(seed)
        coords = list(members[seed][1])
        parts = [seed]

        # Walk forward from the seed's end, then backward from its start.
        for direction in ("forward", "backward"):
            if direction == "backward":
                coords.reverse()
            while True:
                node = _endpoint_key(coords[-1])
                nxt = neighbour(node, parts[-1] if direction == "forward" else parts[0], used)
                if nxt is None:
                    break
                used.add(nxt)
                coords.extend(oriented(nxt, node)[1:])
                parts.append(nxt) if direction == "forward" else parts.insert(0, nxt)
        coords.reverse()  # undo the backward flip: chain now runs start -> end

        if len(parts) == 1:
            out.append(members[seed])
        else:
            out.append(_merged_row([members[i] for i in parts], coords))
            stats.merged_ways += len(parts)
            stats.merge_groups += 1
    return out


ACCESS_MIN_SHARE = 0.5

# Builder 1.3.0: pieces of one named trail whose ends do not touch, but face
# each other across a short gap, are one trail with a bridge, boardwalk or
# road crossing in between that OSM tags as a different way. Measured on the
# NC pack (2026-10-08): of Neuse River Trail's 27 pieces' ends, 22 sit within
# 50 m of another piece's end and only 2 within 1 m, so end-to-end merging
# could not see them. The gap is drawn straight. 50 m is the walk screen's
# off-trail distance, so a bridged gap can never raise a false alert.
BRIDGE_MAX_GAP_M = 50.0
BRIDGE_MAX_TURN_DEG = 45.0


def _bearing_vec(a: Sequence[float], b: Sequence[float]) -> tuple[float, float]:
    lat0 = a[1]
    ax, ay = _local_xy(a, lat0)
    bx, by = _local_xy(b, lat0)
    return _unit(bx - ax, by - ay)


def bridge_named_gaps(
    members: list[tuple[Trail, list[list[float]]]],
    stats: Stats,
) -> list[tuple[Trail, list[list[float]]]]:
    """Join pieces of one name across short gaps where they clearly continue.

    Two ends join when they are within BRIDGE_MAX_GAP_M, the pieces point at
    each other (turn within BRIDGE_MAX_TURN_DEG), and the gap itself runs the
    way the first piece is heading. Closest pairs first; each end joins at
    most once, and a join never closes a ring of pieces. Loops are left alone.
    """
    if len(members) < 2:
        return members
    members = sorted(members, key=lambda m: m[0].source_ref)
    ends = []  # (piece index, 0 = start / 1 = end, coord, heading out of the piece)
    for i, (t, c) in enumerate(members):
        if t.is_loop or len(c) < 2:
            continue
        for side in (0, 1):
            into = _end_heading(c, at_start=(side == 0))
            ends.append((i, side, c[0] if side == 0 else c[-1], (-into[0], -into[1])))

    candidates = []
    for x in range(len(ends)):
        i, si, pi, oi = ends[x]
        for y in range(x + 1, len(ends)):
            j, sj, pj, oj = ends[y]
            if i == j:
                continue
            gap = haversine_m(pi, pj)
            if gap > BRIDGE_MAX_GAP_M or gap < 0.5:
                continue
            # Both "out of the piece" headings point at each other: as for a
            # junction, deflection 0 is dead straight on.
            turn = deflection_deg((-oi[0], -oi[1]), (-oj[0], -oj[1]))
            g = _bearing_vec(pi, pj)
            along = math.degrees(math.acos(max(-1.0, min(1.0, g[0] * oi[0] + g[1] * oi[1]))))
            if turn <= BRIDGE_MAX_TURN_DEG and along <= BRIDGE_MAX_TURN_DEG:
                candidates.append((gap, x, y))
    if not candidates:
        return members

    parent = list(range(len(members)))

    def find(a: int) -> int:
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    link: dict[tuple[int, int], tuple[int, int]] = {}
    for gap, x, y in sorted(candidates):
        i, si = ends[x][0], ends[x][1]
        j, sj = ends[y][0], ends[y][1]
        if (i, si) in link or (j, sj) in link or find(i) == find(j):
            continue
        link[(i, si)] = (j, sj)
        link[(j, sj)] = (i, si)
        parent[find(i)] = find(j)
        stats.bridged_gaps += 1
    if not link:
        return members

    used: set[int] = set()
    out = []
    for seed in range(len(members)):
        if seed in used:
            continue
        # Walk to one end of the chain this piece belongs to.
        cur, came_side = seed, 0
        seen = {seed}
        while (cur, came_side) in link:
            nxt, nside = link[(cur, came_side)]
            if nxt in seen:
                break
            seen.add(nxt)
            cur, came_side = nxt, 1 - nside
        # cur's free end is `came_side`; walk the chain from there.
        start_side = came_side
        chain, coords = [], []
        piece, side_in = cur, start_side
        while True:
            used.add(piece)
            chain.append(members[piece])
            c = members[piece][1]
            oriented = list(c) if side_in == 0 else list(reversed(c))
            coords.extend(oriented)            # the gap is the straight step between pieces
            out_side = 1 - side_in
            if (piece, out_side) not in link:
                break
            piece, side_in = link[(piece, out_side)]
            if piece in used:
                break
        if len(chain) == 1:
            out.append(chain[0])
            continue
        trail, merged = _merged_row(chain, coords, base=min(chain, key=lambda m: m[0].source_ref)[0])
        tags = json.loads(trail.tags_json)
        tags["merged_ways"] = sum(json.loads(t.tags_json).get("merged_ways", 1) for t, _ in chain)
        tags["bridged_gaps"] = len(chain) - 1
        trail.tags_json = json.dumps(tags, separators=(",", ":"), sort_keys=True)
        out.append((trail, merged))
    return out


def _merged_row(parts, coords: list[list[float]], base: Optional[Trail] = None):
    """One Trail from several.

    Tags (and name) come from `base`, by default the first part.

    Crossings do not vote on access, surface, difficulty or dogs: they are a
    few metres of road crosswalk, usually tagged with nothing, and letting
    them vote took bike access off the whole Duck sidepath (bicycle=designated
    cycleways joined by untagged crossings) and 3.5 km of the Charlotte Rail
    Trail. Among the rest, a mode (foot, bike, horse) is allowed when no
    member forbids it outright (_forbids: an explicit no) and the members
    that allow it make up at least ACCESS_MIN_SHARE of the row's non-crossing
    length: 2 m of bicycle=designated does not make a 2.5 km dirt corridor a
    bike route. A member that is merely silent — an untagged footway in a
    cycleway corridor — does not forbid, it only fails to count toward the
    share. Dog access is the most restrictive value any member states or
    infers from access tags."""
    first = base or parts[0][0]
    refs = sorted(t.source_ref for t, _ in parts)
    length_m = line_length_m(coords)
    lats = [c[1] for c in coords]
    lons = [c[0] for c in coords]
    all_parts = parts
    parts = [p for p in parts if not p[0].is_crossing] or parts  # the voters

    def allowed(allows: str, forbids: str) -> int:
        members = [t for t, _ in parts]
        total = sum(t.length_m for t in members)
        allowing = sum(t.length_m for t in members if getattr(t, allows))
        return 1 if (allowing > 0 and allowing >= ACCESS_MIN_SHARE * total
                     and not any(getattr(t, forbids) for t in members)) else 0

    tagged = [(t.dog_access, t.dog_access_provenance) for t, _ in parts if t.dog_access_provenance != "default"]
    if tagged:
        dog_access = min((d for d, _ in tagged), key=_DOG_CONSERVATIVE_ORDER.index)
        provenance = "tagged" if any(p == "tagged" and d == dog_access for d, p in tagged) else "inferred"
    else:
        dog_access, provenance = DOG_UNKNOWN, "default"

    def majority(values):
        values = [v for v in values if v]
        if not values:
            return None
        return max(sorted(set(values)), key=values.count)

    tags = json.loads(first.tags_json)
    tags["merged_ways"] = len(all_parts)
    is_loop = 1 if haversine_m(coords[0], coords[-1]) < 50 and length_m > 200 else 0

    trail = Trail(
        source_id=first.source_id,
        source_ref=refs[0],
        name=first.name,
        polyline=encode_polyline(coords),
        point_count=len(coords),
        length_m=round(length_m, 1),
        min_lat=min(lats), min_lon=min(lons), max_lat=max(lats), max_lon=max(lons),
        surface=majority(t.surface for t, _ in parts),
        difficulty=majority(t.difficulty for t, _ in parts),
        dog_access=dog_access,
        dog_access_provenance=provenance,
        allows_foot=allowed("allows_foot", "forbids_foot"),
        allows_bike=allowed("allows_bike", "forbids_bike"),
        allows_horse=allowed("allows_horse", "forbids_horse"),
        is_loop=is_loop,
        tags_json=json.dumps(tags, separators=(",", ":"), sort_keys=True),
        id=min(t.id for t, _ in all_parts),
        family=first.family,
        surface_class=first.surface_class,
        is_sidewalk=first.is_sidewalk,
        forbids_foot=any(t.forbids_foot for t, _ in parts),
        forbids_bike=any(t.forbids_bike for t, _ in parts),
        forbids_horse=any(t.forbids_horse for t, _ in parts),
        floor_length_m=sum(t.length_m for t, _ in all_parts if not t.is_crossing),
    )
    return trail, coords


# ---------------------------------------------------------------------------
# Joining unnamed ways into corridors. OSM splits an unnamed sidepath at every
# driveway and side street: the paved path along NC 12 from Kitty Hawk into
# Duck was 58 "Unnamed Trail" rows of 30-300 m (found on a walk, 2026-09-26).
# Named ways can chain by name; unnamed ones have nothing to group by, so they
# chain by geometry and kind instead:
#
#   * Two ways join where their ends meet: the same OSM node, or ends within
#     JOIN_ENDPOINT_TOLERANCE_M of each other.
#   * Only ways of the same family (path_family) and a compatible surface
#     class (surface_class) join, and a chain never mixes paved and unpaved,
#     even through a neutral boardwalk or untagged piece.
#   * Where exactly two ways meet, they join whatever the angle — a switchback
#     is still one path. Where three or more ways meet (named ones count
#     toward that), the straightest pair joins first, and only if it turns by
#     at most JUNCTION_MAX_DEFLECTION_DEG; the others start their own
#     corridors. That keeps a sidepath running straight past a beach access
#     and leaves the access as its own row.
#   * Crossings (footway=crossing and friends) join like any path, but only
#     survive as the link between two pieces: one dangling off a corridor's
#     end, or standing alone, is dropped. Without them the Duck sidepath
#     broke at every side street, 12-18 m short of its other half.
#   * Unnamed ways are pooled before the 30 m floor, like named ones: a 12 m
#     piece between two driveways is part of the corridor.
#
# A joined corridor is written exactly like a merged named trail: identity is
# the smallest member id, and `merged_ways` in its tags counts the members.
# ---------------------------------------------------------------------------

JOIN_ENDPOINT_TOLERANCE_M = 3.0
JUNCTION_MAX_DEFLECTION_DEG = 45.0
# Through a junction of one name, the continuation must beat every other way
# there by this much, or the junction is a fork and nothing is merged.
JUNCTION_CLEAR_MARGIN_DEG = 15.0
# The heading of a way at one end is taken over this much of it, so a kink in
# the last metre (a curb ramp) does not decide which way a path "goes".
_HEADING_SAMPLE_M = 15.0
_M_PER_DEG_LAT = 111_320.0


def _local_xy(coord: Sequence[float], lat0: float) -> tuple[float, float]:
    """Equirectangular metres around latitude lat0. Fine over a few hundred m."""
    return (coord[0] * _M_PER_DEG_LAT * math.cos(math.radians(lat0)),
            coord[1] * _M_PER_DEG_LAT)


def _unit(dx: float, dy: float) -> tuple[float, float]:
    n = math.hypot(dx, dy)
    return (dx / n, dy / n) if n > 0 else (0.0, 0.0)


def _end_heading(coords: Sequence[Sequence[float]], at_start: bool) -> tuple[float, float]:
    """Unit vector pointing from one end of a way into the way."""
    pts = coords if at_start else list(reversed(coords))
    lat0 = pts[0][1]
    x0, y0 = _local_xy(pts[0], lat0)
    x, y = x0, y0
    for p in pts[1:]:
        x, y = _local_xy(p, lat0)
        if math.hypot(x - x0, y - y0) >= _HEADING_SAMPLE_M:
            break
    return _unit(x - x0, y - y0)


def deflection_deg(va: tuple[float, float], vb: tuple[float, float]) -> float:
    """How far a walker turns going from way A into way B at their shared end.

    Both vectors point away from the shared end. 0 = dead straight on,
    90 = a right-angle turn, 180 = doubling back."""
    if va == (0.0, 0.0) or vb == (0.0, 0.0):
        return 180.0
    dot = max(-1.0, min(1.0, -(va[0] * vb[0] + va[1] * vb[1])))
    return math.degrees(math.acos(dot))


def _cluster_points(points: Sequence[Sequence[float]], tol_m: float) -> list[int]:
    """Union points within tol_m of each other. Returns a cluster id per point."""
    parent = list(range(len(points)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    cell_lat = tol_m / _M_PER_DEG_LAT
    cell_lon = cell_lat * 2  # a lon degree is >= half a lat degree up to 60° N
    grid: dict[tuple[int, int], list[int]] = {}
    for i, p in enumerate(points):
        grid.setdefault((math.floor(p[0] / cell_lon), math.floor(p[1] / cell_lat)), []).append(i)
    for (cx, cy), idxs in grid.items():
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in grid.get((cx + dx, cy + dy), ()):
                    for i in idxs:
                        if j > i and haversine_m(points[i], points[j]) <= tol_m:
                            ri, rj = find(i), find(j)
                            if ri != rj:
                                parent[max(ri, rj)] = min(ri, rj)
    return [find(i) for i in range(len(points))]


class _SegmentGrid:
    """Line segments in a coarse grid, stored only in the cells asked for."""

    def __init__(self, cell_deg: float, needed: Optional[set[tuple[int, int]]] = None) -> None:
        self.cell_deg = cell_deg
        self.needed = needed
        self.cells: dict[tuple[int, int], list[tuple[int, int, int]]] = {}
        self.lines: list[Sequence[Sequence[float]]] = []

    def cell(self, lon: float, lat: float) -> tuple[int, int]:
        return (math.floor(lon / self.cell_deg), math.floor(lat / self.cell_deg))

    def add(self, coords: Sequence[Sequence[float]]) -> int:
        key = len(self.lines)
        self.lines.append(coords)
        last = len(coords) - 2
        for k, (a, b) in enumerate(zip(coords, coords[1:])):
            x0, y0 = self.cell(min(a[0], b[0]), min(a[1], b[1]))
            x1, y1 = self.cell(max(a[0], b[0]), max(a[1], b[1]))
            for cx in range(x0, x1 + 1):
                for cy in range(y0, y1 + 1):
                    if self.needed is None or (cx, cy) in self.needed:
                        self.cells.setdefault((cx, cy), []).append((key, k, last))
        return key

    def near(self, p: Sequence[float], tol_m: float):
        """(line key, unit direction of the segment, t, is first seg, is last seg)
        for every segment within tol_m of p. t is where p projects, 0..1."""
        cx, cy = self.cell(p[0], p[1])
        seen = set()
        px, py = _local_xy(p, p[1])
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for key, k, last in self.cells.get((cx + dx, cy + dy), ()):
                    if (key, k) in seen:
                        continue
                    seen.add((key, k))
                    a, b = self.lines[key][k], self.lines[key][k + 1]
                    ax, ay = _local_xy(a, p[1])
                    bx, by = _local_xy(b, p[1])
                    sx, sy = bx - ax, by - ay
                    seg2 = sx * sx + sy * sy
                    t = 0.0 if seg2 == 0 else max(0.0, min(1.0, ((px - ax) * sx + (py - ay) * sy) / seg2))
                    if math.hypot(px - (ax + t * sx), py - (ay + t * sy)) <= tol_m:
                        yield key, _unit(sx, sy), t, k == 0, k == last


_JUNCTION_CELL_DEG = 0.0005  # ~50 m; one ring covers the 3 m tolerance


def _grid_cells_around(points: Iterable[Sequence[float]], cell_deg: float) -> set[tuple[int, int]]:
    cells = set()
    for p in points:
        cx, cy = math.floor(p[0] / cell_deg), math.floor(p[1] / cell_deg)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                cells.add((cx + dx, cy + dy))
    return cells


def join_unnamed_ways(
    members: list[tuple[Trail, list[list[float]]]],
    stats: Stats,
    other_lines: Sequence[Sequence[Sequence[float]]] = (),
) -> list[tuple[Trail, list[list[float]]]]:
    """Chain unnamed ways of one source into corridors (rules above).

    `other_lines` are every other way in the source (the named ones): they
    are never joined here, but they make a meeting point a junction — by
    ending there, or by running through it (two legs) without a split."""
    if len(members) < 2:
        crossings = [m for m in members if m[0].is_crossing]
        stats.skipped_crossing += len(crossings)
        return [m for m in members if not m[0].is_crossing]
    members = sorted(members, key=lambda m: m[0].id)
    n = len(members)

    points: list[Sequence[float]] = []
    for _, c in members:
        points.append(c[0])
        points.append(c[-1])
    for c in other_lines:
        points.append(c[0])
        points.append(c[-1])
    cluster = _cluster_points(points, JOIN_ENDPOINT_TOLERANCE_M)
    degree: dict[int, int] = {}
    for node in cluster:
        degree[node] = degree.get(node, 0) + 1

    ends_at: dict[int, list[tuple[int, int]]] = {}
    for i in range(n):
        for end in (0, 1):
            ends_at.setdefault(cluster[2 * i + end], []).append((i, end))

    # A way that runs through a meeting point without being split there is
    # two more legs: an unnamed path ending on the side of an unsplit trail
    # is at a T, not at a simple end-to-end joint. Only points where two or
    # more unnamed ends meet can be joins, so only those are looked up.
    live = {node: ends for node, ends in ends_at.items() if len(ends) >= 2}
    if live:
        lines = [c for _, c in members] + list(other_lines)
        node_point = {node: points[2 * ends[0][0] + ends[0][1]] for node, ends in live.items()}
        grid = _SegmentGrid(_JUNCTION_CELL_DEG, _grid_cells_around(node_point.values(), _JUNCTION_CELL_DEG))
        for line in lines:
            grid.add(line)
        for node, p in node_point.items():
            through = set()
            for key, _, _, _, _ in grid.near(p, JOIN_ENDPOINT_TOLERANCE_M):
                if cluster[2 * key] != node and cluster[2 * key + 1] != node:
                    through.add(key)
            degree[node] += 2 * len(through)

    candidates = []
    for node, ends in ends_at.items():
        if len(ends) < 2:
            continue
        junction = degree[node] > 2
        for a in range(len(ends)):
            for b in range(a + 1, len(ends)):
                (i, ei), (j, ej) = ends[a], ends[b]
                if i == j:
                    continue
                ti, tj = members[i][0], members[j][0]
                if ti.family != tj.family:
                    continue
                turn = deflection_deg(_end_heading(members[i][1], ei == 0),
                                      _end_heading(members[j][1], ej == 0))
                if junction and turn > JUNCTION_MAX_DEFLECTION_DEG:
                    continue
                candidates.append((round(turn, 6), min(ti.id, tj.id), max(ti.id, tj.id), i, ei, j, ej))
    candidates.sort()

    # Straightest pairs claim their ends first. Union-find over ways tracks
    # the surface classes each growing chain already contains.
    root = list(range(n))
    classes = [{m[0].surface_class} - {SURFACE_UNKNOWN} for m in members]

    def find(i: int) -> int:
        while root[i] != i:
            root[i] = root[root[i]]
            i = root[i]
        return i

    partner: dict[tuple[int, int], tuple[int, int]] = {}
    for _, _, _, i, ei, j, ej in candidates:
        if (i, ei) in partner or (j, ej) in partner:
            continue
        ri, rj = find(i), find(j)
        if ri != rj:
            merged = classes[ri] | classes[rj]
            if len(merged) > 1:
                continue  # would put paved and unpaved in one chain
            root[rj] = ri
            classes[ri] = merged
        partner[(i, ei)] = (j, ej)
        partner[(j, ej)] = (i, ei)

    def oriented(i: int, start_end: int) -> list[list[float]]:
        c = members[i][1]
        return list(c) if start_end == 0 else list(reversed(c))

    used: set[int] = set()
    out: list[tuple[Trail, list[list[float]]]] = []
    for seed in range(n):
        if seed in used:
            continue
        # Walk out of the seed's start to find the chain's free end (or come
        # back round to the seed, for a closed loop).
        way, end = seed, 0
        while (way, end) in partner:
            nxt, nxt_end = partner[(way, end)]
            if nxt == seed:
                break
            way, end = nxt, 1 - nxt_end
        start_way, start_end = (seed, 0) if (way, end) in partner else (way, end)

        chain: list[tuple[int, int]] = []
        way, entry = start_way, start_end
        while True:
            used.add(way)
            chain.append((way, entry))
            nxt = partner.get((way, 1 - entry))
            if nxt is None or nxt[0] in used:
                break
            way, entry = nxt

        # A crossing only belongs to a corridor as the link between two
        # pieces of it: one dangling off either end leads to a sidewalk that
        # is not in the pack, and one on its own is not a trail.
        while chain and members[chain[0][0]][0].is_crossing:
            chain.pop(0)
            stats.skipped_crossing += 1
        while chain and members[chain[-1][0]][0].is_crossing:
            chain.pop()
            stats.skipped_crossing += 1
        if not chain:
            continue

        parts = [w for w, _ in chain]
        coords: list[list[float]] = []
        for w, e in chain:
            piece = oriented(w, e)
            if coords and haversine_m(coords[-1], piece[0]) < 0.01:
                piece = piece[1:]
            coords.extend(piece)

        if len(parts) == 1:
            out.append(members[parts[0]])
            continue
        longest = max((members[i][0] for i in parts), key=lambda t: (t.length_m, -t.id))
        out.append(_merged_row([members[i] for i in parts], coords, base=longest))
        stats.joined_unnamed_ways += len(parts)
        stats.unnamed_corridors += 1
    return out


# ---------------------------------------------------------------------------
# Derived names. A joined sidepath is still "Unnamed Trail" to a walker, but
# the road it runs beside is usually named in the same extract. A corridor is
# named after a road only if that road runs alongside it — within
# DERIVED_NAME_MAX_DISTANCE_M and within DERIVED_NAME_MAX_ANGLE_DEG of
# parallel — for at least DERIVED_NAME_MIN_SHARE of its length. A road that
# merely crosses it is near for a few metres at a right angle, and fails
# both. Derived names are marked `name_source: derived_road` in tags_json so
# they can always be told apart from names the data itself carries. Only
# paved shared-use paths of 100 m or more qualify (_may_derive_name).
# ---------------------------------------------------------------------------

DERIVED_NAME_MAX_DISTANCE_M = 40.0
DERIVED_NAME_MAX_ANGLE_DEG = 30.0
DERIVED_NAME_MIN_SHARE = 0.6
DERIVED_NAME_MIN_LENGTH_M = 100.0
_DERIVED_NAME_SAMPLE_M = 20.0
_ROAD_CELL_DEG = 0.001  # ~110 m N-S, ~90 m E-W in NC; one ring covers 40 m
DERIVED_NAME_FAMILIES = {"path", "sidewalk"}


def _cell(lon: float, lat: float) -> tuple[int, int]:
    return (math.floor(lon / _ROAD_CELL_DEG), math.floor(lat / _ROAD_CELL_DEG))


def _samples(coords: Sequence[Sequence[float]], step_m: float):
    """(lon, lat, unit heading) every step_m along a line, starting half a step in."""
    out = []
    next_at, walked = step_m / 2, 0.0
    for a, b in zip(coords, coords[1:]):
        seg = haversine_m(a, b)
        if seg <= 0:
            continue
        ax, ay = _local_xy(a, a[1])
        bx, by = _local_xy(b, a[1])
        heading = _unit(bx - ax, by - ay)
        while next_at <= walked + seg:
            t = (next_at - walked) / seg
            out.append((a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]), heading))
            next_at += step_m
        walked += seg
    return out


class RoadIndex:
    """Named road segments in a coarse grid, loaded only where they are needed."""

    def __init__(self) -> None:
        self.names: list[str] = []
        self._name_ids: dict[str, int] = {}
        self.cells: dict[tuple[int, int], list[tuple[int, float, float, float, float]]] = {}

    def add(self, name: str, coords: Sequence[Sequence[float]],
            needed: Optional[set[tuple[int, int]]] = None) -> None:
        nid = self._name_ids.get(name)
        if nid is None:
            nid = self._name_ids[name] = len(self.names)
            self.names.append(name)
        for a, b in zip(coords, coords[1:]):
            x0, y0 = _cell(min(a[0], b[0]), min(a[1], b[1]))
            x1, y1 = _cell(max(a[0], b[0]), max(a[1], b[1]))
            seg = (nid, a[0], a[1], b[0], b[1])
            for cx in range(x0, x1 + 1):
                for cy in range(y0, y1 + 1):
                    if needed is None or (cx, cy) in needed:
                        self.cells.setdefault((cx, cy), []).append(seg)

    @classmethod
    def load(cls, path: str, needed: Optional[set[tuple[int, int]]] = None) -> "RoadIndex":
        index = cls()
        for feature in read_features(path):
            name = str((feature.get("properties") or {}).get("name") or "").strip()
            geom = feature.get("geometry") or {}
            if not name:  # absent, empty, or only whitespace
                continue
            if geom.get("type") == "LineString":
                lines = [geom.get("coordinates") or []]
            elif geom.get("type") == "MultiLineString":
                lines = geom.get("coordinates") or []
            else:
                continue
            for line in lines:
                if len(line) >= 2:
                    index.add(name, [c[:2] for c in line], needed)
        return index

    def near(self, lon: float, lat: float):
        cx, cy = _cell(lon, lat)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                yield from self.cells.get((cx + dx, cy + dy), ())


def _cells_for(coords: Sequence[Sequence[float]]) -> set[tuple[int, int]]:
    cells = set()
    for lon, lat, _ in _samples(coords, _DERIVED_NAME_SAMPLE_M):
        cx, cy = _cell(lon, lat)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                cells.add((cx + dx, cy + dy))
    return cells


def derive_road_name(coords: Sequence[Sequence[float]], roads: RoadIndex) -> Optional[str]:
    """The named road running alongside this line for most of it, or None."""
    samples = _samples(coords, _DERIVED_NAME_SAMPLE_M)
    if not samples:
        return None
    max_cos = math.cos(math.radians(DERIVED_NAME_MAX_ANGLE_DEG))
    hits: dict[int, int] = {}
    dist_sum: dict[int, float] = {}
    for lon, lat, (hx, hy) in samples:
        best: dict[int, float] = {}
        px, py = _local_xy((lon, lat), lat)
        for nid, lon1, lat1, lon2, lat2 in roads.near(lon, lat):
            ax, ay = _local_xy((lon1, lat1), lat)
            bx, by = _local_xy((lon2, lat2), lat)
            dx, dy = bx - ax, by - ay
            seg2 = dx * dx + dy * dy
            if seg2 == 0:
                continue
            # Parallel either way round: a road has no direction here.
            if abs(hx * dx + hy * dy) / math.sqrt(seg2) < max_cos:
                continue
            t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / seg2))
            d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if d <= DERIVED_NAME_MAX_DISTANCE_M and d < best.get(nid, math.inf):
                best[nid] = d
        for nid, d in best.items():
            hits[nid] = hits.get(nid, 0) + 1
            dist_sum[nid] = dist_sum.get(nid, 0.0) + d
    if not hits:
        return None
    # Most samples wins; ties go to the closer road, then the name.
    nid = min(hits, key=lambda k: (-hits[k], dist_sum[k] / hits[k], roads.names[k]))
    if hits[nid] / len(samples) < DERIVED_NAME_MIN_SHARE:
        return None
    return roads.names[nid]


def _may_derive_name(trail: Trail) -> bool:
    """Paved shared-use paths only — the sidepath a road name describes.

    * A plain footway beside a road is, in practice, a sidewalk nobody tagged
      as one; "X Road Path" would dress it up as a trail. It needs bicycle
      access to qualify.
    * An unpaved or untagged path that follows a road for a while is usually a
      hiking trail that happens to (a stretch of forest trail beside the Blue
      Ridge Parkway was about to become "Blue Ridge Parkway Path"). It needs a
      paved surface, except a cycleway, which is paved unless it says not.
    Anything that fails keeps its empty name."""
    if trail.length_m < DERIVED_NAME_MIN_LENGTH_M or trail.family not in DERIVED_NAME_FAMILIES:
        return False
    if trail.family == "sidewalk":
        return True
    surface = surface_class(trail.surface)
    if surface == SURFACE_UNPAVED:
        return False
    highway = json.loads(trail.tags_json).get("highway", "")
    if highway == "cycleway":
        return True
    return surface == SURFACE_PAVED and (highway == "path" or bool(trail.allows_bike))


def derived_corridor_name(road: str, family: str) -> str:
    if family == "sidewalk":
        return f"{road} Sidewalk"
    # "Mill Path Path" reads as a typo and "Virginia Dare Trail Path" as a
    # stutter; a road already called a path or trail gets "Sidepath".
    return f"{road} Sidepath" if road.split()[-1].lower() in ("path", "trail") else f"{road} Path"


# A corridor that carries straight on out of a trail with a real name is that
# trail's unnamed continuation — "Eastwood Road Path" was the unnamed end of
# Cross City Trail. Naming it after the road would put two names on one path,
# so it keeps no name. (Inheriting the trail's name is a separate decision.)
NAMED_CONTINUATION_MAX_DEFLECTION_DEG = JUNCTION_MAX_DEFLECTION_DEG


def _continues_named_path(coords: Sequence[Sequence[float]], named: _SegmentGrid) -> bool:
    for at_start in (True, False):
        end = coords[0] if at_start else coords[-1]
        heading = _end_heading(coords, at_start)
        for _, (ux, uy), t, first_seg, last_seg in named.near(end, JOIN_ENDPOINT_TOLERANCE_M):
            # Directions a walker can go along the named way from here. At
            # the named way's own end there is only one: into it.
            if first_seg and t == 0.0:
                ways = [(ux, uy)]
            elif last_seg and t == 1.0:
                ways = [(-ux, -uy)]
            else:
                ways = [(ux, uy), (-ux, -uy)]
            if any(deflection_deg(heading, w) <= NAMED_CONTINUATION_MAX_DEFLECTION_DEG for w in ways):
                return True
    return False


# Sidepaths on both sides of one road get the same derived name, and the app
# sums same-named sections within 400 m into one card (TrailList.swift), so
# "The Plaza Path" showed 2.85 km for a 1.5 km road. Two derived rows named
# after the same road that run side by side get the side of the road each is
# on: "Duck Road Path (East Side)".
SIDE_BY_SIDE_MAX_DISTANCE_M = 60.0
SIDE_BY_SIDE_MIN_SHARE = 0.5


def _share_within(coords: Sequence[Sequence[float]], other: Sequence[Sequence[float]], tol_m: float) -> float:
    samples = _samples(coords, _DERIVED_NAME_SAMPLE_M)
    if not samples:
        return 0.0
    grid = _SegmentGrid(_ROAD_CELL_DEG)
    grid.add(other)
    near = sum(1 for lon, lat, _ in samples if next(grid.near((lon, lat), tol_m), None) is not None)
    return near / len(samples)


def _road_offset(coords: Sequence[Sequence[float]], roads: RoadIndex, road: str):
    """Summed offset (east, north metres) from `road` to this line, and the
    road's direction as a doubled-angle sum (cos 2θ, sin 2θ): positive cos 2θ
    means the road runs more east-west than north-south, whichever way its
    ways happen to be drawn."""
    nid = roads.names.index(road)
    sx = sy = c2 = s2 = 0.0
    for lon, lat, _ in _samples(coords, _DERIVED_NAME_SAMPLE_M):
        px, py = _local_xy((lon, lat), lat)
        best = None
        for rid, lon1, lat1, lon2, lat2 in roads.near(lon, lat):
            if rid != nid:
                continue
            ax, ay = _local_xy((lon1, lat1), lat)
            bx, by = _local_xy((lon2, lat2), lat)
            dx, dy = bx - ax, by - ay
            seg2 = dx * dx + dy * dy
            if seg2 == 0:
                continue
            t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / seg2))
            ox, oy = px - (ax + t * dx), py - (ay + t * dy)
            if best is None or math.hypot(ox, oy) < math.hypot(best[0], best[1]):
                best = (ox, oy, dx, dy)
        if best is not None and math.hypot(best[0], best[1]) <= DERIVED_NAME_MAX_DISTANCE_M:
            sx, sy = sx + best[0], sy + best[1]
            theta = math.atan2(best[3], best[2])
            c2, s2 = c2 + math.cos(2 * theta), s2 + math.sin(2 * theta)
    return sx, sy, c2, s2


def apply_derived_names(
    rows: list[tuple[Trail, list[list[float]]]],
    roads_path: str,
    stats: Stats,
) -> None:
    """Name unnamed path-like rows after the road they run beside, in place."""
    targets = [r for r in rows if not r[0].name and _may_derive_name(r[0])]
    if not targets:
        return
    needed: set[tuple[int, int]] = set()
    for _, coords in targets:
        needed |= _cells_for(coords)
    roads = RoadIndex.load(roads_path, needed)

    ends = [c for _, coords in targets for c in (coords[0], coords[-1])]
    named = _SegmentGrid(_JUNCTION_CELL_DEG, _grid_cells_around(ends, _JUNCTION_CELL_DEG))
    for trail, coords in rows:
        if trail.name and trail.family == "path":
            named.add(coords)

    by_road: dict[str, list[tuple[Trail, list[list[float]]]]] = {}
    for trail, coords in targets:
        road = derive_road_name(coords, roads)
        if road is None:
            continue
        if _continues_named_path(coords, named):
            stats.derived_suppressed_named += 1
            continue
        trail.name = derived_corridor_name(road, trail.family)
        tags = json.loads(trail.tags_json)
        tags["name_source"] = "derived_road"
        trail.tags_json = json.dumps(tags, separators=(",", ":"), sort_keys=True)
        stats.derived_names += 1
        by_road.setdefault(road, []).append((trail, coords))

    for road in sorted(by_road):
        group = by_road[road]
        pairs = []
        for i, (a, ca) in enumerate(group):
            for b, cb in group[i + 1:]:
                if max(_share_within(ca, cb, SIDE_BY_SIDE_MAX_DISTANCE_M),
                       _share_within(cb, ca, SIDE_BY_SIDE_MAX_DISTANCE_M)) >= SIDE_BY_SIDE_MIN_SHARE:
                    pairs.append((a, b))
        if not pairs:
            continue
        # One compass axis for the whole road, from the road's own direction,
        # so every piece along it is labelled on the same axis. Judging each
        # row by its own start and end called one piece "North Side" and the
        # piece opposite it "East Side".
        offsets = {id(t): _road_offset(c, roads, road) for t, c in group}
        east_west = sum(o[2] for o in offsets.values()) >= 0
        labels = ("North Side", "South Side") if east_west else ("East Side", "West Side")

        def lean(t: Trail) -> float:
            o = offsets[id(t)]
            return o[1] if east_west else o[0]

        # Both on one side (two strands of path on the same side of a road):
        # a side label cannot tell them apart, and giving each the label it
        # earned from some other pair made them identical ("Blue Ridge Road
        # Path (East Side)" twice). Neither gets one. Counted, so it shows.
        same_side = set()
        for a, b in pairs:
            if lean(a) * lean(b) >= 0:
                stats.derived_same_side_pairs += 1
                same_side |= {id(a), id(b)}
        for a, b in pairs:
            la, lb = lean(a), lean(b)
            if la * lb >= 0 or id(a) in same_side or id(b) in same_side:
                continue
            for t, l in ((a, la), (b, lb)):
                if not t.name.endswith(")"):
                    t.name = f"{t.name} ({labels[0] if l > 0 else labels[1]})"
                    stats.derived_side_suffixed += 1


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
    trail_key              TEXT,
    UNIQUE (source_id, source_ref)
);

CREATE VIRTUAL TABLE trails_rtree USING rtree(
    id, min_lat, max_lat, min_lon, max_lon
);

CREATE INDEX idx_trails_dog    ON trails (dog_access);
CREATE INDEX idx_trails_length ON trails (length_m);
CREATE INDEX idx_trails_name   ON trails (name);
CREATE INDEX idx_trails_key    ON trails (trail_key);
"""


# --- Curation after the rows are final (builder 1.3.0) ----------------------

# Pieces of one name closer than this are one trail, matching the app's
# `TrailList.joinGapMeters`, so the key groups exactly what the list groups.
TRAIL_KEY_JOIN_GAP_M = 400.0
# An unnamed path shorter than this, that no name reached, is a stub between
# driveways, not something to walk: 38% of NC's unnamed rows were under 100 m.
MIN_UNNAMED_LENGTH_M = 150.0


def _bbox_gap_m(a: "Trail", b: "Trail") -> float:
    lat0 = math.radians((a.min_lat + a.max_lat + b.min_lat + b.max_lat) / 4)
    dlat = max(0.0, max(a.min_lat, b.min_lat) - min(a.max_lat, b.max_lat)) * _M_PER_DEG_LAT
    dlon = max(0.0, max(a.min_lon, b.min_lon) - min(a.max_lon, b.max_lon)) * _M_PER_DEG_LAT * math.cos(lat0)
    return math.hypot(dlat, dlon)


def assign_trail_keys(rows: list, region: str, stats: Stats) -> None:
    """Give every piece of one named trail the same `trail_key`.

    A trail is the pieces sharing a name that sit within
    TRAIL_KEY_JOIN_GAP_M of one another, chained (A near B near C is one
    trail even if A and C are far apart). The key is the region and the
    smallest source ref in the trail, so it survives rebuilds while that way
    exists. Unnamed rows have no key: the app titles them by kind.
    """
    by_name: dict[str, list[int]] = {}
    for i, (t, _) in enumerate(rows):
        if t.name:
            by_name.setdefault(" ".join(t.name.lower().split()), []).append(i)
    for idx in by_name.values():
        parent = {i: i for i in idx}

        def find(i: int) -> int:
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i

        order = sorted(idx, key=lambda i: rows[i][0].min_lon)
        pad = TRAIL_KEY_JOIN_GAP_M / _M_PER_DEG_LAT * 2
        for k, i in enumerate(order):
            for j in order[k + 1:]:
                if rows[j][0].min_lon - rows[i][0].max_lon > pad:
                    break
                if _bbox_gap_m(rows[i][0], rows[j][0]) <= TRAIL_KEY_JOIN_GAP_M:
                    parent[find(i)] = find(j)
        groups: dict[int, list[int]] = {}
        for i in idx:
            groups.setdefault(find(i), []).append(i)
        for members in groups.values():
            key = f"{region}:{min(rows[i][0].source_ref for i in members)}"
            for i in members:
                rows[i][0].trail_key = key
            stats.trail_keys += 1


def drop_short_unnamed(rows: list, min_m: float, stats: Stats) -> list:
    kept = []
    for row in rows:
        t = row[0]
        if not t.name and not t.is_loop and t.length_m < min_m:
            stats.skipped_short_unnamed += 1
        else:
            kept.append(row)
    return kept


def build_pack(
    inputs: list[tuple[str, str]],
    out_path: str,
    region: str,
    region_name: str,
    tolerance_deg: float,
    min_length_m: float,
    merge_ways: bool = True,
    named_only: bool = False,
    built_at: Optional[str] = None,
    join_unnamed: bool = True,
    roads_path: Optional[str] = None,
    keep_sidewalks: bool = False,
    min_unnamed_length_m: float = MIN_UNNAMED_LENGTH_M,
) -> Stats:
    # Joining unnamed ways is a kind of merging; --no-merge-ways turns off both.
    join_unnamed = join_unnamed and merge_ways and not named_only
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
    # Every row to write, as (trail, simplified coords). Held until all inputs
    # are read so derived names can be looked up in one pass over the roads.
    rows: list[tuple[Trail, list[list[float]]]] = []

    for path, source_id in inputs:
        if source_id not in SOURCES:
            raise SystemExit(
                f"Unknown source '{source_id}'. Known: {', '.join(sorted(SOURCES))}"
            )
        used_sources.add(source_id)

        # Named ways wait here until the whole input is read, so same-named
        # ways can be chained; unnamed ways likewise, to be joined by geometry.
        pool: dict[str, list[tuple[Trail, list[list[float]]]]] = {}
        unnamed: list[tuple[Trail, list[list[float]]]] = []

        def keep(row: tuple[Trail, list[list[float]]]) -> None:
            t = row[0]
            # Crossings do not count toward the floor: two 12 m pieces
            # stitched by a 10 m crosswalk are not a 34 m trail.
            if (t.length_m if t.floor_length_m is None else t.floor_length_m) < min_length_m:
                stats.skipped_short += 1
            else:
                rows.append(row)

        for feature in read_features(path):
            stats.read += 1
            normalized = normalize_feature(feature, source_id, tolerance_deg, stats)
            if normalized is None:
                continue
            trail, coords = normalized
            key = (trail.source_id, trail.source_ref)
            if key in seen:
                stats.skipped_duplicate += 1
                continue
            seen.add(key)
            trail.id = next_id
            next_id += 1

            # A sidewalk is the pavement beside a road, not a trail. The osmium
            # recipe already drops them; this catches inputs that did not.
            if trail.is_sidewalk and not keep_sidewalks:
                stats.skipped_sidewalk += 1
                continue

            if not trail.name:
                if named_only:
                    stats.skipped_unnamed += 1
                elif join_unnamed:
                    # Floor applied after joining, as for named ways below: a
                    # 12 m piece between two driveways is part of the corridor.
                    unnamed.append((trail, coords))
                elif trail.is_crossing:
                    stats.skipped_crossing += 1
                else:
                    keep((trail, coords))
            elif trail.is_crossing and not merge_ways:
                stats.skipped_crossing += 1  # a named crosswalk with nothing to join
            elif merge_ways:
                # The length floor is applied AFTER merging: a 12 m connector
                # way is exactly what joins two long pieces of a named trail,
                # and dropping it first left the Mountains-to-Sea Trail with
                # 246 of 300 endpoints touching nothing.
                pool.setdefault(trail.name, []).append((trail, coords))
            else:
                keep((trail, coords))

        # Deterministic: names in sorted order, members sorted inside.
        named_lines = [coords for name in sorted(pool) for _, coords in pool[name]]
        for name in sorted(pool):
            for row in bridge_named_gaps(merge_named_ways(pool[name], stats), stats):
                if row[0].is_crossing:  # a named crosswalk that joined nothing
                    stats.skipped_crossing += 1
                    continue
                keep(row)
        for row in join_unnamed_ways(unnamed, stats, other_lines=named_lines):
            keep(row)

    if roads_path:
        apply_derived_names(rows, roads_path, stats)
    # After derived names, so a short path that took a road's name stays.
    rows = drop_short_unnamed(rows, min_unnamed_length_m, stats)
    assign_trail_keys(rows, region, stats)

    batch: list[tuple] = []
    rtree_batch: list[tuple] = []
    for trail, _ in rows:
        stats.dog[trail.dog_access] = stats.dog.get(trail.dog_access, 0) + 1
        batch.append((
            trail.id, trail.source_id, trail.source_ref, trail.name, trail.polyline,
            trail.point_count, trail.length_m, trail.min_lat, trail.min_lon,
            trail.max_lat, trail.max_lon, trail.surface, trail.difficulty,
            trail.dog_access, trail.dog_access_provenance, trail.allows_foot,
            trail.allows_bike, trail.allows_horse, trail.is_loop, trail.tags_json,
            trail.trail_key,
        ))
        rtree_batch.append(
            (trail.id, trail.min_lat, trail.max_lat, trail.min_lon, trail.max_lon)
        )
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
        # Overridable so a rebuild from unchanged input is byte-identical —
        # a fixture or a published pack should not churn for a timestamp.
        "built_at": built_at or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "trail_count": str(stats.written),
        "simplify_tolerance_deg": str(tolerance_deg),
        "min_length_m": str(min_length_m),
        "merge_ways": "1" if merge_ways else "0",
        "named_only": "1" if named_only else "0",
        "join_unnamed": "1" if join_unnamed else "0",
        "derived_names": "1" if roads_path else "0",
        "keep_sidewalks": "1" if keep_sidewalks else "0",
        "min_unnamed_length_m": str(min_unnamed_length_m),
        "trail_keys": "1",
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
        "INSERT INTO trails VALUES (" + ",".join("?" * 21) + ")", batch
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
    parser.add_argument("--no-merge-ways", action="store_true",
                        help="Keep same-named ways as separate rows instead of "
                             "chaining them end to end (default: merge)")
    parser.add_argument("--named-only", action="store_true",
                        help="Drop unnamed trails. For a trimmed bundled pack.")
    parser.add_argument("--no-join-unnamed", action="store_true",
                        help="Keep unnamed ways as OSM split them instead of "
                             "joining them into corridors (default: join)")
    parser.add_argument("--roads", metavar="GEOJSONSEQ",
                        help="Named roads from the same extract (osmium export). "
                             "Unnamed paths running alongside one get a derived "
                             "name, e.g. \"Duck Road Path\"")
    parser.add_argument("--min-unnamed-length", type=float, default=MIN_UNNAMED_LENGTH_M,
                        help="Drop unnamed, non-loop trails shorter than this many metres "
                             f"after joining and derived names (default {MIN_UNNAMED_LENGTH_M:.0f})")
    parser.add_argument("--keep-sidewalks", action="store_true",
                        help="Keep highway=footway + footway=sidewalk ways "
                             "(default: drop — a sidewalk is not a trail)")
    parser.add_argument("--built-at", metavar="ISO8601",
                        help="Stamp this build time instead of now, so a rebuild "
                             "from unchanged input is byte-identical")
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
    if args.roads and not os.path.exists(args.roads):
        raise SystemExit(f"Roads file not found: {args.roads}")

    started = time.time()
    stats = build_pack(inputs, args.out, args.region, args.region_name,
                       args.simplify, args.min_length,
                       merge_ways=not args.no_merge_ways,
                       named_only=args.named_only,
                       built_at=args.built_at,
                       join_unnamed=not args.no_join_unnamed,
                       roads_path=args.roads,
                       keep_sidewalks=args.keep_sidewalks,
                       min_unnamed_length_m=args.min_unnamed_length)
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
    print(f"  skipped unnamed    {stats.skipped_unnamed:,}")
    print(f"  generic names      {stats.generic_names:,} (treated as unnamed)")
    print(f"  short unnamed      {stats.skipped_short_unnamed:,} dropped (under {args.min_unnamed_length:.0f} m)")
    print(f"  junction merges    {stats.junction_merges:,}")
    print(f"  bridged gaps       {stats.bridged_gaps:,} (same name, facing, under {BRIDGE_MAX_GAP_M:.0f} m)")
    print(f"  named trails       {stats.trail_keys:,} (trail keys)")
    print(f"  skipped sidewalk   {stats.skipped_sidewalk:,}")
    print(f"  skipped crossing   {stats.skipped_crossing:,} (not joining two pieces of a path)")
    print(f"  merged             {stats.merged_ways:,} ways -> {stats.merge_groups:,} trails; "
          f"{stats.merge_groups_left:,} same-name groups left unmerged (branching)")
    print(f"  joined unnamed     {stats.joined_unnamed_ways:,} ways -> "
          f"{stats.unnamed_corridors:,} corridors")
    print(f"  derived names      {stats.derived_names:,} ({stats.derived_side_suffixed:,} with a side; "
          f"{stats.derived_suppressed_named:,} withheld: they continue a named trail; "
          f"{stats.derived_same_side_pairs:,} side-by-side pairs on one side, no side given)")
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
