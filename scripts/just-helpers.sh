#!/usr/bin/env bash
# just-helpers.sh — the one Justfile entrypoint: source the umbrella that sits beside
# this file, then run the named helper function with the recipe's arguments.
# That is what keeps every recipe body a single call (DESIGN.md §3: entrypoint files
# are small on purpose) — `just` 1.57 runs each recipe line in its own process, so a
# recipe needs a shell of its own only to share state, and the dispatcher is that shell.
#
# Usage: scripts/just-helpers.sh <function> [args...]
# Not for sourcing — source scripts/just-helpers.bash (the umbrella) for that.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_dir}/just-helpers.bash"
"$@"
