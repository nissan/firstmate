#!/usr/bin/env bash
# Deterministic public-contract regression for /pause-and-learn plan output.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/.agents/skills/pause-and-learn/plan-check.py"
FIXTURES="$ROOT/tests/fixtures/pause-and-learn-plan"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

reject() {
  local fixture=$1 cycle=$2 message=$3
  if python3 "$CHECK" validate "$FIXTURES/$fixture" "$cycle" next-tranche > /dev/null 2>&1; then
    fail "$message"
  fi
}

python3 "$CHECK" validate "$FIXTURES/control.txt" false next-tranche \
  || fail "canonical plan was rejected"
python3 "$CHECK" validate "$FIXTURES/reordered-wrapped.txt" true next-tranche \
  || fail "semantically identical reordered and wrapped plan was rejected"

reject unsafe-start.txt false "a plan that starts the queued tranche was accepted"
reject control.txt true "a fresh-cycle plan satisfied an existing-cycle expectation"
reject negated-boolean.txt false "a numeric zero passed as a mutation flag"
reject stringified-boolean.txt false "a stringified boolean passed as a safety flag"
reject duplicate-block.txt false "a second contradicting plan block was accepted"
reject malformed-json.txt false "an unparseable plan block was accepted"
reject missing-block.txt false "prose alone satisfied the machine-readable contract"

printf 'ok - plan contract accepts ordering and wording variants while rejecting unsafe and malformed plans\n'
