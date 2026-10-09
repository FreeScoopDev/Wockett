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
        self.assertEqual(meta["builder_version"], "1.5.0")
        self.assertTrue(btp.verify_pack(out))


if __name__ == "__main__":
    unittest.main()


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
