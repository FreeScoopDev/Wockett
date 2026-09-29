# Changelog entries

Each change adds **one new file here** instead of editing `CHANGELOG.md`. Two
open PRs that both edit `CHANGELOG.md` conflict at the same line every time,
and a conflicted PR cannot merge until it is fixed. Two PRs that each add a new file never
conflict.

## Format

Name the file after the branch, without its prefix:
`fix/trail-pack-bad-install-fallback` → `trail-pack-bad-install-fallback.md`.

The content is the entry exactly as it will appear in `CHANGELOG.md`: one or
more [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) headings, each
with its bullets. Explain *why*, not just what.

```markdown
### Fixed
- A downloaded trail pack that cannot be opened no longer takes the bundled
  North Carolina trails with it. …
```

Headings, in the order `CHANGELOG.md` uses: `Added`, `Changed`, `Fixed`,
`Internal`.

## At release

The release PR moves every file's bullets into `[Unreleased]` under the
matching heading, deletes the files (this README stays), then cuts
`[Unreleased]` into the new version. `CHANGELOG.md` is only edited there.
