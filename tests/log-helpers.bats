#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# log-helpers.bats — the GHA log directives have exactly one spelling.
#
# Run with: bats tests/log-helpers.bats

setup() {
  source "$BATS_TEST_DIRNAME/../scripts/log-helpers.bash"
}

@test "fail renders the error directive on stderr" {
  local err
  err="$(fail 'boom' 2>&1 1>/dev/null)"
  [ "$err" = "::error::boom" ]
}

@test "warn renders the warning directive on stderr" {
  local err
  err="$(warn 'careful now' 2>&1 1>/dev/null)"
  [ "$err" = "::warning::careful now" ]
}

@test "a multi-line message stays one directive line" {
  local err
  err="$(fail "$(printf 'first\nsecond')" 2>&1 1>/dev/null)"
  [ "$err" = "::error::first second" ]
}

@test "no shell driver spells a GHA directive" {
  local offenders
  offenders="$(grep -rn '::error::\|::warning::' "$BATS_TEST_DIRNAME/../scripts" 2>/dev/null \
    | grep -v 'log-helpers.bash' | grep -v '\.bats' | grep -v '__pycache__' | grep -v '\.py' || true)"
  [ "$offenders" = "" ]
}
