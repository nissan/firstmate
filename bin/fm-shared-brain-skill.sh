#!/usr/bin/env bash
# Resolve an authoritative skill from the registered shared-brain project clone.
# This is discovery only: it never clones, fetches, checks out, or modifies the source.
# Usage: fm-shared-brain-skill.sh pause-and-learn
set -eu
# Every refusal below is a git answer about the registered local copy, so those
# answers must come from the filesystem rather than the caller's environment.
# `git -C` only changes directory: an inherited GIT_DIR/GIT_WORK_TREE - which
# git exports into every hook environment - would make the clean, untracked, and
# identity checks describe an unrelated checkout, and inherited config carriers
# like GIT_CONFIG_PARAMETERS (git exports that one too) can point core.excludesFile
# at a broad pattern so the untracked check reports a dirty copy as clean. CDPATH
# would redirect the relative `cd` below the same way. Clear the whole class once
# so every later git call inherits it.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS

SCRIPT_DIR="$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_NAME=shared-brain
REQUIRED_COMMIT=29099a5f40c28e2f09fec157b7f49816e3e41971
if [ "${FM_TESTING:-0}" = 1 ] && [ -n "${FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT:-}" ]; then
  REQUIRED_COMMIT=$FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT
fi
SKILL=${1:-}

if [ "$SKILL" != pause-and-learn ]; then
  echo "error: usage: fm-shared-brain-skill.sh pause-and-learn" >&2
  exit 2
fi
# The registry, the clone, and the printed source path are all named relative to
# this home, and the caller reads that path from wherever it happens to be
# standing, so the home has to become an absolute physical directory here. The
# refusals never echo the rejected value back: a Firstmate home path is the
# captain's private machine layout.
FM_HOME=$(cd -P -- "${FM_HOME:-$SCRIPT_DIR/..}" 2>/dev/null && pwd -P) || FM_HOME=
case "$FM_HOME" in
  /*) ;;
  *)
    echo "error: set FM_HOME to a readable Firstmate home directory before loading /pause-and-learn" >&2
    exit 1
    ;;
esac
REG="$FM_HOME/data/projects.md"
if [ ! -r "$REG" ] \
  || ! awk -v n="$PROJECT_NAME" '$1=="-" && $2==n { found=1 } END { exit !found }' "$REG"; then
  echo "error: register the shared-brain project in this Firstmate home's data/projects.md" >&2
  exit 1
fi
PROJECT="$FM_HOME/projects/$PROJECT_NAME"
if [ ! -d "$PROJECT/.git" ] && [ ! -f "$PROJECT/.git" ]; then
  echo "error: clone the registered shared-brain project into this Firstmate home's projects/shared-brain" >&2
  exit 1
fi
refuse_unreadable() {
  echo "error: repair or re-clone this Firstmate home's projects/shared-brain so git can read it before loading /pause-and-learn" >&2
  exit 1
}
# Discovery is a local read: no prompt, no credential helper, no transport, and
# no lazy fetch of a missing object may turn one of these queries into network
# work or a wait for input.
git_local() {
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS='' SSH_ASKPASS='' GIT_NO_LAZY_FETCH=1 \
    git --no-optional-locks \
    -c core.askPass= -c credential.helper= -c protocol.allow=never \
    -C "$PROJECT" "$@"
}
PROJECT_ROOT=$(cd -P -- "$PROJECT" 2>/dev/null && pwd -P) || refuse_unreadable
# git walks past an unusable `.git` and keeps searching upward, and a Firstmate
# home is itself a repository, so an interrupted clone would otherwise be
# answered for by the home around it.
TOPLEVEL=$(git_local rev-parse --show-toplevel 2>/dev/null) || refuse_unreadable
[ "$TOPLEVEL" = "$PROJECT_ROOT" ] || refuse_unreadable
# One status answers tracked, staged, unmerged, and untracked state together,
# and it answers in three ways, not two: it fails when the copy cannot be read
# at all, it reports on stdout what is dirty, and it demotes a path it could not
# open to a stderr warning while still succeeding with nothing to report. Only
# the second is dirtiness. The other two leave part of the copy uninspected, so
# they take the repair prerequisite - and take it without repeating git's
# diagnostic, which names paths inside the captain's home.
STATUS_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-shared-brain-status.XXXXXX" 2>/dev/null) || {
  echo "error: make a writable temporary directory available before loading /pause-and-learn: inspecting the shared-brain local copy needs one" >&2
  exit 1
}
trap 'rm -f "$STATUS_ERR"' EXIT
WORKTREE_STATE=$(git_local status --porcelain=v1 --untracked-files=normal --ignore-submodules=none \
  2>"$STATUS_ERR") || refuse_unreadable
[ ! -s "$STATUS_ERR" ] || refuse_unreadable
if [ -n "$WORKTREE_STATE" ]; then
  echo "error: clean the shared-brain local copy before loading /pause-and-learn so its source identity is unambiguous" >&2
  exit 1
fi
if ! git_local cat-file -e "$REQUIRED_COMMIT^{commit}" 2>/dev/null \
  || ! git_local merge-base --is-ancestor "$REQUIRED_COMMIT" HEAD 2>/dev/null; then
  echo "error: update the registered shared-brain local copy to include merge $REQUIRED_COMMIT before loading /pause-and-learn" >&2
  exit 1
fi
SOURCE="$PROJECT_ROOT/skills/$SKILL/SKILL.md"
if [ ! -f "$SOURCE" ] || [ ! -r "$SOURCE" ]; then
  echo "error: the authoritative shared-brain source skills/pause-and-learn/SKILL.md is missing or unreadable" >&2
  exit 1
fi
printf '%s\n' "$SOURCE"
