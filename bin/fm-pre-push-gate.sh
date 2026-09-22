#!/usr/bin/env bash
# Local pre-push gate: run the checks CI runs, before the push, not after it.
#
# Usage: fm-pre-push-gate.sh
#   Runs from any directory inside a firstmate checkout. Reads nothing from
#   stdin, so it is safe to call from a git pre-push hook, which pipes its ref
#   list in; .githooks/pre-push is that hook and this script is its whole body.
#
# Why it exists: one firstmate CI run is 17 jobs, and GitHub bills every job
# rounded UP to the whole minute, so a run costs at least 17 minutes before any
# work happens and about 221 in practice. In the seven days to 2026-09-22 this
# repository spent roughly 2,650 billed minutes against 3,000 included per
# month, most of it re-running the full fan-out to discover a one-line lint or
# test failure. The same two checks take about a minute here and are free.
# CI stays the authority; this only stops it being used as the search.
#
# It is NOT the no-mistakes pre-push gate, which is the pipeline CONTRIBUTING.md
# points tracked firstmate changes at and which needs a live firstmate home.
# This is the cheap subset that runs anywhere, including a fresh clone with no
# home at all, and it never claims to replace that pipeline.
#
# Environment:
#   SKIP_GATE=1   Skip every check and exit 0. Same spelling as the captain's
#                 other repositories, so one habit covers all of them.
#
# Exit status: 0 when every check passed or the gate was skipped, 1 when a
# check failed, and 1 when a required tool is missing. A missing linter is a
# failure rather than a silent pass, because a gate that quietly checks nothing
# is worse than no gate: it teaches you to trust it.
set -eu

if [ "${SKIP_GATE:-0}" = 1 ]; then
  printf 'fm-pre-push-gate.sh: SKIP_GATE=1, skipping the local gate.\n' >&2
  exit 0
fi

if ! ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  printf 'fm-pre-push-gate.sh: not inside a git checkout.\n' >&2
  exit 1
fi
cd "$ROOT"

fail=0
step() {  # <label> <command>...
  local label=$1
  shift
  printf '\nfm-pre-push-gate.sh: %s\n' "$label" >&2
  if "$@"; then
    return 0
  fi
  printf 'fm-pre-push-gate.sh: %s FAILED\n' "$label" >&2
  fail=1
}

# Parse first: a syntax error is the cheapest failure to find and the one that
# wastes a whole CI run most often. Locally fm-lint.sh --list-files resolves to
# the changed shell files, which is exactly the set worth parsing before a push.
# shellcheck disable=SC2329 # Invoked indirectly by step() below.
parse_changed_shell() {
  local script parsed=0 bad=0
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    [ -f "$script" ] || continue
    parsed=$((parsed + 1))
    /bin/bash -n "$script" || bad=1
  done <<PARSE_INPUT
$(bin/fm-lint.sh --list-files)
PARSE_INPUT
  printf 'fm-pre-push-gate.sh: parsed %s changed shell file(s)\n' "$parsed" >&2
  [ "$bad" -eq 0 ]
}

step 'syntax-checking changed shell files' parse_changed_shell
step 'linting (bin/fm-lint.sh)' bin/fm-lint.sh
step 'running affected tests (bin/fm-test-run.sh --changed)' bin/fm-test-run.sh --changed

if [ "$fail" -ne 0 ]; then
  printf '\nfm-pre-push-gate.sh: local gate failed; push refused.\n' >&2
  printf 'fm-pre-push-gate.sh: fix the failure above, or re-push with SKIP_GATE=1 to override.\n' >&2
  exit 1
fi

printf '\nfm-pre-push-gate.sh: local gate passed.\n' >&2
exit 0
