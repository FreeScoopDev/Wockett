#!/usr/bin/env python3
"""
build_routing_graph.py — Wockett walkable routing-graph builder.

Companion to build_trail_pack.py. That script builds the DISCOVERY pack:
named trails a user browses. This one builds the ROUTING graph: the connected
walkable network a route is computed over — sidewalks, crossings, paths and
residential streets included, because that is where most walks and runs
actually happen.

Why this reads OPL and not GeoJSON
----------------------------------
`osmium export` emits independent LineStrings. Two ways meeting at a junction
share a coordinate, but nothing in the output says they share a NODE — and a
node is precisely what a router traverses. OPL (`osmium cat -f opl`) keeps the
node references, so it is the only one of the two that can produce a graph.

Scope it to a metro, not a state
--------------------------------
Measured on North Carolina: statewide, the largest connected component holds
under 9% of nodes, because a state is a dozen walkable islands separated by
roads nobody walks. A metro is genuinely one network. Metro-scoped graphs are
smaller AND better connected, and match the use case: nobody routes a 5k
across state lines.

Usage
-----
    osmium tags-filter <region>.osm.pbf \\
        w/highway=path,footway,track,bridleway,cycleway,steps,pedestrian,\\
living_street,residential,unclassified \\
        w/route=hiking,foot -o walkable.osm.pbf
    osmium cat walkable.osm.pbf -f opl -o walkable.opl
    python3 build_routing_graph.py --region raleigh --region-name "Raleigh" \\
        --input walkable.opl --out packs/raleigh.wktgraph

Standard library only. No shapely, no networkx, no dependency to break.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import argparse
import heapq
import math
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_trail_pack import encode_polyline, decode_polyline, haversine_m  # noqa: E402

SCHEMA_VERSION = 1
BUILDER_VERSION = "1.0.0"

# ---------------------------------------------------------------------------
# Walkability
# ---------------------------------------------------------------------------

_NO = {"no", "private", "false", "0"}
_YES = {"yes", "designated", "permissive", "official", "destination", "true", "1"}

# highway values a pedestrian may legitimately use. `service` is deliberately
# absent from the default: it is 1.1M driveways and parking aisles in NC alone
# and nearly trebles graph size for almost no routing value. --include-service
# puts it back for anyone who wants it.
WALKABLE = {
    "footway", "path", "pedestrian", "steps", "cycleway", "bridleway", "track",
    "living_street", "residential", "unclassified", "tertiary", "secondary",
}
SERVICE = {"service"}


def edge_kind(tags: dict[str, str]) -> str:
    """A label the app can style and the router can weight."""
    hw = tags.get("highway", "")
    fw = tags.get("footway", "")
    if fw == "sidewalk":
        return "sidewalk"
    if fw == "crossing":
        return "crossing"
    if fw in ("access_aisle", "traffic_island"):
        return "connector"
    if hw == "steps":
        return "steps"
    if hw in ("path", "bridleway"):
        return "trail"
    if hw == "track":
        return "track"
    if hw == "cycleway":
        return "cycleway"
    if hw in ("footway", "pedestrian"):
        return "footpath"
    return "road"


def foot_allowed(tags: dict[str, str]) -> bool:
    """True when a pedestrian may use this way.

    `foot` beats `access`: a private drive tagged foot=yes is a public right of
    way, and a track tagged access=private is not walkable whatever it looks
    like on a map.
    """
    foot = (tags.get("foot") or "").strip().lower()
    if foot in _NO:
        return False
    if foot in _YES:
        return True
    access = (tags.get("access") or "").strip().lower()
    if access in _NO:
        return False
    return True


# ---------------------------------------------------------------------------
# OPL parsing
# ---------------------------------------------------------------------------


def parse_tags(field_value: str) -> dict[str, str]:
    """OPL percent-decodes to keep fields space-free. Undo it."""
    tags: dict[str, str] = {}
    for kv in field_value.split(","):
        if "=" not in kv:
            continue
        k, v = kv.split("=", 1)
        tags[_unescape(k)] = _unescape(v)
    return tags


def _unescape(s: str) -> str:
    if "%" not in s:
        return s
    out, i = [], 0
    while i < len(s):
        if s[i] == "%" and i + 2 < len(s):
            # OPL escapes as %XX%  (unicode codepoint in hex, then a marker)
            j = s.find("%", i + 1)
            if j > i:
                try:
                    out.append(chr(int(s[i + 1:j], 16)))
                    i = j + 1
                    continue
                except ValueError:
                    pass
        out.append(s[i])
        i += 1
    return "".join(out)


@dataclass
class Stats:
    ways_seen: int = 0
    ways_kept: int = 0
    skipped_not_walkable: int = 0
    skipped_no_access: int = 0
    skipped_short: int = 0
    self_loops: int = 0
    nodes_total: int = 0
    junctions: int = 0
    edges: int = 0
    components: int = 0
    pruned_nodes: int = 0
    pruned_edges: int = 0
    kinds: dict = field(default_factory=dict)


def read_ways(path: str, include_service: bool, stats: Stats):
    """Pass 1 — walkable ways, their node refs, and how often each node is used."""
    allowed = WALKABLE | (SERVICE if include_service else set())
    way_refs: dict[int, list[int]] = {}
    way_meta: dict[int, tuple[str, str, str]] = {}
    usage: dict[int, int] = {}

    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line or line[0] != "w":
                continue
            stats.ways_seen += 1
            wid = 0
            tags: dict[str, str] = {}
            refs: list[int] = []
            for part in line.rstrip("\n").split(" "):
                if not part:
                    continue
                if part[0] == "w" and not wid:
                    try:
                        wid = int(part[1:])
                    except ValueError:
                        wid = 0
                elif part[0] == "T" and len(part) > 1:
                    tags = parse_tags(part[1:])
                elif part[0] == "N" and len(part) > 1:
                    refs = [int(r[1:]) for r in part[1:].split(",") if r[:1] == "n"]

            if not wid or len(refs) < 2:
                continue
            hw = tags.get("highway", "")
            route = tags.get("route", "")
            if hw not in allowed and route not in ("hiking", "foot"):
                stats.skipped_not_walkable += 1
                continue
            if not foot_allowed(tags):
                stats.skipped_no_access += 1
                continue

            stats.ways_kept += 1
            kind = edge_kind(tags)
            stats.kinds[kind] = stats.kinds.get(kind, 0) + 1
            way_refs[wid] = refs
            way_meta[wid] = (kind, tags.get("surface", "") or "", tags.get("name", "") or "")
            for r in refs:
                usage[r] = usage.get(r, 0) + 1

    return way_refs, way_meta, usage


def read_node_coords(path: str, wanted: set[int]) -> dict[int, tuple[float, float]]:
    """Pass 2 — coordinates, only for nodes the kept ways actually reference."""
    coords: dict[int, tuple[float, float]] = {}
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line or line[0] != "n":
                continue
            nid = 0
            lon = lat = None
            for part in line.rstrip("\n").split(" "):
                if not part:
                    continue
                if part[0] == "n" and not nid:
                    try:
                        nid = int(part[1:])
                    except ValueError:
                        break
                    if nid not in wanted:
                        break
                elif part[0] == "x" and len(part) > 1:
                    lon = float(part[1:])
                elif part[0] == "y" and len(part) > 1:
                    lat = float(part[1:])
            if nid and nid in wanted and lat is not None and lon is not None:
                coords[nid] = (lat, lon)
    return coords


# ---------------------------------------------------------------------------
# Graph construction
# ---------------------------------------------------------------------------


class UnionFind:
    def __init__(self) -> None:
        self.parent: dict[int, int] = {}

    def find(self, x: int) -> int:
        p = self.parent
        p.setdefault(x, x)
        while p[x] != x:
            p[x] = p[p[x]]
            x = p[x]
        return x

    def union(self, a: int, b: int) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[ra] = rb


@dataclass
class Edge:
    a: int
    b: int
    length_m: float
    kind: str
    surface: str
    name: str
    way_ref: int
    geometry: str


def build_edges(way_refs, way_meta, usage, coords, stats: Stats) -> list[Edge]:
    """Split each way at its junctions; every span becomes one edge."""
    junctions: set[int] = set()
    for refs in way_refs.values():
        junctions.add(refs[0])
        junctions.add(refs[-1])
        for r in refs[1:-1]:
            if usage.get(r, 0) >= 2:
                junctions.add(r)
    stats.junctions = len(junctions)

    edges: list[Edge] = []
    for wid, refs in way_refs.items():
        kind, surface, name = way_meta[wid]
        marks = [i for i, r in enumerate(refs) if r in junctions]
        for start, end in zip(marks, marks[1:]):
            span = refs[start:end + 1]
            pts = [coords[n] for n in span if n in coords]
            if len(pts) < 2:
                continue
            a, b = span[0], span[-1]
            if a == b:
                stats.self_loops += 1
                continue
            length = 0.0
            for p, q in zip(pts, pts[1:]):
                length += haversine_m((p[1], p[0]), (q[1], q[0]))
            if length < 0.5:
                stats.skipped_short += 1
                continue
            edges.append(Edge(
                a=a, b=b, length_m=length, kind=kind, surface=surface, name=name,
                way_ref=wid,
                geometry=encode_polyline([[lon, lat] for lat, lon in pts]),
            ))
    return edges


def prune_components(edges: list[Edge], min_nodes: int, stats: Stats) -> list[Edge]:
    """Drop islands too small to route within — parking-lot paths, orphan
    driveways, a footbridge mapped without its approaches."""
    uf = UnionFind()
    for e in edges:
        uf.union(e.a, e.b)
    size: dict[int, int] = {}
    seen: set[int] = set()
    for e in edges:
        for n in (e.a, e.b):
            if n in seen:
                continue
            seen.add(n)
            root = uf.find(n)
            size[root] = size.get(root, 0) + 1
    stats.components = len(size)
    keep = [e for e in edges if size[uf.find(e.a)] >= min_nodes]
    stats.pruned_edges = len(edges) - len(keep)
    kept_nodes = {n for e in keep for n in (e.a, e.b)}
    stats.pruned_nodes = len(seen) - len(kept_nodes)
    return keep


# ---------------------------------------------------------------------------
# Pack writing
# ---------------------------------------------------------------------------

DDL = """
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

-- Coordinates are fixed-point 1e7 integers, not REALs. SQLite stores a REAL
-- as 8 bytes always; these fit in 4, and 1e7 is ~1 cm — far finer than GPS.
CREATE TABLE nodes (
    id     INTEGER PRIMARY KEY,
    lat_e7 INTEGER NOT NULL,
    lon_e7 INTEGER NOT NULL,
    cell   INTEGER NOT NULL
);

-- Snapping a GPS fix to the nearest node does NOT need an R*Tree. Measured on
-- Raleigh: an R*Tree over 292k points cost 15.6 MB, more than the node table
-- itself. A coarse integer grid does the same job in a fraction of the space:
-- look up the 9 cells around the fix, then compare distances in memory.
CREATE INDEX idx_nodes_cell ON nodes(cell);

-- Names and surfaces repeat enormously (one street is hundreds of edges), so
-- they are interned rather than stored per row.
CREATE TABLE strings (id INTEGER PRIMARY KEY, value TEXT NOT NULL UNIQUE);

CREATE TABLE edges (
    id        INTEGER PRIMARY KEY,
    from_node INTEGER NOT NULL,
    to_node   INTEGER NOT NULL,
    length_dm INTEGER NOT NULL,   -- decimetres; centimetre precision is noise
    kind      INTEGER NOT NULL,   -- index into KINDS
    surface   INTEGER,            -- -> strings.id
    name      INTEGER,            -- -> strings.id
    way_ref   INTEGER NOT NULL,
    geometry  TEXT NOT NULL
);

CREATE INDEX idx_edges_from ON edges(from_node);
CREATE INDEX idx_edges_to   ON edges(to_node);
"""

# Grid cells are ~0.005 degrees, roughly 550 m.
CELL = 200


def cell_key(lat: float, lon: float) -> int:
    return int((lat + 90) * CELL) * 100_000 + int((lon + 180) * CELL)


KINDS = ["sidewalk", "crossing", "connector", "steps", "trail", "track",
         "cycleway", "footpath", "road"]
KIND_ID = {k: i for i, k in enumerate(KINDS)}

ATTRIBUTION = (
    "osm", "OpenStreetMap", "© OpenStreetMap contributors",
    "ODbL 1.0", "https://www.openstreetmap.org/copyright", 1,
)


def write_graph(path, region, region_name, edges, coords, stats: Stats, profile: str) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    if os.path.exists(path):
        os.remove(path)
    conn = sqlite3.connect(path)
    conn.executescript(DDL)
    conn.execute("""CREATE TABLE attribution (
        source_id TEXT PRIMARY KEY, name TEXT NOT NULL, attribution TEXT NOT NULL,
        license TEXT NOT NULL, url TEXT, requires_attribution INTEGER NOT NULL)""")
    conn.execute("INSERT INTO attribution VALUES (?,?,?,?,?,?)", ATTRIBUTION)

    # Remap sparse 64-bit OSM ids onto a dense 0..N-1 range.
    node_ids = sorted({n for e in edges for n in (e.a, e.b)} & set(coords))
    remap = {osm: i for i, osm in enumerate(node_ids)}
    stats.nodes_total = len(node_ids)
    stats.edges = len(edges)

    conn.executemany(
        "INSERT INTO nodes (id, lat_e7, lon_e7, cell) VALUES (?,?,?,?)",
        ((remap[n], round(coords[n][0] * 1e7), round(coords[n][1] * 1e7),
          cell_key(coords[n][0], coords[n][1])) for n in node_ids),
    )

    interned: dict[str, int] = {}

    def intern(value: str):
        if not value:
            return None
        if value not in interned:
            interned[value] = len(interned) + 1
        return interned[value]

    rows = []
    for e in edges:
        if e.a not in remap or e.b not in remap:
            continue
        rows.append((remap[e.a], remap[e.b], round(e.length_m * 10),
                     KIND_ID.get(e.kind, KIND_ID["road"]),
                     intern(e.surface), intern(e.name), e.way_ref, e.geometry))
    conn.executemany(
        """INSERT INTO edges (from_node, to_node, length_dm, kind, surface, name,
                              way_ref, geometry) VALUES (?,?,?,?,?,?,?,?)""", rows)
    conn.executemany("INSERT INTO strings (id, value) VALUES (?,?)",
                     ((v, k) for k, v in interned.items()))
    stats.edges = len(rows)

    lats = [coords[n][0] for n in node_ids]
    lons = [coords[n][1] for n in node_ids]
    meta = {
        "schema_version": str(SCHEMA_VERSION),
        "builder_version": BUILDER_VERSION,
        "region": region,
        "region_name": region_name,
        "profile": profile,
        "kinds": ",".join(KINDS),
        "coord_scale": "1e7",
        "cell_size": str(CELL),
        "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "node_count": str(len(node_ids)),
        "edge_count": str(len(rows)),
        "min_lat": f"{min(lats):.7f}", "max_lat": f"{max(lats):.7f}",
        "min_lon": f"{min(lons):.7f}", "max_lon": f"{max(lons):.7f}",
        "sources": "osm",
    }
    conn.executemany("INSERT INTO meta VALUES (?,?)", meta.items())
    conn.commit()
    conn.execute("VACUUM")
    conn.close()


# ---------------------------------------------------------------------------
# Verification — route something. A graph that cannot be traversed is not a
# graph, and a schema check alone would not notice.
# ---------------------------------------------------------------------------


def shortest_path(conn, start: int, goal: int, limit: int = 400_000):
    """Plain Dijkstra. Undirected: pedestrians ignore oneway."""
    dist = {start: 0.0}
    prev: dict[int, int] = {}
    heap = [(0.0, start)]
    visited = 0
    cur = conn.cursor()
    while heap:
        d, node = heapq.heappop(heap)
        if node == goal:
            path = [node]
            while path[-1] in prev:
                path.append(prev[path[-1]])
            return d, path[::-1], visited
        if d > dist.get(node, math.inf):
            continue
        visited += 1
        if visited > limit:
            return None, [], visited
        rows = cur.execute(
            """SELECT to_node, length_dm FROM edges WHERE from_node = ?
               UNION ALL
               SELECT from_node, length_dm FROM edges WHERE to_node = ?""",
            (node, node),
        ).fetchall()
        for nxt, length in rows:
            nd = d + length / 10.0
            if nd < dist.get(nxt, math.inf):
                dist[nxt] = nd
                prev[nxt] = node
                heapq.heappush(heap, (nd, nxt))
    return None, [], visited


def verify_graph(path: str) -> bool:
    conn = sqlite3.connect(path)
    ok = True

    tables = {r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type IN ('table','index')")}
    for required in ("meta", "nodes", "edges", "attribution", "strings",
                     "idx_nodes_cell", "idx_edges_from", "idx_edges_to"):
        if required not in tables:
            print(f"  FAIL — missing {required}")
            ok = False

    n_nodes = conn.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
    n_cells = conn.execute("SELECT COUNT(*) FROM nodes WHERE cell IS NOT NULL").fetchone()[0]
    if n_nodes != n_cells:
        print(f"  FAIL — {n_nodes - n_cells} nodes have no grid cell")
        ok = False

    # The grid index is only useful if it actually finds the nearest node.
    probe = conn.execute(
        "SELECT id, lat_e7/1e7, lon_e7/1e7 FROM nodes ORDER BY id LIMIT 1 OFFSET 1000").fetchone()
    if probe:
        plat, plon = probe[1] + 0.0004, probe[2] + 0.0004      # ~60 m away
        cells = [cell_key(plat + dy * (1.0 / CELL), plon + dx * (1.0 / CELL))
                 for dy in (-1, 0, 1) for dx in (-1, 0, 1)]
        t = time.perf_counter()
        cand = conn.execute(
            f"SELECT id, lat_e7/1e7, lon_e7/1e7 FROM nodes WHERE cell IN ({','.join('?' * 9)})",
            cells).fetchall()
        best = min(cand, key=lambda r: haversine_m((plon, plat), (r[2], r[1]))) if cand else None
        snap_ms = (time.perf_counter() - t) * 1000
        if not best:
            print("  FAIL — grid snap found no candidate nodes")
            ok = False
        else:
            d = haversine_m((plon, plat), (best[2], best[1]))
            print(f"  grid snap: {len(cand)} candidates, nearest {d:.0f} m, {snap_ms:.2f} ms")

    orphans = conn.execute(
        """SELECT COUNT(*) FROM edges e LEFT JOIN nodes n ON n.id = e.from_node
           WHERE n.id IS NULL""").fetchone()[0]
    if orphans:
        print(f"  FAIL — {orphans} edges reference a missing node")
        ok = False

    row = conn.execute("SELECT geometry, from_node, to_node FROM edges LIMIT 1").fetchone()
    if row:
        pts = decode_polyline(row[0])
        ends = conn.execute(
            "SELECT id, lat_e7/1e7, lon_e7/1e7 FROM nodes WHERE id IN (?,?)",
            (row[1], row[2])).fetchall()
        byid = {r[0]: (r[1], r[2]) for r in ends}
        a, b = byid[row[1]], byid[row[2]]
        d0 = haversine_m((pts[0][0], pts[0][1]), (a[1], a[0]))
        d1 = haversine_m((pts[-1][0], pts[-1][1]), (b[1], b[0]))
        if max(d0, d1) > 2.0:
            print(f"  FAIL — edge geometry does not meet its nodes ({d0:.1f}m / {d1:.1f}m)")
            ok = False

    # The real test: route between two well-separated nodes.
    hi = conn.execute("SELECT id FROM nodes ORDER BY lat_e7 DESC LIMIT 1").fetchone()
    mid = conn.execute("SELECT id FROM nodes ORDER BY id LIMIT 1 OFFSET (SELECT COUNT(*)/2 FROM nodes)").fetchone()
    t = time.perf_counter()
    d, path_nodes, visited = shortest_path(conn, mid[0], hi[0])
    ms = (time.perf_counter() - t) * 1000
    if d is None:
        # Not automatically a failure — the two may sit in different components.
        print(f"  note — no route between sampled nodes ({visited:,} explored, {ms:.0f} ms); "
              "they are in different components")
    else:
        print(f"  routed {d/1000:.2f} km over {len(path_nodes):,} nodes "
              f"in {ms:.0f} ms ({visited:,} explored)")

    conn.close()
    return ok


def component_report(edges: list[Edge]) -> tuple[int, float]:
    uf = UnionFind()
    for e in edges:
        uf.union(e.a, e.b)
    size: dict[int, int] = {}
    seen: set[int] = set()
    for e in edges:
        for n in (e.a, e.b):
            if n not in seen:
                seen.add(n)
                r = uf.find(n)
                size[r] = size.get(r, 0) + 1
    if not size:
        return 0, 0.0
    return len(size), max(size.values()) / len(seen) * 100


def inspect(path: str) -> None:
    conn = sqlite3.connect(path)
    size = os.path.getsize(path) / (1024 * 1024)
    print(f"{path} ({size:.2f} MB)")
    print("-" * 60)
    for k, v in conn.execute("SELECT key, value FROM meta ORDER BY key"):
        print(f"  {k:<16} {v}")
    print("\n  edges by kind:")
    for kind, n, km in conn.execute(
            "SELECT kind, COUNT(*), SUM(length_dm)/10000.0 FROM edges GROUP BY 1 ORDER BY 2 DESC"):
        print(f"    {KINDS[kind]:<12} {n:>8,}  {km:>10,.0f} km")
    conn.close()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Build a Wockett walkable routing graph from OPL.")
    ap.add_argument("--input", help="OPL file from `osmium cat -f opl`")
    ap.add_argument("--out", help="Output graph path, e.g. packs/raleigh.wktgraph")
    ap.add_argument("--region", default="", help="Short code, e.g. raleigh")
    ap.add_argument("--region-name", default="", help='Display name, e.g. "Raleigh"')
    ap.add_argument("--include-service", action="store_true",
                    help="Include highway=service (driveways, parking aisles). "
                         "Nearly trebles graph size; off by default.")
    ap.add_argument("--min-component", type=int, default=50,
                    help="Drop islands with fewer than this many nodes (default 50)")
    ap.add_argument("--inspect", help="Print a graph's metadata and exit")
    args = ap.parse_args(argv)

    if args.inspect:
        inspect(args.inspect)
        return 0
    if not args.input or not args.out:
        ap.error("--input and --out are required")
    if not os.path.exists(args.input):
        print(f"Input file not found: {args.input}", file=sys.stderr)
        return 1

    stats = Stats()
    t0 = time.perf_counter()

    way_refs, way_meta, usage = read_ways(args.input, args.include_service, stats)
    if not way_refs:
        print("No walkable ways found — check the tags-filter step.", file=sys.stderr)
        return 1

    wanted = {n for refs in way_refs.values() for n in refs}
    coords = read_node_coords(args.input, wanted)
    edges = build_edges(way_refs, way_meta, usage, coords, stats)
    if not edges:
        print("No edges built.", file=sys.stderr)
        return 1

    comps_before, largest_before = component_report(edges)
    edges = prune_components(edges, args.min_component, stats)
    comps_after, largest_after = component_report(edges)

    write_graph(args.out, args.region or "region", args.region_name or args.region,
                edges, coords, stats,
                "walkable+service" if args.include_service else "walkable")

    elapsed = time.perf_counter() - t0
    size = os.path.getsize(args.out) / (1024 * 1024)
    print(f"\nBuilt {args.out}")
    print(f"  ways seen          {stats.ways_seen:,}")
    print(f"  ways kept          {stats.ways_kept:,}")
    print(f"  not walkable       {stats.skipped_not_walkable:,}")
    print(f"  foot access denied {stats.skipped_no_access:,}")
    print(f"  graph nodes        {stats.nodes_total:,}")
    print(f"  graph edges        {stats.edges:,}")
    print(f"  components         {comps_before:,} -> {comps_after:,} after pruning")
    print(f"  largest component  {largest_before:.1f}% -> {largest_after:.1f}% of nodes")
    print(f"  pruned             {stats.pruned_nodes:,} nodes, {stats.pruned_edges:,} edges")
    print(f"  by kind            " + ", ".join(
        f"{k}={v:,}" for k, v in sorted(stats.kinds.items(), key=lambda kv: -kv[1])))
    print(f"  graph size         {size:.2f} MB")
    print(f"  elapsed            {elapsed:.1f}s")

    print("\nVerifying...")
    ok = verify_graph(args.out)
    print("  OK — schema, grid index, edge/node integrity and geometry all pass" if ok
          else "  FAILED — see above")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
