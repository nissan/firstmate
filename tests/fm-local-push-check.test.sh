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

# core.hooksPath lives in the shared config every linked worktree reads, so a
# no-mistakes worker inherits this hook whether or not anyone wired it there.
# That pipeline runs its own lint and targeted tests before it pushes, so the
# check must stand down rather than run them a second time inside it.
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
  remote=3333333333333333333333333333333333333333
  out=$(run_gate "$dir" \
    "FM_PUSH_REFS=refs/heads/main $head refs/heads/main $remote") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "pushing the checked-out commit was refused (rc=$rc): $out"
  assert_contains "$out" "stub-tests ran --changed --base $remote" \
    "the checker did not bound the tests by the commit the remote already has"
  pass "the commit the remote already has becomes the test base"
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

# The check only fires when core.hooksPath names .githooks, and that is
# per-clone local config no clone inherits. bin/fm-githooks-wire.sh is what a
# session start runs to set it, so its restraint matters more than its action.
wire_fixture() {  # <name>
  local dir=$1
  dir="$TMP_ROOT/$dir"
  mkdir -p "$dir/.githooks"
  git init -q "$dir" 2>/dev/null || return 1
  printf '%s\n' "$dir"
}

wired_local() { git -C "$1" config --local --get core.hooksPath 2>/dev/null || true; }
wired_effective() { git -C "$1" config --get core.hooksPath 2>/dev/null || true; }

# core.hooksPath is stored once for the whole repository, so every linked
# worktree resolves the same string. A relative one names nothing in a worktree
# whose checkout has no .githooks, and a hooks path naming nothing disables
# that worktree's hooks entirely instead of adding one.
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
  # still resolve, or that worktree's hooks are silently switched off.
  [ -d "$(wired_effective "$linked")" ] \
    || fail "the shared hooks path does not resolve in a linked worktree: '$(wired_effective "$linked")'"
  pass "the wired path still resolves from a worktree that has no .githooks of its own"
}

test_wiring_never_overwrites_a_local_choice() {
  local dir
  dir=$(wire_fixture wire-existing) || fail "could not build the wired fixture"
  git -C "$dir" config --local core.hooksPath .myhooks
  bash "$WIRE" "$dir" >/dev/null 2>&1 || fail "wiring an already-wired checkout failed"
  [ "$(wired_local "$dir")" = .myhooks ] \
    || fail "wiring overwrote an existing core.hooksPath: '$(wired_local "$dir")'"
  pass "wiring leaves an existing core.hooksPath alone, so unsetting it is a durable opt-out"
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

test_wiring_skips_a_bare_repository() {
  local dir
  dir="$TMP_ROOT/wire-bare.git"
  git init -q --bare "$dir" 2>/dev/null || fail "could not build the bare fixture"
  mkdir -p "$dir/.githooks"
  bash "$WIRE" "$dir" >/dev/null 2>&1 || fail "wiring a bare repository should not fail"
  [ -z "$(wired_local "$dir")" ] \
    || fail "wiring set core.hooksPath on a bare repository: '$(wired_local "$dir")'"
  pass "wiring skips a bare repository, which has no working tree to hook"
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
test_a_new_branch_keeps_the_default_base
test_the_hook_reads_the_ref_list_and_keeps_it_from_the_checks
test_the_hook_refuses_exactly_as_the_checker_does
test_wiring_writes_an_absolute_path
test_wiring_survives_a_worktree_without_the_hooks_directory
test_wiring_never_overwrites_a_local_choice
test_wiring_never_shadows_a_global_choice
test_wiring_skips_a_checkout_with_no_hooks_directory
test_wiring_skips_a_bare_repository

echo "# all fm-local-push-check tests passed"
