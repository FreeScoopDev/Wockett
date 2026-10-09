# Trail data standards

How Wockett's trail regions are added, updated and improved. Agreed with Joe
on 2026-10-08/09: "I want them to be useful, informative, and accessible for
users in their respective areas. If we can't deliver useful trails, we should
hold off adding more", and each update should leave the data better than the
one before.

The tools enforce what can be enforced; this page says what they enforce, why,
and what a person still decides.

## What a region pack is for

A person opens Trails in their town and sees **named places they can walk**,
nearest first. Everything else (unnamed paths) is one tap away under "Other
paths". The pack is judged by that list, not by how many rows it holds.

## The bar every pack must clear (blocking gates)

`make_region.sh <region>` builds, then `tools/region_release.py` refuses to
write a release manifest unless all of these hold:

| Gate | Rule | Why |
| --- | --- | --- |
| Verify | Schema, R*Tree index, attribution, polyline round trip | A pack the app cannot read is worse than none |
| Bounds | Trails inside the source extract (±0.05°) | Catches a wrong extract or a corrupt build |
| Probe city | Named trails within 25 km of the row's probe city | The main city must work |
| Size | At least 100 rows, at most 150 MB | Empty or oversized downloads |
| **Coverage** | **≥ 50%** of the state's cities and towns have a named, walkable trail of at least ¼ mile within 3 miles (whole-trail length) | The usefulness bar for a new state |
| **No regression** | Coverage may not fall more than 2 points below the published version | Each update leaves the state at least as useful |

A coverage drop that is real and understood (OSM deleted a county's paths, a
rule was deliberately tightened) ships with
`ACCEPT_REGRESSION="<why>" make_region.sh <region>`. The reason is kept in the
manifest and in the published record's history.

## What every build prints for review (not gates)

- **Quality**: named share, named trails in pieces, short pieces.
- **Coverage** against the published version, and the first towns without a trail.
- **One name on many separate trails**: park blaze names ("Red Trail") are
  expected; descriptions ("Logging Road", "Multi-Modal Path") are candidates
  for the builder's generic list; variants of one name ("Sheltowee Trace",
  "Sheltowee Trace Trail #100") are candidates for name normalisation.
- **Very long single trails** (over 150 km): usually a place name painted on
  every way inside it (Eglin Air Force Base, 369 km). The Appalachian Trail is
  the legitimate exception.
- **Changes against the published version**: rows, named trails, names added
  and removed. Compared with the archived copy of what users have
  (`published/<region>-v<N>.wktpack`), never with the build folder.

## The curation rules (builder, in order of introduction)

Each rule exists because of a measured problem, and each has a test that was
broken on purpose to prove it guards something.

| Builder | Rule |
| --- | --- |
| 1.2.0 | Crossings kept as links; same-name ways merged where exactly two meet |
| 1.3.0 | Generic names ("Trail", "Connector") are unnamed; pieces of one trail within 50 m bridged; trail keys group a trail's pieces within 400 m; unnamed stubs under 150 m dropped |
| 1.3.1 | Descriptions ("abandoned track", "Logging Road", "WMA Road") are unnamed |
| 1.3.2 | Military installation names and names with no letter or digit are unnamed; `access=military` dropped |
| 1.4.0 | Unnamed dirt roads (`highway=track`) dropped unless open or within 100 m of a trailhead; street-named dirt roads likewise (trail-like names stay); bike paths walkable unless `foot=no`; ways closed to walking and riding dropped |
| 1.5.0 | Name variants of one trail (case, spacing, a trailing "Trail") share its key, named by the spelling covering most of its length, best written; trail numbers are identity ("Loop #1" and "Loop #2", "#109" and "#109A" stay apart); "access line/connector/point/spur" names are unnamed, "Access Trail/Path" names are kept |

Source filters in `make_region.sh`: sidewalks, traffic islands and
`access=private/no/military` never enter the build.

## Adding a state

1. Add a row to `tools/regions.json`: name, Geofabrik path, probe city (the
   largest city), `bundled: false`.
2. `make_region.sh <region>`. If a gate fails, the state waits. Look at the
   towns without a trail and the review lists before changing any threshold.
3. `region_publish.py publish <region>` (Development). On the simulator,
   download it and check the Trails list in the probe city **and one small
   town**. Under `-WKTUITest` each launch starts with an empty pack folder and
   the list is centred on Raleigh, so download inside the same launch and
   override the centre temporarily (never committed).
4. Production only with Joe's go-ahead:
   `region_publish.py publish <region> --production --tested`.

## Updating states (the improvement loop)

1. **When**: every release cycle, or sooner when a review list shows a
   problem. Republish a state only when its data materially changed (names
   added or removed, or coverage moved), not on every OSM update.
2. **Improve the builder first**: take one item from the review lists, write
   the rule with a test, break the rule and watch the test fail, bump
   `BUILDER_VERSION`, and add a row to the table above.
3. **Rebuild every published state** with the new builder, one at a time
   (disk is tight). The no-regression gate holds each one to its published
   coverage.
4. **Measure**: compare coverage and the review lists with the published
   history (`published/<region>.json` → `history`). A rule that does not
   improve the lists, or costs coverage, is reconsidered before it ships.
5. Development, simulator check, then Production with Joe's go-ahead, as above.

## Backlog from the review lists (2026-10-09)

- Long-distance trails split into many keys: Mountains-to-Sea Trail (55),
  Florida Trail (39), Sheltowee Trace (11), Palmetto Trail (7). Fine as
  separate nearby rows, but the card could say it is part of a longer trail.
- Dog rules: almost no ways carry them, so "informative" needs another source
  before dog access can be shown for most trails.
- Road-side paths are 3–31% of a town's named list (Florida highest). Kept on
  purpose (Joe likes "Duck Road Path"); revisit if they crowd out trails.
