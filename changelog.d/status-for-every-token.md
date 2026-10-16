### Fixed
- Wockett Staff: featuring a nominated trail now tells every nomination of
  it that carries a claim token, not only each person's newest. The
  dashboard counts one nomination per person per trail so that one account
  can't outvote everyone, and the Feature step reused that list, so someone
  who nominated a trail from two devices (or again after a reinstall) was
  told on one device and saw Sent on the other for good. Each token belongs
  to the device that sent it, and the app now names nominations randomly,
  so this would have been the usual case for anyone with two devices. The
  Feature confirm now counts nominations (from the same query Feature
  writes from, on both the Nominations and Featured tabs) and says a
  person's other devices are included; Unfeature already withdrew every
  status of the trail and still does. Statuses still hold no token or
  nominator, so telling every device costs no privacy. The nomination queue
  still counts each person once. Comments that said CloudKit refuses a
  second nomination or walker report from one account are corrected: the
  app names those records randomly, so nothing refuses a second.
