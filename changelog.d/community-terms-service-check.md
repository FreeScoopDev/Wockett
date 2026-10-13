### Fixed
- Nothing reaches the community without agreement to the current Terms of
  Service, even if a screen forgets to ask. Until now the agreement was only
  checked by the sheet each screen shows before its community action, so a
  button wired around that sheet would have published without agreement, and
  no test would have noticed (a test audit of #222 found exactly that gap).
  The check every public write already passes through on its way to CloudKit,
  the one that refuses suspended accounts, now also refuses one that hasn't
  agreed, and says so. It covers creating and joining challenges, posting
  achievements, sharing routes, likes and Wocketts. Trail nominations are
  left out on purpose: only moderators ever read them, and the Terms sheet
  is about what everyone can see.
