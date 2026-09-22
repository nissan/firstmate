#!/usr/bin/env bash
# Contract tests for the local pre-push gate: bin/fm-pre-push-gate.sh and the
# hook that calls it, .githooks/pre-push.
#
# Origin: firstmate CI spends about 221 billed minutes per run across 17 jobs,
# and in the seven days to 2026-09-22 most of that went on re-running the full
# fan-out to find a failure the same checks catch locally in about a minute.
# The gate only pays that back if it actually refuses a bad push, so these
# tests pin the properties that make it trustworthy: every check runs even
# after an earlier one fails, any failure refuses the push, a clean tree
# permits it, and SKIP_GATE is the one documented way past it.
#
# The gate is driven in a throwaway checkout whose bin/fm-lint.sh and
# bin/fm-test-run.sh are stubs, so these assertions describe the gate's own
# orchestration rather than re-testing the linter and the suite runner, which
# own their behavior and have their own regressions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-pre-push-gate.sh"
HOOK="$ROOT/.githooks/pre-push"
TMP_ROOT=$(fm_test_tmproot fm-pre-push-gate)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

assert_present "$GATE" "bin/fm-pre-push-gate.sh is missing"
assert_present "$HOOK" ".githooks/pre-push is missing"
[ -x "$GATE" ] || fail "bin/fm-pre-push-gate.sh is not executable"
[ -x "$HOOK" ] || fail ".githooks/pre-push is not executable, so git would ignore it"

# Build a throwaway checkout carrying the real gate and hook over stub tools.
# <lint-rc> and <test-rc> are the exit statuses the two stubs return.
make_checkout() {  # <name> <lint-rc> <test-rc>
  local dir=$1 lint_rc=$2 test_rc=$3
  dir="$TMP_ROOT/$dir"
  mkdir -p "$dir/bin" "$dir/.githooks"
  git -C "$dir" init -q 2>/dev/null || { git init -q "$dir" 2>/dev/null || return 1; }
  cp "$GATE" "$dir/bin/fm-pre-push-gate.sh"
  cp "$HOOK" "$dir/.githooks/pre-push"
  chmod +x "$dir/bin/fm-pre-push-gate.sh" "$dir/.githooks/pre-push"
  cat > "$dir/bin/fm-lint.sh" <<STUB
#!/usr/bin/env bash
# --list-files names one real script so the gate has something to parse.
if [ "\${1:-}" = --list-files ]; then
  printf '%s\n' bin/fm-lint.sh
  exit 0
fi
printf 'stub-lint ran\n'
exit $lint_rc
STUB
  cat > "$dir/bin/fm-test-run.sh" <<STUB
#!/usr/bin/env bash
printf 'stub-tests ran %s\n' "\$*"
exit $test_rc
STUB
  chmod +x "$dir/bin/fm-lint.sh" "$dir/bin/fm-test-run.sh"
  printf '%s\n' "$dir"
}

run_gate() {  # <dir> [env-assignment...]
  local dir=$1
  shift
  ( cd "$dir" && env "$@" bash bin/fm-pre-push-gate.sh 2>&1 )
}

test_clean_tree_permits_the_push() {
  local dir out rc
  dir=$(make_checkout clean 0 0) || fail "could not build the clean fixture"
  out=$(run_gate "$dir") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a clean tree refused the push (rc=$rc): $out"
  assert_contains "$out" "stub-lint ran" "the gate did not run the linter"
  assert_contains "$out" "stub-tests ran --changed" \
    "the gate did not run the affected tests with --changed"
  assert_contains "$out" "local gate passed" "the gate did not report passing"
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

# A gate that stopped at the first failure would hand back one problem per
# push, so a two-fault branch would cost two full CI runs to discover locally.
test_every_check_runs_even_after_an_earlier_failure() {
  local dir out rc
  dir=$(make_checkout bothfail 1 1) || fail "could not build the both-failing fixture"
  out=$(run_gate "$dir") && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a doubly-failing tree did not refuse the push (rc=$rc): $out"
  assert_contains "$out" "stub-lint ran" "the linter did not run"
  assert_contains "$out" "stub-tests ran" \
    "the gate stopped at the failing linter instead of reporting both faults"
  pass "every check runs even after an earlier one fails"
}

test_skip_gate_is_the_one_way_past() {
  local dir out rc
  dir=$(make_checkout skipped 1 1) || fail "could not build the skip fixture"
  out=$(run_gate "$dir" SKIP_GATE=1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "SKIP_GATE=1 did not skip the gate (rc=$rc): $out"
  assert_not_contains "$out" "stub-lint ran" "SKIP_GATE=1 still ran the linter"
  assert_not_contains "$out" "stub-tests ran" "SKIP_GATE=1 still ran the tests"
  pass "SKIP_GATE=1 skips every check and permits the push"
}

# git runs the hook from the top level with the ref list on stdin. The hook
# must not leave that pipe open to the gate's own commands, and must refuse
# exactly as the gate does.
test_the_hook_refuses_exactly_as_the_gate_does() {
  local dir out rc
  dir=$(make_checkout hook 1 0) || fail "could not build the hook fixture"
  out=$( cd "$dir" && printf 'refs/heads/x abc refs/heads/x def\n' \
    | bash .githooks/pre-push origin git@example.invalid:x.git 2>&1 ) && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail ".githooks/pre-push did not refuse a failing push (rc=$rc): $out"
  assert_contains "$out" "push refused" "the hook did not surface the gate's refusal"
  pass ".githooks/pre-push hands its ref list nowhere and refuses as the gate does"
}

test_clean_tree_permits_the_push
test_a_failing_lint_refuses_the_push
test_a_failing_test_run_refuses_the_push
test_every_check_runs_even_after_an_earlier_failure
test_skip_gate_is_the_one_way_past
test_the_hook_refuses_exactly_as_the_gate_does

echo "# all fm-pre-push-gate tests passed"
