### Changed
- On the Routes results, Start now sits in a bar under the route list once a
  route is picked, so it is always in view. Before, it was the last thing in
  the scrolling list, after every route card and the elevation chart, so a
  person who had picked a route had to scroll to find the button they came
  for: on an iPhone 17e it was at y 1228 at the default text size and y 1828
  at Accessibility 2 with real routes, on an 844 pt screen. The list gives
  the bar its height (with a floor, so it stays usable at the largest text
  sizes), so the panel covers no more of the map than before.
  Open in Apple Maps stays in the list. The saved route's Start bar and this
  one now share one style. The trail detail's Start was measured on screen
  without scrolling at both sizes on an iPhone 17e and 17, so it is unchanged.
