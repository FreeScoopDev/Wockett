#!/usr/bin/env bash
# Builds the North Carolina trail pack the app bundles (PoCSquat/Trails/nc.wktpack)
# from a Geofabrik extract, end to end. Run from anywhere:
#
#     bash scripts/trail-pack/build_nc.sh
#
# Needs: osmium-tool (brew install osmium-tool), python3, ~500 MB of disk in
# ~/Desktop/wockett-trails, and the builder from tools/ (PR #47 or later).
#
# What it does, and why each step exists — the reasoning is in the Notion card
# "Public trail data — sources, trade-offs, and a no-API-ceiling architecture":
#   1. Download the state extract. Bulk download, no API, no ceiling.
#   2. Filter to trail-like ways. The first filter pulled the whole urban
#      sidewalk network (65% of the result); the second pass removes it.
#   3. Drop private-access ways (decision 2026-09-16): 99% of "dogs not
#      permitted" came from private farm tracks, a confident wrong answer.
#   4. Export to GeoJSON-seq with feature-level ids (osmium's real output
#      shape — a hand-made fixture that differed from it hid two bugs).
#   5. Build the pack: named trails only (the bundle is the trimmed home
#      region; the full pack downloads on demand), same-named ways merged,
#      --built-at pinned to the extract's date so a rebuild is byte-identical.
#
# Refresh cadence: review this pipeline every release; republish a pack only
# when the data materially changed (Notion decision, 2026-09-10).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
WORK=~/Desktop/wockett-trails
mkdir -p "$WORK/packs"
EXTRACT="$WORK/north-carolina-latest.osm.pbf"

if [[ ! -f "$EXTRACT" ]]; then
  curl -L -o "$EXTRACT" https://download.geofabrik.de/north-america/us/north-carolina-latest.osm.pbf
fi
# The extract's own timestamp becomes the pack's built_at, so the pack says
# what the data is, not when someone ran this script.
BUILT_AT="$(osmium fileinfo -e -g header.option.osmosis_replication_timestamp "$EXTRACT" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

osmium tags-filter "$EXTRACT" w/highway=path,footway,track,bridleway,cycleway,steps w/route=hiking,foot \
  -o "$WORK/nc-trails.osm.pbf" --overwrite
osmium tags-filter -i "$WORK/nc-trails.osm.pbf" w/footway=sidewalk,crossing,access_aisle,traffic_island \
  -o "$WORK/nc-trails-clean.osm.pbf" --overwrite
osmium tags-filter -i "$WORK/nc-trails-clean.osm.pbf" w/access=private \
  -o "$WORK/nc-trails-public.osm.pbf" --overwrite
osmium export "$WORK/nc-trails-public.osm.pbf" -f geojsonseq --add-unique-id=type_id --geometry-types=linestring \
  -o "$WORK/nc-trails-public.geojsonseq" --overwrite

python3 tools/build_trail_pack.py \
  --region nc --region-name "North Carolina" \
  --input "$WORK/nc-trails-public.geojsonseq:osm" \
  --named-only --built-at "$BUILT_AT" \
  --out "$WORK/packs/nc-named.wktpack"

cp "$WORK/packs/nc-named.wktpack" PoCSquat/Trails/nc.wktpack
python3 tools/build_trail_pack.py --inspect PoCSquat/Trails/nc.wktpack
