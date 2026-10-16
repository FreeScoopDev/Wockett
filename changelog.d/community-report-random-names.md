### Fixed
- A report of a post, route or challenge, and a challenge owner's request to
  delete one, is now saved under a random name. The name used to be worked
  out from the item and the reporter's account, both of which anyone can see,
  so anyone could work it out and use it to tell whether that account had
  reported the item. The phone now remembers
  what it has sent itself: reporting the same item again from it still says
  "You've already reported this", and asking to delete the same challenge
  twice in a day still says you've asked today, without saving a second
  record. A report from another device is saved, and the staff dashboard
  counts each person once per item. A save that fails for any reason now
  offers the email, rather than reading a name clash as "already reported".
