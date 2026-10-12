### Added
- **Share a challenge.** A challenge's screen has a Share Challenge button
  that sends an invitation through the iOS share sheet (Messages, Mail,
  social apps): the challenge's name, its goal and length in plain words
  ("run 10 km in 7 days", "3 runs at 8:00/km pace or faster in 14 days"),
  and the challenge's link (see Challenge links). Until now the only way
  into a challenge was to come across it in the list, so a challenge could
  not be used to invite friends. Distance and pace use the sharer's units,
  and the message says "my" challenge only to the person who created it.

### Internal
- Wockett's App Store link is one constant (`AppStoreLink`), used by the
  challenge invitation, the activity share card and Settings' Write a
  Review, instead of three hand-copied strings that could drift apart.
