### Changed
- Trail pack builder 1.3.2, from building Florida, Alabama, Kentucky, West Virginia and Maryland (2026-10-08):
  - A military installation's name on the ways inside it is not a trail name. Eglin Air Force Base was 193 tracks, 369 km, listed as one trail; most carry no access tag, so the name is the only signal. Such ways are kept as unnamed paths, since parts of some bases are open with a permit.
  - Ways tagged `access=military` are dropped, as `private` and `no` already are.
  - A name with no letter or digit ("???", 29 trails across the batch) counts as unnamed.
  - More descriptions count as unnamed: "Multi-Modal Path" (86 pieces in one Florida county, and misspelt "Multi-Model Path" in the next), "Tunnel", "Farm Road", "Forest Road", "National Forest Road", "Power Line Road", "Tram Road".
  - 1 new builder test; removing the installation rule or the no-letters rule each turns it red.
