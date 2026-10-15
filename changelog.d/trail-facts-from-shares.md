### Changed
- The Trail facts card now words each fact from how much of the whole trail
  the map data says it about, not from one OSM way per section. A pack row is
  often several ways joined together, and until trail builder 1.6.0 it kept
  only the first way's tags, so a long trail could read "Smooth" because of a
  short smooth stretch: the 24.6 km American Tobacco Trail row said
  "Smooth" and "Lit at night" from ways covering 2% of it (it now reads
  "Uneven in places", and no lighting line, since part of it is mapped unlit),
  and a 21.8 km Appalachian Trail row said "Walking path" and "Mapped as
  wheelchair accessible" from 0.9% of it (now "Rough mountain path"). Lower
  Piney Trail reads "Includes rough mountain path": 12% of it is graded
  mountain_hiking. Joe's rules and thresholds are unchanged; only their input
  is. A trail with any section from a pack built before 1.6.0 keeps the old
  per-section reading, so a missing share is never taken as silence. The
  bundled North Carolina pack is rebuilt with builder 1.6.0 from the same
  extract (only `tags_json` and two meta values differ; +0.63 MB). Downloaded
  states gain this when they are republished.
