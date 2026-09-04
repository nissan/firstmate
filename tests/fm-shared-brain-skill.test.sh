#!/usr/bin/env bash
# Behavioral tests for local, identity-bound discovery of the authoritative
# shared-brain /pause-and-learn source, and for every refusal that keeps a
# stale, dirty, absent, or unreadable source from being loaded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVER="$ROOT/bin/fm-shared-brain-skill.sh"
PRODUCTION_COMMIT=29099a5f40c28e2f09fec157b7f49816e3e41971
TMP_ROOT=$(fm_test_tmproot fm-shared-brain-skill)
fm_git_identity

run_expect_failure() {
  local expected=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected', but the command succeeded"
  assert_contains "$out" "$expected" "refusal did not name its prerequisite"
}

# A home whose data/projects.md registers shared-brain, with no clone yet.
register_home() {
  local home=$1
  mkdir -p "$home/data" "$home/projects"
  printf '%s\n' '- shared-brain [no-mistakes] - authoritative skill source' > "$home/data/projects.md"
}

# A registered home whose projects/shared-brain is a clean one-commit clone
# carrying the skill source.
new_home() {
  local home=$1 project
  register_home "$home"
  project="$home/projects/shared-brain"
  mkdir -p "$project/skills/pause-and-learn"
  git -C "$project" init -q
  printf '%s\n' '# fixture source' > "$project/skills/pause-and-learn/SKILL.md"
  git -C "$project" add .
  git -C "$project" commit -qm source
}

home="$TMP_ROOT/good"
new_home "$home"
PROJECT="$home/projects/shared-brain"
SOURCE="$PROJECT/skills/pause-and-learn/SKILL.md"
head=$(git -C "$PROJECT" rev-parse HEAD)

out=$(FM_HOME="$home" FM_TESTING=1 FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn)
[ "$out" = "$SOURCE" ] || fail "registered source did not resolve to the authoritative path"
pass "discovery resolves the registered local source from FM_HOME alone"

run_expect_failure "$PRODUCTION_COMMIT" env FM_HOME="$home" "$RESOLVER" pause-and-learn
pass "a local copy below the required merge is refused"

run_expect_failure "$PRODUCTION_COMMIT" env FM_HOME="$home" \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn
pass "the required-commit override is inert outside FM_TESTING"

missing="$TMP_ROOT/unregistered"
mkdir -p "$missing/data" "$missing/projects"
run_expect_failure 'register the shared-brain project' env FM_HOME="$missing" "$RESOLVER" pause-and-learn
pass "an unregistered shared-brain project is refused with the registration prerequisite"

uncloned="$TMP_ROOT/uncloned"
register_home "$uncloned"
run_expect_failure 'clone the registered shared-brain project' env FM_HOME="$uncloned" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn
pass "a registered but uncloned shared-brain project is refused with the clone prerequisite"

rm "$SOURCE"
run_expect_failure 'clean the shared-brain local copy' env FM_HOME="$home" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn
pass "a dirty local copy is refused so source identity stays unambiguous"

# The dirty copy above must stay refused even when the caller's environment
# points git at a clean, sufficiently current checkout of its own.
foreign="$TMP_ROOT/foreign"
mkdir -p "$foreign"
fm_git_init_commit "$foreign"
foreign_head=$(git -C "$foreign" rev-parse HEAD)
run_expect_failure 'clean the shared-brain local copy' env FM_HOME="$home" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$foreign_head" \
  GIT_DIR="$foreign/.git" GIT_WORK_TREE="$foreign" "$RESOLVER" pause-and-learn
pass "an inherited GIT_DIR cannot answer the validation for an unrelated checkout"

git -C "$PROJECT" restore .
printf '%s\n' stray > "$PROJECT/stray"
run_expect_failure 'clean the shared-brain local copy' env FM_HOME="$home" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn
pass "an untracked stray file in the local copy is refused"
rm "$PROJECT/stray"

rm "$SOURCE"
git -C "$PROJECT" add -u
git -C "$PROJECT" commit -qm "remove source"
newhead=$(git -C "$PROJECT" rev-parse HEAD)
run_expect_failure 'missing or unreadable' env FM_HOME="$home" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$newhead" "$RESOLVER" pause-and-learn
pass "a clean current copy without the skill source is refused as unreadable"
