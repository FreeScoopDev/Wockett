#!/usr/bin/env bash
# Builds the North Carolina trail packs from a Geofabrik extract, end to end:
# the one the app bundles (PoCSquat/Trails/nc.wktpack, named trails only) and
# the full one it downloads ($WORK/packs/nc-full.wktpack, published to the
# CloudKit TrailRegion record by hand). Run from anywhere:
#
#     bash scripts/trail-pack/build_nc.sh
#
# Needs: osmium-tool (brew install osmium-tool), python3, ~1 GB of disk in
# ~/Desktop/Apps/wockett-trails (or WORK=/some/dir), and the builder from
# tools/ (1.2.0 or later for the full pack's corridors and derived names).
#
# What it does, and why each step exists — the reasoning is in the Notion card
# "Public trail data — sources, trade-offs, and a no-API-ceiling architecture":
#   1. Download the state extract. Bulk download, no API, no ceiling.
#   2. Filter to trail-like ways. The first filter pulled the whole urban
#      sidewalk network (65% of the result); the second pass removes it.
#      Crossings (footway=crossing) are KEPT since builder 1.2.0: they are
#      the link between the two halves of a sidepath either side of a side
#      street, and the builder drops every crossing that joins nothing.
#   3. Drop private-access ways (decision 2026-09-16): 99% of "dogs not
#      permitted" came from private farm tracks, a confident wrong answer.
#      access=no goes too: the shipped 1.1.0 packs were built with
#      access=private,no (their input reproduces byte for byte only with
#      both), though this script said private alone until 2026-09-26.
#   4. Export to GeoJSON-seq with feature-level ids (osmium's real output
#      shape — a hand-made fixture that differed from it hid two bugs).
#   5. Build the bundled pack: named trails only (the bundle is the trimmed
#      home region; the full pack downloads on demand), same-named ways
#      merged, --built-at pinned to the extract's date so a rebuild is
#      byte-identical.
#   6. Export the named roads, and build the full pack: unnamed ways joined
#      into corridors, and a corridor running beside a named road named
#      after it ("Duck Road Path"). See the builder's comments for the rules.
#
# Refresh cadence: review this pipeline every release; republish a pack only
# when the data materially changed (Notion decision, 2026-09-10).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
WORK="${WORK:-$HOME/Desktop/Apps/wockett-trails}"
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
osmium tags-filter -i "$WORK/nc-trails.osm.pbf" w/footway=sidewalk,access_aisle,traffic_island \
  -o "$WORK/nc-trails-clean.osm.pbf" --overwrite
osmium tags-filter -i "$WORK/nc-trails-clean.osm.pbf" w/access=private,no \
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

# Named roads, for derived corridor names. Motorways and service roads are
# left out: no sidepath is named after an interstate or a parking aisle.
osmium tags-filter "$EXTRACT" w/highway=trunk,primary,secondary,tertiary,unclassified,residential,living_street,pedestrian \
  -o "$WORK/nc-roads.osm.pbf" --overwrite
osmium tags-filter "$WORK/nc-roads.osm.pbf" w/name -o "$WORK/nc-roads-named.osm.pbf" --overwrite
osmium export "$WORK/nc-roads-named.osm.pbf" -f geojsonseq --add-unique-id=type_id --geometry-types=linestring \
  -o "$WORK/nc-roads-named.geojsonseq" --overwrite

python3 tools/build_trail_pack.py \
  --region nc --region-name "North Carolina" \
  --input "$WORK/nc-trails-public.geojsonseq:osm" \
  --roads "$WORK/nc-roads-named.geojsonseq" \
  --built-at "$BUILT_AT" \
  --out "$WORK/packs/nc-full.wktpack"
# The CloudKit record needs sizeBytes and trailCount from this file:
stat -f %z "$WORK/packs/nc-full.wktpack"
python3 tools/build_trail_pack.py --inspect "$WORK/packs/nc-full.wktpack"
