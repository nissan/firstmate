#!/usr/bin/env bash
# Shows which tests bin/fm-test-run.sh --changed selects for each file this
# integration owns, so the guards that police the stub and the resolver are
# actually reached on the changed-file fast path. Runs against a clean worktree
# and restores every probe edit.
set -eu
ROOT=$1
cd "$ROOT"
[ -z "$(git status --porcelain)" ] || { echo "refusing: worktree is not clean" >&2; exit 1; }

probe() {
  local file=$1 label=$2
  printf '\n--- edit %s (%s) ---\n' "$file" "$label"
  printf '$ bin/fm-test-run.sh --list --changed --base HEAD\n'
  printf '\n<!-- probe -->\n' >> "$file"
  bin/fm-test-run.sh --list --changed --base HEAD | LC_ALL=C sort
  git checkout -- "$file"
}

echo "=== changed-file test selection for the /pause-and-learn integration ==="
probe .agents/skills/pause-and-learn/SKILL.md "the captain-invocable routing stub" \
  | grep -E 'pause-and-learn|shared-brain|^---|^\$|^===' 
probe bin/fm-shared-brain-skill.sh "the discovery resolver" \
  | grep -E 'pause-and-learn|shared-brain|^---|^\$|^===' 

printf '\n[both owned files select fm-shared-brain-skill.test.sh (behavior) and\n'
printf ' fm-pause-and-learn-inventory.test.sh (ownership/privacy), so neither the\n'
printf " resolver's contract nor the stub's one-owner inventory can change unguarded]\n"
git status --porcelain
