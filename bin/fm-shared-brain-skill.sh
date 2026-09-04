#!/usr/bin/env bash
# Resolve an authoritative skill from the registered shared-brain project clone.
# This is discovery only: it never clones, fetches, checks out, or modifies the source.
# Usage: fm-shared-brain-skill.sh pause-and-learn
set -eu
# Every refusal below is a git answer about the registered local copy, so those
# answers must come from the filesystem rather than the caller's environment.
# `git -C` only changes directory: an inherited GIT_DIR/GIT_WORK_TREE - which
# git exports into every hook environment - would make the clean, untracked, and
# identity checks describe an unrelated checkout. CDPATH would redirect the
# relative `cd` below the same way. Clear the whole class once so every later
# git call inherits it.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
REG="${FM_DATA_OVERRIDE:-$FM_HOME/data}/projects.md"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
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
if [ ! -r "$REG" ]; then
  echo "error: register the shared-brain project in this Firstmate home's data/projects.md" >&2
  exit 1
fi
if ! awk -v n="$PROJECT_NAME" '$1=="-" && $2==n { found=1 } END { exit !found }' "$REG"; then
  echo "error: register the shared-brain project in this Firstmate home's data/projects.md" >&2
  exit 1
fi
PROJECT="$PROJECTS/$PROJECT_NAME"
SOURCE="$PROJECT/skills/$SKILL/SKILL.md"
if [ ! -d "$PROJECT/.git" ] && [ ! -f "$PROJECT/.git" ]; then
  echo "error: clone the registered shared-brain project into this Firstmate home's projects/shared-brain" >&2
  exit 1
fi
if ! git -C "$PROJECT" diff --quiet --ignore-submodules -- || ! git -C "$PROJECT" diff --cached --quiet --ignore-submodules --; then
  echo "error: clean the shared-brain local copy before loading /pause-and-learn so its source identity is unambiguous" >&2
  exit 1
fi
if [ -n "$(git -C "$PROJECT" ls-files --others --exclude-standard)" ]; then
  echo "error: clean the shared-brain local copy before loading /pause-and-learn so its source identity is unambiguous" >&2
  exit 1
fi
if ! git -C "$PROJECT" cat-file -e "$REQUIRED_COMMIT^{commit}" 2>/dev/null \
  || ! git -C "$PROJECT" merge-base --is-ancestor "$REQUIRED_COMMIT" HEAD 2>/dev/null; then
  echo "error: update the registered shared-brain local copy to include merge $REQUIRED_COMMIT before loading /pause-and-learn" >&2
  exit 1
fi
if [ ! -f "$SOURCE" ] || [ ! -r "$SOURCE" ]; then
  echo "error: the authoritative shared-brain source skills/pause-and-learn/SKILL.md is missing or unreadable" >&2
  exit 1
fi
printf '%s\n' "$SOURCE"
