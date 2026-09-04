#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RESOLVER="$ROOT/bin/fm-shared-brain-skill.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_fails_with() {
  expected=$1
  shift
  out=$("$@" 2>&1) && fail "command unexpectedly succeeded: $*"
  case "$out" in *"$expected"*) ;; *) fail "expected '$expected', got: $out" ;; esac
}
new_home() {
  home=$1
  mkdir -p "$home/data" "$home/projects/shared-brain/skills/pause-and-learn"
  printf '%s\n' '- shared-brain [no-mistakes] - authoritative skill source' > "$home/data/projects.md"
  git -C "$home/projects/shared-brain" init -q
  git -C "$home/projects/shared-brain" config user.name test
  git -C "$home/projects/shared-brain" config user.email test@example.invalid
  printf '%s\n' '# fixture source' > "$home/projects/shared-brain/skills/pause-and-learn/SKILL.md"
  git -C "$home/projects/shared-brain" add .
  git -C "$home/projects/shared-brain" commit -qm source
}

home="$TMP/good"
new_home "$home"
head=$(git -C "$home/projects/shared-brain" rev-parse HEAD)
out=$(FM_HOME="$home" FM_TESTING=1 FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn)
[ "$out" = "$home/projects/shared-brain/skills/pause-and-learn/SKILL.md" ] || fail "registered source did not resolve"

assert_fails_with '29099a5f40c28e2f09fec157b7f49816e3e41971' env FM_HOME="$home" "$RESOLVER" pause-and-learn

missing="$TMP/missing"
mkdir -p "$missing/data" "$missing/projects"
assert_fails_with 'register the shared-brain project' env FM_HOME="$missing" "$RESOLVER" pause-and-learn

rm "$home/projects/shared-brain/skills/pause-and-learn/SKILL.md"
assert_fails_with 'clean the shared-brain local copy' env FM_HOME="$home" FM_TESTING=1 FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn
git -C "$home/projects/shared-brain" restore .
printf '%s\n' stray > "$home/projects/shared-brain/stray"
assert_fails_with 'clean the shared-brain local copy' env FM_HOME="$home" FM_TESTING=1 FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn
rm "$home/projects/shared-brain/stray"
rm "$home/projects/shared-brain/skills/pause-and-learn/SKILL.md"
git -C "$home/projects/shared-brain" add -u
git -C "$home/projects/shared-brain" commit -qm missing
newhead=$(git -C "$home/projects/shared-brain" rev-parse HEAD)
assert_fails_with 'missing or unreadable' env FM_HOME="$home" FM_TESTING=1 FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$newhead" "$RESOLVER" pause-and-learn

echo "PASS: shared-brain skill discovery is local, identity-bound, and stops safely"
