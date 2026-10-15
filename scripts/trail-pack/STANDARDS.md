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
- **Fact shares** (builder 1.6.0): `N rows state a fact; M of them not one
  value over their whole length`. Rows, not trails, and "states a fact" is
  not "the card shows a fact". The per-trail numbers come from the fact
  checks below.

## Checking the trail facts (builder 1.6.0 and later)

The Trail facts card words each fact from the length shares in a row's
`tags_json` (`facts`), and from a pack's meta `fact_shares=1`, which tells
"this row states nothing" apart from "this pack is too old to say". A pack
without them falls back to the older per-section rule, silently: the card
still shows something, so nothing on screen says the shares are missing.
These checks are for review, not gates; no threshold depends on them.

**1. The pack carries shares.** Read-only, on the pack that will be
published:

```bash
sqlite3 -readonly "$WORK/packs/<region>-full.wktpack" \
  "SELECT key, value FROM meta WHERE key IN ('builder_version','fact_shares');"
```

Expect `builder_version` 1.6.0 or later and `fact_shares|1`. A pack without
`fact_shares` was built by an older builder: rebuild it, do not publish it as
a fact update.

**2. Per state: how many named trails the map data gives a fact.** Also
read-only. `trail_key` is set on named rows only, so distinct keys are named
trails:

```bash
sqlite3 -readonly "$WORK/packs/<region>-full.wktpack" <<'SQL'
SELECT count(DISTINCT trail_key) AS named_trails,
       count(DISTINCT CASE WHEN json_extract(tags_json,'$.facts') IS NOT NULL
                           THEN trail_key END) AS stating_any_fact
FROM trails WHERE trail_key IS NOT NULL;
SELECT s.key AS tag, count(DISTINCT t.trail_key) AS named_trails_stating_it
FROM trails t, json_each(t.tags_json,'$.facts.shares') s
WHERE t.trail_key IS NOT NULL
GROUP BY s.key ORDER BY 2 DESC;
SQL
```

This is a ceiling, not what users see: the card applies Joe's rules (0.8 of
the length for a plain claim, 0.25 for "in places", a veto when any section
says otherwise), so fewer trails show a fact than state one. On the bundled
NC pack (2026-10-15): 2,850 of 4,688 named trails state a fact; 1,886
(40.2%) show one on the card. A pre-1.6.0 pack prints 0 for the second
number, which is how the query was checked.

**Not yet a script: the share that would show at least one fact.** The
1,886 above came from a Python copy of the card's rules that was not kept
(#242). The repo has no tool that prints it per state. The one to write is
read-only and runs the app's own rules rather than a copy, because a copy
drifts the first time a rule changes and keeps printing a plausible number:
a `WockettTests` test that opens the pack named in an environment variable
through `BundledTrailSource`, builds every trail key's `TrailFacts`, and
prints the trails showing at least one fact and the count for each fact
(path type, shared use, surface, marking, wheelchair, lit, maintainer). It
must skip when the variable is unset, so CI never runs it. Until it exists,
print query 2 for each state and say in the review that the card's number
was not measured.

**3. Two real rows on the simulator.** After the Development publish and
before Production, open two trails' cards in a Debug build of `main` (it
must include #242, or the app ignores the shares): one long trail merged from
many ways, and one with several graded sections. These queries find them:

```bash
sqlite3 -readonly "$WORK/packs/<region>-full.wktpack" <<'SQL'
-- Long rows whose ways disagree along their length
SELECT t.name, t.trail_key, round(t.length_m/1000,1) AS km
FROM trails t
WHERE (SELECT count(*) FROM json_each(t.tags_json,'$.facts.shares') s
       WHERE (SELECT count(*) FROM json_each(s.value)) > 1) > 0
ORDER BY t.length_m DESC LIMIT 3;
-- Rows with two or more stated grades
SELECT t.name, t.trail_key, round(t.length_m) AS m,
       json_extract(t.tags_json,'$.facts.shares.sac_scale') AS sac_scale
FROM trails t
WHERE (SELECT count(*) FROM json_each(t.tags_json,'$.facts.shares.sac_scale')
       WHERE key <> 'unstated') >= 2
ORDER BY t.length_m DESC LIMIT 5;
SQL
```

The card sums every row of the trail key, not just the row the query
found, so work out what it should say from all of that key's rows
(`SELECT name, length_m, tags_json FROM trails WHERE trail_key = '<key>'`)
before looking, then compare. In NC the worked examples are an Appalachian
Trail row (`hiking` on 0.9% of 21.8 km: "Rough mountain path" on its own,
where the flat tags said "Walking path") and Lower Piney Trail (1,569 m
`hiking` + 216 m `mountain_hiking`: "Includes rough mountain path"); #242
lists them. A card that reads as if only one way's tags existed means the
shares were not read: stop before Production.

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
| 1.6.0 | Fact shares: for `sac_scale`, `smoothness`, `trail_visibility`, `wheelchair`, `lit`, `foot` and `operator`, each row's `tags_json` carries `facts`, the share of its length stating each value (summed over every way merged into it, "unstated" for the rest, exactly 1 per tag) and the worst and best value on OSM's scale. Before, a merged row kept one way's tags. Flat tags, columns, ids, keys and names are unchanged; `verify_pack` refuses shares that do not sum to 1 |

Source filters in `make_region.sh`: sidewalks, traffic islands and
`access=private/no/military` never enter the build.

## Adding a state

1. Add a row to `tools/regions.json`: name, Geofabrik path, probe city (the
   largest city), `bundled: false`.
2. `make_region.sh <region>`. If a gate fails, the state waits. Look at the
   towns without a trail and the review lists before changing any threshold.
3. Fact checks 1 and 2 above: builder 1.6.0 or later, `fact_shares=1`, and
   the per-state counts in the review.
4. `region_publish.py publish <region>` (Development). On the simulator,
   download it and check the Trails list in the probe city **and one small
   town**, and the two cards from fact check 3. Under `-WKTUITest` each
   launch starts with an empty pack folder and the list is centred on
   Raleigh, so download inside the same launch and override the centre
   temporarily (never committed).
5. Production only with Joe's go-ahead, and with a fresh cktool token (it
   expires within hours; Joe renews it in his own Terminal):
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
   Print the fact checks too, against the archived published pack where it
   has shares.
5. Development, simulator check (including the two fact cards), then
   Production with Joe's go-ahead and a fresh cktool token, as above.

**Fact shares reach a published state only when it is republished.** The
states live in Production on 2026-10-15 were all built before 1.6.0, so
their rows carry no shares and the card uses the per-section rule for them.
Republishing them with 1.6.0 is a material change in the sense of step 1,
but it waits for the app release that reads the shares (1.17): apps before
it ignore them, so an earlier republish gains users nothing and spends a
version. Then one state at a time, each through Development, the simulator
check and its own go-ahead from Joe: NC (bundled) first, then SC, VA, TN,
GA, then FL, AL, KY, WV, MD, then the New England states. A new state built
by 1.6.0 carries shares from the start, and older apps read it as before.

## Backlog from the review lists (2026-10-09)

- Long-distance trails split into many keys: Mountains-to-Sea Trail (55),
  Florida Trail (39), Sheltowee Trace (11), Palmetto Trail (7). Fine as
  separate nearby rows, but the card could say it is part of a longer trail.
- Dog rules: almost no ways carry them, so "informative" needs another source
  before dog access can be shown for most trails.
- Road-side paths are 3–31% of a town's named list (Florida highest). Kept on
  purpose (Joe likes "Duck Road Path"); revisit if they crowd out trails.

## Backlog from the New England check (2026-10-14)

- Boston's Freedom Trail lists as a 0.3 mi piece, not the ~2.5 mi trail: the
  long-trail splitting above, in a city centre.
- "Childs Park Road B" (a park road, Northampton MA) is the first row of the
  town's list: a candidate for the generic or road-name rules.
