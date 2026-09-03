#!/usr/bin/env bash
# Deterministic regression for the command classification the skill relies on.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/.agents/skills/pause-and-learn/plan-check.py"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

classify() {
  python3 "$CHECK" classify "$1"
}

[ "$(classify '/pause-and-learn plan')" = plan ] \
  || fail "exact planning command was not read-only planning mode"
[ "$(classify '  /pause-and-learn plan  ')" = plan ] \
  || fail "optional surrounding whitespace was refused"
[ "$(classify '/pause-and-learn plan for Example Project')" = refuse ] \
  || fail "trailing arguments were not refused"
[ "$(classify '/pause-and-learn plan ')" = plan ] \
  || fail "a trailing space was treated as an argument"
[ "$(classify '/pause-and-learn')" = cycle ] \
  || fail "the bare command was not the ordinary mutating cycle"
[ "$(classify '/pause-and-learn Example Project')" = cycle ] \
  || fail "a scoped cycle invocation changed classification"

scenario='Registered project: Example Project
Current thread: current tranche'
[ "$(classify "$scenario")" = none ] \
  || fail "scenario context alone classified as a command"
[ "$(classify "/pause-and-learn plan
$scenario")" = refuse ] \
  || fail "scenario text appended to the command entered planning mode"

if python3 "$CHECK" classify > /dev/null 2>&1; then
  fail "classifier accepted a missing command argument"
fi

printf 'ok - only the exact no-argument plan command is read-only and trailing arguments are refused\n'
