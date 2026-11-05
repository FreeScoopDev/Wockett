### Internal
- GitHub Actions workflows declare a read-only token and pin every action to
  a commit (the version in a comment), as PlowR's already did: a moved tag
  can't change what runs, and no job can push or comment. `.gitignore` keeps
  Apple signing keys and profiles out of git. The staff dashboard page carries
  a Content Security Policy, so a script that ever slipped into it could not
  load code from, or send data to, anywhere but Apple's CloudKit.
