### Fixed
- Hiding a shared route's start and finish gives the same path every time.
  It measured distances with `CLLocation.distance(from:)`, which keeps one
  process-wide cache of the scale at a latitude and reuses it for any point
  within 0.005° of it, so its answer depended on whatever distance any other
  part of the app had measured last. The share preview and the record
  `CommunityRouteService` publishes are trimmed separately, and could differ
  by centimetres, or by a whole point where the 10 m spacing or a privacy
  zone's edge fell between the two answers. `SharedRouteTrim.distance` is
  now its own WGS 84 calculation, within 0.1 mm of an exact geodesic up to
  1 km. Found when `SharedRouteTrimTests/publicRecord()` failed in CI on
  2026-10-13 with every published point 1-3 cm from a direct trim of the
  same route, because tests running alongside it moved that cache.
