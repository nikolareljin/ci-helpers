#!/usr/bin/env bats

# Separate directory from tests/, so the passing leg and the must-fail leg can
# each point at exactly one of them.
@test "this test is meant to fail" {
  run bash -c 'exit 3'
  [ "$status" -eq 0 ]
}
