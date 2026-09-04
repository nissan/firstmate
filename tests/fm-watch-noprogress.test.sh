#!/usr/bin/env bash
# tests/fm-watch-noprogress.test.sh - the spend-without-artifact guard
# (bin/fm-noprogress-lib.sh) and its wiring into bin/fm-watch.sh.
#
# The motivating incident: a worker ran roughly 18 hours and spent 292.7k tokens
# producing nothing at all, twice on the same task, and nothing noticed either
# time. The pane-staleness backbone could not see it, because that backbone only
# fires on a FROZEN pane hash and this pane never froze - its token counter kept
# climbing.
#
# So the wiring cases below deliberately drive panes that CHURN on every poll,
# and every assertion is made while that churn is still running - never after
# the fixture stops rewriting the pane, which would let the backbone go stale
# and hand a wake to an assertion that did not earn it. Verified: against the
# pre-guard watcher the escalating case fails, and it fails because nothing
# carrying this guard's reason was ever queued.
#
# Each silent case additionally asserts that the guard DID observe the pane (its
# per-task record exists and holds the counter the fixture last rendered), so
# silence can never be the silence of a check that never ran.
#
# The three behaviours the guard has to separate, all with a churning pane:
#   climbing tokens, no artifact   -> escalate (the burn)
#   frozen tokens                  -> silent (a worker waiting on a pipeline)
#   climbing tokens, report grows  -> silent (a scout writing findings as it goes)
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-noprogress-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-noprogress-tests)

# The phrase the guard's wake reason is built around. Asserted as a literal so a
# silently reworded reason cannot let a "no wake" case pass vacuously.
GUARD_PHRASE='spending without producing'

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Whether the durable queue holds a guard escalation yet.
queued_guard_wake() {  # <state>
  grep -qF "$GUARD_PHRASE" "$1/.wake-queue" 2>/dev/null
}

# --- the library, as pure functions ----------------------------------------

# The counter grammar every verified harness renders. A pane this cannot read
# yields NO observation, which is what keeps an unrecognised harness on exactly
# the coverage it had before rather than on a guessed number.
test_pane_token_parsing() {
  local got
  got=$(fm_noprogress_pane_tokens '  · 292.7k tokens · esc to interrupt')
  [ "$got" = 292700 ] || fail "a 'k'-suffixed counter parsed as '$got', not 292700"
  got=$(fm_noprogress_pane_tokens ' Running  59 tokens')
  [ "$got" = 59 ] || fail "a bare counter parsed as '$got', not 59"
  got=$(fm_noprogress_pane_tokens 'tokens used: 1,234')
  [ "$got" = 1234 ] || fail "a comma-separated counter parsed as '$got', not 1234"
  got=$(fm_noprogress_pane_tokens 'Total tokens: 15,300')
  [ "$got" = 15300 ] || fail "a 'tokens:' counter parsed as '$got', not 15300"
  # A footer can render a per-turn AND a session total. The session total is the
  # one that tracks cumulative burn; taking the smaller one would let each new
  # turn re-baseline and hide exactly the sustained spend this guard exists for.
  got=$(fm_noprogress_pane_tokens 'turn 1.2k tokens
session 292.7k tokens')
  [ "$got" = 292700 ] || fail "two counters in one footer picked '$got', not the larger 292700"
  if fm_noprogress_pane_tokens 'reading the brief, nothing numeric here' >/dev/null 2>&1; then
    fail "a pane with no counter still produced an observation"
  fi
  pass "the pane counter grammar reads every verified harness footer and refuses to guess"
}

# The core decision table, driven directly so each rule is asserted alone.
test_observe_decision_table() {
  local dir state verdict
  dir=$(make_case observe-table); state="$dir/state"
  export FM_NOPROGRESS_SPEND=1000 FM_NOPROGRESS_SECS=100

  # First sighting only opens a window; it can never escalate on its own.
  verdict=$(fm_noprogress_observe "$state" t "5000" "sig-a" 1000)
  [ "$verdict" = ok ] || fail "a first sighting escalated: $verdict"

  # THE BURN. Tokens climbed past the threshold against an unchanged artifact,
  # and the window is older than the time gate.
  fm_noprogress_observe "$state" t "5500" "sig-a" 1050 >/dev/null
  verdict=$(fm_noprogress_observe "$state" t "9000" "sig-a" 1200)
  [ "$verdict" = "escalate 4000 200" ] \
    || fail "spend without artifact did not escalate as expected: $verdict"

  # THE FROZEN WAIT. Same task, same unchanged artifact, spend still far past
  # the threshold - but the counter did not move since the previous poll, so the
  # worker is waiting, not burning, and the guard says nothing.
  fm_noprogress_clear "$state" t
  fm_noprogress_observe "$state" t "5000" "sig-a" 1000 >/dev/null
  fm_noprogress_observe "$state" t "9000" "sig-a" 1100 >/dev/null
  verdict=$(fm_noprogress_observe "$state" t "9000" "sig-a" 9999)
  [ "$verdict" = ok ] || fail "a frozen counter escalated: $verdict"
  # And it stays silent however long the wait runs.
  verdict=$(fm_noprogress_observe "$state" t "9000" "sig-a" 99999)
  [ "$verdict" = ok ] || fail "a long frozen wait escalated: $verdict"

  # PRODUCTION. The artifact fingerprint moved, so the window restarts and the
  # accumulated spend goes with it.
  fm_noprogress_clear "$state" t
  fm_noprogress_observe "$state" t "5000" "sig-a" 1000 >/dev/null
  verdict=$(fm_noprogress_observe "$state" t "9000" "sig-b" 1200)
  [ "$verdict" = ok ] || fail "a moved artifact escalated: $verdict"
  verdict=$(fm_noprogress_observe "$state" t "9400" "sig-b" 1400)
  [ "$verdict" = ok ] || fail "spend from before the artifact moved was not reset: $verdict"

  # BOTH GATES. Spend past the threshold but the window younger than the time
  # gate is a fast burst, not a burn.
  fm_noprogress_clear "$state" t
  fm_noprogress_observe "$state" t "5000" "sig-a" 1000 >/dev/null
  verdict=$(fm_noprogress_observe "$state" t "9000" "sig-a" 1010)
  [ "$verdict" = ok ] || fail "a young window escalated on spend alone: $verdict"
  # ...and a long window with little spend is just a slow task.
  fm_noprogress_clear "$state" t
  fm_noprogress_observe "$state" t "5000" "sig-a" 1000 >/dev/null
  verdict=$(fm_noprogress_observe "$state" t "5100" "sig-a" 9000)
  [ "$verdict" = ok ] || fail "a long quiet window escalated on age alone: $verdict"

  # An unreadable counter is no observation at all.
  verdict=$(fm_noprogress_observe "$state" t "" "sig-a" 9000)
  [ "$verdict" = ok ] || fail "an unreadable counter escalated: $verdict"

  unset FM_NOPROGRESS_SPEND FM_NOPROGRESS_SECS
  pass "observe: the burn escalates; frozen counter, moved artifact, one gate alone, and an unreadable counter stay silent"
}

# One flagged burn must not become a wake on every poll thereafter, and a
# counter that goes backwards (a compaction, a fresh session) must not launder
# the burn by restarting the artifact clock.
test_reescalation_and_counter_reset() {
  local dir state verdict
  dir=$(make_case observe-pacing); state="$dir/state"
  export FM_NOPROGRESS_SPEND=1000 FM_NOPROGRESS_SECS=100

  fm_noprogress_observe "$state" t "5000" "sig-a" 1000 >/dev/null
  fm_noprogress_observe "$state" t "5500" "sig-a" 1050 >/dev/null
  verdict=$(fm_noprogress_observe "$state" t "9000" "sig-a" 1200)
  case "$verdict" in escalate\ *) ;; *) fail "the first burn did not escalate: $verdict" ;; esac
  verdict=$(fm_noprogress_observe "$state" t "9100" "sig-a" 1300)
  [ "$verdict" = ok ] || fail "a flagged burn re-escalated on the very next poll: $verdict"
  verdict=$(fm_noprogress_observe "$state" t "10500" "sig-a" 1400)
  case "$verdict" in escalate\ *) ;; *) fail "a burn that kept burning never flagged again: $verdict" ;; esac

  # A backwards counter re-anchors the baseline but keeps the artifact clock, so
  # the window's age survives the reset.
  fm_noprogress_clear "$state" t
  fm_noprogress_observe "$state" t "5000" "sig-a" 1000 >/dev/null
  fm_noprogress_observe "$state" t "200" "sig-a" 1500 >/dev/null
  verdict=$(fm_noprogress_observe "$state" t "1400" "sig-a" 1600)
  case "$verdict" in
    escalate\ *) ;;
    *) fail "spend after a counter reset never escalated, so a reset launders a burn: $verdict" ;;
  esac
  case "$verdict" in
    *' 600') ;;
    *) fail "a counter reset restarted the artifact clock: $verdict" ;;
  esac

  unset FM_NOPROGRESS_SPEND FM_NOPROGRESS_SECS
  pass "escalations are paced by further spend, and a counter reset cannot launder a burn"
}

# The artifact fingerprint has to move for each of the three cheap signals, and
# an unreadable component must contribute a fixed placeholder rather than a
# changing value (or an unreadable worktree would read as constant progress).
test_artifact_fingerprint_tracks_each_signal() {
  local dir state data wt a b
  dir=$(make_case artifact-sig); state="$dir/state"; data="$dir/data"
  wt="$dir/wt"; mkdir -p "$wt" "$data/t"
  printf 'window=test:fm-t\nkind=ship\nworktree=%s\n' "$wt" > "$state/t.meta"
  git -C "$wt" init -q
  git -C "$wt" config user.email t@example.com
  git -C "$wt" config user.name t
  printf 'one\n' > "$wt/f"
  git -C "$wt" add f >/dev/null
  git -C "$wt" commit -qm one >/dev/null

  a=$(fm_noprogress_artifact_sig "$state" t "$data")
  printf 'two\n' > "$wt/f"
  git -C "$wt" commit -qam two >/dev/null
  b=$(fm_noprogress_artifact_sig "$state" t "$data")
  [ "$a" != "$b" ] || fail "a landed commit did not move the artifact fingerprint"

  a=$b
  printf 'a finding\n' >> "$data/t/report.md"
  b=$(fm_noprogress_artifact_sig "$state" t "$data")
  [ "$a" != "$b" ] || fail "a growing report did not move the artifact fingerprint"

  a=$b
  printf 'working: still going\n' >> "$state/t.status"
  b=$(fm_noprogress_artifact_sig "$state" t "$data")
  [ "$a" != "$b" ] || fail "a status append did not move the artifact fingerprint"

  # A task with nothing readable at all must produce a STABLE fingerprint, so
  # the guard can still observe it rather than seeing endless fake progress.
  printf 'window=test:fm-none\nkind=ship\n' > "$state/none.meta"
  a=$(fm_noprogress_artifact_sig "$state" none "$data")
  sleep 1
  b=$(fm_noprogress_artifact_sig "$state" none "$data")
  [ "$a" = "$b" ] || fail "an unreadable task's fingerprint changed on its own: $a vs $b"

  pass "the artifact fingerprint moves on a commit, a report write, and a status append, and is stable when unreadable"
}

# --- the wiring, against a real bin/fm-watch.sh -----------------------------

WIRED_DIR=; WIRED_STATE=; WIRED_OUT=; WIRED_PID=; WIRED_TOKENS=

# Drive a real watcher against a pane the test rewrites between rounds. The pane
# always churns, so the staleness backbone never fires and only the guard can
# produce a wake. <mode> chooses what each round changes.
run_wired_case() {  # <name> <mode> <rounds>
  local name=$1 mode=$2 rounds=$3
  local dir state fakebin out pane window pid tokens i
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; pane="$dir/pane.txt"
  window="test:fm-$name"
  mkdir -p "$dir/data/$name"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/$name.meta"
  tokens=100000
  printf 'apply_patch start\n. %s tokens\n' "$tokens" > "$pane"
  # The codex verdict verbatim: no verified semantic busy source, so nothing
  # else on the stale path can absorb or surface this pane on our behalf.
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$dir/data" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_NOPROGRESS_SPEND=5000 FM_NOPROGRESS_SECS=0 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt "$rounds" ]; do
    is_live_non_zombie "$pid" || break
    queued_guard_wake "$state" && break
    case "$mode" in
      # Tokens climb. Nothing else moves.
      burn) tokens=$((tokens + 4000)) ;;
      # The counter is FROZEN while the pane still churns - a worker parked on a
      # background pipeline. Nothing is being spent, so nothing is wrong.
      frozen) : ;;
      # Tokens climb exactly as fast as in the burn case, but the report grows
      # too: a scout appending findings as it establishes them.
      producing)
        tokens=$((tokens + 4000))
        printf 'finding %s\n' "$i" >> "$dir/data/$name/report.md"
        ;;
    esac
    printf 'apply_patch frame-%s\n. %s tokens\n' "$i" "$tokens" > "$pane"
    sleep 0.4
    i=$((i + 1))
  done
  WIRED_DIR=$dir; WIRED_STATE=$state; WIRED_OUT=$out; WIRED_PID=$pid; WIRED_TOKENS=$tokens
}

# The guard is only allowed to be silent if it actually looked. Its per-task
# record is written on every observation, so its absence means the hook never
# ran and the case proves nothing.
assert_guard_observed() {  # <state> <task>
  local rec seen
  rec=$(fm_noprogress_record "$1" "$2")
  [ -f "$rec" ] \
    || fail "the guard never observed $2 at all, so its silence proves nothing (no $rec)"
  seen=$(sed -n 's/^tokens=//p' "$rec" | tail -1)
  case "$seen" in
    ''|*[!0-9]*) fail "the guard's record for $2 holds no token observation: $(cat "$rec")" ;;
  esac
  [ "$seen" -ge 100000 ] \
    || fail "the guard read '$seen' tokens from the fixture pane, which renders at least 100000"
}

test_climbing_tokens_without_artifact_escalate() {
  # The driver breaks the moment the guard escalates, so this is asserted with
  # the pane still churning: no plain staleness wake can stand in for it.
  run_wired_case burn burn 60
  queued_guard_wake "$WIRED_STATE" \
    || { reap "$WIRED_PID"; unset FM_FAKE_CREW_STATE
         fail "a pane whose token counter climbed with no commit, report write, or status line never escalated: queue=[$(cat "$WIRED_STATE/.wake-queue" 2>/dev/null)] out=[$(cat "$WIRED_OUT")]"; }
  assert_guard_observed "$WIRED_STATE" burn
  # The wake has to be actionable: the reason names what to inspect rather than
  # just reporting "stale", and says plainly that nothing was stopped.
  grep -qF 'demand-deep-inspection' "$WIRED_STATE/.wake-queue" \
    || fail "the escalation did not demand inspection, so it can be re-absorbed on pane state alone"
  grep -qF "captain's call" "$WIRED_STATE/.wake-queue" \
    || fail "the escalation did not state that stopping the worker is the captain's call"
  # An actionable wake exits the watcher so firstmate is woken.
  wait_for_exit "$WIRED_PID" 100 >/dev/null 2>&1 || true
  is_live_non_zombie "$WIRED_PID" \
    && { reap "$WIRED_PID"; unset FM_FAKE_CREW_STATE
         fail "the escalation was queued but the watcher kept polling, so firstmate is never woken"; }
  reap "$WIRED_PID"
  unset FM_FAKE_CREW_STATE
  pass "a churning pane spending tokens with no artifact escalates for a human"
}

test_frozen_token_wait_stays_silent() {
  run_wired_case frozen frozen 25
  assert_guard_observed "$WIRED_STATE" frozen
  if queued_guard_wake "$WIRED_STATE"; then
    reap "$WIRED_PID"; unset FM_FAKE_CREW_STATE
    fail "a worker idling on a background pipeline with a frozen token counter was flagged as a burn"
  fi
  is_live_non_zombie "$WIRED_PID" \
    || { unset FM_FAKE_CREW_STATE
         fail "the watcher exited during the frozen-counter case, so its silence proves nothing: out=[$(cat "$WIRED_OUT")]"; }
  reap "$WIRED_PID"
  unset FM_FAKE_CREW_STATE
  pass "a frozen token counter is a wait, not a burn, and never escalates"
}

test_growing_report_stays_silent() {
  run_wired_case producing producing 25
  assert_guard_observed "$WIRED_STATE" producing
  [ -s "$WIRED_DIR/data/producing/report.md" ] \
    || fail "the producing fixture never wrote a report, so its silence proves nothing"
  [ "$WIRED_TOKENS" -gt 100000 ] \
    || fail "the producing fixture never spent any tokens, so its silence proves nothing"
  if queued_guard_wake "$WIRED_STATE"; then
    reap "$WIRED_PID"; unset FM_FAKE_CREW_STATE
    fail "a worker spending tokens WHILE its report grew was flagged as a burn"
  fi
  is_live_non_zombie "$WIRED_PID" \
    || { unset FM_FAKE_CREW_STATE
         fail "the watcher exited during the producing case, so its silence proves nothing: out=[$(cat "$WIRED_OUT")]"; }
  reap "$WIRED_PID"
  unset FM_FAKE_CREW_STATE
  pass "a worker whose report file is growing is producing, and never escalates"
}

# The guard must never reach for a lifecycle control. Asserted against the
# source, because the escalating case above can only prove what it happened to
# execute, and the thing that must never happen is the thing never executed.
test_guard_never_stops_a_worker() {
  local src="$ROOT/bin/fm-noprogress-lib.sh" body
  # Comments are stripped first: this asserts on what the code RUNS, not on
  # prose that names the thing it must never do.
  if sed 's/#.*//' "$src" | grep -qE 'kill[[:space:]]|pkill|fm-control\.sh|send-keys|SIGINT|SIGTERM'; then
    fail "the guard library reaches for a lifecycle control; it may only escalate"
  fi
  body=$(sed -n '/^noprogress_check()/,/^}/p' "$ROOT/bin/fm-watch.sh")
  [ -n "$body" ] || fail "noprogress_check is not wired into the watcher"
  if printf '%s\n' "$body" | sed 's/#.*//' \
    | grep -qE 'kill[[:space:]]|pkill|fm-control\.sh|send-keys|SIGINT|SIGTERM'; then
    fail "the watcher's guard hook reaches for a lifecycle control; it may only escalate"
  fi
  printf '%s\n' "$body" | grep -qF 'fm_wake_append stale' \
    || fail "the watcher's guard hook does not raise a wake at all"
  pass "the guard only ever raises a flag - it never stops, signals, or restarts a worker"
}

test_pane_token_parsing
test_observe_decision_table
test_reescalation_and_counter_reset
test_artifact_fingerprint_tracks_each_signal
test_climbing_tokens_without_artifact_escalate
test_frozen_token_wait_stays_silent
test_growing_report_stays_silent
test_guard_never_stops_a_worker
