#!/usr/bin/env bash
# bin/fm-teardown.sh: the report-less scout gate.
#
# A scout's deliverable is its report, so cleanup refuses while that report is
# missing - and that refusal must not depend on whether the scout's endpoint is
# still alive. But refusing FOREVER strands the slot: after a session provider
# restart an investigation can be left with a gone endpoint and no findings
# written down, and the only way to get the slot back is a forced cleanup
# (issue #9). That escape hatch stays, and must announce on one loud line that
# an investigation is being discarded - but only once the discard is actually
# certain, so a cleanup that refuses further down never claims to have thrown
# away work it left completely intact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-scout-report)

NOTICE='its investigation is being discarded'
ID_EMPTY_HINT='is empty'

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

# make_herdr_scout_case <name> <id>: the same report-less scout, recorded on a
# Herdr endpoint whose server answers nothing readable. Herdr's teardown
# preflight is NOT skipped by --force, so this cleanup refuses after the report
# gate has already been passed - the exact ordering the notice must respect.
make_herdr_scout_case() {  # <name> <id>
  local name=$1 id=$2 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/fakebin"
  fm_git_worktree "$dir/project" "$dir/worktree" "scout-$id"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/herdr" "$dir/fakebin/treehouse"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fmses:p1" "endpoint_task_id=$id" "backend=herdr" \
    "herdr_session=fmses" "herdr_workspace_id=w1" "herdr_tab_id=w1:t1" \
    "herdr_pane_id=p1" "worktree=$dir/worktree" "project=$dir/project" \
    "harness=claude" "kind=scout" "mode=local-only" "spawn_gen=s-scout-$id"
  printf '%s\n' "$dir"
}

test_a_later_refusal_never_prints_the_discard_notice() {
  local dir out rc
  dir=$(make_herdr_scout_case later-refusal sc5)
  out=$(run_teardown "$dir" sc5 --force); rc=$?
  expect_code 1 "$rc" "an unreadable Herdr endpoint must refuse even under --force"$'\n'"$out"
  case "$out" in
    *"$NOTICE"*)
      fail "the discard notice was printed over a teardown that then refused:"$'\n'"$out" ;;
  esac
  assert_present "$dir/home/state/sc5.meta" "the refused cleanup removed the task record"
  assert_present "$dir/worktree" "the refused cleanup removed the recorded local copy"
  pass "fm-teardown: nothing is announced as discarded by a cleanup that refuses instead"
}

# break_worktree_process_scan <case-dir>: make the leaked-process scan
# unanswerable. `reap_task_worktree_processes` then REFUSES - preserving the
# worktree, the tasktmp and the record - and it is not skipped by --force, so
# it runs after the report gate has already been passed.
break_worktree_process_scan() {  # <case-dir>
  cat > "$1/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$1/fakebin/lsof"
}

test_a_later_refusal_after_the_report_gate_never_prints_the_notice() {
  local dir out rc
  dir=$(make_scout_case reap-refusal sc6)
  break_worktree_process_scan "$dir"
  out=$(run_teardown "$dir" sc6 --force); rc=$?
  expect_code 1 "$rc" "an unanswerable leaked-process scan must refuse even under --force"$'\n'"$out"
  assert_contains "$out" "cannot determine leaked processes" \
    "the refusal should be the leaked-process scan, not an earlier gate"
  case "$out" in
    *"$NOTICE"*)
      fail "the discard notice was printed over a teardown that then refused:"$'\n'"$out" ;;
  esac
  assert_present "$dir/home/state/sc6.meta" "the refused cleanup removed the task record"
  assert_present "$dir/worktree" "the refused cleanup removed the recorded local copy"
  pass "fm-teardown: a refusal past the report gate still announces no discard"
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

# A zero-byte report is not a work product. The generated scout instructions
# forbid a terminal status until the report "exists and is non-empty", so the
# mechanical gates owe the same standard: an existence-only check lets an empty
# file satisfy cleanup and silently discard the investigation.
test_zero_byte_report_scout_is_refused_without_force() {
  local dir out rc
  dir=$(make_scout_case zero-byte sc5)
  : > "$dir/home/data/sc5/report.md"
  [ -f "$dir/home/data/sc5/report.md" ] || fail "fixture did not create the empty report"
  [ ! -s "$dir/home/data/sc5/report.md" ] || fail "fixture report was not empty"
  out=$(run_teardown "$dir" sc5); rc=$?
  expect_code 1 "$rc" "an empty scout report must refuse cleanup like a missing one"$'\n'"$out"
  case "$out" in
    *"$ID_EMPTY_HINT"*) ;;
    *) fail "the refusal did not name the empty report"$'\n'"$out" ;;
  esac
  pass "fm-teardown: a zero-byte scout report refuses cleanup without --force"
}

test_forced_zero_byte_report_teardown_announces_the_discard() {
  local dir out rc
  dir=$(make_scout_case zero-byte-forced sc6)
  : > "$dir/home/data/sc6/report.md"
  out=$(run_teardown "$dir" sc6 --force); rc=$?
  expect_code 0 "$rc" "a forced cleanup of an empty-report scout should succeed"$'\n'"$out"
  case "$out" in
    *"$NOTICE"*) ;;
    *) fail "a forced cleanup discarding an empty report must announce the loss"$'\n'"$out" ;;
  esac
  pass "fm-teardown: --force announces the discard for a zero-byte report too"
}

test_reportless_scout_with_a_gone_endpoint_is_refused_without_force
test_reportless_scout_with_a_live_endpoint_is_refused_without_force
test_forced_reportless_scout_teardown_announces_the_discard
test_a_later_refusal_never_prints_the_discard_notice
test_a_later_refusal_after_the_report_gate_never_prints_the_notice
test_forced_scout_teardown_with_a_report_is_silent
test_zero_byte_report_scout_is_refused_without_force
test_forced_zero_byte_report_teardown_announces_the_discard
