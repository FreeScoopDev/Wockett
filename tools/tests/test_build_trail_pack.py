"""Tests for tools/build_trail_pack.py. Run from the repo root:

    python3 -m unittest discover -s tools/tests -v

Standard library only, like the builder. The merge rules are the part worth
pinning: a simple chain becomes one trail, a loop becomes one loop, and a
branching network with one name is left alone.
"""
import json
import math
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


# A line of longitude near Raleigh; 0.001 deg of latitude is ~111 m.
LON = -78.64


def north(fid, lat0, lat1, lon=LON, **tags):
    return feature(fid, [[lon, lat0], [lon, lat1]], **tags)


SIDEPATH = dict(highway="cycleway", surface="asphalt")


class JoinUnnamedTests(unittest.TestCase):
    """Unnamed ways join into corridors by geometry and kind (builder 1.2.0)."""

    def build(self, features, roads=None, **kw):
        d = tempfile.mkdtemp()
        src = os.path.join(d, "in.geojsonseq")
        out = os.path.join(d, "out.wktpack")
        write_seq(src, features)
        if roads is not None:
            kw["roads_path"] = os.path.join(d, "roads.geojsonseq")
            write_seq(kw["roads_path"], roads)
        stats = btp.build_pack([(src, "osm")], out, "t", "Test", 0.00002, 30.0,
                               built_at="2026-01-01T00:00:00Z", **kw)
        conn = sqlite3.connect(out)
        rows = conn.execute(
            "SELECT source_ref, name, length_m, tags_json, polyline FROM trails ORDER BY id").fetchall()
        meta = dict(conn.execute("SELECT key, value FROM meta"))
        conn.close()
        return stats, rows, meta

    # Five pieces of one sidepath, listed out of order, one of them reversed
    # and one only 11 m long — shorter than the 30 m floor on its own.
    CHAIN = [
        north("w14", 35.790, 35.792, **SIDEPATH),
        north("w12", 35.781, 35.780, **SIDEPATH),          # reversed
        north("w13", 35.781, 35.7811, **SIDEPATH),         # 11 m
        north("w15", 35.7811, 35.790, **SIDEPATH),
        north("w16", 35.792, 35.795, highway="footway", surface="concrete", bicycle="yes"),
    ]

    def test_chain_of_unnamed_pieces_becomes_one_row(self):
        stats, rows, _ = self.build(self.CHAIN)
        self.assertEqual(len(rows), 1, rows)
        ref, name, length, tags, poly = rows[0]
        self.assertEqual(ref, "w12", "identity is the smallest member ref")
        self.assertIsNone(name)
        self.assertEqual(json.loads(tags)["merged_ways"], 5)
        self.assertAlmostEqual(length, 15 * 111.2, delta=5)
        lats = [c[1] for c in btp.decode_polyline(poly)]
        self.assertIn(lats, (sorted(lats), sorted(lats, reverse=True)), "no doubling back")
        self.assertEqual(stats.joined_unnamed_ways, 5)
        self.assertEqual(stats.unnamed_corridors, 1)

    def test_ends_a_metre_apart_join_but_ten_metres_apart_do_not(self):
        near = [north("w1", 35.780, 35.781, **SIDEPATH),
                north("w2", 35.78101, 35.782, **SIDEPATH)]   # ~1.1 m gap
        far = [north("w1", 35.780, 35.781, **SIDEPATH),
               north("w2", 35.7811, 35.782, **SIDEPATH)]     # ~11 m gap
        self.assertEqual(len(self.build(near)[1]), 1)
        self.assertEqual(len(self.build(far)[1]), 2)

    def test_fork_takes_the_straightest_continuation(self):
        # w1 runs north into a Y. w2 carries straight on; w3 bears off 30°
        # right. The straight pair joins; the branch is its own corridor.
        lat = 35.790
        fork = [
            north("w1", 35.780, lat, **SIDEPATH),
            feature("w3", [[LON, lat], [LON + 0.005 * math.tan(math.radians(30)) / math.cos(math.radians(lat)), lat + 0.005]], **SIDEPATH),
            north("w2", lat, 35.795, **SIDEPATH),
        ]
        _, rows, _ = self.build(fork)
        self.assertEqual(len(rows), 2, rows)
        joined = [r for r in rows if "merged_ways" in json.loads(r[3])]
        self.assertEqual(len(joined), 1)
        self.assertEqual(joined[0][0], "w1")
        self.assertAlmostEqual(joined[0][2], 15 * 111.2, delta=5, msg="w1 + w2, not w1 + w3")

    def test_right_angle_at_a_junction_does_not_join(self):
        # A T: w1 north into the junction, w2 and w3 leave east and west.
        # Every pair turns 90° or more, so nothing joins there.
        lat = 35.790
        tee = [
            north("w1", 35.780, lat, **SIDEPATH),
            feature("w2", [[LON, lat], [LON + 0.01, lat]], **SIDEPATH),
            feature("w3", [[LON, lat], [LON - 0.01, lat]], **SIDEPATH),
        ]
        _, rows, _ = self.build(tee)
        self.assertEqual(len(rows), 2, "w2 + w3 run straight through; w1 stays alone")
        self.assertEqual(sorted(r[0] for r in rows), ["w1", "w2"])

    def test_sharp_turn_at_a_junction_does_not_join(self):
        # w1 runs north into a junction where a named trail carries on north
        # and w2 turns off east. The named trail makes it a junction, and a
        # 90° turn there is a different path, so w1 and w2 stay apart.
        lat = 35.790
        ways = [north("w1", 35.780, lat, **SIDEPATH),
                feature("w2", [[LON, lat], [LON + 0.01, lat]], **SIDEPATH),
                north("w3", lat, 35.800, name="Ridge Trail", **SIDEPATH)]
        _, rows, _ = self.build(ways)
        self.assertEqual(sorted(r[0] for r in rows), ["w1", "w2", "w3"])

    def test_gentle_bend_at_a_junction_still_joins(self):
        # The same junction, but w2 bends off 30°: within the 45° limit.
        lat = 35.790
        dlon = 0.01 * math.tan(math.radians(30)) / math.cos(math.radians(lat))
        ways = [north("w1", 35.780, lat, **SIDEPATH),
                feature("w2", [[LON, lat], [LON + dlon, lat + 0.01]], **SIDEPATH),
                feature("w3", [[LON, lat], [LON - 0.01, lat]], name="Ridge Trail", **SIDEPATH)]
        _, rows, _ = self.build(ways)
        self.assertEqual(sorted(r[0] for r in rows), ["w1", "w3"])

    def test_where_only_two_ways_meet_they_join_at_any_angle(self):
        switchback = [north("w1", 35.780, 35.790, **SIDEPATH),
                      feature("w2", [[LON, 35.790], [LON + 0.01, 35.790]], **SIDEPATH)]
        self.assertEqual(len(self.build(switchback)[1]), 1)

    def test_paved_and_unpaved_do_not_join(self):
        mixed = [north("w1", 35.780, 35.790, highway="path", surface="asphalt"),
                 north("w2", 35.790, 35.800, highway="path", surface="dirt")]
        _, rows, _ = self.build(mixed)
        self.assertEqual(len(rows), 2)

    def test_a_neutral_boardwalk_does_not_bridge_paved_to_unpaved(self):
        # asphalt - wood - dirt: the boardwalk may join either side, not both.
        mixed = [north("w1", 35.780, 35.790, highway="path", surface="asphalt"),
                 north("w2", 35.790, 35.791, highway="path", surface="wood"),
                 north("w3", 35.791, 35.800, highway="path", surface="dirt")]
        _, rows, _ = self.build(mixed)
        self.assertEqual(len(rows), 2)
        for _, _, _, tags, _ in rows:
            self.assertLessEqual(json.loads(tags).get("merged_ways", 1), 2)

    def test_track_and_path_do_not_join(self):
        mixed = [north("w1", 35.780, 35.790, highway="track"),
                 north("w2", 35.790, 35.800, highway="path")]
        self.assertEqual(len(self.build(mixed)[1]), 2)

    def test_named_and_unnamed_do_not_join_and_named_merge_is_unchanged(self):
        ways = [north("w1", 35.780, 35.790, name="Long Trail"),
                north("w2", 35.790, 35.800, name="Long Trail"),
                north("w3", 35.800, 35.810)]
        stats, rows, _ = self.build(ways)
        self.assertEqual([(r[0], r[1]) for r in rows], [("w1", "Long Trail"), ("w3", None)])
        self.assertEqual(json.loads(rows[0][3])["merged_ways"], 2)
        self.assertNotIn("merged_ways", json.loads(rows[1][3]))
        self.assertEqual((stats.merged_ways, stats.merge_groups), (2, 1))

    def test_crossing_links_two_pieces_and_is_dropped_on_its_own(self):
        ways = [north("w1", 35.780, 35.790, **SIDEPATH),
                north("w2", 35.790, 35.7902, highway="footway", footway="crossing"),   # 22 m
                north("w3", 35.7902, 35.800, **SIDEPATH),
                north("w4", 35.800, 35.8004, highway="footway", footway="crossing"),   # dangling
                north("w5", 35.7796, 35.780, highway="footway", footway="crossing"),   # dangling
                north("w9", 35.850, 35.8505, highway="footway", footway="crossing")]   # alone, 55 m
        stats, rows, _ = self.build(ways)
        self.assertEqual(len(rows), 1, rows)
        self.assertEqual(json.loads(rows[0][3])["merged_ways"], 3, "w1 + crossing + w3, not w4 or w5")
        self.assertEqual(stats.skipped_crossing, 3)

    def test_a_lone_crossing_is_not_a_trail(self):
        stats, rows, _ = self.build([north("w1", 35.780, 35.7805, highway="footway", footway="crossing")])
        self.assertEqual(rows, [])
        self.assertEqual(stats.skipped_crossing, 1)
        stats, rows, _ = self.build([north("w1", 35.780, 35.7805, highway="footway", footway="crossing")],
                                    join_unnamed=False)
        self.assertEqual(rows, [], "not a trail with joining off either")

    def test_named_crossing_joins_its_trail_or_goes(self):
        # Greenways often name their crossings (the Charlotte Rail Trail has 25).
        ways = [north("w1", 35.780, 35.790, name="Rail Trail"),
                north("w2", 35.790, 35.7902, name="Rail Trail", highway="footway", footway="crossing"),
                north("w3", 35.7902, 35.800, name="Rail Trail"),
                north("w9", 35.850, 35.8505, name="Elm Street", highway="footway", footway="crossing")]
        stats, rows, _ = self.build(ways)
        self.assertEqual([(r[0], r[1]) for r in rows], [("w1", "Rail Trail")])
        self.assertEqual(json.loads(rows[0][3])["merged_ways"], 3)
        self.assertEqual(stats.skipped_crossing, 1)

    def test_no_join_flag_keeps_unnamed_ways_apart(self):
        stats, rows, meta = self.build(self.CHAIN, join_unnamed=False)
        self.assertEqual(len(rows), 4, "the 11 m piece falls under the floor")
        self.assertEqual(meta["join_unnamed"], "0")

    def test_meta_records_the_new_flags(self):
        _, _, meta = self.build(self.CHAIN)
        self.assertEqual(meta["schema_version"], "1")
        self.assertEqual(meta["builder_version"], btp.BUILDER_VERSION)
        self.assertEqual((meta["join_unnamed"], meta["derived_names"], meta["keep_sidewalks"]),
                         ("1", "0", "0"))

    # --- derived names -----------------------------------------------------

    @staticmethod
    def road(fid, coords, name):
        return feature(fid, coords, highway="primary", name=name)

    # ~20 m east of the sidepath, the whole way along.
    PARALLEL = [feature("w100", [[LON + 0.00022, 35.775], [LON + 0.00022, 35.800]],
                        highway="primary", name="Duck Road")]

    def test_parallel_road_names_the_corridor(self):
        stats, rows, meta = self.build(self.CHAIN, roads=self.PARALLEL)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][1], "Duck Road Path")
        self.assertEqual(json.loads(rows[0][3])["name_source"], "derived_road")
        self.assertEqual(stats.derived_names, 1)
        self.assertEqual(meta["derived_names"], "1")

    def test_crossing_road_does_not_name_the_corridor(self):
        # A 110 m sidepath crossed at its middle by a road at 60° to it: the
        # road is within 40 m of every sample, so only the parallel-angle
        # rule (30°) turns it down.
        short = [north("w1", 35.7800, 35.7805, **SIDEPATH),
                 north("w2", 35.7805, 35.7810, **SIDEPATH)]
        # 60° off north: 0.01 deg north for every 0.01*tan(60°) deg-east-equivalent.
        dlon = 0.01 * math.tan(math.radians(60)) / math.cos(math.radians(35.7805))
        crossing = [feature("w100", [[LON - dlon, 35.7705], [LON + dlon, 35.7905]],
                            highway="primary", name="Cross Street")]
        _, rows, _ = self.build(short, roads=crossing)
        self.assertEqual(len(rows), 1)
        self.assertIsNone(rows[0][1])
        self.assertNotIn("name_source", json.loads(rows[0][3]))

    def test_parallel_road_too_far_away_does_not_name_it(self):
        far = [feature("w100", [[LON + 0.0006, 35.775], [LON + 0.0006, 35.800]],   # ~54 m
                       highway="primary", name="Far Road")]
        _, rows, _ = self.build(self.CHAIN, roads=far)
        self.assertIsNone(rows[0][1])

    def test_road_alongside_for_less_than_the_share_does_not_name_it(self):
        # Alongside for the first 0.007 deg of 0.015 (47%): not most of it.
        partial = [feature("w100", [[LON + 0.00022, 35.780], [LON + 0.00022, 35.787]],
                           highway="primary", name="Short Road")]
        _, rows, _ = self.build(self.CHAIN, roads=partial)
        self.assertIsNone(rows[0][1])

    def test_real_names_are_never_replaced(self):
        named = [north("w1", 35.780, 35.795, name="Neuse River Trail", **SIDEPATH)]
        _, rows, _ = self.build(named, roads=self.PARALLEL)
        self.assertEqual(rows[0][1], "Neuse River Trail")
        self.assertNotIn("name_source", json.loads(rows[0][3]))

    def test_unpaved_trail_beside_a_road_is_not_named_after_it(self):
        for tags in (dict(highway="path", surface="dirt"),
                     dict(highway="cycleway", surface="gravel"),
                     dict(highway="footway", surface="concrete")):   # no bike: a sidewalk
            _, rows, _ = self.build([north("w1", 35.780, 35.795, **tags)], roads=self.PARALLEL)
            self.assertIsNone(rows[0][1], tags)

    # --- sidewalks ---------------------------------------------------------

    SIDEWALKS = [north("w1", 35.780, 35.790, highway="footway", footway="sidewalk"),
                 north("w2", 35.790, 35.795, highway="footway", footway="sidewalk"),
                 north("w3", 35.700, 35.710, highway="footway")]

    def test_sidewalks_are_dropped_by_default(self):
        stats, rows, meta = self.build(self.SIDEWALKS)
        self.assertEqual([r[0] for r in rows], ["w3"])
        self.assertEqual(stats.skipped_sidewalk, 2)
        self.assertEqual(meta["keep_sidewalks"], "0")

    def test_keep_sidewalks_keeps_them_and_calls_them_sidewalks(self):
        stats, rows, meta = self.build(self.SIDEWALKS, roads=self.PARALLEL, keep_sidewalks=True)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0][1], "Duck Road Sidewalk")
        self.assertEqual(stats.skipped_sidewalk, 0)
        self.assertEqual(meta["keep_sidewalks"], "1")


class PolylineTests(unittest.TestCase):
    def test_google_reference_vector(self):
        self.assertEqual(btp.encode_polyline([(-120.2, 38.5), (-120.95, 40.7), (-126.453, 43.252)]),
                         "_p~iF~ps|U_ulLnnqC_mqNvxq`@")


if __name__ == "__main__":
    unittest.main()
