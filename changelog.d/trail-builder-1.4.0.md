### Changed
- Trail pack builder 1.4.0 decides which ways are worth listing. Measured over 1,563 towns in the ten published states (2026-10-08), 50-77% of a town's Trails list was unnamed paths or dirt roads, and 80% of the long unnamed rows were `highway=track`: farm, logging and forest roads, much of it on private land OSM does not mark private. Joe's rules, 2026-10-08:
  - An unnamed dirt road is left out unless the map says it is open (foot, bicycle, horse or access yes/permissive/designated), or it comes within 100 m of an official trailhead (`highway=trailhead`, now exported by `make_region.sh`).
  - A dirt road with a street name ("Tranquil Drive Southeast", "Holly", "Holly Way") is left out on the same terms. One with a trail-like name ("Bear Creek Trail") stays: dirt roads can be trails.
  - A bike path is walkable unless it says `foot=no`. The old default marked every `highway=cycleway` without a foot tag as closed to walkers: about 2,600 rail trails and greenways across the ten packs, Florence's Rail Trail among them. A bike-only path stays in the pack for Ride.
  - A way closed to both walking and riding is left out.
  - Effect on the rebuilt packs: Virginia 91,214 rows to 20,320, North Carolina 34,422 to 17,253, the bundled NC pack 8,407 to 6,373; every state still passes its gates.
  - 5 new builder tests. Removing each rule (dirt roads, the trailhead exemption, "way" as a street word, the bike-path default, the closed-way rule) turned its test red.
