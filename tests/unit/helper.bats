#!/usr/bin/env bats
# Bats fails a test through errexit and reports it from its EXIT trap. If load_script loses either, an assertion in any
# test that uses it can't fail, and the test still says ok. So these two check with exit, not an assertion.
load ../helpers
@test "load_script leaves assertions working" {
  load_script ap-tools
  [[ $- == *e* ]] || exit 1
}
@test "load_script keeps bats' own traps" {
  load_script ap-tools
  [[ "$(trap -p EXIT)" == *bats* ]] || exit 1
}
