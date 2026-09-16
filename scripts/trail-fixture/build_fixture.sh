#!/usr/bin/env bash
# Rebuilds WockettTests/Fixtures/fixture.wktpack from trails-fixture.geojsonseq
# using the real builder, so the test fixture can never drift from the shipped
# schema. Run from anywhere:
#
#     bash scripts/trail-fixture/build_fixture.sh
#
# Lives here, not beside the fixture, because WockettTests is a synchronized
# folder: anything in it that is not Swift is copied into the .xctest bundle,
# and a shell script has no business inside a test bundle.
#
# The fixture is built by tools/build_trail_pack.py rather than by hand: on
# 2026-09-10 a hand-made fixture agreed with the code instead of with osmium's
# real output and hid two bugs. The builder arrived in PR #43; this script
# needs that merged (or checked out) to run.
#
# `--built-at` is pinned so a rebuild from unchanged input is byte-identical;
# `git status` stays clean unless the input or the builder actually changed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
if [[ ! -f tools/build_trail_pack.py ]]; then
  echo "tools/build_trail_pack.py not found — it lands with PR #43 (chore/track-offline-builders-1.12)." >&2
  exit 1
fi
python3 tools/build_trail_pack.py \
  --region fixture --region-name "Test Fixture" \
  --input scripts/trail-fixture/trails-fixture.geojsonseq:osm \
  --built-at 2026-09-16T00:00:00Z \
  --out WockettTests/Fixtures/fixture.wktpack
python3 tools/build_trail_pack.py --inspect WockettTests/Fixtures/fixture.wktpack
