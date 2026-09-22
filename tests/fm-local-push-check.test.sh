#!/usr/bin/env bash
# Contract tests for the local push check: bin/fm-local-push-check.sh, the hook
# that calls it (.githooks/pre-push), and the wiring that arms it
# (bin/fm-githooks-wire.sh).
#
# These pin the properties that make the check trustworthy rather than merely
# present, because the failure mode that matters is a check that reports having
# passed while having examined nothing:
#   - every check runs even after an earlier one fails, and any failure refuses;
#   - a push that cannot be tied to the working tree is refused, not waved
#     through on the strength of an unrelated clean tree;
#   - the ref list git pipes in reaches the checker and NOT the commands it runs;
#   - the pipeline that owns its own lint and tests is left alone;
#   - wiring never takes a hooks path away from whoever already set one.
#
# The checker is driven in a throwaway checkout whose bin/fm-lint.sh and
# bin/fm-test-run.sh are stubs, so these assertions describe its orchestration
# rather than re-testing the linter and the suite runner, which own their
# behavior and have their own regressions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-local-push-check.sh"
HOOK="$ROOT/.githooks/pre-push"
WIRE="$ROOT/bin/fm-githooks-wire.sh"
ZERO=0000000000000000000000000000000000000000
TMP_ROOT=$(fm_test_tmproot fm-local-push-check)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

assert_present "$GATE" "bin/fm-local-push-check.sh is missing"
assert_present "$HOOK" ".githooks/pre-push is missing"
assert_present "$WIRE" "bin/fm-githooks-wire.sh is missing"
[ -x "$GATE" ] || fail "bin/fm-local-push-check.sh is not executable"
[ -x "$HOOK" ] || fail ".githooks/pre-push is not executable, so git would ignore it"
[ -x "$WIRE" ] || fail "bin/fm-githooks-wire.sh is not executable"

# Build a throwaway checkout carrying the real checker and hook over stub tools.
# <lint-rc> and <test-rc> are the exit statuses the two stubs return. Each stub
# records what it was given so a test can assert the checker's own choices.
make_checkout() {  # <name> <lint-rc> <test-rc>
  local dir=$1 lint_rc=$2 test_rc=$3
  dir="$TMP_ROOT/$dir"
  mkdir -p "$dir/bin" "$dir/.githooks"
  git init -q "$dir" 2>/dev/null || return 1
  git -C "$dir" config --local user.email fixture@example.invalid
  git -C "$dir" config --local user.name fixture
  cp "$GATE" "$dir/bin/fm-local-push-check.sh"
  cp "$HOOK" "$dir/.githooks/pre-push"
  chmod +x "$dir/bin/fm-local-push-check.sh" "$dir/.githooks/pre-push"
  cat > "$dir/bin/fm-lint.sh" <<STUB
#!/usr/bin/env bash
printf 'stub-lint ran\n'
printf 'stdin:[%s]\n' "\$(cat)"
exit $lint_rc
STUB
  cat > "$dir/bin/fm-test-run.sh" <<STUB
#!/usr/bin/env bash
printf 'stub-tests ran %s\n' "\$*"
printf 'stdin:[%s]\n' "\$(cat)"
exit $test_rc
STUB
  chmod +x "$dir/bin/fm-lint.sh" "$dir/bin/fm-test-run.sh"
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" commit -q -m fixture >/dev/null 2>&1 || return 1
  printf '%s\n' "$dir"
}

run_gate() {  # <dir> [env-assignment...]
  local dir=$1
  shift
  ( cd "$dir" && env "$@" bash bin/fm-local-push-check.sh </dev/null 2>&1 )
}

head_of() { git -C "$1" rev-parse HEAD; }

test_clean_tree_permits_the_push() {
  local dir out rc
  dir=$(make_checkout clean 0 0) || fail "could not build the clean fixture"
  out=$(run_gate "$dir") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a clean tree refused the push (rc=$rc): $out"
  assert_contains "$out" "stub-lint ran" "the checker did not run the linter"
  assert_contains "$out" "stub-tests ran --changed" \
    "the checker did not run the affected tests with --changed"
  assert_contains "$out" "local checks passed" "the checker did not report passing"
  pass "a clean tree runs every check and permits the push"
}

test_a_failing_lint_refuses_the_push() {
  local dir out rc
  dir=$(make_checkout lintfail 1 0) || fail "could not build the lint-failure fixture"
  out=$(run_gate "$dir") && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a failing linter did not refuse the push (rc=$rc): $out"
  assert_contains "$out" "push refused" "the refusal did not say the push was refused"
  assert_contains "$out" "SKIP_GATE=1" "the refusal did not name the documented override"
  pass "a failing linter refuses the push and names the override"
}

test_a_failing_test_run_refuses_the_push() {
  local dir out rc
  dir=$(make_checkout testfail 0 1) || fail "could not build the test-failure fixture"
  out=$(run_gate "$dir") && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a failing test run did not refuse the push (rc=$rc): $out"
  pass "a failing test run refuses the push"
}

# A checker that stopped at the first failure would hand back one problem per
# push, so a two-fault branch would cost two full CI runs to discover locally.
test_every_check_runs_even_after_an_earlier_failure() {
  local dir out rc
  dir=$(make_checkout bothfail 1 1) || fail "could not build the both-failing fixture"
  out=$(run_gate "$dir") && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a doubly-failing tree did not refuse the push (rc=$rc): $out"
  assert_contains "$out" "stub-lint ran" "the linter did not run"
  assert_contains "$out" "stub-tests ran" \
    "the checker stopped at the failing linter instead of reporting both faults"
  pass "every check runs even after an earlier one fails"
}

test_skip_gate_is_the_one_way_past() {
  local dir out rc
  dir=$(make_checkout skipped 1 1) || fail "could not build the skip fixture"
  out=$(run_gate "$dir" SKIP_GATE=1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "SKIP_GATE=1 did not skip the checks (rc=$rc): $out"
  assert_not_contains "$out" "stub-lint ran" "SKIP_GATE=1 still ran the linter"
  assert_not_contains "$out" "stub-tests ran" "SKIP_GATE=1 still ran the tests"
  pass "SKIP_GATE=1 skips every check and permits the push"
}

# A no-mistakes worker inherits this hook whether or not anyone wired it there
# (bin/fm-local-push-check.sh's NO_MISTAKES_GATE entry owns why), so the check
# must stand down rather than run that pipeline's own lint and tests again.
test_the_no_mistakes_pipeline_is_left_alone() {
  local dir out rc
  dir=$(make_checkout nomistakes 1 1) || fail "could not build the pipeline fixture"
  out=$(run_gate "$dir" NO_MISTAKES_GATE=1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "the checker did not stand down for no-mistakes (rc=$rc): $out"
  assert_not_contains "$out" "stub-lint ran" "the checker linted inside the pipeline"
  assert_not_contains "$out" "stub-tests ran" "the checker ran tests inside the pipeline"
  assert_contains "$out" "standing down" "the checker did not say why it did nothing"
  pass "the checker stands down inside the no-mistakes pipeline"
}

# The ref list is the only thing that says what a push contains. Checking the
# working tree and reporting that as a verdict on some other branch is a false
# green, which is worse than no check at all.
test_a_push_that_is_not_the_checkout_is_refused() {
  local dir out rc other
  dir=$(make_checkout foreign 0 0) || fail "could not build the foreign-push fixture"
  other=1111111111111111111111111111111111111111
  out=$(run_gate "$dir" \
    "FM_PUSH_REFS=refs/heads/other $other refs/heads/other $ZERO") && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a push of another commit was permitted (rc=$rc): $out"
  assert_not_contains "$out" "stub-lint ran" \
    "the checker checked the working tree and would have spoken for another branch"
  assert_contains "$out" "SKIP_GATE=1" "the refusal did not name the documented override"
  pass "a push that does not carry the checked-out commit is refused, not passed"
}

test_a_deletion_carries_nothing_to_check() {
  local dir out rc
  dir=$(make_checkout deletion 1 1) || fail "could not build the deletion fixture"
  out=$(run_gate "$dir" \
    "FM_PUSH_REFS=(delete) $ZERO refs/heads/gone 2222222222222222222222222222222222222222") \
    && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "deleting a remote branch was refused (rc=$rc): $out"
  assert_not_contains "$out" "stub-lint ran" "a deletion ran the linter"
  assert_not_contains "$out" "stub-tests ran" "a deletion ran the tests"
  pass "a push that only deletes refs runs nothing and is permitted"
}

# When git names the remote side, that commit bounds exactly what this push
# adds, which is a better answer than the suite runner's default base and does
# not depend on any particular remote branch existing.
test_the_remote_side_becomes_the_test_base() {
  local dir out rc head remote
  dir=$(make_checkout basepass 0 0) || fail "could not build the base fixture"
  head=$(head_of "$dir")
  # A real commit, because a base this clone cannot resolve is deliberately
  # not passed on; test_an_unfetched_remote_side_is_not_passed_on owns that.
  git -C "$dir" commit -q --allow-empty -m later
  remote=$head
  head=$(head_of "$dir")
  out=$(run_gate "$dir" \
    "FM_PUSH_REFS=refs/heads/main $head refs/heads/main $remote") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "pushing the checked-out commit was refused (rc=$rc): $out"
  assert_contains "$out" "stub-tests ran --changed --base $remote" \
    "the checker did not bound the tests by the commit the remote already has"
  pass "the commit the remote already has becomes the test base"
}

# A push can carry several refs. Tying ONE of them to the working tree says
# nothing about the others, and letting it stand for all of them is the same
# false green the ref list was read to prevent.
test_a_push_carrying_another_branch_is_refused() {
  local dir out rc head other
  dir=$(make_checkout multiref 0 0) || fail "could not build the multi-ref fixture"
  head=$(head_of "$dir")
  git -C "$dir" checkout -q -b sideline
  printf 'never examined\n' > "$dir/unreviewed.txt"
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" commit -q -m sideline
  other=$(head_of "$dir")
  git -C "$dir" checkout -q -
  [ "$(head_of "$dir")" = "$head" ] || fail "the fixture did not return to the first commit"
  [ "$other" != "$head" ] || fail "the fixture's two commits are the same, so this proves nothing"
  out=$(run_gate "$dir" \
    "FM_PUSH_REFS=refs/heads/main $head refs/heads/main $ZERO
refs/heads/sideline $other refs/heads/sideline $ZERO") && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a push carrying an unexamined branch was permitted (rc=$rc): $out"
  assert_contains "$out" "do not have checked out" \
    "the refusal did not say which commit it could not speak for"
  pass "a push carrying a branch other than the checkout is refused, not passed"
}

# An annotated tag's ref line carries the TAG OBJECT's sha, never the commit's,
# so an unpeeled comparison refuses every annotated tag with a message that is
# simply untrue.
test_an_annotated_tag_on_the_checkout_is_permitted() {
  local dir out rc tag
  dir=$(make_checkout tagpush 0 0) || fail "could not build the tag fixture"
  git -C "$dir" tag -a v1.0 -m release
  tag=$(git -C "$dir" rev-parse v1.0)
  [ "$tag" != "$(head_of "$dir")" ] \
    || fail "the fixture's tag is not annotated, so this proves nothing"
  out=$(run_gate "$dir" "FM_PUSH_REFS=refs/tags/v1.0 $tag refs/tags/v1.0 $ZERO") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "an annotated tag on the checked-out commit was refused (rc=$rc): $out"
  pass "an annotated tag naming the checked-out commit is permitted"
}

# A force-push to a ref this clone never fetched names a remote commit that is
# not here. Handing it to the suite runner makes it refuse with a message about
# a flag nobody passed, so widen to its own default instead.
test_an_unfetched_remote_side_is_not_passed_on() {
  local dir out rc head
  dir=$(make_checkout baseunknown 0 0) || fail "could not build the unknown-base fixture"
  head=$(head_of "$dir")
  out=$(run_gate "$dir" \
    "FM_PUSH_REFS=refs/heads/main $head refs/heads/main 3333333333333333333333333333333333333333") \
    && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a remote side we do not have refused the push (rc=$rc): $out"
  assert_contains "$out" "stub-tests ran --changed" "the tests did not run at all"
  assert_not_contains "$out" "--base" \
    "the checker passed on a base commit this clone cannot resolve"
  pass "a remote commit this clone does not have is not passed on as a base"
}

test_a_new_branch_keeps_the_default_base() {
  local dir out rc head
  dir=$(make_checkout newbranch 0 0) || fail "could not build the new-branch fixture"
  head=$(head_of "$dir")
  out=$(run_gate "$dir" \
    "FM_PUSH_REFS=refs/heads/new $head refs/heads/new $ZERO") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "pushing a new branch was refused (rc=$rc): $out"
  assert_contains "$out" "stub-tests ran --changed" "the checker did not run the tests"
  assert_not_contains "$out" "--base" \
    "the checker invented a base for a branch the remote does not have"
  pass "a branch the remote does not have yet keeps the suite runner's own base"
}

# git pipes the ref list on stdin. The hook must read it and pass it on, and
# must NOT leave that pipe open to the commands the checker runs, which would
# let one of them consume it.
test_the_hook_reads_the_ref_list_and_keeps_it_from_the_checks() {
  local dir out rc head
  dir=$(make_checkout hookrefs 0 0) || fail "could not build the hook fixture"
  head=$(head_of "$dir")
  # Two refs, so a hook that read only as far as it needed would leave the
  # second line on stdin for the first command the checker runs to swallow.
  out=$( cd "$dir" && printf 'refs/heads/main %s refs/heads/main %s\nrefs/heads/side %s refs/heads/side %s\n' \
    "$head" "$ZERO" "$head" "$ZERO" \
    | bash .githooks/pre-push origin git@example.invalid:x.git 2>&1 ) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "the hook refused a clean push (rc=$rc): $out"
  assert_contains "$out" "stub-lint ran" \
    "the hook did not pass the ref list on, so the checker could not tie it to HEAD"
  assert_contains "$out" 'stdin:[]' \
    "the ref list reached a command the checker ran instead of being consumed by the hook"
  assert_not_contains "$out" "stdin:[refs/" \
    "a command the checker ran read the push's ref list off its own stdin"
  pass ".githooks/pre-push reads the ref list, passes it on, and keeps it off the checks"
}

# The hook is the only thing that puts the ref list where the checker reads it.
# Drive the refusal through the hook, not through the checker's environment, or
# nothing notices when the hand-off stops happening and every push of a commit
# other than HEAD goes back to being waved through.
test_the_hook_hands_the_ref_list_over_well_enough_to_refuse() {
  local dir out rc other
  dir=$(make_checkout hookscope 0 0) || fail "could not build the hook-scope fixture"
  git -C "$dir" checkout -q -b sideline
  git -C "$dir" commit -q --allow-empty -m sideline
  other=$(head_of "$dir")
  git -C "$dir" checkout -q -
  [ "$other" != "$(head_of "$dir")" ] \
    || fail "the fixture's two commits are the same, so this proves nothing"
  out=$( cd "$dir" && printf 'refs/heads/sideline %s refs/heads/sideline %s\n' "$other" "$ZERO" \
    | bash .githooks/pre-push origin git@example.invalid:x.git 2>&1 ) && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "the hook permitted a push of a commit that is not checked out (rc=$rc): $out"
  assert_contains "$out" "do not have checked out" \
    "the hook did not deliver the ref list, so the checker had no scope to refuse"
  pass ".githooks/pre-push delivers the ref list well enough for the checker to refuse on it"
}

test_the_hook_refuses_exactly_as_the_checker_does() {
  local dir out rc head
  dir=$(make_checkout hookfail 1 0) || fail "could not build the hook-failure fixture"
  head=$(head_of "$dir")
  out=$( cd "$dir" && printf 'refs/heads/main %s refs/heads/main %s\n' "$head" "$ZERO" \
    | bash .githooks/pre-push origin git@example.invalid:x.git 2>&1 ) && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail ".githooks/pre-push did not refuse a failing push (rc=$rc): $out"
  assert_contains "$out" "push refused" "the hook did not surface the refusal"
  pass ".githooks/pre-push refuses exactly as the checker does"
}

# bin/fm-githooks-wire.sh's header owns why a clone needs arming at all. What
# these pin is its restraint, which matters more than its action.
wire_fixture() {  # <name>
  local dir=$1
  dir="$TMP_ROOT/$dir"
  mkdir -p "$dir/.githooks"
  git init -q "$dir" 2>/dev/null || return 1
  printf '%s\n' "$dir"
}

wired_local() { git -C "$1" config --local --get core.hooksPath 2>/dev/null || true; }
wired_effective() { git -C "$1" config --get core.hooksPath 2>/dev/null || true; }

# A relative hooks path would name nothing in a worktree whose checkout has no
# .githooks, disabling that worktree's hooks instead of adding one; the wiring
# script's header owns why the value is shared across worktrees at all.
test_wiring_writes_an_absolute_path() {
  local dir
  dir=$(wire_fixture wire-empty) || fail "could not build the unwired fixture"
  bash "$WIRE" "$dir" >/dev/null 2>&1 || fail "wiring an unwired checkout failed"
  case "$(wired_local "$dir")" in
    /*) ;;
    *) fail "core.hooksPath is not absolute: '$(wired_local "$dir")'" ;;
  esac
  [ -d "$(wired_local "$dir")" ] \
    || fail "core.hooksPath does not name a directory: '$(wired_local "$dir")'"
  pass "wiring points an unwired checkout at an absolute .githooks that exists"
}

test_wiring_survives_a_worktree_without_the_hooks_directory() {
  local dir linked
  dir=$(wire_fixture wire-worktree) || fail "could not build the worktree fixture"
  git -C "$dir" config --local user.email fixture@example.invalid
  git -C "$dir" config --local user.name fixture
  git -C "$dir" commit -q --allow-empty -m base
  bash "$WIRE" "$dir" >/dev/null 2>&1 || fail "wiring failed"
  linked="$TMP_ROOT/wire-worktree-linked"
  git -C "$dir" worktree add -q --detach "$linked" HEAD 2>/dev/null \
    || fail "could not add a linked worktree"
  # The linked worktree has no .githooks of its own; the shared value must
  # still resolve, or that worktree's hooks are silently switched off. Resolve
  # it FROM that worktree: a relative value tested from anywhere else is tested
  # against the wrong directory, and this suite's runner works from the repo
  # root, where a bare '.githooks' exists and the check would pass vacuously.
  ( cd "$linked" && [ -d "$(git config --get core.hooksPath)" ] ) \
    || fail "the shared hooks path does not resolve inside a linked worktree: '$(wired_effective "$linked")'"
  pass "the wired path still resolves from a worktree that has no .githooks of its own"
}

# core.hooksPath is one shared value for the whole repository, so a run from a
# disposable worktree that named ITSELF would point the clone at a directory
# that vanishes with that worktree - after which git runs no hooks at all and
# says nothing. This repository's own validation pipeline runs from exactly
# such a worktree.
test_wiring_from_a_linked_worktree_names_the_main_one() {
  local dir linked
  dir=$(wire_fixture wire-from-linked) || fail "could not build the main fixture"
  git -C "$dir" config --local user.email fixture@example.invalid
  git -C "$dir" config --local user.name fixture
  git -C "$dir" commit -q --allow-empty -m base
  linked="$TMP_ROOT/wire-from-linked-worktree"
  git -C "$dir" worktree add -q --detach "$linked" HEAD 2>/dev/null \
    || fail "could not add a linked worktree"
  bash "$WIRE" "$linked" >/dev/null 2>&1 || fail "wiring from a linked worktree failed"
  [ "$(wired_local "$dir")" = "$dir/.githooks" ] \
    || fail "wiring from a linked worktree named '$(wired_local "$dir")', not the main worktree's .githooks"
  pass "wiring run from a linked worktree points the repository at the main worktree"
}

# A session start is the only thing that arms an ordinary clone, so the wiring
# has to survive being called from bin/fm-bootstrap.sh and not just by hand.
# tests/lib.sh sets FM_GITHOOKS_WIRE_SKIP=1 for every suite, because this is the
# one bootstrap sweep that writes to the CODE root: without it a test run would
# rewrite whatever checkout it was started from, and the fact the first wiring
# prints would land in output other suites assert is empty. Strip it here, the
# way tests/fm-gate-refuse.test.sh strips its own bypass, so both halves are
# proved: bootstrap really wires, and the escape hatch really stops it.
test_a_session_start_arms_the_clone_unless_the_suite_stops_it() {
  local dir out
  dir=$(wire_fixture wire-bootstrap) || fail "could not build the bootstrap fixture"
  mkdir -p "$dir/bin" "$dir/home"
  cp "$WIRE" "$dir/bin/fm-githooks-wire.sh"
  chmod +x "$dir/bin/fm-githooks-wire.sh"

  out=$(FM_GITHOOKS_WIRE_SKIP=1 FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  [ -z "$(wired_local "$dir")" ] \
    || fail "a session start wired the checkout although the suite asked it not to: '$(wired_local "$dir")'"
  assert_not_contains "$out" "pointed this checkout" \
    "a skipped wiring still printed a startup fact, which other suites assert is absent"

  out=$(env -u FM_GITHOOKS_WIRE_SKIP FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  [ "$(wired_local "$dir")" = "$dir/.githooks" ] \
    || fail "a session start did not arm the clone: '$(wired_local "$dir")'"
  assert_contains "$out" "pointed this checkout" \
    "arming the clone was not reported as a startup fact"
  pass "a session start arms the clone, and the suite's own opt-out stops it"
}

test_wiring_never_overwrites_a_local_choice() {
  local dir
  dir=$(wire_fixture wire-existing) || fail "could not build the wired fixture"
  git -C "$dir" config --local core.hooksPath .myhooks
  bash "$WIRE" "$dir" >/dev/null 2>&1 || fail "wiring an already-wired checkout failed"
  [ "$(wired_local "$dir")" = .myhooks ] \
    || fail "wiring overwrote an existing core.hooksPath: '$(wired_local "$dir")'"
  pass "wiring leaves an existing core.hooksPath alone, so naming your own is a durable opt-out"
}

# Naming a directory is the opt-out; clearing the setting is not, because the
# next session start finds nothing set and wires it again. The header says so,
# so pin it: a header that promised the opposite is what this replaced.
test_clearing_the_setting_is_not_an_opt_out() {
  local dir
  dir=$(wire_fixture wire-cleared) || fail "could not build the cleared fixture"
  bash "$WIRE" "$dir" >/dev/null 2>&1 || fail "wiring an unwired checkout failed"
  git -C "$dir" config --local --unset core.hooksPath 2>/dev/null \
    || fail "could not clear core.hooksPath in the fixture"
  [ -z "$(wired_local "$dir")" ] \
    || fail "the fixture did not actually clear core.hooksPath, so this proves nothing"
  bash "$WIRE" "$dir" >/dev/null 2>&1 || fail "wiring after a clear failed"
  [ -n "$(wired_local "$dir")" ] \
    || fail "a cleared core.hooksPath was left cleared, which the header says it is not"
  pass "a cleared core.hooksPath is wired again, exactly as the header warns"
}

# bin/fm-bootstrap.sh classifies the startup digest's line from this token, so
# it is a contract rather than a convenience, and 'kept' stays quiet because a
# routine confirmation is not news.
test_wiring_names_its_outcome_for_a_caller() {
  local dir out err
  dir=$(wire_fixture wire-outcome) || fail "could not build the outcome fixture"
  out=$(bash "$WIRE" "$dir" 2>/dev/null)
  [ "$out" = wired ] || fail "a first wiring did not report 'wired': '$out'"
  out=$(bash "$WIRE" "$dir" 2>/tmp/fm-wire-kept.$$)
  err=$(cat /tmp/fm-wire-kept.$$ 2>/dev/null); rm -f /tmp/fm-wire-kept.$$
  [ "$out" = kept ] || fail "wiring an already-wired checkout did not report 'kept': '$out'"
  [ -z "$err" ] || fail "leaving our own value alone was announced instead of staying quiet: '$err'"
  out=$(bash "$WIRE" "$TMP_ROOT" 2>/dev/null)
  [ "$out" = skipped ] || fail "a checkout it cannot wire did not report 'skipped': '$out'"
  pass "wiring names its outcome on stdout so a session start can classify it"
}

# A global hooks path is usually somebody's org-wide signing or secret-scanning
# setup. A local value shadows it with no warning from git, so writing one over
# the top silently removes their hooks from the path.
test_wiring_never_shadows_a_global_choice() {
  local dir home theirs effective
  dir=$(wire_fixture wire-global) || fail "could not build the global fixture"
  home="$TMP_ROOT/wire-global-home"
  theirs="$home/.theirhooks"
  mkdir -p "$theirs"
  # tests/lib.sh points GIT_CONFIG_GLOBAL at /dev/null to isolate fixtures from
  # the host, so a global value has to be introduced through that same variable
  # rather than through HOME.
  GIT_CONFIG_GLOBAL="$home/gitconfig" git config --global core.hooksPath "$theirs"
  GIT_CONFIG_GLOBAL="$home/gitconfig" bash "$WIRE" "$dir" >/dev/null 2>&1 \
    || fail "wiring a globally-configured checkout failed"
  [ -z "$(wired_local "$dir")" ] \
    || fail "wiring shadowed a global core.hooksPath: '$(wired_local "$dir")'"
  effective=$(GIT_CONFIG_GLOBAL="$home/gitconfig" wired_effective "$dir")
  [ "$effective" = "$theirs" ] \
    || fail "the global hooks path no longer applies to this checkout: '$effective'"
  pass "wiring leaves a global core.hooksPath in force instead of shadowing it"
}

test_wiring_skips_a_checkout_with_no_hooks_directory() {
  local dir
  dir="$TMP_ROOT/wire-nohooks"
  mkdir -p "$dir"
  git init -q "$dir" 2>/dev/null || fail "could not build the hookless fixture"
  bash "$WIRE" "$dir" >/dev/null 2>&1 \
    || fail "wiring a hookless checkout should not fail a session open"
  [ -z "$(wired_local "$dir")" ] \
    || fail "wiring set core.hooksPath with no .githooks present: '$(wired_local "$dir")'"
  pass "wiring skips a checkout with no .githooks and disables nothing"
}

# A bare repository has no working tree, and resolving one through the common
# git dir would land on its PARENT directory, whose .githooks belongs to
# something else entirely.
test_wiring_skips_a_bare_repository() {
  local dir out
  mkdir -p "$TMP_ROOT/bare-parent/.githooks"
  dir="$TMP_ROOT/bare-parent/wire-bare.git"
  git init -q --bare "$dir" 2>/dev/null || fail "could not build the bare fixture"
  out=$(bash "$WIRE" "$dir" 2>/dev/null) || fail "wiring a bare repository should not fail"
  [ "$out" = skipped ] || fail "a bare repository was not reported as skipped: '$out'"
  [ -z "$(wired_local "$dir")" ] \
    || fail "wiring set core.hooksPath on a bare repository: '$(wired_local "$dir")'"
  pass "wiring skips a bare repository instead of reaching outside it for a hooks directory"
}

test_clean_tree_permits_the_push
test_a_failing_lint_refuses_the_push
test_a_failing_test_run_refuses_the_push
test_every_check_runs_even_after_an_earlier_failure
test_skip_gate_is_the_one_way_past
test_the_no_mistakes_pipeline_is_left_alone
test_a_push_that_is_not_the_checkout_is_refused
test_a_deletion_carries_nothing_to_check
test_the_remote_side_becomes_the_test_base
test_an_unfetched_remote_side_is_not_passed_on
test_a_push_carrying_another_branch_is_refused
test_an_annotated_tag_on_the_checkout_is_permitted
test_a_new_branch_keeps_the_default_base
test_the_hook_reads_the_ref_list_and_keeps_it_from_the_checks
test_the_hook_hands_the_ref_list_over_well_enough_to_refuse
test_the_hook_refuses_exactly_as_the_checker_does
test_wiring_writes_an_absolute_path
test_wiring_survives_a_worktree_without_the_hooks_directory
test_wiring_from_a_linked_worktree_names_the_main_one
test_a_session_start_arms_the_clone_unless_the_suite_stops_it
test_wiring_never_overwrites_a_local_choice
test_clearing_the_setting_is_not_an_opt_out
test_wiring_names_its_outcome_for_a_caller
test_wiring_never_shadows_a_global_choice
test_wiring_skips_a_checkout_with_no_hooks_directory
test_wiring_skips_a_bare_repository

echo "# all fm-local-push-check tests passed"
