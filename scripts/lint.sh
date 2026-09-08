#!/usr/bin/env bash
#
# The canonical way to run SwiftLint on Wockett.
#
# Why this exists:
#   SwiftLint resolves `excluded:` paths relative to THE CONFIG FILE'S OWN
#   DIRECTORY. Running `swiftlint --config /somewhere/else.yml` therefore
#   resolves `WockettTests` to `/somewhere/else/WockettTests`, matches nothing,
#   and silently lints the test targets that .swiftlint.yml means to exclude.
#   That inflates every count. On 2026-09-07 this produced two wrong violation
#   figures before anyone noticed, because the output looks completely normal.
#
#   This script always runs from the repo root with the in-place config, and
#   then asserts the exclusions actually took effect.
#
# Usage:
#   scripts/lint.sh          # report violations
#   scripts/lint.sh --fix    # autocorrect, then MUST be followed by scripts/test.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint not installed. brew install swiftlint" >&2
  exit 1
fi

if [[ "${1:-}" == "--fix" ]]; then
  echo "WARNING: swiftlint --fix has broken this build before."
  echo "  redundant_discardable_let rewrote 'let _ = x' inside a @ViewBuilder"
  echo "  empty_count rewrote a count>0 check on XCUIElementQuery, which has no isEmpty"
  echo "Both are disabled in .swiftlint.yml now, but ALWAYS run scripts/test.sh after."
  echo
  swiftlint --fix
  echo
  echo "Now run: scripts/test.sh"
  exit 0
fi

OUT="$(swiftlint lint --quiet 2>/dev/null || true)"

# Two independent checks that the config was actually applied.
#
# The expected list is HARDCODED on purpose. Deriving it from .swiftlint.yml
# would be circular: if the config is not being read, it is not read for the
# expectations either, and the check passes vacuously. That is an assertion
# that cannot fail — which is worse than no assertion, because it counts as
# coverage. (Verified: this guard fires when .swiftlint.yml is renamed away.)
EXPECTED_EXCLUDED="WockettTests prompts docs"

# 1. Config drift — the hardcoded list must still match the file.
ACTUAL_EXCLUDED=$(awk '/^excluded:/{f=1;next} /^[^ -]/{f=0} f&&/^ *- /{gsub(/^ *- */,"");print}' .swiftlint.yml 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
SORTED_EXPECTED=$(tr ' ' '\n' <<<"$EXPECTED_EXCLUDED" | sort | tr '\n' ' ' | sed 's/ $//')
if [[ "$ACTUAL_EXCLUDED" != "$SORTED_EXPECTED" ]]; then
  echo "ABORT: .swiftlint.yml excluded list changed." >&2
  echo "  expected: $SORTED_EXPECTED" >&2
  echo "  found:    $ACTUAL_EXCLUDED" >&2
  echo "Update EXPECTED_EXCLUDED in this script to match, deliberately." >&2
  exit 2
fi

# 2. The exclusions are in effect — independent of what the config says.
for excluded in $EXPECTED_EXCLUDED; do
  if grep -q "/${excluded}/" <<<"$OUT"; then
    echo "ABORT: violations reported inside excluded path '${excluded}/'." >&2
    echo "The config was not applied from the repo root — counts are unreliable." >&2
    exit 2
  fi
done

TOTAL=$(grep -c . <<<"$OUT" || true)
SERIOUS=$(grep -c ": error:" <<<"$OUT" || true)

echo "SwiftLint: $TOTAL violations, $SERIOUS at error severity"
echo "(exclusions verified in effect)"
echo
if [[ "$SERIOUS" -gt 0 ]]; then
  echo "--- error severity, by rule ---"
  grep ": error:" <<<"$OUT" | grep -oE '\(([a-z_]+)\)$' | sort | uniq -c | sort -rn
  echo
  echo "These are what will gate merges once continue-on-error is removed"
  echo "from the swiftlint job in .github/workflows/guards.yml."
fi
