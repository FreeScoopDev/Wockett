#!/usr/bin/env python3
"""Publishes a released trail region pack to CloudKit, and reads what is live.

    python3 tools/region_publish.py live-version nc
    python3 tools/region_publish.py publish nc                       # Development
    python3 tools/region_publish.py publish nc --production --tested  # after a phone test

`publish` uploads the newest release manifest for the region
($WORK/release/<region>-v<N>.json, written by region_release.py) as a
`TrailRegionPack` record in the public database, then removes the region's
older records in that environment. Every field comes from the manifest; none
is typed. It refuses, before touching CloudKit, when:
  * the pack file no longer matches the manifest's sha256;
  * the version is not newer than every record already there;
  * the target is Production without --tested (a device has downloaded the
    pack from Development and the Trails list looked right).

Replacing is create-then-delete: cktool cannot edit a record in place. For
the seconds in between the region has two records; the app lists the newest
(TrailPackLibrary.refreshCatalog) and the older one still downloads.

Tokens: cktool reads them from ~/.config/cktool (saved once with
`xcrun cktool save-token --type management|user --method file`). The user
token is short-lived; when a call fails with an auth error, save it again.
Stdlib only.
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

TEAM_ID = "7U83DJ2F97"
CONTAINER = "iCloud.Scoops.PoCSquat"
RECORD_TYPE = "TrailRegionPack"
DEFAULT_WORK = os.path.expanduser("~/Desktop/Apps/wockett-trails")


class PublishError(Exception):
    pass


def cktool(args: list[str]) -> str:
    """Runs `xcrun cktool`; replaced in tests."""
    out = subprocess.run(["xcrun", "cktool", *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise PublishError((out.stderr or out.stdout).strip() or f"cktool {args[0]} failed")
    return out.stdout


def _base(env: str, team: bool = True) -> list[str]:
    # delete-record has no --team-id option and fails on it (it takes the team
    # from the saved token). That failure left nc v2 beside v3 in Production on
    # 2026-10-08 until it was deleted by hand.
    return (["--team-id", TEAM_ID] if team else []) + ["--container-id", CONTAINER,
            "--environment", env, "--database-type", "public"]


def records(env: str, region: str | None = None, run=None) -> list[dict]:
    """Every TrailRegionPack record in `env` as {recordName, region, packVersion, sizeBytes, ...}."""
    run = run or cktool
    raw = run(["query-records", *_base(env), "--record-type", RECORD_TYPE])
    data = json.loads(raw) if raw.strip() else {}
    out = []
    for r in data.get("records", []):
        f = {k: v.get("value") for k, v in r.get("fields", {}).items() if k != "pack"}
        f["recordName"] = r.get("recordName")
        if region is None or f.get("region") == region:
            out.append(f)
    return out


def live_version(region: str, env: str = "production", run=None) -> int:
    """The highest packVersion published for `region` in `env`; 0 if none."""
    return max((int(r.get("packVersion") or 0) for r in records(env, region, run)), default=0)


def latest_manifest(work: str, region: str) -> str:
    paths = glob.glob(os.path.join(work, "release", f"{region}-v*.json"))
    if not paths:
        raise PublishError(f"no release manifest for '{region}' in {work}/release — run make_region.sh {region} first")
    return max(paths, key=lambda p: int(re.search(r"-v(\d+)\.json$", p).group(1)))


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fields_json(m: dict) -> str:
    built = m["builtAt"]
    # CloudKit timestamps want an ISO date with a zone.
    built = datetime.fromisoformat(built.replace("Z", "+00:00")).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return json.dumps({
        "region": {"type": "stringType", "value": m["region"]},
        "regionName": {"type": "stringType", "value": m["regionName"]},
        "schemaVersion": {"type": "int64Type", "value": int(m["schemaVersion"])},
        "packVersion": {"type": "int64Type", "value": int(m["packVersion"])},
        "builtAt": {"type": "timestampType", "value": built},
        "trailCount": {"type": "int64Type", "value": int(m["trailCount"])},
        "sizeBytes": {"type": "int64Type", "value": int(m["sizeBytes"])},
        "pack": {"type": "assetType", "value": "PACK"},
    })


def publish(region: str, work: str, production: bool, tested: bool, run=None, log=print) -> dict:
    run = run or cktool
    env = "production" if production else "development"
    if production and not tested:
        raise PublishError("Production needs --tested: download the pack from Development on a phone first "
                           "(Settings → Trail Regions in a TestFlight or Xcode build pointed at Development).")
    path = latest_manifest(work, region)
    with open(path) as f:
        m = json.load(f)
    if m["region"] != region:
        raise PublishError(f"{path} is for '{m['region']}', not '{region}'")
    if not os.path.exists(m["pack"]):
        raise PublishError(f"the pack {m['pack']} is gone; rebuild with make_region.sh {region}")
    if sha256(m["pack"]) != m["sha256"] or os.path.getsize(m["pack"]) != m["sizeBytes"]:
        raise PublishError(f"{m['pack']} changed since its manifest was written; rebuild with make_region.sh {region}")

    existing = records(env, region, run)
    newest = max((int(r.get("packVersion") or 0) for r in existing), default=0)
    if int(m["packVersion"]) <= newest:
        raise PublishError(f"{env} already has {region} v{newest}; this release is v{m['packVersion']}. "
                           f"Rebuild so the release step picks the next version.")

    log(f"Uploading {region} v{m['packVersion']} ({m['trailCount']:,} trails, {m['sizeBytes'] / 1e6:.1f} MB) to {env}…")
    run(["create-record", *_base(env), "--record-type", RECORD_TYPE,
         "--fields-json", fields_json(m), "--asset-files", f"PACK={m['pack']}"])

    after = records(env, region, run)
    mine = [r for r in after if int(r.get("packVersion") or 0) == int(m["packVersion"])
            and int(r.get("sizeBytes") or 0) == int(m["sizeBytes"])]
    if not mine:
        raise PublishError(f"the new {region} v{m['packVersion']} record is not visible in {env}; nothing was removed")
    for r in after:
        if int(r.get("packVersion") or 0) < int(m["packVersion"]):
            run(["delete-record", *_base(env, team=False), "--record-name", r["recordName"], "--yes"])
            log(f"Removed the older {region} v{r.get('packVersion')} record ({r['recordName']}).")

    result = {"region": region, "packVersion": int(m["packVersion"]), "environment": env,
              "recordName": mine[0]["recordName"], "pack": m["pack"], "sha256": m["sha256"],
              "publishedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    if production:
        os.makedirs(os.path.join(work, "published"), exist_ok=True)
        with open(os.path.join(work, "published", f"{region}.json"), "w") as f:
            json.dump(result, f, indent=2)
    log(f"Published {region} v{m['packVersion']} to {env}.")
    return result


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Publish a trail region pack to CloudKit, or read what is live.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    lv = sub.add_parser("live-version", help="print the highest packVersion live for a region")
    lv.add_argument("region")
    lv.add_argument("--environment", default="production", choices=["development", "production"])
    pb = sub.add_parser("publish", help="upload the newest release of a region")
    pb.add_argument("region")
    pb.add_argument("--work", default=os.environ.get("WORK", DEFAULT_WORK))
    pb.add_argument("--production", action="store_true", help="publish to Production (users get it)")
    pb.add_argument("--tested", action="store_true", help="the Development upload was checked on a phone")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "live-version":
            print(live_version(args.region, args.environment))
        else:
            publish(args.region, args.work, args.production, args.tested)
    except PublishError as e:
        print(f"Not published: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
