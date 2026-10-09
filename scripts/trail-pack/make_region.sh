#!/usr/bin/env bash
# Builds one trail region end to end, from its row in tools/regions.json:
#
#     bash scripts/trail-pack/make_region.sh sc
#
# Then checks it and writes the release manifest the publish step uploads:
#   $WORK/packs/<region>-full.wktpack       the downloadable pack
#   $WORK/release/<region>-v<N>.json        every CloudKit record field, computed
# For a bundled region (bundled: true) it also rebuilds the named-only pack and
# copies it to PoCSquat/Trails/<region>.wktpack, which ships with the next app
# release.
#
# Adding a region is a row in tools/regions.json (name, Geofabrik path, a probe
# point at the main city), then this command. Nothing here is per-state.
#
# Needs: osmium-tool (brew install osmium-tool), python3, curl, ~1 GB per state
# in WORK (default ~/Desktop/Apps/wockett-trails). The extract is cached; delete
# it, or pass --refresh, to fetch new data.
#
# What it does, and why each step exists — the reasoning is in the Notion card
# "Public trail data — sources, trade-offs, and a no-API-ceiling architecture":
#   1. Download the state extract (cached in $WORK/extracts). Bulk download, no API, no ceiling.
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
#      access=military goes too since 2026-10-08 (Florida: closed ranges).
#   4. Export to GeoJSON-seq with feature-level ids (osmium's real output
#      shape — a hand-made fixture that differed from it hid two bugs).
#   5. Build the bundled pack (bundled regions only): named trails only (the bundle is the trimmed
#      home region; the full pack downloads on demand), same-named ways
#      merged, --built-at pinned to the extract's date so a rebuild is
#      byte-identical.
#   6. Export the named roads, and build the full pack: unnamed ways joined
#      into corridors, and a corridor running beside a named road named
#      after it ("Duck Road Path"). See the builder's comments for the rules.
#   7. Gate and stamp it (tools/region_release.py): verify, bounds, named
#      trails near the region's main city, size budget, quality report;
#      then the next packVersion and the release manifest.
#
# Refresh cadence: review this pipeline every release; republish a pack only
# when the data materially changed (Notion decision, 2026-09-10).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

REGION="${1:-}"
REFRESH=false
[[ "${2:-}" == "--refresh" ]] && REFRESH=true
if [[ -z "$REGION" ]]; then
  echo "usage: make_region.sh <region> [--refresh]   (regions: $(python3 -c 'import json;print(" ".join(k for k in json.load(open("tools/regions.json")) if not k.startswith("_")))'))" >&2
  exit 2
fi
field() { python3 -c "import json,sys; r=json.load(open('tools/regions.json'))['$REGION']; print(r['$1'])"; }
NAME="$(field name)" || { echo "Unknown region '$REGION' — add it to tools/regions.json" >&2; exit 2; }
SLUG="$(field geofabrik)"
BUNDLED="$(field bundled)"

WORK="${WORK:-$HOME/Desktop/Apps/wockett-trails}"
mkdir -p "$WORK/packs" "$WORK/extracts"
BASE="$(basename "$SLUG")"
EXTRACT="$WORK/extracts/$BASE-latest.osm.pbf"
# Older NC builds kept the extract at the top of WORK; reuse it rather than download again.
if [[ ! -f "$EXTRACT" && -f "$WORK/$BASE-latest.osm.pbf" ]]; then mv "$WORK/$BASE-latest.osm.pbf" "$EXTRACT"; fi
if [[ ! -f "$EXTRACT" || "$REFRESH" == true ]]; then
  echo "Downloading $NAME from Geofabrik…"
  curl -fL -o "$EXTRACT.part" "https://download.geofabrik.de/$SLUG-latest.osm.pbf"
  mv "$EXTRACT.part" "$EXTRACT"
fi
MD5="$(md5 -q "$EXTRACT" 2>/dev/null || md5sum "$EXTRACT" | cut -d' ' -f1)"
BUILT_AT="$(osmium fileinfo -e -g header.option.osmosis_replication_timestamp "$EXTRACT" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
BBOX="$(osmium fileinfo -e -g data.bbox "$EXTRACT" | tr -d '() ')"
echo "$NAME: extract $BUILT_AT, md5 $MD5"

T="$WORK/$REGION"
osmium tags-filter "$EXTRACT" w/highway=path,footway,track,bridleway,cycleway,steps w/route=hiking,foot \
  -o "$T-trails.osm.pbf" --overwrite
osmium tags-filter -i "$T-trails.osm.pbf" w/footway=sidewalk,access_aisle,traffic_island \
  -o "$T-trails-clean.osm.pbf" --overwrite
osmium tags-filter -i "$T-trails-clean.osm.pbf" w/access=private,no,military \
  -o "$T-trails-public.osm.pbf" --overwrite
osmium export "$T-trails-public.osm.pbf" -f geojsonseq --add-unique-id=type_id --geometry-types=linestring \
  -o "$T-trails-public.geojsonseq" --overwrite

# Official trailheads (highway=trailhead): a dirt road that reaches one is kept
# as a way in, even with a street name or none (builder 1.4.0, 2026-10-08).
osmium tags-filter "$EXTRACT" n/highway=trailhead -o "$T-trailheads.osm.pbf" --overwrite
osmium export "$T-trailheads.osm.pbf" -f geojsonseq --add-unique-id=type_id --geometry-types=point \
  -o "$T-trailheads.geojsonseq" --overwrite

if [[ "$BUNDLED" == "True" ]]; then
  python3 tools/build_trail_pack.py \
    --region "$REGION" --region-name "$NAME" \
    --input "$T-trails-public.geojsonseq:osm" \
    --trailheads "$T-trailheads.geojsonseq" \
    --named-only --built-at "$BUILT_AT" \
    --out "$WORK/packs/$REGION-named.wktpack"
  cp "$WORK/packs/$REGION-named.wktpack" "PoCSquat/Trails/$REGION.wktpack"
  echo "Bundled pack copied to PoCSquat/Trails/$REGION.wktpack (ships with the next app release)."
fi

# Named roads, for derived corridor names. Motorways and service roads are
# left out: no sidepath is named after an interstate or a parking aisle.
osmium tags-filter "$EXTRACT" w/highway=trunk,primary,secondary,tertiary,unclassified,residential,living_street,pedestrian \
  -o "$T-roads.osm.pbf" --overwrite
osmium tags-filter "$T-roads.osm.pbf" w/name -o "$T-roads-named.osm.pbf" --overwrite
osmium export "$T-roads-named.osm.pbf" -f geojsonseq --add-unique-id=type_id --geometry-types=linestring \
  -o "$T-roads-named.geojsonseq" --overwrite

python3 tools/build_trail_pack.py \
  --region "$REGION" --region-name "$NAME" \
  --input "$T-trails-public.geojsonseq:osm" \
  --roads "$T-roads-named.geojsonseq" \
  --trailheads "$T-trailheads.geojsonseq" \
  --built-at "$BUILT_AT" \
  --out "$WORK/packs/$REGION-full.wktpack"

# The next version follows what users have, read from CloudKit Production
# (2026-10-08: a local record said nothing was published while v2 was live).
# LIVE_VERSION=N overrides it when CloudKit cannot be reached.
if [[ -z "${LIVE_VERSION:-}" ]]; then
  LIVE_VERSION="$(python3 tools/region_publish.py live-version "$REGION")" || {
    echo "Could not read the live $NAME version from CloudKit. Save the tokens (see tools/region_publish.py)," >&2
    echo "or run again with LIVE_VERSION=<the packVersion users have>." >&2
    exit 1
  }
fi
echo "Live in Production: $NAME v$LIVE_VERSION"

python3 tools/region_release.py "$REGION" \
  --pack "$WORK/packs/$REGION-full.wktpack" --work "$WORK" \
  --extract-md5 "$MD5" --extract-bbox "$BBOX" --live-version "$LIVE_VERSION"

echo "Next: python3 tools/region_publish.py publish $REGION   (uploads to Development)"
