### Fixed
- A route's difficulty no longer turns Hard or Expert because of a few metres
  of map noise on a short, flat route. Steepness is now measured over at least
  100 m, the scale the elevation data can actually resolve: it gives one
  whole-metre height per ~90 m square, so two points a few metres apart with a
  1 m difference read as a 12-17 % slope, and the demo's flat half-mile loop
  said "Hard because one part is 17 % steep". Real steep stretches of 100 m or
  more still count as before. The climb figure and the difficulty thresholds
  are unchanged.
