#!/usr/bin/env bash
# tests/fm-crew-cap.test.sh - the spawn concurrency cap owned by
# bin/fm-crew-cap-lib.sh and enforced in bin/fm-spawn.sh.
#
# The incident (data/learnings.md, 2026-09-04): eleven workers ran at once in a
# single home, each paying its own startup cost re-reading the same
# repositories, and the provider allowance was exhausted before the work was.
#
# The guarantees under test, in the order they matter:
#   - THE FAIL-SAFE DIRECTION IS THE WHOLE RISK. Every task flows through spawn,
#     so a gate that errs toward refusing bricks the fleet. A broken, empty,
#     malformed, unsafe, or unreadable cap surface, and an unreadable endpoint
#     inventory, must all PERMIT the spawn - even in a home that is plainly over
#     its cap, which is what makes those cases non-vacuous here.
#   - Only positively verified live workers are counted. Losing either
#     independent signal - the session inventory listing the window, or the
#     pane's process classifying as an agent - must lower the count, never raise
#     it, so uncertainty can never manufacture a refusal.
#   - An established count at an established cap refuses, and the refusal names
#     what is already running.
#   - The documented override spawns past an established cap, and says so.
#   - Secondmates (persistent idle infrastructure) and another host's records
#     are never counted.
#
# Signals are driven apart deliberately: each negative case starts from a home
# that DOES refuse, then breaks exactly one input and asserts the refusal is
# gone. The refusing baseline is asserted in the same test so a broken fixture
# cannot make the negative cases pass vacuously.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-cap)
fm_git_identity fmtest fmtest@example.com

# A tmux fake that answers the two independent liveness signals separately, so a
# test can break one without touching the other:
#   FM_FAKE_WINDOWS   newline-separated session inventory (list-windows)
#   FM_FAKE_COMM_DIR  per-window pane_current_command override files
#   FM_FAKE_LIST_FAIL non-empty makes list-windows fail unreadably
# It keeps the spawn-world behaviors (pane path, session name, send-keys) so the
# real bin/fm-spawn.sh still runs end to end against it.
make_cap_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=
prev=
for a in "$@"; do
  [ "$prev" = "-t" ] && target=$a
  prev=$a
done
window=${target#*:}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*)
    if [ -n "${FM_FAKE_COMM_DIR:-}" ] && [ -f "$FM_FAKE_COMM_DIR/$window" ]; then
      cat "$FM_FAKE_COMM_DIR/$window"
    else
      printf '%s\n' claude
    fi
    exit 0
    ;;
  *"#{pane_pid}"*) exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_LIST_FAIL:-}" ]; then
      printf '%s\n' "permission denied" >&2
      exit 1
    fi
    printf '%s' "${FM_FAKE_WINDOWS:-}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# write_worker <home> <id> [comm]
# One ordinary local worker record plus its inventory window name.
write_worker() {
  local home=$1 id=$2 comm=${3:-claude}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/wt-$id" \
    "harness=claude" \
    "kind=ship"
  mkdir -p "$home/comms"
  printf '%s\n' "$comm" > "$home/comms/fm-$id"
  printf '%s\n' "fm-$id" >> "$home/windows"
}

new_cap_home() {
  local home=$1
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/comms"
  : > "$home/windows"
}

# run_check <home> [env assignments...]
# Runs fm_crew_cap_check in a real subprocess against the real libraries and
# prints "<rc>|<count>|<cap>|<warning>|<active ids>".
run_check() {
  local home=$1 fakebin
  shift
  fakebin=$(make_cap_tmux "$home/fake")
  env "$@" \
    FM_FAKE_WINDOWS="$(cat "$home/windows")" \
    FM_FAKE_COMM_DIR="$home/comms" \
    PATH="$fakebin:$PATH" \
    bash -c '
      . "$0/bin/fm-backend.sh"
      . "$0/bin/fm-crew-cap-lib.sh"
      rc=0
      fm_crew_cap_check "$1/config" "$1/state" || rc=$?
      printf "%s|%s|%s|%s|%s\n" "$rc" "$FM_CREW_CAP_COUNT" "$FM_CREW_CAP_VALUE" \
        "$FM_CREW_CAP_WARNING" "$(printf "%s" "$FM_CREW_CAP_ACTIVE" | tr "\n" " ")"
    ' "$ROOT" "$home"
}

rc_of() { printf '%s\n' "${1%%|*}"; }

field_of() {
  local record=$1 index=$2
  printf '%s\n' "$record" | cut -d'|' -f"$index"
}

# --- library level ----------------------------------------------------------

# An absent file is not uncertainty: absence has a documented default, and the
# operator must be able to see and edit it afterwards.
test_absent_cap_file_uses_and_publishes_the_default() {
  local home out
  home="$TMP_ROOT/absent"
  new_cap_home "$home"
  out=$(PATH="$(make_cap_tmux "$home/fake"):$PATH" bash -c \
    '. "$0/bin/fm-crew-cap-lib.sh"; fm_crew_cap_read "$1/config"' "$ROOT" "$home")
  [ "$out" = 3 ] || fail "an absent cap file must resolve to the documented default of 3, got '$out'"
  assert_present "$home/config/crew-concurrency-cap" "the default cap was not materialized for the operator"
  [ "$(cat "$home/config/crew-concurrency-cap")" = 3 ] \
    || fail "the materialized default must be the documented value"
  pass "fm-crew-cap: an absent cap file resolves to the default and publishes it"
}

# Only a verified live agent counts. Secondmates and remote records never do.
test_only_verified_live_local_workers_are_counted() {
  local home record
  home="$TMP_ROOT/counting"
  new_cap_home "$home"
  write_worker "$home" crew1                 # listed + agent  -> alive
  write_worker "$home" crew2                 # listed + agent  -> alive
  write_worker "$home" crew3 zsh             # listed + shell  -> dead
  write_worker "$home" crew5 node            # listed + node   -> ambiguous
  fm_write_meta "$home/state/crew4.meta" \
    "window=firstmate:fm-crew4" "harness=claude" "kind=ship"   # never listed -> missing
  fm_write_secondmate_meta "$home/state/sm1.meta" "$home/sm1"
  printf '%s\n' "fm-sm1" >> "$home/windows"
  fm_write_meta "$home/state/remote1.meta" \
    "window=firstmate:fm-remote1" "harness=claude" "kind=ship" "remote_host=elsewhere"
  printf '%s\n' "fm-remote1" >> "$home/windows"

  record=$(run_check "$home")
  [ "$(rc_of "$record")" = 0 ] || fail "two live workers under a cap of 3 must proceed: $record"
  [ "$(field_of "$record" 2)" = 2 ] \
    || fail "only the two verified live workers should be counted, got: $record"
  case "$(field_of "$record" 5)" in
    *crew1*) ;;
    *) fail "the active list must name crew1: $record" ;;
  esac
  case "$(field_of "$record" 5)" in
    *sm1*|*remote1*|*crew3*|*crew4*|*crew5*)
      fail "a secondmate, remote, dead, missing, or ambiguous record must never be counted: $record" ;;
  esac
  pass "fm-crew-cap: only verified live local workers count toward the cap"
}

# The refusing baseline, and then each independent signal broken in turn. Losing
# a signal must lower the count, never raise it.
test_established_count_refuses_and_losing_a_signal_never_does() {
  local home record refuse_rc=2
  home="$TMP_ROOT/refuse"
  new_cap_home "$home"
  write_worker "$home" crewA
  write_worker "$home" crewB
  write_worker "$home" crewC

  record=$(run_check "$home")
  [ "$(rc_of "$record")" = "$refuse_rc" ] \
    || fail "three live workers at a cap of 3 must refuse: $record"
  [ "$(field_of "$record" 2)" = 3 ] || fail "the refusal must report the measured count: $record"
  for id in crewA crewB crewC; do
    case "$(field_of "$record" 5)" in
      *"$id"*) ;;
      *) fail "the refusal must name $id so the operator can see what is running: $record" ;;
    esac
  done

  # Signal 1 broken: the session inventory is unreadable. Every window is now
  # unverifiable, so nothing is counted and the same home proceeds.
  record=$(run_check "$home" FM_FAKE_LIST_FAIL=1)
  [ "$(rc_of "$record")" != "$refuse_rc" ] \
    || fail "an unreadable endpoint inventory must never refuse a spawn: $record"
  [ "$(field_of "$record" 2)" = 0 ] || fail "an unreadable inventory must count nothing: $record"

  # Signal 2 broken: the inventory still lists every window, but no pane
  # classifies as an agent.
  for id in crewA crewB crewC; do printf 'zsh\n' > "$home/comms/fm-$id"; done
  record=$(run_check "$home")
  [ "$(rc_of "$record")" != "$refuse_rc" ] \
    || fail "panes with no verified agent must never refuse a spawn: $record"
  [ "$(field_of "$record" 2)" = 0 ] || fail "agent-less panes must count nothing: $record"

  # An error inside the check itself: the backend liveness reader is not even
  # available. The failure of the gate must never become a refusal.
  record=$(bash -c '
      . "$0/bin/fm-crew-cap-lib.sh"
      rc=0
      fm_crew_cap_check "$1/config" "$1/state" || rc=$?
      printf "%s|%s\\n" "$rc" "$FM_CREW_CAP_WARNING"
    ' "$ROOT" "$home")
  [ "$(rc_of "$record")" != "$refuse_rc" ] \
    || fail "an error inside the check itself must never refuse a spawn: $record"
  [ -n "$(field_of "$record" 2)" ] \
    || fail "a check that could not run must explain why: $record"
  pass "fm-crew-cap: an established count refuses, and losing any signal never does"
}

# The single most important class: a broken cap surface must not refuse, in a
# home that would otherwise refuse.
test_no_unsafe_or_malformed_cap_surface_can_refuse() {
  local home record cap
  home="$TMP_ROOT/unsafe"
  new_cap_home "$home"
  write_worker "$home" crewX
  write_worker "$home" crewY
  write_worker "$home" crewZ
  cap="$home/config/crew-concurrency-cap"

  # Baseline: this home genuinely refuses, so the cases below are not vacuous.
  printf '3\n' > "$cap"
  record=$(run_check "$home")
  [ "$(rc_of "$record")" = 2 ] || fail "the over-cap baseline must refuse: $record"

  # printf-style bodies keep the exact byte shape each case is about.
  for body in '' '0\n' 'three\n' '-1\n' '3' '3\n\n' '3 4\n' ' 3\n' '03\n'; do
    printf '%b' "$body" > "$cap"
    record=$(run_check "$home")
    [ "$(rc_of "$record")" != 2 ] \
      || fail "a malformed cap body '$body' must never refuse a spawn: $record"
    [ -n "$(field_of "$record" 4)" ] \
      || fail "a malformed cap body '$body' must explain why no cap was applied: $record"
  done

  # An unsafe file: a symlink can point anywhere, so it is not this home's setting.
  rm -f "$cap"
  printf '1\n' > "$home/elsewhere-cap"
  ln -s "$home/elsewhere-cap" "$cap"
  record=$(run_check "$home")
  [ "$(rc_of "$record")" != 2 ] || fail "a symlinked cap file must never refuse a spawn: $record"
  rm -f "$cap"

  # An unsafe config directory.
  printf '3\n' > "$home/config/crew-concurrency-cap"
  mv "$home/config" "$home/config-real"
  ln -s "$home/config-real" "$home/config"
  record=$(run_check "$home")
  [ "$(rc_of "$record")" != 2 ] || fail "a symlinked config directory must never refuse a spawn: $record"
  rm -f "$home/config"
  mv "$home/config-real" "$home/config"

  # An absent state directory cannot establish a count of anything.
  mv "$home/state" "$home/state-away"
  record=$(run_check "$home")
  [ "$(rc_of "$record")" != 2 ] || fail "an absent state directory must never refuse a spawn: $record"
  mv "$home/state-away" "$home/state"
  pass "fm-crew-cap: no unsafe or malformed cap surface can refuse a spawn"
}

# --- end to end through the real bin/fm-spawn.sh ----------------------------

# make_spawn_home <name> <live-worker-count>
# A real spawn home with a real isolated git worktree, plus <n> records that the
# cap tmux fake reports as verified live workers. Echoes "home|wt|fakebin".
make_spawn_home() {
  local name=$1 live=$2 case_dir home proj wt fakebin i
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fm_test_spawn_home "$home" claude
  mkdir -p "$home/comms"
  : > "$home/windows"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$name-new"
  i=1
  while [ "$i" -le "$live" ]; do
    write_worker "$home" "$name-live$i"
    i=$((i + 1))
  done
  fakebin=$(make_cap_tmux "$case_dir/fake")
  printf '%s|%s|%s|%s\n' "$home" "$wt" "$fakebin" "$proj"
}

# run_capped_spawn <home> <wt> <fakebin> <proj> <id> [env assignments...]
run_capped_spawn() {
  local home=$1 wt=$2 fakebin=$3 proj=$4 id=$5
  shift 5
  env "$@" \
    FM_FAKE_WINDOWS="$(cat "$home/windows")" \
    FM_FAKE_COMM_DIR="$home/comms" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="${TMUX:-fake,1,0}" \
    CLAUDE_CONFIG_DIR='' \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --mode local-only --yolo off 2>&1
}

test_spawn_permits_under_the_cap_and_refuses_past_it() {
  local rec home wt fakebin proj out status
  # Positive control: an under-cap spawn must actually succeed, or every
  # "did not refuse" assertion below would be meaningless.
  rec=$(make_spawn_home under 2)
  IFS='|' read -r home wt fakebin proj <<EOF
$rec
EOF
  out=$(run_capped_spawn "$home" "$wt" "$fakebin" "$proj" under-new); status=$?
  expect_code 0 "$status" "a spawn with two workers running and a cap of 3 must succeed: $out"
  assert_contains "$out" "spawned under-new" "the under-cap spawn did not report success"

  rec=$(make_spawn_home over 3)
  IFS='|' read -r home wt fakebin proj <<EOF
$rec
EOF
  out=$(run_capped_spawn "$home" "$wt" "$fakebin" "$proj" over-new); status=$?
  [ "$status" -ne 0 ] || fail "a fourth worker past the cap of 3 must be refused: $out"
  assert_contains "$out" "spawn refused" "the refusal must say the spawn was refused"
  assert_contains "$out" "over-live1" "the refusal must name a worker that is already running"
  assert_contains "$out" "crew-concurrency-cap" "the refusal must name the setting to change"
  assert_absent "$home/state/over-new.meta" "a refused spawn must not create task state"
  pass "fm-spawn: spawns under the cap succeed and a spawn past it is refused by name"
}

test_documented_override_spawns_past_the_cap_loudly() {
  local rec home wt fakebin proj out status
  rec=$(make_spawn_home override 3)
  IFS='|' read -r home wt fakebin proj <<EOF
$rec
EOF
  out=$(run_capped_spawn "$home" "$wt" "$fakebin" "$proj" override-new FM_CREW_CAP_OVERRIDE=1)
  status=$?
  expect_code 0 "$status" "the documented override must spawn past the cap: $out"
  assert_contains "$out" "spawned override-new" "the overridden spawn did not report success"
  assert_contains "$out" "FM_CREW_CAP_OVERRIDE" "using the override must be loud, not silent"
  assert_contains "$out" "override-live1" "the override warning must still name what is running"
  pass "fm-spawn: the documented override spawns past the cap and says so"
}

# The fleet-bricking case: an over-cap home whose cap surface is broken must
# still spawn. Asserted against the same fixture that refuses when the surface
# is intact, so the pass cannot be vacuous.
test_a_broken_cap_surface_never_blocks_a_spawn() {
  local rec home wt fakebin proj out status
  rec=$(make_spawn_home broken 3)
  IFS='|' read -r home wt fakebin proj <<EOF
$rec
EOF
  out=$(run_capped_spawn "$home" "$wt" "$fakebin" "$proj" broken-first)
  [ $? -ne 0 ] || fail "the intact fixture must refuse, or this case proves nothing: $out"

  printf 'not-a-number\n' > "$home/config/crew-concurrency-cap"
  out=$(run_capped_spawn "$home" "$wt" "$fakebin" "$proj" broken-new); status=$?
  expect_code 0 "$status" "a malformed cap value must not block a spawn: $out"
  assert_contains "$out" "concurrency cap not applied" "a skipped cap must warn, not stay silent"
  assert_contains "$out" "spawned broken-new" "the spawn must still complete: $out"

  : > "$home/config/crew-concurrency-cap"
  fm_test_spawn_brief "$home" broken-empty
  out=$(run_capped_spawn "$home" "$wt" "$fakebin" "$proj" broken-empty); status=$?
  expect_code 0 "$status" "an empty cap file must not block a spawn: $out"

  rm -f "$home/config/crew-concurrency-cap"
  fm_test_spawn_brief "$home" broken-blind
  out=$(run_capped_spawn "$home" "$wt" "$fakebin" "$proj" broken-blind FM_FAKE_LIST_FAIL=1)
  status=$?
  expect_code 0 "$status" "an unreadable endpoint inventory must not block a spawn: $out"
  pass "fm-spawn: a broken cap surface warns and never blocks a spawn"
}

test_absent_cap_file_uses_and_publishes_the_default
test_only_verified_live_local_workers_are_counted
test_established_count_refuses_and_losing_a_signal_never_does
test_no_unsafe_or_malformed_cap_surface_can_refuse
test_spawn_permits_under_the_cap_and_refuses_past_it
test_documented_override_spawns_past_the_cap_loudly
test_a_broken_cap_surface_never_blocks_a_spawn
