#!/usr/bin/env bash
# Run this repository's cheap checks locally, before a push leaves the machine.
#
# Usage: fm-local-push-check.sh
#   Runs from any directory inside a firstmate checkout. Reads nothing from
#   stdin. .githooks/pre-push is the hook that calls it; that hook owns reading
#   git's ref list and passes what it learned in FM_PUSH_REFS.
#
# Why it exists: GitHub bills every CI job rounded UP to the whole minute, and
# this repository's CI fans out across every lane on each run, so a push that
# only needed a one-line lint fix costs the same as a full green run. Running
# the same checks here first makes CI a confirmation instead of a search. CI
# stays the authority.
#
# This is NOT the no-mistakes pipeline that CONTRIBUTING.md points tracked
# firstmate changes at. It runs a strict subset, it needs no firstmate home,
# and it stands down entirely inside that pipeline (see NO_MISTAKES_GATE
# below), which owns lint and tests for the pushes it drives.
#
# Environment:
#   SKIP_GATE=1       Skip every check and exit 0.
#   NO_MISTAKES_GATE  Set by no-mistakes in every gate agent's environment.
#                     When present this script stands down, because that
#                     pipeline already ran lint and targeted tests for the push
#                     it is about to make. core.hooksPath is repository-wide
#                     git config shared by every linked worktree, so a pipeline
#                     worker inherits the hook whether or not anyone wired it
#                     there; standing down here is what keeps that harmless.
#   FM_PUSH_REFS      The pre-push ref list, verbatim, as .githooks/pre-push
#                     read it from git. See "What gets checked" below.
#
# What gets checked: this script inspects the WORKING TREE, which is only the
# same thing as the push when the push carries the checked-out commit. With
# FM_PUSH_REFS set it proves that rather than assuming it: a push that updates
# no ref it can tie to HEAD is refused, naming the override, instead of being
# waved through on the strength of an unrelated clean tree. Deletions carry no
# content and are let through untouched.
#
# Known limits, so a refusal here is recognisable rather than mysterious:
#   - bin/fm-test-run.sh --changed counts untracked, non-ignored files as
#     changed and refuses a path it has no suite mapping for, so an unrelated
#     scratch file left in the checkout refuses the push until it is removed,
#     ignored, or SKIP_GATE=1 is passed. That strictness is fm-test-run.sh's
#     own contract and is not softened here.
#   - On main, and on a branch with no merge-base, bin/fm-lint.sh lints its
#     full canonical set rather than the changed files (its header owns why),
#     so a push from main is the slow case.
#
# Exit status: 0 when every check passed, when the gate stood down, or when the
# push carries nothing to check; 1 when a check failed, when a required tool is
# missing, or when the push cannot be tied to the working tree. A check that
# cannot run is a failure rather than a silent pass, because a gate that
# quietly checks nothing is worse than no gate: it teaches you to trust it.
set -eu

say() { printf 'fm-local-push-check.sh: %s\n' "$1" >&2; }

if [ "${SKIP_GATE:-0}" = 1 ]; then
  say 'SKIP_GATE=1, skipping the local checks.'
  exit 0
fi

if [ "${NO_MISTAKES_GATE+x}" = x ]; then
  say 'no-mistakes owns this push; standing down.'
  exit 0
fi

if ! ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  say 'not inside a git checkout.'
  exit 1
fi
cd "$ROOT"

# Resolve the push against the working tree. Sets BASE to the remote-side commit
# when git named one, so the test selection covers exactly what is being pushed.
BASE=
resolve_push_scope() {
  local head local_sha remote_sha updates=0 matched=0
  [ "${FM_PUSH_REFS+x}" = x ] || return 0

  head=$(git rev-parse HEAD 2>/dev/null) || head=
  while read -r _ local_sha _ remote_sha; do
    [ -n "${local_sha:-}" ] || continue
    # An all-zero local sha is a deletion: no content is being sent.
    case "$local_sha" in
      *[!0]*) ;;
      *) continue ;;
    esac
    updates=$((updates + 1))
    [ -n "$head" ] && [ "$local_sha" = "$head" ] || continue
    matched=1
    # An all-zero remote sha means the remote has no such ref yet, so there is
    # no commit to measure against and the suite runner keeps its own default.
    case "${remote_sha:-}" in
      *[!0]*) BASE=$remote_sha ;;
    esac
  done <<PUSH_REFS
${FM_PUSH_REFS}
PUSH_REFS

  if [ "$updates" -eq 0 ]; then
    say 'the push sends no commits; nothing to check.'
    exit 0
  fi
  if [ "$matched" -eq 0 ]; then
    say 'this push does not include the commit you have checked out.'
    say 'these checks read the working tree, so they cannot speak for it.'
    say 'check out what you are pushing, or re-push with SKIP_GATE=1.'
    exit 1
  fi
}

resolve_push_scope

fail=0
step() {  # <label> <command>...
  local label=$1
  shift
  printf '\nfm-local-push-check.sh: %s\n' "$label" >&2
  if "$@"; then
    return 0
  fi
  say "$label FAILED"
  fail=1
}

# bin/fm-lint.sh is the single owner of the lint definition, including which
# files it selects and how; a syntax error surfaces here as a ShellCheck parse
# error, so there is no separate parse pass to keep in step with it.
step 'linting (bin/fm-lint.sh)' bin/fm-lint.sh

# bin/fm-test-run.sh owns suite selection. --base pins it to the commits this
# push actually adds when git told us the remote side; without that it falls
# back to its own default base.
if [ -n "$BASE" ]; then
  step 'running affected tests (bin/fm-test-run.sh --changed)' \
    bin/fm-test-run.sh --changed --base "$BASE"
else
  step 'running affected tests (bin/fm-test-run.sh --changed)' \
    bin/fm-test-run.sh --changed
fi

if [ "$fail" -ne 0 ]; then
  printf '\n' >&2
  say 'a check failed; push refused.'
  say 'fix the failure above, or re-push with SKIP_GATE=1 to override.'
  exit 1
fi

printf '\n' >&2
say 'local checks passed.'
exit 0
