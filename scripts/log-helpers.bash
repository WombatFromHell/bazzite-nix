#!/usr/bin/env bash
# log-helpers.bash — one home for the GitHub Actions log directives.
#
# A `::error::` / `::warning::` prefix is a protocol detail: spelled per call site it can
# drift (`::warn` renders as prose), and a message containing a newline silently stops being
# a directive at all. So both live here, on stderr, flattened to one line.
#
# Usage: source scripts/log-helpers.bash

# Report a problem the run log should mark as an error. Never fatal by itself — callers
# decide whether the run continues.
# Usage: fail <message>
# Prints: one `::error::<message>` line on stderr
fail() {
  local message="${1:?message required}"
  printf '::error::%s\n' "${message//$'\n'/ }" >&2
}

# Report a problem the run can carry on past.
# Usage: warn <message>
# Prints: one `::warning::<message>` line on stderr
warn() {
  local message="${1:?message required}"
  printf '::warning::%s\n' "${message//$'\n'/ }" >&2
}
