### Internal
- The Terms gate's tests now fail when the gate is wired wrong, not only when
  its logic is. A test audit of #222 found four broken versions that stayed
  green: Agree calling Cancel, a Terms sheet that never presents (every
  community button a dead tap), a sheet on a different view in the same file
  as the gate, and an action run outside the gate. The source scan now
  counts gates and sheets per type rather than per file; the sheet's two
  buttons are `Binding` helpers with unit tests; and a new UI smoke test
  creates a challenge with the Terms not agreed to, checks Cancel leaves the
  form untouched and Agree runs the save. That one name is over the length
  limit, so the save stops before CloudKit and the test runs offline. An
  action run outside the gate on some other screen is still not caught.
