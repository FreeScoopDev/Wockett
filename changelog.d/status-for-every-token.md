### Fixed
- Wockett Staff: featuring a nominated trail now tells each device that
  nominated it, not only each person's newest nomination. The dashboard
  counts one nomination per person per trail so that one account can't
  outvote everyone, and the Feature step reused that list. Each claim token
  belongs to the device that sent it, so once the app names nominations
  randomly (the contribution-status app release; until then a second
  device's nomination from the same account is refused), someone who
  nominated a trail from two devices would have been told on one and seen
  Sent on the other for good. Each person counts for at most 5 devices per
  trail, because anyone can create nominations with tokens of their
  choosing, and without a cap one account could make Feature write
  thousands of public records. The Feature confirm now counts nominations
  (from the same query Feature writes from, on both the Nominations and
  Featured tabs) and says a person's other devices are included; Unfeature
  and History count nominations too. Unfeature already withdrew every
  status of the trail and still does. Statuses still hold no token or
  nominator, so telling every device costs no privacy. The nomination queue
  still counts each person once. Comments that said CloudKit refuses a
  second walker report or nomination from one account are corrected: the
  app names walker reports randomly, and nominations from the
  contribution-status app release.
