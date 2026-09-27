#!/usr/bin/env bats

@test "the clean script greets" {
  run bash "${BATS_TEST_DIRNAME}/../scripts/clean.sh" ci
  [ "$status" -eq 0 ]
  [ "$output" = "hello, ci" ]
}
