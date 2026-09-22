#!/usr/bin/env bash
# Run this repository's cheap checks locally, before a push leaves the machine.
#
# Usage: fm-local-push-check.sh
#   Runs from any directory inside a firstmate checkout. Reads nothing from
#   stdin. .githooks/pre-push is the hook that calls it; that hook owns reading
#   git's ref list and passes what it learned in FM_PUSH_REFS.
#
# CONTRIBUTING.md "Development" owns why this exists and how it relates to the
# separate no-mistakes pre-push gate, which this is not. bin/fm-githooks-wire.sh
# owns how a clone comes to run it.
#
# Environment:
#   SKIP_GATE=1       Skip every check and exit 0.
#   NO_MISTAKES_GATE  Set by no-mistakes in every gate agent's environment.
#                     When present this script stands down, because that
#                     pipeline already ran lint and targeted tests for the push
#                     it is about to make. core.hooksPath is repository-wide
#                     config shared by every linked worktree (see
#                     bin/fm-githooks-wire.sh), so a pipeline worker inherits
#                     this hook whether or not anyone wired it there; standing
#                     down is what keeps that harmless.
#   FM_PUSH_REFS      The pre-push ref list, verbatim, as .githooks/pre-push
#                     read it from git. See "What gets checked" below.
#
# What gets checked: bin/fm-lint.sh, then bin/fm-test-run.sh --changed, each
# owning its own definition. Both run even when the first fails, so one push
# reports every fault rather than one per attempt.
#
# These read the WORKING TREE, so what a pass here covers is bounded twice over.
# With FM_PUSH_REFS set this script requires EVERY content-bearing ref to be the
# checked-out commit and refuses the whole push otherwise, naming the override,
# rather than passing it on the strength of the one ref that matched; that is
# why `git push --all`, a `--tags` push carrying a tag on an older commit, and
# push.default=matching are all refused here. Deletions carry no content and are
# let through untouched. The remote-side commit, when git named one, is passed
# as --base so the test selection covers exactly what is being sent, and several
# refs naming different remote-side commits widen back to the runner's own base
# rather than narrowing to one of them.
# What it does NOT establish is that the tree matches that commit. Uncommitted
# edits are what the checks actually read, so a pass describes the tree in hand,
# not the commits the push carries.
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

# Sets BASE to the remote-side commit when git named one; see the header.
BASE=
resolve_push_scope() {
  local head local_sha remote_sha commit updates=0 foreign=0 bases=0
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
    # An annotated tag's line carries the tag OBJECT's sha, never the commit
    # it names, so peel before comparing or every annotated tag reads foreign.
    commit=$(git rev-parse --verify -q "${local_sha}^{commit}" 2>/dev/null) || commit=
    if [ -z "$head" ] || [ -z "$commit" ] || [ "$commit" != "$head" ]; then
      foreign=$((foreign + 1))
      continue
    fi
    # An all-zero remote sha means the remote has no such ref yet, so there is
    # no commit to measure against and the suite runner keeps its own default.
    case "${remote_sha:-}" in
      *[!0]*) ;;
      *) continue ;;
    esac
    # The object has to be here to diff against it. A force-push to a ref this
    # clone never fetched names one that is not, and a narrower base nobody can
    # resolve is worse than the runner's own default.
    git cat-file -e "${remote_sha}^{commit}" 2>/dev/null || continue
    bases=$((bases + 1))
    if [ "$bases" -eq 1 ]; then
      BASE=$remote_sha
    elif [ "$BASE" != "$remote_sha" ]; then
      # Several refs carry HEAD from different remote positions. Narrowing to
      # one of them would leave the others' commits untested, so widen instead.
      BASE=
    fi
  done <<PUSH_REFS
${FM_PUSH_REFS}
PUSH_REFS

  if [ "$updates" -eq 0 ]; then
    say 'the push sends no commits; nothing to check.'
    exit 0
  fi
  # Every content-bearing ref has to be the commit in hand. One that is not
  # carries work these checks never read, and passing the push on the strength
  # of the rest is the false green this whole script exists to refuse.
  if [ "$foreign" -ne 0 ]; then
    say 'this push sends a commit you do not have checked out.'
    say 'these checks read the working tree, so they cannot speak for it.'
    say 'push the refs that match your checkout, or re-push with SKIP_GATE=1.'
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

# A syntax error surfaces here as a ShellCheck parse error, so there is no
# separate parse pass to keep in step with the lint definition.
step 'linting (bin/fm-lint.sh)' bin/fm-lint.sh

# Without a remote side to pin to, the suite runner keeps its own default base.
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
