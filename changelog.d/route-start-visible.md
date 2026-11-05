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
  one now share one style. A trail's Start, shown when you are at the trail,
  moves into the same kind of bar: it was already on screen, but at
  Accessibility 2 on an iPhone 17e it cleared the tab bar by 4.7 pt under a
  two-line trail name, so a longer name hid it. The Distance | Time choice
  and the line describing the walk stay in the scrolling details.
