### Internal
- Changelog entries now go in their own file in `changelog.d/`, one per change, and the release PR gathers them into `CHANGELOG.md`. On 2026-09-27 three PRs in a row (#90, #91, #92) conflicted at the same line of `[Unreleased]`, because each open PR added its entry there. A conflicted PR cannot merge until someone fixes it. `changelog.d/README.md` has the format.
