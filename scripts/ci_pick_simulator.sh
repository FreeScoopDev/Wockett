#!/usr/bin/env bash
# Thin wrapper. The implementation is shared with Joe's other apps and lives in
# ~/.claude/toolkit/bin/ci_pick_simulator.sh, driven by this repo's .claude/app.json.
# CI does not use this script, so a clone without the toolkit still builds.
set -euo pipefail
TOOLKIT="${APP_TOOLKIT:-$HOME/.claude/toolkit}"
if [[ ! -x "$TOOLKIT/bin/ci_pick_simulator.sh" ]]; then
  echo "Shared toolkit not found at $TOOLKIT (set APP_TOOLKIT to override)." >&2
  exit 1
fi
exec "$TOOLKIT/bin/ci_pick_simulator.sh" "$@"
