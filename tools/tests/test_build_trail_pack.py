"""Tests for tools/build_trail_pack.py. Run from the repo root:

    python3 -m unittest discover -s tools/tests -v

Standard library only, like the builder. The merge rules are the part worth
pinning: a simple chain becomes one trail, a loop becomes one loop, and a
branching network with one name is left alone.
"""
import json
import math
import os
import signal
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

    def test_trail_continues_straight_through_a_spur(self):
        # A -> B -> C -> D with a spur B -> E. Since builder 1.3.0 the trail
        # carries straight on through B (w1 + w2 + w3 merge, 0 deg turn) and
        # the spur, a 90 deg turn, stays its own row. Before, B split the
        # trail in two as well (2026-10-08: Neuse River Trail was 29 rows).
        spurred = [
            feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], name="Ridge Trail"),
            feature("w2", [[-78.64, 35.79], [-78.64, 35.80]], name="Ridge Trail"),
            feature("w3", [[-78.64, 35.80], [-78.64, 35.81]], name="Ridge Trail"),
            feature("w4", [[-78.64, 35.79], [-78.63, 35.79]], name="Ridge Trail"),
        ]
        stats, rows, _ = self.build(spurred)
        self.assertEqual(len(rows), 2)
        merged = [r for r in rows if json.loads(r[7]).get("merged_ways")]
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0][0], "w1")
        self.assertEqual(json.loads(merged[0][7])["merged_ways"], 3)
        self.assertGreaterEqual(stats.junction_merges, 1)

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
        # These tests pin the joining rules on short ways; the 1.3.0 stub
        # cut has its own tests (CurationTests).
        kw.setdefault("min_unnamed_length_m", 0.0)
        stats = btp.build_pack([(src, "osm")], out, "t", "Test", 0.00002, 30.0,
                               built_at="2026-01-01T00:00:00Z", **kw)
        conn = sqlite3.connect(out)
        rows = conn.execute(
            "SELECT source_ref, name, length_m, tags_json, polyline FROM trails ORDER BY id").fetchall()
        meta = dict(conn.execute("SELECT key, value FROM meta"))
        conn.row_factory = sqlite3.Row
        self.full = {r["source_ref"]: dict(r) for r in conn.execute("SELECT * FROM trails")}
        conn.close()
        return stats, rows, meta

    # Five pieces of one sidepath, listed out of order, one of them reversed
    # and one only 11 m long — shorter than the 30 m floor on its own.
    CHAIN = [
        north("w14", 35.790, 35.792, **SIDEPATH),
        north("w12", 35.781, 35.780, **SIDEPATH),          # reversed
        north("w13", 35.781, 35.7811, **SIDEPATH),         # 11 m
        north("w15", 35.7811, 35.790, lit="yes", **SIDEPATH),   # the longest
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
        # w14 was read first, so it has id 1: neither the chain's first piece
        # (w12 or w16) nor the longest (w15), whose tags the row carries.
        self.assertEqual(self.full["w12"]["id"], 1, "the smallest member id")
        self.assertEqual(json.loads(tags).get("lit"), "yes", "tags come from the longest member")
        self.assertEqual(json.loads(tags)["highway"], "cycleway")

    def test_three_unnamed_ways_forming_a_triangle_are_one_loop(self):
        tri = [feature("w1", [[LON, 35.780], [LON + 0.004, 35.780]], **SIDEPATH),
               feature("w2", [[LON + 0.004, 35.780], [LON + 0.002, 35.783]], **SIDEPATH),
               feature("w3", [[LON + 0.002, 35.783], [LON, 35.780]], **SIDEPATH)]

        def hung(*_):
            raise TimeoutError("joining a closed loop never finished")
        old = signal.signal(signal.SIGALRM, hung)
        signal.setitimer(signal.ITIMER_REAL, 5)
        try:
            _, rows, _ = self.build(tri)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, old)
        self.assertEqual(len(rows), 1)
        self.assertEqual(self.full["w1"]["is_loop"], 1)
        self.assertEqual(json.loads(rows[0][3])["merged_ways"], 3)

    def test_heading_is_read_past_a_kink_at_the_end(self):
        # At a junction w2 carries on north but starts with a 5 m jog east (a
        # curb ramp); w3 bears off 30°. Read over its first 15 m, w2 is the
        # straight one; read off its first segment alone it would be a 90°
        # turn and w3 would win.
        lat = 35.790
        jog = 5 / (111_320 * math.cos(math.radians(lat)))
        dlon = 0.01 * math.tan(math.radians(30)) / math.cos(math.radians(lat))
        ways = [north("w1", 35.780, lat, **SIDEPATH),
                feature("w2", [[LON, lat], [LON + jog, lat], [LON + jog, lat + 0.01]], **SIDEPATH),
                feature("w3", [[LON, lat], [LON + dlon, lat + 0.01]], **SIDEPATH)]
        _, rows, _ = self.build(ways)
        self.assertEqual(json.loads(self.full["w1"]["tags_json"]).get("merged_ways"), 2)
        self.assertIn("w3", self.full, "w3 is left as its own row")
        self.assertAlmostEqual(self.full["w1"]["length_m"], 2 * 1112 + 5, delta=10, msg="w1 + w2")

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
        # An open track, so the 1.4.0 dirt-road rule keeps it; joining is what is tested.
        mixed = [north("w1", 35.780, 35.790, highway="track", foot="yes"),
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
        ways = [north("w1", 35.780, 35.790, name="Rail Trail", bicycle="designated", **SIDEPATH),
                north("w2", 35.790, 35.7902, name="Rail Trail", highway="footway", footway="crossing"),
                north("w3", 35.7902, 35.800, name="Rail Trail", bicycle="designated", **SIDEPATH),
                north("w9", 35.850, 35.8505, name="Elm Street", highway="footway", footway="crossing")]
        stats, rows, _ = self.build(ways)
        self.assertEqual([(r[0], r[1]) for r in rows], [("w1", "Rail Trail")])
        self.assertEqual(json.loads(rows[0][3])["merged_ways"], 3)
        self.assertEqual(self.full["w1"]["allows_bike"], 1, "the crossing does not vote")
        self.assertEqual(stats.skipped_crossing, 1)

    def test_no_merge_flag_still_drops_named_crossings(self):
        ways = [north("w1", 35.780, 35.790, name="Rail Trail"),
                north("w2", 35.790, 35.7905, name="Rail Trail", highway="footway", footway="crossing")]
        stats, rows, _ = self.build(ways, merge_ways=False)
        self.assertEqual([r[0] for r in rows], ["w1"])
        self.assertEqual(stats.skipped_crossing, 1)

    # --- access, surface and dogs on joined rows ---------------------------

    def test_crossings_do_not_vote_on_bike_surface_or_dogs(self):
        ways = [north("w1", 35.780, 35.790, bicycle="designated", foot="designated", **SIDEPATH),
                north("w2", 35.790, 35.7902, highway="footway", footway="crossing",
                      surface="paving_stones", dog="no"),
                north("w3", 35.7902, 35.800, bicycle="designated", foot="designated", **SIDEPATH),
                north("w4", 35.800, 35.8002, highway="footway", footway="crossing", surface="paving_stones"),
                north("w5", 35.8002, 35.810, bicycle="designated", foot="designated", **SIDEPATH)]
        self.build(ways)
        row = self.full["w1"]
        self.assertEqual(json.loads(row["tags_json"])["merged_ways"], 5)
        self.assertEqual((row["allows_bike"], row["allows_foot"]), (1, 1))
        self.assertEqual(row["surface"], "asphalt", "not the crossings' paving stones")
        self.assertEqual(row["dog_access"], "unknown", "the crosswalk's dog=no is not the path's")

    def test_a_silent_member_does_not_take_access_away(self):
        # A cycleway continued by an untagged footway: the footway says
        # nothing about bikes, which is not a no.
        ways = [north("w1", 35.780, 35.790, **SIDEPATH),
                north("w2", 35.790, 35.800, highway="footway", surface="asphalt")]
        self.build(ways)
        self.assertEqual(self.full["w1"]["allows_bike"], 1)

    def test_an_explicit_no_takes_access_away(self):
        ways = [north("w1", 35.780, 35.790, **SIDEPATH),
                north("w2", 35.790, 35.800, highway="footway", surface="asphalt", bicycle="no")]
        self.build(ways)
        self.assertEqual(self.full["w1"]["allows_bike"], 0)
        self.assertEqual(self.full["w1"]["allows_foot"], 1, "footway allows foot; bicycle=no is not about feet")

    def test_access_no_is_a_no_for_every_mode_it_does_not_reopen(self):
        ways = [north("w1", 35.780, 35.790, bicycle="designated", **SIDEPATH),
                north("w2", 35.790, 35.800, highway="path", surface="asphalt", access="no", foot="yes")]
        self.build(ways)
        self.assertEqual((self.full["w1"]["allows_bike"], self.full["w1"]["allows_foot"]), (0, 1))

    def test_access_needs_half_the_length_to_allow_it(self):
        # A 1.0 km cycleway continued by an untagged footway. Bikes are
        # allowed on 1,000 of 2,200 m (45%): no. On 1,200 of 2,200 m: yes.
        short = [north("w1", 35.7800, 35.7890, **SIDEPATH),
                 north("w2", 35.7890, 35.7998, highway="footway", surface="asphalt")]
        long = [north("w1", 35.7800, 35.7908, **SIDEPATH),
                north("w2", 35.7908, 35.7998, highway="footway", surface="asphalt")]
        self.build(short)
        self.assertEqual(self.full["w1"]["allows_bike"], 0)
        self.build(long)
        self.assertEqual(self.full["w1"]["allows_bike"], 1)

    def test_access_needs_one_member_that_allows_it(self):
        ways = [north("w1", 35.780, 35.790, highway="footway", surface="asphalt"),
                north("w2", 35.790, 35.800, highway="footway", surface="asphalt")]
        self.build(ways)
        self.assertEqual(self.full["w1"]["allows_bike"], 0, "no member says bikes may")

    def test_named_merge_uses_the_same_access_rule(self):
        ways = [north("w1", 35.780, 35.790, name="Rail Trail", **SIDEPATH),
                north("w2", 35.790, 35.800, name="Rail Trail", highway="footway", surface="asphalt"),
                north("w5", 35.880, 35.890, name="Mill Trail", **SIDEPATH),
                north("w6", 35.890, 35.900, name="Mill Trail", highway="footway", bicycle="no")]
        self.build(ways)
        self.assertEqual(self.full["w1"]["allows_bike"], 1)
        self.assertEqual(self.full["w5"]["allows_bike"], 0)

    def test_crossings_do_not_count_toward_the_length_floor(self):
        # 12 m + a 10 m crossing + 12 m is 34 m of row but 24 m of trail.
        ways = [north("w1", 35.7800, 35.78011, **SIDEPATH),
                north("w2", 35.78011, 35.7802, highway="footway", footway="crossing"),
                north("w3", 35.7802, 35.78031, **SIDEPATH)]
        stats, rows, _ = self.build(ways)
        self.assertEqual(rows, [])
        self.assertEqual(stats.skipped_short, 1)

    def test_a_trail_running_through_the_meeting_point_makes_it_a_junction(self):
        # w1 ends where w2 starts, at a right angle, on the middle of a named
        # trail that was never split there. That is a crossroads, not a bend.
        lat = 35.790
        ways = [north("w1", 35.780, lat, **SIDEPATH),
                feature("w2", [[LON, lat], [LON + 0.01, lat]], **SIDEPATH),
                feature("w3", [[LON - 0.005, lat + 0.005], [LON + 0.005, lat - 0.005]],
                        name="Diagonal Trail", **SIDEPATH)]
        _, rows, _ = self.build(ways)
        self.assertEqual(sorted(r[0] for r in rows), ["w1", "w2", "w3"])

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

    def test_a_continuation_of_a_named_trail_is_not_named_after_the_road(self):
        ways = [north("w1", 35.770, 35.780, name="Cross City Trail", **SIDEPATH),
                north("w2", 35.780, 35.795, **SIDEPATH)]
        stats, rows, _ = self.build(ways, roads=self.PARALLEL)
        self.assertIsNone(self.full["w2"]["name"])
        self.assertEqual(stats.derived_suppressed_named, 1)

    def test_a_named_trail_crossing_at_the_end_does_not_suppress_the_name(self):
        ways = [feature("w1", [[LON - 0.01, 35.780], [LON + 0.01, 35.780]], name="Cross City Trail", **SIDEPATH),
                north("w2", 35.780, 35.795, **SIDEPATH)]
        stats, _, _ = self.build(ways, roads=self.PARALLEL)
        self.assertEqual(self.full["w2"]["name"], "Duck Road Path")
        self.assertEqual(stats.derived_suppressed_named, 0)

    def test_sidepaths_on_both_sides_get_the_side_in_their_name(self):
        road = [feature("w100", [[LON, 35.775], [LON, 35.800]], highway="primary", name="Duck Road")]
        east = LON + 0.00022   # ~20 m either side
        west = LON - 0.00022
        ways = [north("w1", 35.780, 35.795, lon=east, **SIDEPATH),
                north("w2", 35.780, 35.795, lon=west, **SIDEPATH)]
        stats, _, _ = self.build(ways, roads=road)
        self.assertEqual(self.full["w1"]["name"], "Duck Road Path (East Side)")
        self.assertEqual(self.full["w2"]["name"], "Duck Road Path (West Side)")
        self.assertEqual(stats.derived_side_suffixed, 2)
        # An east-west road gets North / South.
        road = [feature("w100", [[-78.66, 35.780], [-78.62, 35.780]], highway="primary", name="Main Street")]
        ways = [feature("w1", [[-78.655, 35.7802], [-78.640, 35.7802]], **SIDEPATH),
                feature("w2", [[-78.655, 35.7798], [-78.640, 35.7798]], **SIDEPATH)]
        self.build(ways, roads=road)
        self.assertEqual(self.full["w1"]["name"], "Main Street Path (North Side)")
        self.assertEqual(self.full["w2"]["name"], "Main Street Path (South Side)")

    @staticmethod
    def _offset_line(p0, p1, metres):
        """The segment p0-p1 moved `metres` to its right."""
        lat0 = p0[1]
        kx = 111_320 * math.cos(math.radians(lat0))
        dx, dy = (p1[0] - p0[0]) * kx, (p1[1] - p0[1]) * 111_320
        n = math.hypot(dx, dy)
        rx, ry = dy / n * metres, -dx / n * metres   # right-hand normal
        return [[p0[0] + rx / kx, p0[1] + ry / 111_320], [p1[0] + rx / kx, p1[1] + ry / 111_320]]

    def test_side_labels_follow_the_road_not_each_piece(self):
        # A road runs north, then bends to 50° east of north. Paths on both
        # sides of each leg. The second leg's pieces run more east than
        # north, but the road as a whole is north-south, so all four are
        # East or West — never "North Side" opposite "East Side".
        kx = 111_320 * math.cos(math.radians(35.79))
        r0, r1 = [LON, 35.775], [LON, 35.790]
        r2 = [r1[0] + 1300 * math.sin(math.radians(50)) / kx, r1[1] + 1300 * math.cos(math.radians(50)) / 111_320]
        road = [feature("w100", [r0, r1, r2], highway="primary", name="Bend Road")]
        a0, a1 = [LON, 35.7765], [LON, 35.7880]
        f = 0.15   # start the second-leg pieces a little past the bend
        b0 = [r1[0] + f * (r2[0] - r1[0]), r1[1] + f * (r2[1] - r1[1])]
        ways = [feature("w1", self._offset_line(a0, a1, 20), **SIDEPATH),    # east of leg 1
                feature("w2", self._offset_line(a0, a1, -20), **SIDEPATH),   # west of leg 1
                feature("w3", self._offset_line(b0, r2, 20), **SIDEPATH),    # right of leg 2
                feature("w4", self._offset_line(b0, r2, -20), **SIDEPATH)]   # left of leg 2
        stats, _, _ = self.build(ways, roads=road)
        names = {k: self.full[k]["name"] for k in ("w1", "w2", "w3", "w4")}
        self.assertEqual(names, {"w1": "Bend Road Path (East Side)", "w2": "Bend Road Path (West Side)",
                                 "w3": "Bend Road Path (East Side)", "w4": "Bend Road Path (West Side)"})

    def test_two_paths_on_the_same_side_get_no_side(self):
        road = [feature("w100", [[LON, 35.775], [LON, 35.800]], highway="primary", name="Duck Road")]
        ways = [north("w1", 35.780, 35.795, lon=LON + 0.00016, **SIDEPATH),   # ~15 m east
                north("w2", 35.780, 35.795, lon=LON + 0.00038, **SIDEPATH)]   # ~34 m east
        stats, _, _ = self.build(ways, roads=road)
        self.assertEqual((self.full["w1"]["name"], self.full["w2"]["name"]), ("Duck Road Path", "Duck Road Path"))
        self.assertEqual((stats.derived_side_suffixed, stats.derived_same_side_pairs), (0, 1))

    def test_a_path_with_a_same_side_neighbour_gets_no_side_from_another_pair(self):
        # w1 and w2 are both east of the road; w3 is west, beside both. Each
        # east path pairs with w3 on opposite sides, but labelling both
        # "East Side" would make them identical again.
        road = [feature("w100", [[LON, 35.775], [LON, 35.800]], highway="primary", name="Duck Road")]
        ways = [north("w1", 35.780, 35.795, lon=LON + 0.00016, **SIDEPATH),
                north("w2", 35.780, 35.795, lon=LON + 0.00038, **SIDEPATH),
                north("w3", 35.780, 35.795, lon=LON - 0.00022, **SIDEPATH)]
        stats, _, _ = self.build(ways, roads=road)
        self.assertEqual((self.full["w1"]["name"], self.full["w2"]["name"]), ("Duck Road Path", "Duck Road Path"))
        self.assertEqual(stats.derived_same_side_pairs, 1)

    def test_sidepaths_on_opposite_sides_but_not_side_by_side_get_no_side(self):
        # East of the road for one stretch, west of it further on: two
        # separate cards in the app already (1.1 km apart), so no suffix.
        road = [feature("w100", [[LON, 35.775], [LON, 35.830]], highway="primary", name="Duck Road")]
        ways = [north("w1", 35.780, 35.795, lon=LON + 0.00022, **SIDEPATH),
                north("w2", 35.805, 35.820, lon=LON - 0.00022, **SIDEPATH)]
        stats, _, _ = self.build(ways, roads=road)
        self.assertEqual((self.full["w1"]["name"], self.full["w2"]["name"]), ("Duck Road Path", "Duck Road Path"))
        self.assertEqual(stats.derived_side_suffixed, 0)

    def test_one_sidepath_gets_no_side(self):
        _, rows, _ = self.build(self.CHAIN, roads=self.PARALLEL)
        self.assertEqual(rows[0][1], "Duck Road Path")

    def test_a_road_called_a_trail_gives_a_sidepath(self):
        road = [feature("w100", [[LON + 0.00022, 35.775], [LON + 0.00022, 35.800]],
                        highway="primary", name="Virginia Dare Trail")]
        _, rows, _ = self.build(self.CHAIN, roads=road)
        self.assertEqual(rows[0][1], "Virginia Dare Trail Sidepath")

    def test_a_blank_road_name_is_no_name(self):
        road = [feature("w100", [[LON + 0.00022, 35.775], [LON + 0.00022, 35.800]],
                        highway="primary", name="   ")]
        _, rows, _ = self.build(self.CHAIN, roads=road)
        self.assertIsNone(rows[0][1])

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


class CurationTests(unittest.TestCase):
    """Builder 1.3.0 (2026-10-08): generic names, short unnamed stubs, trail keys."""

    def build(self, features, **kw):
        d = tempfile.mkdtemp()
        src = os.path.join(d, "in.geojsonseq")
        out = os.path.join(d, "out.wktpack")
        write_seq(src, features)
        stats = btp.build_pack([(src, "osm")], out, "t", "Test", 0.00002, 30.0,
                               built_at="2026-01-01T00:00:00Z", **kw)
        conn = sqlite3.connect(out)
        rows = conn.execute(
            "SELECT source_ref, name, length_m, is_loop, trail_key FROM trails ORDER BY id").fetchall()
        conn.close()
        return stats, rows

    def test_generic_name_is_treated_as_unnamed(self):
        stats, rows = self.build([
            feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], name="  service   ROAD ", highway="path"),
            feature("w2", [[-78.62, 35.78], [-78.62, 35.79]], name="Red Trail", highway="path"),
        ])
        names = {r[0]: r[1] for r in rows}
        self.assertIsNone(names["w1"])
        self.assertEqual(names["w2"], "Red Trail")  # a colour blaze is a real name in its park
        self.assertEqual(stats.generic_names, 1)

    def test_descriptions_from_other_states_are_generic(self):
        # 1.3.1: what Georgia, Virginia and the Carolinas' data put in name=.
        stats, rows = self.build([
            feature("w1", [[-84.39, 33.75], [-84.39, 33.76]], name="abandoned track", highway="track"),
            feature("w2", [[-84.37, 33.75], [-84.37, 33.76]], name="Logging Road", highway="track"),
            feature("w3", [[-84.35, 33.75], [-84.35, 33.76]], name="WMA Road", highway="track"),
            feature("w4", [[-84.33, 33.75], [-84.33, 33.76]], name="Shortcut", highway="path"),
            feature("w5", [[-84.31, 33.75], [-84.31, 33.76]], name="Logging Road Trail", highway="path"),
        ], curate=False)  # naming only; the 1.4.0 dirt-road rule is tested below
        names = {r[0]: r[1] for r in rows}
        self.assertEqual([names[k] for k in ("w1", "w2", "w3", "w4")], [None] * 4)
        self.assertEqual(names["w5"], "Logging Road Trail", "exact matches only")
        self.assertEqual(stats.generic_names, 4)

    def test_installations_and_unreadable_names_are_generic(self):
        # 1.3.2: Florida's "Eglin Air Force Base" tracks, "???" names, "Multi-Modal Path".
        stats, rows = self.build([
            feature("w1", [[-86.5, 30.5], [-86.5, 30.51]], name="Eglin Air Force Base", highway="track"),
            feature("w2", [[-86.4, 30.5], [-86.4, 30.51]], name="???", highway="path"),
            feature("w3", [[-86.3, 30.5], [-86.3, 30.51]], name="Multi-Modal Path", highway="cycleway"),
            feature("w4", [[-86.2, 30.5], [-86.2, 30.51]], name="Afton Mountain Trail", highway="path"),
            feature("w5", [[-86.1, 30.5], [-86.1, 30.51]], name="Trail 7", highway="path"),
        ], curate=False)  # naming only; the 1.4.0 dirt-road rule is tested below
        names = {r[0]: r[1] for r in rows}
        self.assertEqual([names[k] for k in ("w1", "w2", "w3")], [None] * 3)
        self.assertEqual(names["w4"], "Afton Mountain Trail", "'afb' only as a whole word")
        self.assertEqual(names["w5"], "Trail 7", "a digit is something to read")
        self.assertEqual(stats.generic_names, 3)

    def test_short_unnamed_stub_is_dropped_but_loops_and_named_stay(self):
        stub = feature("w1", [[-78.64, 35.78], [-78.64, 35.7808]], highway="path")             # ~89 m
        named = feature("w2", [[-78.62, 35.78], [-78.62, 35.7808]], name="Pond Path", highway="path")
        long_ = feature("w3", [[-78.60, 35.78], [-78.60, 35.79]], highway="path")             # ~1.1 km
        loop = feature("w4", [[-78.58, 35.78], [-78.5790, 35.78], [-78.5790, 35.7810],
                              [-78.58, 35.7810], [-78.58, 35.78]], highway="path")          # ~400 m loop
        stats, rows = self.build([stub, named, long_, loop])
        refs = {r[0] for r in rows}
        self.assertNotIn("w1", refs)
        self.assertTrue({"w2", "w3", "w4"} <= refs)
        self.assertEqual(stats.skipped_short_unnamed, 1)

    def test_stub_floor_is_a_parameter(self):
        stub = feature("w1", [[-78.64, 35.78], [-78.64, 35.7808]], highway="path")
        _, rows = self.build([stub], min_unnamed_length_m=0.0)
        self.assertEqual(len(rows), 1)

    def test_pieces_of_one_trail_share_a_key_and_far_pieces_do_not(self):
        # Two pieces 300 m apart (a gap in the data): one trail. A third 40 km away: another.
        stats, rows = self.build([
            feature("w5", [[-78.64, 35.780], [-78.64, 35.790]], name="Creek Trail"),
            feature("w7", [[-78.64, 35.7927], [-78.64, 35.800]], name="Creek Trail"),
            feature("w9", [[-78.20, 35.780], [-78.20, 35.790]], name="Creek Trail"),
            feature("w3", [[-78.60, 35.78], [-78.60, 35.79]], highway="path"),
        ])
        keys = {r[0]: r[4] for r in rows}
        self.assertEqual(keys["w5"], keys["w7"])
        self.assertEqual(keys["w5"], "t:w5")              # region + smallest source ref
        self.assertNotEqual(keys["w9"], keys["w5"])
        self.assertIsNone(keys["w3"])                     # unnamed rows have no key
        self.assertEqual(stats.trail_keys, 2)

    def test_key_ignores_case_and_spacing(self):
        _, rows = self.build([
            feature("w1", [[-78.64, 35.780], [-78.64, 35.790]], name="Creek Trail"),
            feature("w2", [[-78.64, 35.7905], [-78.64, 35.800]], name="creek  trail"),
        ])
        self.assertEqual(rows[0][4], rows[1][4])

    def test_symmetric_fork_is_not_guessed(self):
        # A Y whose two branches leave at the same angle: no straight on.
        y = [
            feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], name="Park Trail"),
            feature("w2", [[-78.64, 35.79], [-78.635, 35.80]], name="Park Trail"),
            feature("w3", [[-78.64, 35.79], [-78.645, 35.80]], name="Park Trail"),
        ]
        stats, rows = self.build(y)
        self.assertEqual(len(rows), 3)
        self.assertEqual(stats.junction_merges, 0)
        self.assertEqual(len({r[4] for r in rows}), 1, "still one trail")

    # --- Gap bridging (same name, facing each other, under 50 m) ----------
    # ~0.00027 deg of latitude is 30 m.

    def test_facing_pieces_across_a_short_gap_join(self):
        stats, rows = self.build([
            feature("w1", [[-78.64, 35.780], [-78.64, 35.790]], name="River Trail"),
            feature("w2", [[-78.64, 35.79027], [-78.64, 35.800]], name="River Trail"),   # 30 m gap, straight on
        ])
        self.assertEqual(len(rows), 1)
        self.assertEqual(stats.bridged_gaps, 1)
        self.assertGreater(rows[0][2], 2200)  # both pieces plus the 30 m step

    def test_gap_over_50_m_stays_apart(self):
        stats, rows = self.build([
            feature("w1", [[-78.64, 35.780], [-78.64, 35.790]], name="River Trail"),
            feature("w2", [[-78.64, 35.7906], [-78.64, 35.800]], name="River Trail"),    # ~67 m
        ])
        self.assertEqual(len(rows), 2)
        self.assertEqual(stats.bridged_gaps, 0)
        self.assertEqual(rows[0][4], rows[1][4], "still one trail by key")

    def test_side_by_side_pieces_do_not_join(self):
        # Parallel, 30 m apart east-west: close, but neither points at the other.
        stats, rows = self.build([
            feature("w1", [[-78.6400, 35.780], [-78.6400, 35.790]], name="River Trail"),
            feature("w2", [[-78.6397, 35.780], [-78.6397, 35.790]], name="River Trail"),
        ])
        self.assertEqual(len(rows), 2)
        self.assertEqual(stats.bridged_gaps, 0)

    def test_gap_that_turns_sharply_does_not_join(self):
        # w2 starts 30 m beyond w1's end but heads east: a 90 deg turn.
        stats, rows = self.build([
            feature("w1", [[-78.64, 35.780], [-78.64, 35.790]], name="River Trail"),
            feature("w2", [[-78.64, 35.79027], [-78.63, 35.79027]], name="River Trail"),
        ])
        self.assertEqual(stats.bridged_gaps, 0)

    def test_offset_continuation_does_not_join(self):
        # w2 runs north like w1 but starts 30 m to the EAST of w1's end: the
        # gap is sideways (a path on the other side of a road), not onward.
        stats, rows = self.build([
            feature("w1", [[-78.6400, 35.780], [-78.6400, 35.790]], name="River Trail"),
            feature("w2", [[-78.6397, 35.790], [-78.6397, 35.800]], name="River Trail"),
        ])
        self.assertEqual(stats.bridged_gaps, 0)

    def test_bridging_never_closes_a_ring_of_pieces(self):
        # A ~300 m-radius circle cut into four arcs, with a ~30 m straight-on
        # gap after each. Every gap qualifies, but bridging all four would
        # make a ring with no ends: three bridge, the last stays open.
        def arc(fid, start_deg):
            pts = []
            for k in range(0, 86, 5):   # 0..85 deg; the 5 deg gap is ~26 m
                a = math.radians(start_deg + k)
                pts.append([-78.64 + 0.0033 * math.cos(a), 35.78 + 0.0027 * math.sin(a)])
            return feature(fid, pts, name="Pond Trail")
        stats, rows = self.build([arc("w1", 0), arc("w2", 90), arc("w3", 180), arc("w4", 270)])
        self.assertEqual(stats.bridged_gaps, 3)
        self.assertEqual(len(rows), 1)

    def test_pack_says_it_has_trail_keys(self):
        d = tempfile.mkdtemp()
        src = os.path.join(d, "in.geojsonseq")
        out = os.path.join(d, "out.wktpack")
        write_seq(src, [feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], name="A Trail")])
        btp.build_pack([(src, "osm")], out, "t", "Test", 0.00002, 30.0, built_at="2026-01-01T00:00:00Z")
        meta = dict(sqlite3.connect(out).execute("SELECT key, value FROM meta"))
        self.assertEqual(meta["trail_keys"], "1")
        self.assertEqual(meta["builder_version"], "1.6.0")
        self.assertTrue(btp.verify_pack(out))



class ListingRulesTests(unittest.TestCase):
    """Builder 1.4.0 (2026-10-08): which ways are worth listing. Joe's rules."""

    def build(self, features, trailheads=()):
        d = tempfile.mkdtemp()
        src = os.path.join(d, "in.geojsonseq")
        out = os.path.join(d, "out.wktpack")
        write_seq(src, features)
        heads = None
        if trailheads:
            heads = os.path.join(d, "heads.geojsonseq")
            write_seq(heads, [{"type": "Feature", "id": f"n{i}",
                               "geometry": {"type": "Point", "coordinates": list(pt)},
                               "properties": {"highway": "trailhead"}} for i, pt in enumerate(trailheads)])
        stats = btp.build_pack([(src, "osm")], out, "t", "Test", 0.00002, 30.0,
                               built_at="2026-01-01T00:00:00Z", trailheads_path=heads)
        conn = sqlite3.connect(out)
        rows = {r[0]: r[1:] for r in conn.execute(
            "SELECT source_ref, name, allows_foot, allows_bike FROM trails")}
        conn.close()
        return stats, rows

    def test_unnamed_dirt_road_is_left_out_unless_open(self):
        stats, rows = self.build([
            feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], highway="track"),
            feature("w2", [[-78.62, 35.78], [-78.62, 35.79]], highway="track", foot="permissive"),
            feature("w3", [[-78.60, 35.78], [-78.60, 35.79]], highway="path"),
        ])
        self.assertEqual(sorted(rows), ["w2", "w3"])
        self.assertEqual(stats.skipped_unnamed_track, 1)

    def test_street_named_dirt_road_is_left_out_but_a_trail_named_one_stays(self):
        stats, rows = self.build([
            feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], name="Tranquil Drive Southeast", highway="track"),
            feature("w2", [[-78.62, 35.78], [-78.62, 35.79]], name="Holly", highway="track"),
            feature("w3", [[-78.60, 35.78], [-78.60, 35.79]], name="Bear Creek Trail", highway="track"),
            feature("w4", [[-78.58, 35.78], [-78.58, 35.79]], name="Holly Way", highway="track"),
        ])
        self.assertEqual(sorted(rows), ["w3"], "'Way' is a street word, not a trail word")
        self.assertEqual(stats.skipped_street_named_track, 3)

    def test_a_dirt_road_that_reaches_a_trailhead_stays(self):
        # w1 ends ~50 m from the trailhead; w2 is ~1.8 km away from it.
        stats, rows = self.build([
            feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], name="Fire Tower Road", highway="track"),
            feature("w2", [[-78.62, 35.78], [-78.62, 35.79]], highway="track"),
        ], trailheads=[(-78.6405, 35.7904)])
        self.assertEqual(sorted(rows), ["w1"])
        self.assertEqual(stats.kept_track_at_trailhead, 1)

    def test_a_bike_path_is_walkable_unless_it_says_no(self):
        stats, rows = self.build([
            feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], name="Rail Trail", highway="cycleway"),
            feature("w2", [[-78.62, 35.78], [-78.62, 35.79]], name="Church Street Cycle Track",
                    highway="cycleway", foot="no"),
        ])
        self.assertEqual(rows["w1"][1:], (1, 1), "Florence's Rail Trail: walk and ride")
        self.assertEqual(rows["w2"][1:], (0, 1), "a bike-only path stays, for Ride")

    def test_a_way_closed_to_walking_and_riding_is_left_out(self):
        stats, rows = self.build([
            feature("w1", [[-78.64, 35.78], [-78.64, 35.79]], name="Closed Path", highway="path",
                    foot="no", bicycle="no"),
            feature("w2", [[-78.62, 35.78], [-78.62, 35.79]], name="Horse Trail", highway="bridleway",
                    foot="no"),
        ])
        self.assertEqual(sorted(rows), [], "a bridleway with foot=no and no bicycle access is no use here")
        self.assertEqual(stats.skipped_closed, 2)


class NameVariantTests(unittest.TestCase):
    """Builder 1.5.0 (2026-10-09): one trail, one name; access connectors unnamed."""

    def build(self, features):
        d = tempfile.mkdtemp()
        src = os.path.join(d, "in.geojsonseq")
        out = os.path.join(d, "out.wktpack")
        write_seq(src, features)
        btp.build_pack([(src, "osm")], out, "t", "Test", 0.00002, 30.0, built_at="2026-01-01T00:00:00Z")
        conn = sqlite3.connect(out)
        rows = conn.execute("SELECT source_ref, name, trail_key FROM trails ORDER BY source_ref").fetchall()
        conn.close()
        return rows

    def test_name_key(self):
        k = btp.name_key
        self.assertEqual({k("Sheltowee Trace"), k("Sheltowee Trace Trail"), k("Sheltowee Trace #100"),
                          k("sheltowee  trace trail #100"), k("Sheltowee Trace Trail #100:9")}, {"sheltowee trace"})
        self.assertNotEqual(k("IR-#16-Easy"), k("IR-#27-Easy"))
        self.assertEqual(k("Nature Trail"), "nature trail", "one word would be left: keep 'Trail'")
        self.assertNotEqual(k("Trail 7"), k("Trail 8"))

    def test_variants_of_one_trail_share_a_key_and_a_name(self):
        # Three pieces ~100 m apart, three spellings, one trail.
        rows = self.build([
            feature("w1", [[-84.0, 37.000], [-84.0, 37.004]], name="Sheltowee Trace", highway="path"),
            feature("w2", [[-84.0, 37.005], [-84.0, 37.009]], name="Sheltowee Trace Trail #100", highway="path"),
            feature("w3", [[-84.0, 37.010], [-84.0, 37.014]], name="Sheltowee Trace", highway="path"),
        ])
        self.assertEqual(len({r[2] for r in rows}), 1, rows)
        self.assertEqual({r[1] for r in rows}, {"Sheltowee Trace"}, "the name most pieces carry")

    def test_access_connector_is_unnamed(self):
        rows = self.build([
            feature("w1", [[-84.39, 33.75], [-84.39, 33.752]], name="Beltline Access Line", highway="footway"),
            feature("w2", [[-84.38, 33.75], [-84.38, 33.76]], name="Atlanta Beltline Eastside Trail", highway="cycleway"),
        ])
        names = {r[0]: r[1] for r in rows}
        self.assertNotIn("Beltline Access Line", names.values())
        self.assertEqual(names["w2"], "Atlanta Beltline Eastside Trail")


class NumberedTrailTests(unittest.TestCase):
    """Critic run 1 of #160: different trail numbers are different trails;
    the shared name is the one carried by the most length, in ordinary case."""

    def build(self, features):
        d = tempfile.mkdtemp()
        src = os.path.join(d, "in.geojsonseq")
        out = os.path.join(d, "out.wktpack")
        write_seq(src, features)
        btp.build_pack([(src, "osm")], out, "t", "Test", 0.00002, 30.0, built_at="2026-01-01T00:00:00Z")
        conn = sqlite3.connect(out)
        rows = conn.execute("SELECT source_ref, name, trail_key, length_m FROM trails ORDER BY source_ref").fetchall()
        conn.close()
        return rows

    def test_different_numbers_stay_different_trails(self):
        # Beach Access #5, #6, #7, ~150 m apart.
        rows = self.build([feature(f"w{n}", [[-80.0 + n * 0.0015, 26.0], [-80.0 + n * 0.0015, 26.002]],
                                   name=f"Beach Access #{n}", highway="footway") for n in (5, 6, 7)])
        self.assertEqual(sorted(r[1] for r in rows), ["Beach Access #5", "Beach Access #6", "Beach Access #7"])
        self.assertEqual(len({r[2] for r in rows}), 3)

    def test_numbered_loops_sharing_a_trailhead_stay_two_rows(self):
        a = feature("w1", [[-84.0, 37.0], [-84.0, 37.01]], name="Loop #1", highway="path")
        b = feature("w2", [[-84.0, 37.0], [-83.99, 37.0]], name="Loop #2", highway="path")
        rows = self.build([a, b])
        self.assertEqual(sorted(r[1] for r in rows), ["Loop #1", "Loop #2"])

    def test_spur_letters_are_their_own_trails(self):
        self.assertNotEqual(btp.trail_number("Limestone Bike Trail #109"), btp.trail_number("Limestone Bike Trail #109A"))

    def test_an_unnumbered_piece_never_bridges_two_numbers(self):
        rows = self.build([
            feature("w1", [[-84.0, 37.000], [-84.0, 37.002]], name="Loop #1", highway="path"),
            feature("w2", [[-84.0, 37.003], [-84.0, 37.005]], name="Loop", highway="path"),
            feature("w3", [[-84.0, 37.006], [-84.0, 37.008]], name="Loop #2", highway="path"),
        ])
        keys = {r[0]: r[2] for r in rows}
        self.assertNotEqual(keys["w1"], keys["w3"])
        self.assertIn("Loop #1", {r[1] for r in rows})
        self.assertIn("Loop #2", {r[1] for r in rows})

    def test_variants_meeting_end_to_end_merge_into_one_row(self):
        rows = self.build([
            feature("w1", [[-84.0, 37.000], [-84.0, 37.004]], name="Sheltowee Trace", highway="path"),
            feature("w2", [[-84.0, 37.004], [-84.0, 37.008]], name="Sheltowee Trace Trail", highway="path"),
        ])
        self.assertEqual(len(rows), 1, rows)

    def test_the_shared_name_is_the_longest_carried_and_ordinary_case(self):
        rows = self.build([
            feature("w1", [[-82.0, 35.000], [-82.0, 35.036]], name="North Slope Trail", highway="path"),  # ~4 km
            feature("w2", [[-82.0, 35.037], [-82.0, 35.042]], name="North Slope", highway="path"),        # ~0.6 km
        ])
        self.assertEqual({r[1] for r in rows}, {"North Slope Trail"})
        # The typo carries more of the trail; the ordinary spelling still wins.
        typo = self.build([
            feature("w1", [[-82.0, 35.000], [-82.0, 35.010]], name="HIgh Falls Loop", highway="path"),
            feature("w2", [[-82.0, 35.011], [-82.0, 35.013]], name="High Falls Loop", highway="path"),
        ])
        self.assertEqual({r[1] for r in typo}, {"High Falls Loop"})

    def test_a_merged_row_is_named_for_its_longest_spelling(self):
        # 445 m "Raider Camp" then 4 km "Raider Camp Trail": end to end, and across a 30 m gap.
        for gap in (0.0, 0.0003):
            rows = self.build([
                feature("w1", [[-82.0, 35.000], [-82.0, 35.004]], name="Raider Camp", highway="path"),
                feature("w2", [[-82.0, 35.004 + gap], [-82.0, 35.040 + gap]], name="Raider Camp Trail", highway="path"),
            ])
            self.assertEqual([r[1] for r in rows], ["Raider Camp Trail"], f"gap {gap}: {rows}")

    def test_lowercase_and_double_spaced_spellings_never_win(self):
        rows = self.build([
            feature("w1", [[-82.0, 35.000], [-82.0, 35.010]], name="croatan", highway="path"),
            feature("w2", [[-82.0, 35.011], [-82.0, 35.013]], name="Croatan", highway="path"),
        ])
        self.assertEqual({r[1] for r in rows}, {"Croatan"})
        spaced = self.build([
            feature("w1", [[-82.0, 35.000], [-82.0, 35.010]], name="Walking Path - Torrence  Chapel Park", highway="path"),
            feature("w2", [[-82.0, 35.011], [-82.0, 35.013]], name="Walking Path - Torrence Chapel Park", highway="path"),
        ])
        self.assertEqual({r[1] for r in spaced}, {"Walking Path - Torrence Chapel Park"})

    def test_two_spacings_of_one_name_add_up(self):
        # "Fox  Run" (~550 m) and "Fox Run" (~440 m) are one spelling, 990 m in
        # all, against ~880 m of "Fox Run Trail".
        rows = self.build([
            feature("w1", [[-82.0, 35.000], [-82.0, 35.005]], name="Fox  Run", highway="path"),
            feature("w2", [[-82.0, 35.006], [-82.0, 35.010]], name="Fox Run", highway="path"),
            feature("w3", [[-82.0, 35.011], [-82.0, 35.019]], name="Fox Run Trail", highway="path"),
        ])
        self.assertEqual({r[1] for r in rows}, {"Fox Run"}, rows)

    def test_an_unnumbered_piece_never_bridges_two_numbers_east_to_west(self):
        # Laid out west to east, so "Loop #1" is visited first and the group's
        # number has to carry through the join with "Loop".
        rows = self.build([
            feature("w1", [[-84.000, 37.0], [-83.998, 37.0]], name="Loop #1", highway="path"),
            feature("w2", [[-83.997, 37.0], [-83.995, 37.0]], name="Loop", highway="path"),
            feature("w3", [[-83.994, 37.0], [-83.992, 37.0]], name="Loop #2", highway="path"),
        ])
        keys = {r[0]: r[2] for r in rows}
        self.assertNotEqual(keys["w1"], keys["w3"], rows)

    def test_access_trails_keep_their_names(self):
        rows = self.build([feature("w1", [[-83.0, 35.0], [-83.0, 35.01]], name="Hazel Creek Access Trail", highway="path")])
        self.assertEqual(rows[0][1], "Hazel Creek Access Trail")


# Lower Piney Trail (nc:w171710443) as OSM maps it, North Carolina extract of
# 2026-09-09: a 1,569 m way graded hiking and a 216 m way graded
# mountain_hiking, end to end, both smoothness=bad. Laid on a line of
# longitude here at the same lengths (0.001 deg of latitude is ~111 m).
PINEY = dict(highway="path", surface="ground", smoothness="bad", trail_visibility="excellent",
             wheelchair="no", foot="designated", bicycle="no", horse="no", dog="leashed")


def piney(order=(0, 1)):
    ways = [
        feature("w171710443", [[-81.5, 36.0], [-81.5, 36.01410]], name="Lower Piney Trail",
                sac_scale="hiking", **PINEY),
        feature("w430789106", [[-81.5, 36.01410], [-81.5, 36.01604]], name="Lower Piney Trail",
                sac_scale="mountain_hiking", **PINEY),
    ]
    return [ways[i] for i in order]


class FactShareTests(unittest.TestCase):
    """Builder 1.6.0: what every merged way states about the card's facts,
    as length-weighted shares in tags_json (spec feat/trail-builder-tag-preservation)."""

    def build(self, features, **kw):
        d = tempfile.mkdtemp()
        src = os.path.join(d, "in.geojsonseq")
        out = os.path.join(d, "out.wktpack")
        write_seq(src, features)
        self.stats = btp.build_pack([(src, "osm")], out, "t", "Test", 0.00002, 30.0,
                                    built_at="2026-01-01T00:00:00Z", **kw)
        conn = sqlite3.connect(out)
        rows = conn.execute("SELECT source_ref, name, length_m, difficulty, tags_json, trail_key "
                            "FROM trails ORDER BY id").fetchall()
        meta = dict(conn.execute("SELECT key, value FROM meta"))
        conn.close()
        return rows, meta, out

    @staticmethod
    def facts(row):
        return json.loads(row[4]).get("facts")

    def assertSumsToOne(self, facts):
        for tag, shares in facts["shares"].items():
            self.assertEqual(round(sum(shares.values()) * 1000), 1000, (tag, shares))
            self.assertTrue(all(v > 0 for v in shares.values()), (tag, shares))

    def test_lower_piney_shares_follow_length_not_the_first_way(self):
        rows, meta, _ = self.build(piney())
        self.assertEqual(len(rows), 1)
        facts = self.facts(rows[0])
        self.assertEqual(facts["v"], 1)
        # 1,569 m of 1,785 m is 0.879; the 216 m way is 0.121.
        self.assertEqual(facts["shares"]["sac_scale"], {"hiking": 0.879, "mountain_hiking": 0.121})
        self.assertEqual(facts["shares"]["smoothness"], {"bad": 1.0})
        self.assertEqual(facts["shares"]["wheelchair"], {"no": 1.0})
        self.assertEqual(facts["shares"]["foot"], {"designated": 1.0})
        self.assertEqual(facts["worst"]["sac_scale"], "mountain_hiking")
        self.assertEqual(facts["best"]["sac_scale"], "hiking")
        self.assertEqual(meta["fact_shares"], "1")
        self.assertSumsToOne(facts)

    def test_flat_tags_and_columns_are_left_as_they_were(self):
        rows, _, _ = self.build(piney())
        source_ref, name, _, difficulty, tags_json, key = rows[0]
        tags = json.loads(tags_json)
        self.assertEqual((source_ref, name, key), ("w171710443", "Lower Piney Trail", "t:w171710443"))
        # 1.5.0's answers, unchanged: the column is the way-count vote (a tie,
        # alphabetical), the flat tags are one way's.
        self.assertEqual(difficulty, "hiking")
        # The first way of the chain as laid out here (south to north). In
        # the real data the chain runs the other way and the row says
        # mountain_hiking; the NC rebuild compared every row with 1.5.0's.
        self.assertEqual(tags["sac_scale"], "hiking")
        for k in ("highway", "surface", "smoothness", "trail_visibility", "wheelchair",
                  "foot", "bicycle", "horse", "dog"):
            self.assertIn(k, tags, "a kept tag survives beside the shares")
        self.assertEqual(tags["merged_ways"], 2)

    def test_way_order_does_not_change_the_shares(self):
        forward, _, _ = self.build(piney((0, 1)))
        backward, _, _ = self.build(piney((1, 0)))
        flipped = piney()
        flipped[0] = feature("w171710443", [[-81.5, 36.01410], [-81.5, 36.0]], name="Lower Piney Trail",
                             sac_scale="hiking", **PINEY)
        reversed_way, _, _ = self.build(flipped)
        self.assertEqual(self.facts(forward[0]), self.facts(backward[0]))
        self.assertEqual(self.facts(forward[0]), self.facts(reversed_way[0]))

    def test_input_order_does_not_move_the_rounding(self):
        # An unnamed corridor's members are taken in input order, and three
        # equal thirds leave one unit to place: it must land on the same value
        # whichever way the input runs.
        ways = [north("w1", 36.0, 36.01, highway="cycleway", surface="asphalt", lit="yes"),
                north("w2", 36.01, 36.02, highway="cycleway", surface="asphalt", lit="no"),
                north("w3", 36.02, 36.03, highway="cycleway", surface="asphalt", lit="limited")]
        a, _, _ = self.build(ways)
        # Reversed in the input and in direction, so the corridor is walked
        # from its other end and its ways are summed in the other order.
        flipped = [dict(w, geometry=dict(w["geometry"], coordinates=w["geometry"]["coordinates"][::-1]))
                   for w in reversed(ways)]
        b, _, _ = self.build(flipped)
        self.assertEqual((len(a), len(b)), (1, 1))
        self.assertEqual(self.facts(a[0]), self.facts(b[0]))
        self.assertEqual(sorted(self.facts(a[0])["shares"]["lit"].values()), [0.333, 0.333, 0.334])

    def test_a_crossing_inside_a_row_is_unstated_length(self):
        # A lit sidepath, 15 m of crosswalk across a side street, more lit
        # sidepath (the Duck shape, 2026-09-26). The crosswalk states no
        # lighting, so its length is unstated; it does state wheelchair=yes
        # (crossings often carry it), and that counts like any way's: unlike
        # the access vote, a crossing's own data is not left out.
        rows, _, _ = self.build([
            north("w1", 36.0, 36.0045, highway="cycleway", surface="asphalt", lit="yes", wheelchair="yes"),
            north("w2", 36.0045, 36.00463, highway="footway", footway="crossing", wheelchair="yes"),
            north("w3", 36.00463, 36.00913, highway="cycleway", surface="asphalt", lit="yes", wheelchair="yes"),
        ])
        self.assertEqual(len(rows), 1)
        shares = self.facts(rows[0])["shares"]
        self.assertAlmostEqual(shares["lit"]["unstated"], 14.5 / rows[0][2], delta=0.002)
        self.assertGreater(shares["lit"]["unstated"], 0)
        self.assertEqual(shares["wheelchair"], {"yes": 1.0})

    def test_an_unstated_section_counts_as_unstated(self):
        # 700 m says smooth, the 300 m after it says nothing.
        rows, _, _ = self.build([
            north("w1", 36.0, 36.0063, highway="path", name="Creek Trail", smoothness="good"),
            north("w2", 36.0063, 36.0090, highway="path", name="Creek Trail"),
        ])
        shares = self.facts(rows[0])["shares"]["smoothness"]
        self.assertAlmostEqual(shares["good"], 0.7, delta=0.002)
        self.assertAlmostEqual(shares["unstated"], 0.3, delta=0.002)
        self.assertSumsToOne(self.facts(rows[0]))

    def test_the_worst_value_is_kept_however_short(self):
        # 5 km of good surface and 3 m mapped impassable (a washout): the card
        # warns on any section, so the 3 m must not round away.
        rows, _, _ = self.build([
            north("w1", 36.0, 36.045, highway="path", name="River Trail", smoothness="good"),
            north("w2", 36.045, 36.04503, highway="path", name="River Trail", smoothness="impassable"),
        ])
        facts = self.facts(rows[0])
        self.assertEqual(facts["shares"]["smoothness"], {"good": 0.999, "impassable": 0.001})
        self.assertEqual(facts["worst"]["smoothness"], "impassable")
        self.assertEqual(facts["best"]["smoothness"], "good")

    def test_worst_and_best_follow_the_osm_scale_not_the_alphabet(self):
        rows, _, _ = self.build([
            north("w1", 36.0, 36.01, highway="path", name="Ridge Trail", trail_visibility="good"),
            north("w2", 36.01, 36.02, highway="path", name="Ridge Trail", trail_visibility="bad"),
            north("w3", 36.02, 36.03, highway="path", name="Ridge Trail", trail_visibility="excellent"),
        ])
        facts = self.facts(rows[0])
        self.assertEqual(facts["worst"]["trail_visibility"], "bad")
        self.assertEqual(facts["best"]["trail_visibility"], "excellent")

    def test_thirds_sum_to_exactly_one(self):
        rows, _, _ = self.build([
            north("w1", 36.0, 36.01, highway="path", name="Three Trail", smoothness="good"),
            north("w2", 36.01, 36.02, highway="path", name="Three Trail", smoothness="intermediate"),
            north("w3", 36.02, 36.03, highway="path", name="Three Trail", smoothness="bad"),
        ])
        shares = self.facts(rows[0])["shares"]["smoothness"]
        self.assertEqual(sorted(shares.values()), [0.333, 0.333, 0.334])
        self.assertSumsToOne(self.facts(rows[0]))

    def test_a_bridged_gap_is_unstated(self):
        # Two pieces 40 m apart, facing each other: one row since 1.3.0. No
        # way covers the gap, so ~40 m of the ~2.26 km row states nothing.
        rows, _, _ = self.build([
            north("w1", 36.0, 36.01, highway="path", name="Gap Trail", lit="yes"),
            north("w2", 36.01036, 36.02036, highway="path", name="Gap Trail", lit="yes"),
        ])
        self.assertEqual(len(rows), 1)
        self.assertIn("bridged_gaps", json.loads(rows[0][4]))
        shares = self.facts(rows[0])["shares"]["lit"]
        self.assertAlmostEqual(shares["unstated"], 40 / rows[0][2], delta=0.002)
        self.assertSumsToOne(self.facts(rows[0]))

    def test_a_bridged_piece_that_is_itself_a_merge_keeps_all_its_ways(self):
        # bridge_named_gaps merges rows merge_named_ways already merged: A1
        # lit=yes and A2 lit=no end to end, a 40 m gap, then B lit=yes. Each
        # way's metres must survive both merges (critic run 1: reading each
        # member's flat tags instead changed 69 NC rows).
        a1 = north("w1", 36.0, 36.005, highway="path", name="Creek Trail", lit="yes")
        a2 = north("w2", 36.005, 36.010, highway="path", name="Creek Trail", lit="no")
        b = north("w3", 36.01036, 36.02036, highway="path", name="Creek Trail", lit="yes")
        rows, _, _ = self.build([a1, a2, b])
        self.assertEqual(len(rows), 1)
        tags = json.loads(rows[0][4])
        self.assertEqual((tags["merged_ways"], tags["bridged_gaps"]), (3, 1))
        metres = {v: s * rows[0][2] for v, s in tags["facts"]["shares"]["lit"].items()}
        length = btp.line_length_m
        self.assertAlmostEqual(metres["yes"], length(a1["geometry"]["coordinates"]) + length(b["geometry"]["coordinates"]), delta=3)
        self.assertAlmostEqual(metres["no"], length(a2["geometry"]["coordinates"]), delta=3)
        self.assertAlmostEqual(metres["unstated"], 40, delta=3)

    def test_an_off_scale_value_has_a_share_but_is_neither_worst_nor_best(self):
        rows, _, _ = self.build([
            north("w1", 36.0, 36.01, highway="path", name="Scale Trail", sac_scale="T3"),
            north("w2", 36.01, 36.02, highway="path", name="Scale Trail", sac_scale="hiking"),
        ])
        facts = self.facts(rows[0])
        self.assertIn("t3", facts["shares"]["sac_scale"])
        self.assertEqual((facts["worst"]["sac_scale"], facts["best"]["sac_scale"]), ("hiking", "hiking"))

    def test_tags_off_any_scale_get_no_worst_or_best(self):
        rows, _, _ = self.build([
            north("w1", 36.0, 36.006, highway="cycleway", surface="asphalt", lit="yes"),
            north("w2", 36.006, 36.010, highway="cycleway", surface="asphalt", lit="no"),
        ])
        facts = self.facts(rows[0])
        self.assertNotIn("worst", facts)
        self.assertNotIn("best", facts)

    def test_a_literal_unstated_value_states_nothing(self):
        rows, _, _ = self.build([
            north("w1", 36.0, 36.01, highway="path", name="Odd Trail", smoothness="good"),
            north("w2", 36.01, 36.02, highway="path", name="Odd Trail", smoothness="unstated"),
            north("w3", 36.02, 36.03, highway="path", name="Odd Trail"),
        ])
        shares = self.facts(rows[0])["shares"]["smoothness"]
        self.assertAlmostEqual(shares["good"], 1 / 3, delta=0.002)
        self.assertAlmostEqual(shares["unstated"], 2 / 3, delta=0.002)

    def test_the_build_counts_rows_with_facts_and_mixed_rows(self):
        self.build(piney() + [
            north("w5", 36.1, 36.11, highway="path", name="Smooth Trail", smoothness="good"),
            north("w6", 36.2, 36.21, highway="path", name="Plain Trail", surface="dirt"),
        ])
        self.assertEqual((self.stats.fact_rows, self.stats.fact_rows_mixed), (2, 1))

    def test_an_unnamed_corridor_counts_every_way_not_its_longest(self):
        rows, _, _ = self.build([
            north("w1", 36.0, 36.006, highway="cycleway", surface="asphalt", lit="yes"),
            north("w2", 36.006, 36.010, highway="cycleway", surface="asphalt", lit="no"),
        ])
        self.assertEqual(len(rows), 1)
        shares = self.facts(rows[0])["shares"]["lit"]
        self.assertAlmostEqual(shares["yes"], 0.6, delta=0.002)
        self.assertAlmostEqual(shares["no"], 0.4, delta=0.002)

    def test_shares_times_length_add_up_to_the_whole_trail(self):
        # Two rows of one trail key (300 m apart, so not merged): the app adds
        # share x length over a key's rows to judge the whole trail.
        a = north("w1", 36.0, 36.01, highway="path", name="Long Trail", smoothness="good")
        b = north("w2", 36.0127, 36.0227, highway="path", name="Long Trail", smoothness="bad")
        c = north("w3", 36.0227, 36.0327, highway="path", name="Long Trail")
        rows, _, _ = self.build([a, b, c])
        self.assertEqual(len(rows), 2)
        self.assertEqual(len({r[5] for r in rows}), 1, "one trail key")
        metres: dict = {}
        for r in rows:
            for value, share in self.facts(r)["shares"]["smoothness"].items():
                metres[value] = metres.get(value, 0.0) + share * r[2]
        way = btp.line_length_m(a["geometry"]["coordinates"])
        self.assertAlmostEqual(metres["good"], way, delta=3)
        self.assertAlmostEqual(metres["bad"], way, delta=3)
        self.assertAlmostEqual(metres["unstated"], way, delta=3)

    def test_a_row_stating_no_fact_has_no_facts(self):
        rows, meta, _ = self.build([north("w1", 36.0, 36.01, highway="path", name="Plain Trail", surface="dirt")])
        self.assertNotIn("facts", json.loads(rows[0][4]))
        self.assertEqual(meta["fact_shares"], "1", "absent facts in a 1.6.0 pack means none stated")

    def test_values_are_normalised_and_operator_keeps_its_case(self):
        rows, _, _ = self.build([
            north("w1", 36.0, 36.01, highway="path", name="Mixed Trail", smoothness=" Good ",
                  operator="Nantahala  Hiking Club"),
            north("w2", 36.01, 36.02, highway="path", name="Mixed Trail", smoothness="good",
                  operator="Nantahala Hiking Club", wheelchair=""),
        ])
        facts = self.facts(rows[0])
        self.assertEqual(facts["shares"]["smoothness"], {"good": 1.0})
        self.assertEqual(facts["shares"]["operator"], {"Nantahala Hiking Club": 1.0})
        self.assertNotIn("wheelchair", facts["shares"], "an empty value states nothing")

    def test_verify_refuses_shares_that_do_not_sum_to_one(self):
        _, _, out = self.build(piney())
        self.assertTrue(btp.verify_pack(out))
        conn = sqlite3.connect(out)
        tags = json.loads(conn.execute("SELECT tags_json FROM trails").fetchone()[0])
        tags["facts"]["shares"]["sac_scale"]["hiking"] = 0.8
        conn.execute("UPDATE trails SET tags_json = ?", (json.dumps(tags),))
        conn.commit()
        conn.close()
        self.assertFalse(btp.verify_pack(out))

    def test_verify_refuses_a_zero_share(self):
        _, _, out = self.build(piney())
        conn = sqlite3.connect(out)
        tags = json.loads(conn.execute("SELECT tags_json FROM trails").fetchone()[0])
        tags["facts"]["shares"]["sac_scale"]["unstated"] = 0.0  # still sums to 1
        conn.execute("UPDATE trails SET tags_json = ?", (json.dumps(tags),))
        conn.commit()
        conn.close()
        self.assertFalse(btp.verify_pack(out))


class AllocateTests(unittest.TestCase):

    def test_rounding_noise_is_not_an_unstated_stretch(self):
        # Up to 1 m more geometry than stated length is rounding; past it, unstated.
        self.assertEqual(btp._allocate({"good": 1000}, 1010), {"good": 1000})
        self.assertEqual(btp._allocate({"good": 1000}, 1011), {"good": 989, "unstated": 11})
        self.assertEqual(btp._allocate({"a": 47}, 57), {"a": 1000})
        self.assertEqual(btp._allocate({"good": 50000}, 50015), {"good": 1000}, "no zero-unit entry")

    def test_more_stated_than_geometry_shares_the_stated_length(self):
        self.assertEqual(btp._allocate({"a": 11, "b": 1}, 7), {"a": 917, "b": 83})

    def test_a_raised_value_takes_no_remainder_unit(self):
        # a is 0.9 units, raised to 1; the spare unit is v's (499.6), not a's
        # (critic run 1).
        self.assertEqual(btp._allocate({"a": 9, "u": 4995, "v": 4996}, 10000), {"a": 1, "u": 499, "v": 500})

    def test_giving_back_units_does_not_depend_on_order(self):
        one = btp._allocate({"a": 100000, "b": 100000, "c": 1, "d": 1, "e": 1}, 200003)
        two = btp._allocate({"e": 1, "d": 1, "c": 1, "b": 100000, "a": 100000}, 200003)
        self.assertEqual(one, two)
        self.assertEqual(sum(one.values()), 1000)

    def test_tiny_values_keep_one_unit_and_the_total_stays_exact(self):
        units = btp._allocate({"good": 100000, "bad": 1, "horrible": 1}, 100002)
        self.assertEqual(units, {"good": 998, "bad": 1, "horrible": 1})


if __name__ == "__main__":
    unittest.main()
