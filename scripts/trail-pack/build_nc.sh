#!/usr/bin/env bash
# North Carolina, through the general region build (2026-10-08). The steps and
# the reasoning behind each filter moved to make_region.sh; this name stays so
# older notes and habits still work.
exec bash "$(dirname "${BASH_SOURCE[0]}")/make_region.sh" nc "$@"
