#!/usr/bin/env bash
# Behavioral regressions for the local exact-head no-mistakes attestation gate.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-no-mistakes-attestation.sh"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"},{"step":"lint","status":"completed"}]'

body_for() {
  local head=$1 steps=${2:-$COMPLETED_STEPS}
  printf '%s\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":%s} -->\n' \
    "$SIGNATURE" "$head" "$steps"
}

run_verifier() {
  local body=$1 head=$2
  printf '%s' "$body" | "$VERIFY" "$head" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local output rc=0
  output=$(run_verifier "$(body_for "$NEW_SHA")" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "local verifier rejected an attestation bound to the current PR head"
  assert_contains "$output" "verified no-mistakes local validation at head $NEW_SHA" \
    "local verifier did not report the exact validated head"
  pass "local attestation accepts an exact head with every authoritative phase completed"
}

test_mismatched_or_missing_head_fails() {
  local output rc
  rc=0
  output=$(run_verifier "$(body_for "$OLD_SHA")" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "local verifier accepted an attestation from a different PR head"
  assert_contains "$output" "malformed, stale" \
    "mismatched-head failure did not identify stale or malformed evidence"

  rc=0
  output=$(run_verifier "$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "local verifier accepted an attestation without head_sha"
  pass "local attestation rejects a mismatched or missing head"
}

test_missing_skipped_or_duplicate_phase_fails() {
  local label steps output rc
  set -- \
    'missing|[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]' \
    'skipped|[{"step":"review","status":"completed"},{"step":"test","status":"skipped"},{"step":"document","status":"completed"},{"step":"lint","status":"completed"}]' \
    'duplicate|[{"step":"review","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"},{"step":"lint","status":"completed"}]'
  for label_steps in "$@"; do
    label=${label_steps%%|*}
    steps=${label_steps#*|}
    rc=0
    output=$(run_verifier "$(body_for "$NEW_SHA" "$steps")" "$NEW_SHA") || rc=$?
    [ "$rc" -ne 0 ] || fail "local verifier accepted a $label authoritative phase"
    assert_contains "$output" "missing a completed local review, test, document, or lint phase" \
      "$label-phase refusal did not name the local validation requirement"
  done
  pass "local attestation rejects missing, skipped, and duplicate authoritative phases"
}

test_duplicate_marker_or_signature_fails() {
  local body output rc
  body=$(body_for "$NEW_SHA")
  rc=0
  output=$(run_verifier "$body
$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "local verifier accepted duplicate signatures and markers"
  assert_contains "$output" "expected exactly one no-mistakes pipeline signature" \
    "duplicate refusal did not identify ambiguous evidence"
  pass "local attestation refuses ambiguous duplicate evidence"
}

test_matching_head_and_completed_steps_pass
test_mismatched_or_missing_head_fails
test_missing_skipped_or_duplicate_phase_fails
test_duplicate_marker_or_signature_fails
