"""Tests for tools/region_release.py and tools/pack_quality.py.

    python3 -m unittest discover -s tools/tests -v

The gates must be able to fail: each test that expects a failure breaks one
condition on an otherwise good pack.
"""
import json
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import build_trail_pack as btp  # noqa: E402
import pack_quality  # noqa: E402
import region_release as rr  # noqa: E402
from test_build_trail_pack import feature, write_seq  # noqa: E402

RALEIGH = {"lat": 35.79, "lon": -78.64, "place": "Raleigh"}
REGION = {"name": "Test", "geofabrik": "x/y", "bundled": False, "probe": RALEIGH}


def corridor(i, lat, name=None, n=4, lon=None, fid=None):
    """A ~450 m north-south way starting at `lat`, optionally named. Unless
    `lon` is given, way i sits 0.003 deg east of way i-1."""
    tags = {"highway": "path"}
    if name:
        tags["name"] = name
    x = lon if lon is not None else -78.64 + i * 0.003
    return feature(fid or f"w{i}", [[x, lat + k * 0.001] for k in range(n + 1)], **tags)


def build(features, d=None):
    d = d or tempfile.mkdtemp()
    src = os.path.join(d, "in.geojsonseq")
    out = os.path.join(d, "t-full.wktpack")
    write_seq(src, features)
    btp.build_pack([(src, "osm")], out, "t", "Test", 0.00002, 30.0, built_at="2026-01-01T00:00:00Z")
    return out


# 120 short corridors near Raleigh; two named, one of them in two pieces 1 km apart.
# Ridge Trail's second piece starts ~200 m beyond the first one's end: one trail
# in the app (pieces within 400 m group), two rows in the pack.
FEATURES = [corridor(i, 35.70) for i in range(118)] + [
    corridor(0, 35.790, name="Creek Trail", lon=-78.640, fid="w900"),
    corridor(0, 35.790, name="Ridge Trail", lon=-78.630, fid="w901"),
    corridor(0, 35.796, name="Ridge Trail", lon=-78.630, fid="w902"),
]


class QualityTests(unittest.TestCase):
    def test_counts_named_trails_split_into_pieces(self):
        q = pack_quality.report(build(FEATURES))
        self.assertEqual(q["named_trails"], 2)            # Creek; Ridge's two pieces are one trail
        self.assertEqual(q["named_trails_in_pieces"], 1)  # Ridge Trail
        self.assertEqual(q["max_pieces"], 2)

    def test_pieces_far_apart_are_separate_trails(self):
        far = FEATURES[:-1] + [corridor(0, 36.50, name="Ridge Trail", lon=-78.630, fid="w902")]  # ~80 km away
        q = pack_quality.report(build(far))
        self.assertEqual(q["named_trails"], 3)
        self.assertEqual(q["named_trails_in_pieces"], 0)


class GateTests(unittest.TestCase):
    def setUp(self):
        self.pack = build(FEATURES)

    def test_good_pack_passes(self):
        self.assertEqual(rr.gates(self.pack, REGION, (-79.5, 35.0, -78.0, 36.5)), [])

    def test_no_named_trails_near_probe_fails(self):
        region = dict(REGION, probe={"lat": 34.0, "lon": -81.0, "place": "Columbia"})
        failures = rr.gates(self.pack, region, None)
        self.assertTrue(any("Columbia" in f for f in failures), failures)

    def test_trails_outside_extract_fail(self):
        failures = rr.gates(self.pack, REGION, (-78.0, 35.0, -77.0, 36.0))  # extract east of the trails
        self.assertTrue(any("outside" in f for f in failures), failures)

    def test_too_few_trails_fail(self):
        small = build(FEATURES[-3:])
        self.assertTrue(any("only" in f for f in rr.gates(small, REGION, None)))

    def test_over_budget_fails(self):
        old = rr.SIZE_BUDGET_BYTES
        rr.SIZE_BUDGET_BYTES = 10
        try:
            self.assertTrue(any("budget" in f for f in rr.gates(self.pack, REGION, None)))
        finally:
            rr.SIZE_BUDGET_BYTES = old


class ManifestTests(unittest.TestCase):
    def run_release(self, work, pack):
        regions = os.path.join(work, "regions.json")
        with open(regions, "w") as f:
            json.dump({"t": REGION}, f)
        code = rr.main(["t", "--pack", pack, "--work", work, "--extract-md5", "abc",
                        "--regions", regions])
        return code

    def test_first_release_is_version_1_with_computed_fields(self):
        work = tempfile.mkdtemp()
        pack = build(FEATURES, work)
        self.assertEqual(self.run_release(work, pack), 0)
        with open(os.path.join(work, "release", "t-v1.json")) as f:
            m = json.load(f)
        self.assertEqual(m["packVersion"], 1)
        self.assertEqual(m["region"], "t")
        self.assertEqual(m["trailCount"], sqlite3.connect(pack).execute("select count(*) from trails").fetchone()[0])
        self.assertEqual(m["sizeBytes"], os.path.getsize(pack))
        meta = dict(sqlite3.connect(pack).execute("select key, value from meta"))
        self.assertEqual(meta["pack_version"], "1")         # the file says which version it is
        self.assertEqual(meta["source_extract_md5"], "abc")
        self.assertTrue(btp.verify_pack(pack))              # stamping meta left it valid

    def test_next_release_follows_the_published_version(self):
        work = tempfile.mkdtemp()
        first = build(FEATURES, tempfile.mkdtemp())
        os.makedirs(os.path.join(work, "published"))
        with open(os.path.join(work, "published", "t.json"), "w") as f:
            json.dump({"packVersion": 4, "pack": first}, f)
        pack = build(FEATURES[:-1], work)                   # Ridge Trail loses a piece
        self.assertEqual(self.run_release(work, pack), 0)
        with open(os.path.join(work, "release", "t-v5.json")) as f:
            m = json.load(f)
        self.assertEqual(m["packVersion"], 5)
        self.assertEqual(m["changes"]["pieces"], -1)

    def test_failed_gate_writes_nothing(self):
        work = tempfile.mkdtemp()
        pack = build(FEATURES[-3:], work)
        self.assertEqual(self.run_release(work, pack), 1)
        self.assertFalse(os.path.exists(os.path.join(work, "release")))


if __name__ == "__main__":
    unittest.main()


class CoverageGateTests(unittest.TestCase):
    """2026-10-08: a state ships only if most of its towns get a named trail within 3 miles."""

    def towns(self, *places):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "towns.geojsonseq")
        write_seq(path, [{"type": "Feature", "geometry": {"type": "Point", "coordinates": [lon, lat]},
                          "properties": {"name": name, "place": "town"}} for name, lat, lon in places])
        return rr.load_towns(path)

    RALEIGH_TOWN = ("Raleigh", 35.79, -78.64)
    FAR = [("Far One", 36.40, -78.64), ("Far Two", 36.45, -78.64)]  # ~70 km north of every trail

    def test_half_the_towns_covered_passes_and_a_third_fails(self):
        pack = build(FEATURES)
        self.assertEqual(rr.gates(pack, REGION, None, self.towns(self.RALEIGH_TOWN, self.FAR[0])), [])
        failures = rr.gates(pack, REGION, None, self.towns(self.RALEIGH_TOWN, *self.FAR))
        self.assertTrue(any("33% of 3 cities and towns" in f for f in failures), failures)

    def test_a_short_named_trail_does_not_cover_a_town(self):
        stub = [corridor(i, 35.70) for i in range(118)] + [
            corridor(0, 35.790, name="Stub Trail", n=2, lon=-78.640, fid="w950")]  # ~220 m
        share, without = rr.coverage(build(stub), self.towns(self.RALEIGH_TOWN))
        self.assertEqual((share, without), (0.0, ["Raleigh"]))

    def test_a_bike_only_path_does_not_cover_a_town(self):
        bike_only = [corridor(i, 35.70) for i in range(118)] + [
            feature("w960", [[-78.64, 35.790 + k * 0.001] for k in range(9)],
                    highway="cycleway", name="Cycle Track", foot="no")]
        share, _ = rr.coverage(build(bike_only), self.towns(self.RALEIGH_TOWN))
        self.assertEqual(share, 0.0)

    def test_a_trail_is_judged_on_its_whole_length(self):
        # Two ~220 m pieces of one trail, ~100 m apart: one trail key, ~440 m
        # in all, over the quarter-mile floor although each piece is under it.
        pieces = [corridor(i, 35.70) for i in range(118)] + [
            corridor(0, 35.790, name="Split Trail", n=2, lon=-78.640, fid="w970"),
            corridor(0, 35.793, name="Split Trail", n=2, lon=-78.640, fid="w971")]
        share, _ = rr.coverage(build(pieces), self.towns(self.RALEIGH_TOWN))
        self.assertEqual(share, 1.0)
