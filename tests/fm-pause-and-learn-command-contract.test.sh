#!/usr/bin/env bash
# Deterministic command-shape and harness-separation checks for planning mode.
set -eu

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

is_plan_request() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  [ "$value" = '/pause-and-learn plan' ]
}

is_plan_request '/pause-and-learn plan' || fail "exact planning command was refused"
is_plan_request '  /pause-and-learn plan  ' || fail "optional surrounding whitespace was refused"
if is_plan_request '/pause-and-learn plan for Example Project'; then
  fail "trailing arguments entered planning mode"
fi

scenario='Registered project: Example Project
Current thread: current tranche'
request='/pause-and-learn plan'
args=(--append-system-prompt "$scenario" "$request")
[ "${args[1]}" = "$scenario" ] || fail "scenario escaped its system-context argument"
[ "${args[2]}" = '/pause-and-learn plan' ] || fail "scenario text leaked into the user command"
is_plan_request "${args[2]}" || fail "isolated scenario changed command classification"

printf 'ok - exact plan command is isolated from scenario context and trailing arguments are refused\n'
