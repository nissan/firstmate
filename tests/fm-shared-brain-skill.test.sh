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
case "$out" in
  /*) ;;
  *) fail "discovery printed a source path the caller cannot resolve from elsewhere: $out" ;;
esac
pass "discovery resolves the registered local source from FM_HOME alone"

# The caller reads the printed path from whatever directory it is standing in,
# so a relative FM_HOME must still name the source absolutely.
relative_out=$(cd "$TMP_ROOT" && env FM_HOME=good FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn)
[ "$relative_out" = "$SOURCE" ] || fail "a relative FM_HOME did not resolve to the absolute authoritative path"
pass "a relative FM_HOME still prints the absolute authoritative source path"

# The stub tells the captain to run the resolver "from the Firstmate code root",
# and an installed Firstmate home is that code root, so the ordinary invocation
# sets no FM_HOME at all. That default has to name the home the resolver was
# installed into rather than whatever directory the caller happens to be in.
installed="$TMP_ROOT/installed"
new_home "$installed"
mkdir -p "$installed/bin"
cp "$RESOLVER" "$installed/bin/fm-shared-brain-skill.sh"
installed_head=$(git -C "$installed/projects/shared-brain" rev-parse HEAD)
default_out=$(cd "$TMP_ROOT" && env -u FM_HOME FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$installed_head" \
  "$installed/bin/fm-shared-brain-skill.sh" pause-and-learn)
[ "$default_out" = "$installed/projects/shared-brain/skills/pause-and-learn/SKILL.md" ] \
  || fail "with no FM_HOME set the resolver did not discover the home it is installed in"
pass "with no FM_HOME set discovery falls back to the installed Firstmate home"

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

# Discovery derives from FM_HOME alone: no caller environment may redirect the
# registry or the clone location to a registration or a copy this home lacks.
run_expect_failure 'register the shared-brain project' env FM_HOME="$missing" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" FM_DATA_OVERRIDE="$home/data" \
  "$RESOLVER" pause-and-learn
pass "a data-location override cannot supply a registration this home does not have"

run_expect_failure 'clone the registered shared-brain project' env FM_HOME="$uncloned" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" FM_PROJECTS_OVERRIDE="$home/projects" \
  "$RESOLVER" pause-and-learn
pass "a projects-location override cannot supply a clone this home does not have"

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

# A staged addition leaves the worktree matching the index, so it shows up only
# on the index side of the copy's state.
printf '%s\n' staged > "$PROJECT/staged"
git -C "$PROJECT" add staged
run_expect_failure 'clean the shared-brain local copy' env FM_HOME="$home" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn
pass "a staged-only change in the local copy is refused"
git -C "$PROJECT" reset -q
rm "$PROJECT/staged"

# An interrupted merge leaves unmerged index entries, which make the copy's
# source identity ambiguous in a way neither side of a plain diff reports alone.
conflicted="$TMP_ROOT/conflicted"
new_home "$conflicted"
conflicted_project="$conflicted/projects/shared-brain"
conflicted_base=$(git -C "$conflicted_project" rev-parse HEAD)
git -C "$conflicted_project" checkout -q -b other-side
printf '%s\n' '# other side' > "$conflicted_project/skills/pause-and-learn/SKILL.md"
git -C "$conflicted_project" commit -qam "other side"
git -C "$conflicted_project" checkout -q -
printf '%s\n' '# this side' > "$conflicted_project/skills/pause-and-learn/SKILL.md"
git -C "$conflicted_project" commit -qam "this side"
git -C "$conflicted_project" merge other-side >/dev/null 2>&1 || true
[ -n "$(git -C "$conflicted_project" ls-files --unmerged)" ] \
  || fail "the conflicted fixture did not produce an unmerged index entry"
run_expect_failure 'clean the shared-brain local copy' env FM_HOME="$conflicted" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$conflicted_base" "$RESOLVER" pause-and-learn
pass "a local copy with unmerged index entries is refused"

# git demotes a worktree path it cannot open to a stderr warning and still exits
# zero with nothing to report, which reads as clean. A stub on PATH reproduces
# that answer deterministically, instead of betting on how the running uid
# experiences a mode-000 directory; every other subcommand still reaches the
# real git, so identity and ancestry stay genuinely enforced.
partial="$TMP_ROOT/partly-inspectable"
new_home "$partial"
partial_head=$(git -C "$partial/projects/shared-brain" rev-parse HEAD)
warnbin="$TMP_ROOT/warnbin"
mkdir -p "$warnbin"
cat > "$warnbin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = status ]; then
    : >"$FM_TEST_STATUS_MARKER"
    printf '%s\n' "warning: could not open directory 'helpers/': Permission denied" >&2
    exit 0
  fi
done
exec "$FM_TEST_REAL_GIT" "$@"
SH
chmod +x "$warnbin/git"
partial_marker="$TMP_ROOT/status-intercepted"
rm -f "$partial_marker"
set +e
partial_out=$(env PATH="$warnbin:$PATH" FM_TEST_REAL_GIT="$(command -v git)" \
  FM_TEST_STATUS_MARKER="$partial_marker" \
  FM_HOME="$partial" FM_TESTING=1 FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$partial_head" \
  "$RESOLVER" pause-and-learn 2>&1)
partial_rc=$?
set -e
# Without this the case would also pass when the stub never ran at all: every
# inspection failure, including one from the earlier identity query, refuses
# with the same sentence.
[ -f "$partial_marker" ] || fail "the stub never intercepted a status query, so the warning path was never reached"
[ "$partial_rc" -ne 0 ] || fail "a copy git could only partly inspect was accepted as an authoritative source"
assert_contains "$partial_out" 'repair or re-clone' "a partly inspectable copy did not name its prerequisite"
assert_not_contains "$partial_out" 'clean the shared-brain local copy' \
  "a partly inspectable copy was mislabeled as dirty"
assert_not_contains "$partial_out" 'Permission denied' \
  "the refusal repeated git's own diagnostic instead of a private-safe prerequisite"
assert_not_contains "$partial_out" 'SKILL.md' "a partly inspectable copy still emitted a source path"
pass "a copy git could only partly inspect is refused instead of read as clean"

# Somewhere to hold the inspection's diagnostics is this run's own prerequisite,
# not the clone's: re-cloning a clean, current copy would not supply one.
set +e
tmpdir_out=$(env TMPDIR="$TMP_ROOT/absent-tmpdir" FM_HOME="$partial" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$partial_head" "$RESOLVER" pause-and-learn 2>&1)
tmpdir_rc=$?
set -e
[ "$tmpdir_rc" -ne 0 ] || fail "an unusable temporary directory was accepted as an authoritative source"
assert_contains "$tmpdir_out" 'temporary directory' "the temporary-directory blocker did not name itself"
assert_not_contains "$tmpdir_out" 'repair or re-clone' \
  "a temporary-directory failure was blamed on the shared-brain local copy"
assert_not_contains "$tmpdir_out" 'absent-tmpdir' "the refusal echoed the temporary directory it was given"
pass "a temporary directory the inspection cannot use is refused on its own terms"

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

# A Firstmate home is itself a git repository in the real layout, so a corrupt
# clone under its projects/ must never be answered by the home repository:
# git's discovery walks past an invalid .git directory and up to the parent.
nested="$TMP_ROOT/nested-home"
mkdir -p "$nested"
git -C "$nested" init -q
register_home "$nested"
printf '%s\n' 'projects/' > "$nested/.gitignore"
git -C "$nested" add .gitignore data/projects.md
git -C "$nested" commit -qm "firstmate home"
nested_project="$nested/projects/shared-brain"
mkdir -p "$nested_project/skills/pause-and-learn" "$nested_project/.git"
printf '%s\n' '# corrupt clone fixture' > "$nested_project/skills/pause-and-learn/SKILL.md"
set +e
nested_out=$(env FM_HOME="$nested" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$head" "$RESOLVER" pause-and-learn 2>&1)
nested_rc=$?
set -e
[ "$nested_rc" -ne 0 ] || fail "a corrupt clone was answered by the surrounding Firstmate home repository"
assert_contains "$nested_out" 'repair or re-clone' "corrupt nested clone did not name its prerequisite"
assert_not_contains "$nested_out" 'to include merge' \
  "a corrupt clone was mislabeled as stale by the surrounding repository"
assert_not_contains "$nested_out" 'clean the shared-brain local copy' \
  "a corrupt clone was mislabeled as dirty by the surrounding repository"
pass "git discovery cannot ascend from a corrupt clone into the Firstmate home repository"

rm "$SOURCE"
git -C "$PROJECT" add -u
git -C "$PROJECT" commit -qm "remove source"
newhead=$(git -C "$PROJECT" rev-parse HEAD)
run_expect_failure 'missing or unreadable' env FM_HOME="$home" FM_TESTING=1 \
  FM_TEST_SHARED_BRAIN_REQUIRED_COMMIT="$newhead" "$RESOLVER" pause-and-learn
pass "a clean current copy with an absent skill source is refused"
