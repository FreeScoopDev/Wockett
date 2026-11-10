### Fixed
- A route's difficulty no longer turns Hard or Expert because of a few metres
  of map noise on a short, flat route. Steepness is now measured over at least
  100 m, the scale the elevation data can actually resolve: it gives one
  whole-metre height per ~90 m square, so two points a few metres apart with a
  1 m difference read as a 12-17 % slope, and the demo's flat half-mile loop
  said "Hard because one part is 17 % steep". Real steep stretches well over 100 m
  still count as before; a steep part only about 100 m long can read a few
  points lower than it did. The climb figure and the difficulty thresholds
  are unchanged.
