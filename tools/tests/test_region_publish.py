"""Tests for tools/region_publish.py against a fake cktool. No network."""
import hashlib
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import region_publish as rp  # noqa: E402


# The options each cktool command accepts, copied from `xcrun cktool <command>
# --help` on 2026-10-08. Hardcoded on purpose: the fake must refuse what the
# real tool refuses, or a wrong option passes here and fails in Production
# (delete-record with --team-id did exactly that).
CKTOOL_OPTIONS = {
    "create-record": {"--asset-files", "--container-id", "--database-type", "--environment", "--fields-file",
                      "--fields-json", "--fields-stdin", "--record-type", "--team-id", "--token", "--zone-name"},
    "delete-record": {"--container-id", "--database-type", "--environment", "--record-name", "--token",
                      "--yes", "--zone-name"},
    "query-records": {"--container-id", "--continuation-token", "--database-type", "--environment", "--filters",
                      "--limit", "--record-type", "--requested-fields", "--sort-by", "--team-id", "--token",
                      "--zone-name"},
}


class FakeCloudKit:
    """Holds records per environment and answers the cktool calls region_publish makes."""

    def __init__(self, records=None, hide_created=False, visible_after=0):
        self.db = {"development": [], "production": []}
        for env, recs in (records or {}).items():
            self.db[env] = list(recs)
        self.calls = []
        self.hide_created = hide_created
        # A created record is left out of this many queries first, as
        # CloudKit's query index lags a create.
        self.visible_after = visible_after
        self.pending = []
        self.n = 0

    def __call__(self, args):
        self.calls.append(args)
        unknown = {a for a in args[1:] if a.startswith("--")} - CKTOOL_OPTIONS[args[0]]
        if unknown:
            raise rp.PublishError(f"Error: Unknown option '{sorted(unknown)[0]}'")
        env = args[args.index("--environment") + 1]
        if args[0] == "query-records":
            if self.pending:
                if self.visible_after > 0:
                    self.visible_after -= 1
                else:
                    self.db[env] += self.pending
                    self.pending = []
            return json.dumps({"records": [
                {"recordName": r["recordName"], "fields": {k: {"value": v} for k, v in r.items() if k != "recordName"}}
                for r in self.db[env]]})
        if args[0] == "create-record":
            fields = json.loads(args[args.index("--fields-json") + 1])
            assert args[args.index("--asset-files") + 1].startswith("PACK=")
            self.n += 1
            if not self.hide_created:
                rec = {k: v["value"] for k, v in fields.items() if k != "pack"}
                rec["recordName"] = f"new-{self.n}"
                (self.pending if self.visible_after else self.db[env]).append(rec)
            return "{}"
        if args[0] == "delete-record":
            name = args[args.index("--record-name") + 1]
            assert "--yes" in args
            self.db[env] = [r for r in self.db[env] if r["recordName"] != name]
            return "{}"
        raise AssertionError(args)


def release(work, version=3, region="nc", tamper=False):
    pack = os.path.join(work, f"{region}-full.wktpack")
    with open(pack, "wb") as f:
        f.write(b"pack bytes " * 100)
    digest = hashlib.sha256(open(pack, "rb").read()).hexdigest()
    m = {"region": region, "regionName": "North Carolina", "schemaVersion": 1, "packVersion": version,
         "builtAt": "2026-09-09T20:21:20Z", "trailCount": 34422, "sizeBytes": os.path.getsize(pack),
         "sha256": digest, "pack": pack}
    os.makedirs(os.path.join(work, "release"), exist_ok=True)
    with open(os.path.join(work, "release", f"{region}-v{version}.json"), "w") as f:
        json.dump(m, f)
    if tamper:
        with open(pack, "ab") as f:
            f.write(b"!")
    return m


LIVE_V2 = {"recordName": "nc", "region": "nc", "packVersion": 2, "sizeBytes": 19070976}


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp()
        self.quiet = lambda *a: None

    def test_reads_the_live_version(self):
        ck = FakeCloudKit({"production": [LIVE_V2]})
        self.assertEqual(rp.live_version("nc", run=ck), 2)
        self.assertEqual(rp.live_version("sc", run=ck), 0)

    def test_development_upload_creates_then_removes_older(self):
        release(self.work, 3)
        ck = FakeCloudKit({"development": [dict(LIVE_V2, recordName="dev-old")]})
        out = rp.publish("nc", self.work, production=False, tested=False, run=ck, log=self.quiet)
        self.assertEqual(out["environment"], "development")
        self.assertEqual([r["packVersion"] for r in ck.db["development"]], [3])
        kinds = [c[0] for c in ck.calls]
        self.assertLess(kinds.index("create-record"), kinds.index("delete-record"), "create before delete")
        self.assertEqual(ck.db["production"], [], "Production untouched")
        self.assertFalse(os.path.exists(os.path.join(self.work, "published", "nc.json")))

    def test_fields_come_from_the_manifest(self):
        m = release(self.work, 3)
        ck = FakeCloudKit()
        rp.publish("nc", self.work, production=False, tested=False, run=ck, log=self.quiet)
        create = next(c for c in ck.calls if c[0] == "create-record")
        fields = json.loads(create[create.index("--fields-json") + 1])
        self.assertEqual(fields["packVersion"], {"type": "int64Type", "value": 3})
        self.assertEqual(fields["sizeBytes"]["value"], m["sizeBytes"])
        self.assertEqual(fields["trailCount"]["value"], 34422)
        self.assertEqual(fields["builtAt"], {"type": "timestampType", "value": "2026-09-09T20:21:20Z"})
        self.assertEqual(create[create.index("--asset-files") + 1], f"PACK={m['pack']}")
        self.assertIn("public", create)

    def test_production_needs_tested(self):
        release(self.work, 3)
        ck = FakeCloudKit({"production": [LIVE_V2]})
        with self.assertRaises(rp.PublishError):
            rp.publish("nc", self.work, production=True, tested=False, run=ck, log=self.quiet)
        self.assertEqual(ck.calls, [], "refused before any CloudKit call")

    def test_production_publish_records_what_users_have(self):
        release(self.work, 3)
        ck = FakeCloudKit({"production": [LIVE_V2]})
        rp.publish("nc", self.work, production=True, tested=True, run=ck, log=self.quiet)
        self.assertEqual([r["packVersion"] for r in ck.db["production"]], [3])
        with open(os.path.join(self.work, "published", "nc.json")) as f:
            self.assertEqual(json.load(f)["packVersion"], 3)

    def test_not_newer_than_live_is_refused(self):
        release(self.work, 2)
        ck = FakeCloudKit({"production": [LIVE_V2]})
        with self.assertRaises(rp.PublishError):
            rp.publish("nc", self.work, production=True, tested=True, run=ck, log=self.quiet)
        self.assertFalse(any(c[0] in ("create-record", "delete-record") for c in ck.calls))

    def test_changed_pack_is_refused(self):
        release(self.work, 3, tamper=True)
        ck = FakeCloudKit()
        with self.assertRaises(rp.PublishError):
            rp.publish("nc", self.work, production=False, tested=False, run=ck, log=self.quiet)
        self.assertEqual(ck.calls, [])

    def test_nothing_removed_when_the_new_record_is_not_visible(self):
        release(self.work, 3)
        ck = FakeCloudKit({"development": [dict(LIVE_V2, recordName="dev-old")]}, hide_created=True)
        slept = []
        with self.assertRaises(rp.PublishError):
            rp.publish("nc", self.work, production=False, tested=False, run=ck, log=self.quiet, sleep=slept.append)
        self.assertEqual([r["recordName"] for r in ck.db["development"]], ["dev-old"])
        self.assertEqual(sum(slept), sum(rp.VISIBILITY_WAITS), "it waited the full minute before giving up")

    def test_waits_for_the_query_index_to_catch_up(self):
        # sc v1, 2026-10-08: created, missing from the next query, listed a
        # minute later. Waiting must publish, and still remove the older one.
        release(self.work, 3)
        ck = FakeCloudKit({"development": [dict(LIVE_V2, recordName="dev-old")]}, visible_after=3)
        slept = []
        out = rp.publish("nc", self.work, production=False, tested=False, run=ck, log=self.quiet, sleep=slept.append)
        self.assertEqual(out["packVersion"], 3)
        self.assertEqual([r["packVersion"] for r in ck.db["development"]], [3])
        self.assertEqual(len(slept), 3)

    def test_newest_manifest_is_used(self):
        release(self.work, 3)
        release(self.work, 10)
        self.assertTrue(rp.latest_manifest(self.work, "nc").endswith("nc-v10.json"))


if __name__ == "__main__":
    unittest.main()
