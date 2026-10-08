### Changed
- A trail in the Trails list is one trail, whole. Joe, 2026-10-08: "I don't want there to be a bunch of trail segments for one trail listed as individual trails." Using the trail keys the 1.3.0 packs carry (#141):
  - The list groups a trail's pieces by its key, the pack builder's grouping over the whole region, so pieces of one trail are one row however far apart they are; packs without keys group by name and distance as before.
  - A row is completed with the rest of its trail (`TrailDataSource.trails(key:)`), so its length and map are the whole trail, not just the pieces within the 10-mile search; the length filters judge that whole length.
  - Cards read "3.9 mi · 0.9 mi away" instead of "3.9 mi · 6 sections · 0.9 mi away", and a trail's detail no longer lists "Section 1 … Section 6" or calls a trail in several pieces "6 sections". The list's "List sections separately" option still shows the pieces.
  - The same path from two neighbouring state packs (Geofabrik extracts keep ways that cross the state line) is listed once, the nearest copy.
  - Settings → Trail Regions no longer reads as North Carolina only: "North Carolina's named trails come with Wockett. Download a state for all of its trails, unnamed paths included."
  - 9 new tests; disabling key grouping, completion, de-duplication, or restoring the sections wording each turned theirs red. All 155 trail tests pass.
