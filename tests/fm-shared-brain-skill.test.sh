#!/usr/bin/env bash
# Behavioral tests for local, identity-bound discovery of the authoritative
# shared-brain /pause-and-learn source, and for every refusal that keeps a
# stale, dirty, absent, or unreadable source from being loaded.
set -eu

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

stale="$TMP_ROOT/stale"
new_home "$stale"
stale_project="$stale/projects/shared-brain"
required_but_divergent=$(git -C "$stale_project" rev-parse HEAD)
git -C "$stale_project" checkout -q --orphan divergent-head
git -C "$stale_project" rm -q -rf .
mkdir -p "$stale_project/skills/pause-and-learn"
printf '%s\n' '# divergent fixture source' > "$stale_project/skills/pause-and-learn/SKILL.md"
git -C "$stale_project" add .
git -C "$stale_project" commit -qm divergent
run_expect_failure "$required_but_divergent" env FM_HOME="$stale" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$required_but_divergent" "$RESOLVER" pause-and-learn
pass "a known required commit that is not an ancestor of HEAD is refused as stale"

missing="$TMP_ROOT/no-registry"
mkdir -p "$missing/data" "$missing/projects"
run_expect_failure 'register the shared-brain project' env FM_HOME="$missing" "$RESOLVER" pause-and-learn
pass "a home without a project registry is refused with the registration prerequisite"

unregistered="$TMP_ROOT/unregistered"
new_home "$unregistered"
unregistered_head=$(git -C "$unregistered/projects/shared-brain" rev-parse HEAD)
printf '%s\n' '- synthetic-project [local-only] - unrelated synthetic fixture' \
  > "$unregistered/data/projects.md"
run_expect_failure 'register the shared-brain project' env FM_HOME="$unregistered" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$unregistered_head" "$RESOLVER" pause-and-learn
pass "a registry without shared-brain is refused despite a resolvable clone"

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

# The untracked refusal must also survive inherited git config, which can point
# core.excludesFile at a pattern that hides every untracked file from the check.
excludes="$TMP_ROOT/excludes"
printf '%s\n' '*' > "$excludes"
run_expect_failure 'clean the shared-brain local copy' env FM_HOME="$home" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" \
  GIT_CONFIG_PARAMETERS="'core.excludesFile'='$excludes'" "$RESOLVER" pause-and-learn
pass "inherited git config cannot hide untracked content from the cleanliness check"
rm "$PROJECT/stray"

# A copy git cannot read at all is a distinct blocker from a dirty one: its
# worktree may be pristine, so the cleanliness prerequisite would be unactionable.
unreadable="$TMP_ROOT/unreadable"
new_home "$unreadable"
unreadable_project="$unreadable/projects/shared-brain"
unreadable_head=$(git -C "$unreadable_project" rev-parse HEAD)
rm -rf "$unreadable_project/.git"
printf 'gitdir: %s\n' "$unreadable/absent-gitdir" > "$unreadable_project/.git"
set +e
unreadable_out=$(env FM_HOME="$unreadable" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$unreadable_head" "$RESOLVER" pause-and-learn 2>&1)
unreadable_rc=$?
set -e
[ "$unreadable_rc" -ne 0 ] || fail "an unreadable local copy was accepted as an authoritative source"
assert_contains "$unreadable_out" 'repair or re-clone' "unreadable copy did not name its prerequisite"
assert_not_contains "$unreadable_out" 'clean the shared-brain local copy' \
  "an unreadable local copy was mislabeled as dirty"
pass "a local copy git cannot read is refused with a repair prerequisite, not a cleanliness one"

rm "$SOURCE"
git -C "$PROJECT" add -u
git -C "$PROJECT" commit -qm "remove source"
newhead=$(git -C "$PROJECT" rev-parse HEAD)
run_expect_failure 'missing or unreadable' env FM_HOME="$home" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$newhead" "$RESOLVER" pause-and-learn
pass "a clean current copy with an absent skill source is refused"
