#!/usr/bin/env bash
# bin/fm-teardown.sh: the report-less scout gate.
#
# A scout's deliverable is its report, so cleanup refuses while that report is
# missing - and that refusal must not depend on whether the scout's endpoint is
# still alive. But refusing FOREVER strands the slot: after a session provider
# restart an investigation can be left with a gone endpoint and no findings
# written down, and the only way to get the slot back is a forced cleanup
# (issue #9). That escape hatch stays, and must announce on one loud line that
# an investigation is being discarded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-scout-report)

NOTICE='its investigation is being discarded'

# make_scout_case <name> <id> [--live]: a scout task whose recorded endpoint is
# structurally gone unless --live is passed, and which has written no report.
make_scout_case() {  # <name> <id> [live]
  local name=$1 id=$2 live=${3:-} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/fakebin"
  fm_git_worktree "$dir/project" "$dir/worktree" "scout-$id"
  # The session inventory decides whether the recorded window still exists, so
  # one stub covers both the gone and the live endpoint.
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) [ -z "${live:-}" ] || printf 'fm-$id\n'; exit 0 ;;
esac
exit 0
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/treehouse"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$dir/worktree" \
    "project=$dir/project" "harness=claude" "kind=scout" "mode=local-only" \
    "spawn_gen=s-scout-$id"
  printf '%s\n' "$dir"
}

# run_teardown <case-dir> <id> [args...]: prints combined output; the caller
# reads the exit code from $? on the assignment, since a command substitution
# cannot hand a variable back out.
run_teardown() {  # <case-dir> <id> [args...]
  local dir=$1 id=$2; shift 2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@" 2>&1
}

test_reportless_scout_with_a_gone_endpoint_is_refused_without_force() {
  local dir out rc
  dir=$(make_scout_case gone-refuse sc1)
  out=$(run_teardown "$dir" sc1); rc=$?
  expect_code 1 "$rc" "a report-less scout must still refuse without --force"$'\n'"$out"
  assert_contains "$out" "REFUSED: scout task sc1 has no report" \
    "the refusal should name the missing report"
  case "$out" in
    *"$NOTICE"*) fail "a refusal must not print the forced-discard notice" ;;
  esac
  assert_present "$dir/home/state/sc1.meta" "a refused cleanup removed the task record"
  pass "fm-teardown: a report-less scout with a gone endpoint still refuses without --force"
}

test_reportless_scout_with_a_live_endpoint_is_refused_without_force() {
  local dir out rc
  dir=$(make_scout_case live-refuse sc2 live)
  out=$(run_teardown "$dir" sc2); rc=$?
  expect_code 1 "$rc" "a report-less scout with a live endpoint must refuse"$'\n'"$out"
  assert_contains "$out" "REFUSED: scout task sc2 has no report" \
    "the live-endpoint refusal should be the unchanged report refusal"
  assert_present "$dir/home/state/sc2.meta" "a refused cleanup removed the task record"
  pass "fm-teardown: the report-less scout refusal is unchanged for a live endpoint"
}

test_forced_reportless_scout_teardown_announces_the_discard() {
  local dir out rc
  dir=$(make_scout_case gone-force sc3)
  out=$(run_teardown "$dir" sc3 --force); rc=$?
  expect_code 0 "$rc" "a forced cleanup must return the stranded slot"$'\n'"$out"
  assert_contains "$out" "NOTICE: FORCED teardown of scout task sc3 with NO report" \
    "the forced cleanup must announce that no report existed"
  assert_contains "$out" "$NOTICE" \
    "the notice must say the investigation is being discarded"
  assert_absent "$dir/home/state/sc3.meta" "the forced cleanup left the task record behind"
  pass "fm-teardown: --force returns a stranded report-less scout and says what it discarded"
}

test_forced_scout_teardown_with_a_report_is_silent() {
  local dir out rc
  dir=$(make_scout_case with-report sc4)
  printf '# Findings\n\nthe investigation landed here\n' > "$dir/home/data/sc4/report.md"
  out=$(run_teardown "$dir" sc4 --force); rc=$?
  expect_code 0 "$rc" "a forced cleanup of a reported scout should succeed"$'\n'"$out"
  case "$out" in
    *"$NOTICE"*) fail "a scout WITH a report must not be reported as discarded" ;;
  esac
  pass "fm-teardown: the discard notice is scoped to a scout that actually has no report"
}

test_reportless_scout_with_a_gone_endpoint_is_refused_without_force
test_reportless_scout_with_a_live_endpoint_is_refused_without_force
test_forced_reportless_scout_teardown_announces_the_discard
test_forced_scout_teardown_with_a_report_is_silent
