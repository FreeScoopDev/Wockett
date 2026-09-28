#!/usr/bin/env bash
#
# Decides which test jobs a change needs. Reads changed paths on stdin, one
# per line, and prints GitHub Actions outputs:
#
#   app=true|false     run the full iOS scheme (unit + UI) on a macOS runner
#   tools=true|false   run the trail-pack builder's Python tests on Linux
#
# The iOS job is skipped only when EVERY changed path is one the app build
# cannot see: documentation, changelog entries, process notes, the Python
# data pipeline and its scripts, and the Linux guard workflow. Anything else,
# including this workflow, the classifier itself, the shared toolkit config
# (.claude/app.json, which sets xcodebuild's arguments) and an empty list, runs
# the iOS job. When in doubt, run it: a skipped job that should have run is
# the failure mode this file must never produce.
#
# Break-test by hand from the repo root:
#   printf 'docs/ci.md\n' | bash .github/scripts/classify_changes.sh     # app=false
#   printf 'PoCSquat/A.swift\n' | bash .github/scripts/classify_changes.sh  # app=true
#   printf '' | bash .github/scripts/classify_changes.sh                # app=true
set -euo pipefail

app=false
tools=false
count=0

while IFS= read -r path; do
  [ -z "$path" ] && continue
  count=$((count + 1))
  case "$path" in
    tools/*) tools=true ;;
  esac
  case "$path" in
    docs/*|changelog.d/*|CHANGELOG.md|CLAUDE.md|README.md|README|prompts/*|audits/*|\
    tools/*|scripts/trail-pack/*|scripts/trail-fixture/*|\
    .github/pull_request_template.md|.github/workflows/guards.yml|\
    .gitignore|.gitattributes|.swiftlint.yml)
      ;;   # the app build cannot see these
    *)
      app=true ;;
  esac
done

# Nothing changed, or the diff could not be read: run the iOS job.
if [ "$count" -eq 0 ]; then app=true; fi

printf 'app=%s\ntools=%s\n' "$app" "$tools"
