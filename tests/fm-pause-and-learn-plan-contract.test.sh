#!/usr/bin/env bash
# Deterministic public-contract regression for /pause-and-learn plan output.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/tests/pause-and-learn-plan-check.py"
FIXTURES="$ROOT/tests/fixtures/pause-and-learn-plan"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

python3 "$CHECK" "$FIXTURES/control.txt" false next-tranche \
  || fail "canonical plan was rejected"
python3 "$CHECK" "$FIXTURES/reordered-wrapped.txt" true next-tranche \
  || fail "semantically identical reordered and wrapped plan was rejected"
if python3 "$CHECK" "$FIXTURES/unsafe-start.txt" false next-tranche > /dev/null 2>&1; then
  fail "a plan that starts the queued tranche was accepted"
fi

printf 'ok - plan contract accepts ordering and wording variants while rejecting unsafe positive behavior\n'
