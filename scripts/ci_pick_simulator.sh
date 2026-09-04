#!/usr/bin/env bash
#
# Prints the UDID of the newest available iPhone simulator on this machine.
#
# Why this exists:
#   Hardcoding -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
#   in CI works only as long as the GitHub runner image happens to ship that
#   exact device. When it doesn't, xcodebuild fails with
#     "Unable to find a device matching the provided destination specifier"
#   and the job dies in ~60s without running a single test. Runner images also
#   drift between the two parallel VMs a workflow gets, so the unit job can
#   pass while the UI job fails on the identical specifier.
#
#   Discovering a real device at runtime and passing -destination "id=<udid>"
#   makes the workflow survive runner-image churn.
#
# Selection order: newest iOS runtime, then highest iPhone number, then the
# plain model (no Pro/Pro Max/Plus/mini suffix) because it boots fastest.
set -euo pipefail

if ! LIST_JSON=$(xcrun simctl list devices available --json 2>/dev/null); then
  echo "::error::xcrun simctl is unavailable on this runner." >&2
  exit 1
fi

printf '%s' "$LIST_JSON" | python3 -c '
import json, re, sys

devices = json.load(sys.stdin)["devices"]
best = None
for runtime, devs in devices.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    os_version = (int(m.group(1)), int(m.group(2)))
    for d in devs:
        if not d.get("isAvailable"):
            continue
        name = d["name"]
        n = re.match(r"^iPhone (\d+)", name)
        if not n:
            continue
        plain = 1 if name == "iPhone " + n.group(1) else 0
        rank = (os_version, int(n.group(1)), plain)
        if best is None or rank > best[0]:
            best = (rank, d)

if best is None:
    sys.stderr.write("::error::No available iPhone simulator found.\n")
    sys.exit(1)

sys.stderr.write("Selected simulator: %s  (%s)\n" % (best[1]["name"], best[1]["udid"]))
print(best[1]["udid"])
' || {
  echo "--- available simulators on this runner ---" >&2
  xcrun simctl list devices available >&2 || true
  exit 1
}
