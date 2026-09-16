"""Tests for tools/build_trail_pack.py. Run from the repo root:

    python3 -m unittest discover -s tools/tests -v

Standard library only, like the builder. The merge rules are the part worth
pinning: a simple chain becomes one trail, a loop becomes one loop, and a
branching network with one name is left alone.
"""
import json
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import build_trail_pack as btp  # noqa: E402


def feature(fid, coords, **tags):
    return {"type": "Feature", "id": fid,
            "geometry": {"type": "LineString", "coordinates": coords},
            "properties": tags}


def write_seq(path, features):
    with open(path, "w") as f:
        for ft in features:
            f.write("\x1e" + json.dumps(ft) + "\n")


class MergeTests(unittest.TestCase):

    def build(self, features, **kw):
        d = tempfile.mkdtemp()
        src = os.path.join(d, "in.geojsonseq")
        out = os.path.join(d, "out.wktpack")
        write_seq(src, features)
        stats = btp.build_pack([(src, "osm")], out, "t", "Test", 0.00002, 30.0,
                               built_at="2026-01-01T00:00:00Z", **kw)
        conn = sqlite3.connect(out)
        rows = conn.execute(
            "SELECT source_ref, name, point_count, length_m, dog_access, "
            "dog_access_provenance, is_loop, tags_json FROM trails ORDER BY id").fetchall()
        conn.close()
        return stats, rows, out

    # Three ways laid end to end along a line of longitude, ~1.1 km each.
    CHAIN = [
        feature("w3", [[-78.64, 35.79], [-78.64, 35.80]], name="Long Trail", dog="leashed"),
        feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], name="Long Trail", surface="gravel"),
        feature("w2", [[-78.64, 35.80], [-78.64, 35.81]], name="Long Trail", surface="gravel"),
    ]

    def test_chain_merges_to_one_trail_with_smallest_ref(self):
        stats, rows, _ = self.build(self.CHAIN)
        self.assertEqual(len(rows), 1)
        ref, name, pts, length, dog, prov, loop, tags = rows[0]
        self.assertEqual(ref, "w1")
        self.assertEqual(name, "Long Trail")
        self.assertEqual(pts, 4, "three segments share two interior points")
        self.assertAlmostEqual(length, 3 * 1113, delta=10)
        self.assertEqual(json.loads(tags)["merged_ways"], 3)
        self.assertEqual(stats.merged_ways, 3)
        self.assertEqual(stats.merge_groups, 1)

    def test_reversed_member_is_flipped_into_the_chain(self):
        flipped = [dict(f) for f in self.CHAIN]
        flipped[1] = feature("w1", [[-78.64, 35.79], [-78.64, 35.78]], name="Long Trail")
        _, rows, out = self.build(flipped)
        self.assertEqual(len(rows), 1)
        conn = sqlite3.connect(out)
        poly = conn.execute("SELECT polyline FROM trails").fetchone()[0]
        coords = btp.decode_polyline(poly)
        lats = [c[1] for c in coords]
        # Direction is arbitrary (a trail has none); what matters is no doubling back.
        self.assertIn(lats, (sorted(lats), sorted(lats, reverse=True)), "chained without a doubling back")

    def test_conservative_dog_access_wins_and_keeps_tagged_provenance(self):
        _, rows, _ = self.build(self.CHAIN)
        self.assertEqual(rows[0][4], "leashRequired")
        self.assertEqual(rows[0][5], "tagged")

    def test_branching_network_is_left_as_ways(self):
        # A Y: three ways meeting at one point.
        y = [
            feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], name="Park Trail"),
            feature("w2", [[-78.64, 35.79], [-78.63, 35.80]], name="Park Trail"),
            feature("w3", [[-78.64, 35.79], [-78.65, 35.80]], name="Park Trail"),
        ]
        stats, rows, _ = self.build(y)
        self.assertEqual(len(rows), 3)
        self.assertEqual(stats.merge_groups_left, 1)
        self.assertEqual(stats.merged_ways, 0)

    def test_spur_splits_the_chain_but_the_rest_still_merges(self):
        # A -> B -> C -> D with a spur B -> E. B is a junction, so w1 stops
        # there and the spur stands alone, but w2 + w3 still merge.
        spurred = [
            feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], name="Ridge Trail"),
            feature("w2", [[-78.64, 35.79], [-78.64, 35.80]], name="Ridge Trail"),
            feature("w3", [[-78.64, 35.80], [-78.64, 35.81]], name="Ridge Trail"),
            feature("w4", [[-78.64, 35.79], [-78.63, 35.79]], name="Ridge Trail"),
        ]
        stats, rows, _ = self.build(spurred)
        self.assertEqual(len(rows), 3)
        merged = [r for r in rows if json.loads(r[7]).get("merged_ways")]
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0][0], "w2")
        self.assertEqual(json.loads(merged[0][7])["merged_ways"], 2)
        self.assertEqual(stats.merge_groups_left, 1, "one group had a junction")

    def test_two_halves_become_one_loop(self):
        halves = [
            feature("w1", [[-78.64, 35.78], [-78.63, 35.78], [-78.63, 35.79]], name="Pond Loop"),
            feature("w2", [[-78.63, 35.79], [-78.64, 35.79], [-78.64, 35.78]], name="Pond Loop"),
        ]
        _, rows, _ = self.build(halves)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][6], 1, "is_loop")

    def test_same_name_but_disconnected_stays_separate(self):
        apart = [
            feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], name="Main Street Path"),
            feature("w2", [[-78.50, 35.90], [-78.50, 35.91]], name="Main Street Path"),
        ]
        _, rows, _ = self.build(apart)
        self.assertEqual(len(rows), 2)

    def test_no_merge_flag_keeps_ways(self):
        _, rows, _ = self.build(self.CHAIN, merge_ways=False)
        self.assertEqual(len(rows), 3)

    def test_named_only_drops_unnamed(self):
        mixed = self.CHAIN + [feature("w9", [[-78.60, 35.70], [-78.60, 35.71]])]
        stats, rows, _ = self.build(mixed, named_only=True)
        self.assertEqual(len(rows), 1)
        self.assertEqual(stats.skipped_unnamed, 1)

    def test_rebuild_is_byte_identical_with_built_at(self):
        _, _, a = self.build(self.CHAIN)
        _, _, b = self.build(self.CHAIN)
        with open(a, "rb") as fa, open(b, "rb") as fb:
            self.assertEqual(fa.read(), fb.read())


class PolylineTests(unittest.TestCase):
    def test_google_reference_vector(self):
        self.assertEqual(btp.encode_polyline([(-120.2, 38.5), (-120.95, 40.7), (-126.453, 43.252)]),
                         "_p~iF~ps|U_ulLnnqC_mqNvxq`@")


if __name__ == "__main__":
    unittest.main()
