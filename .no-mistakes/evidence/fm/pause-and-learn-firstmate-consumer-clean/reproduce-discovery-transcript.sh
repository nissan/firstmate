#!/usr/bin/env bash
# Drives bin/fm-shared-brain-skill.sh the way the captain's /pause-and-learn stub
# does, across every state an end user can be in, and prints a CLI transcript.
set -eu
ROOT=$1
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pl-evidence.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
RESOLVER="$ROOT/bin/fm-shared-brain-skill.sh"
export GIT_AUTHOR_NAME=evidence GIT_AUTHOR_EMAIL=evidence@example.invalid
export GIT_COMMITTER_NAME=evidence GIT_COMMITTER_EMAIL=evidence@example.invalid

redact() { sed "s#$WORK#<HOME-ROOT>#g; s#${FM_HOME:-__no_fm_home__}#<CAPTAIN-FM_HOME>#g; s#$ROOT#<FIRSTMATE-CODE-ROOT>#g"; }

run() {
  local label=$1; shift
  printf '\n$ %s\n' "$(printf '%s ' "$@" | sed "s#$RESOLVER#bin/fm-shared-brain-skill.sh#; s#$WORK#<HOME-ROOT>#g" | sed 's/ $//')" 
  local out rc
  set +e
  out=$("$@" 2>&1); rc=$?
  set -e
  printf '%s\n' "$out" | redact
  printf '[exit %s]  # %s\n' "$rc" "$label"
}

register() {
  mkdir -p "$1/data" "$1/projects"
  printf '%s\n' '- shared-brain [no-mistakes] - authoritative skill source' > "$1/data/projects.md"
}
clone_fixture() {
  register "$1"
  local p="$1/projects/shared-brain"
  mkdir -p "$p/skills/pause-and-learn"
  git -C "$p" init -q
  printf '%s\n' '# synthetic fixture source' > "$p/skills/pause-and-learn/SKILL.md"
  git -C "$p" add .
  git -C "$p" commit -qm source
}

echo "=== /pause-and-learn discovery: what the captain sees in each state ==="
echo "(synthetic Firstmate homes; no private project records, paths, or corpus)"

echo
echo "--- 1. registered, clean, at or above the required merge ---"
good="$WORK/good"; clone_fixture "$good"
head=$(git -C "$good/projects/shared-brain" rev-parse HEAD)
run "resolves the authoritative source, absolute path on stdout" \
  env FM_HOME="$good" FM_TESTING=1 FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn

echo
echo "--- 2. same copy, invoked from an unrelated directory with a relative FM_HOME ---"
printf '\n$ cd <HOME-ROOT> && FM_HOME=good bin/fm-shared-brain-skill.sh pause-and-learn\n'
( cd "$WORK" && env FM_HOME=good FM_TESTING=1 FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn ) | redact
printf '[exit 0]  # the path stays absolute, so the agent can follow it in place\n'

echo
echo "--- 3. no shared-brain registration in this home ---"
noreg="$WORK/no-registry"; mkdir -p "$noreg/data" "$noreg/projects"
run "stops with the registration prerequisite" env FM_HOME="$noreg" "$RESOLVER" pause-and-learn

echo
echo "--- 4. registered but never cloned ---"
uncloned="$WORK/uncloned"; register "$uncloned"
run "stops with the clone prerequisite" env FM_HOME="$uncloned" "$RESOLVER" pause-and-learn

echo
echo "--- 5. local copy has uncommitted edits ---"
dirty="$WORK/dirty"; clone_fixture "$dirty"
dhead=$(git -C "$dirty/projects/shared-brain" rev-parse HEAD)
printf '%s\n' '# locally edited' > "$dirty/projects/shared-brain/skills/pause-and-learn/SKILL.md"
run "stops with the cleanliness prerequisite" \
  env FM_HOME="$dirty" FM_TESTING=1 FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$dhead" "$RESOLVER" pause-and-learn

echo
echo "--- 6. clean copy that does not contain the required merge (stale) ---"
run "stops with the production required-merge prerequisite" env FM_HOME="$good" "$RESOLVER" pause-and-learn

echo
echo "--- 7. clone git cannot read (interrupted clone inside a Firstmate home repo) ---"
nested="$WORK/nested"; mkdir -p "$nested"; git -C "$nested" init -q; register "$nested"
printf '%s\n' 'projects/' > "$nested/.gitignore"
git -C "$nested" add .gitignore data/projects.md; git -C "$nested" commit -qm home
mkdir -p "$nested/projects/shared-brain/skills/pause-and-learn/" "$nested/projects/shared-brain/.git"
printf '%s\n' '# corrupt clone' > "$nested/projects/shared-brain/skills/pause-and-learn/SKILL.md"
run "stops with the repair prerequisite, never answered by the surrounding home repo" \
  env FM_HOME="$nested" FM_TESTING=1 FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn

echo
echo "--- 8. no bundled or global fallback exists after a refusal ---"
printf '\n$ ls <FIRSTMATE-CODE-ROOT>/skills/pause-and-learn\n'
if [ -e "$ROOT/skills/pause-and-learn" ]; then echo "PRESENT (unexpected)"; else
  echo "ls: cannot access 'skills/pause-and-learn': No such file or directory"; fi
printf '$ ls .agents/skills/pause-and-learn\n'
ls -A "$ROOT/.agents/skills/pause-and-learn"
printf '[the only shipped file is the routing stub; nothing to fall back to]\n'

echo
echo "--- 9. discovery is local: same happy path with no network namespace at all ---"
printf '\n$ unshare -rn env FM_HOME=<HOME-ROOT>/good bin/fm-shared-brain-skill.sh pause-and-learn\n'
set +e
netout=$(unshare -rn env FM_HOME="$good" FM_TESTING=1 FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn 2>&1)
netrc=$?
set -e
printf '%s\n' "$netout" | redact
printf '[exit %s]  # resolves with no network reachable\n' "$netrc"

echo
echo "--- 10. the captain's real registered home, real required merge 29099a5f... ---"
echo "     (paths redacted: a Firstmate home layout is private machine data)"
REALHOME=${FM_HOME:-}
if [ -r "$REALHOME/data/projects.md" ]; then
  printf '\n$ FM_HOME=<CAPTAIN-FM_HOME> bin/fm-shared-brain-skill.sh pause-and-learn\n'
  set +e
  realout=$(env FM_HOME="$REALHOME" "$RESOLVER" pause-and-learn 2>&1); realrc=$?
  set -e
  printf '%s\n' "$realout" | redact
  printf '[exit %s]  # production discovery, no FM_TESTING override, no network work\n' "$realrc"
  if [ "$realrc" -eq 0 ]; then
    resolved=$(env FM_HOME="$REALHOME" "$RESOLVER" pause-and-learn)
    printf '$ test -r "$(...)" && echo readable   # the agent can actually follow it in place\n'
    [ -r "$resolved" ] && echo readable
    printf '$ wc -l < "$(...)"   # a real authoritative skill, contents not reproduced here\n'
    wc -l < "$resolved"
  fi
else
  echo "  SKIP - no registered Firstmate home on this machine"
fi
