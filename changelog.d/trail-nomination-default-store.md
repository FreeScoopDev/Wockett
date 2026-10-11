### Internal
- `TrailNominationSubmission.submit` no longer builds a warning. The app's
  code runs on the main actor by default, and a default argument is
  evaluated in the caller's context, so two of its defaults touched the main
  actor from a nonisolated one (Swift 6 makes both errors): the CloudKit
  store's initializer and the `deadline` constant. The nomination sheet now
  owns the store and passes it in, the way the report sheet already does,
  and `deadline` is `nonisolated`, like the other constants used that way.
