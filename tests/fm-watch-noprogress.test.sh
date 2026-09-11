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
# The four behaviours the guard has to separate, all with a churning pane:
#   climbing tokens, no artifact     -> escalate (the burn)
#   frozen tokens                    -> silent (a worker waiting on a pipeline)
#   climbing tokens, report grows    -> silent (a scout writing findings as it goes)
#   climbing tokens, worktree writes -> silent (a crew writing uncommitted source)
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

# The counter grammar every recorded harness footer renders. A pane this cannot
# read yields NO observation, which is what keeps an unrecognised harness on
# exactly the coverage it had before rather than on a guessed number.
test_pane_token_parsing() {
  local got
  got=$(fm_noprogress_pane_tokens '  · 292.7k tokens · esc to interrupt')
  [ "$got" = 292700 ] || fail "a 'k'-suffixed counter parsed as '$got', not 292700"
  got=$(fm_noprogress_pane_tokens ' Running  59 tokens')
  [ "$got" = 59 ] || fail "a bare counter parsed as '$got', not 59"
  got=$(fm_noprogress_pane_tokens '  · 1,234 tokens')
  [ "$got" = 1234 ] || fail "a comma-separated counter parsed as '$got', not 1234"
  # A footer can render more than one number next to "tokens". The FOOTER-MOST
  # one is the counter; which of them is per-turn does not matter, because
  # fm_noprogress_observe accumulates deltas across turn boundaries.
  got=$(fm_noprogress_pane_tokens 'session 292.7k tokens
turn 1.2k tokens')
  [ "$got" = 1200 ] || fail "two counters in one footer picked '$got', not the footer-most 1200"
  if fm_noprogress_pane_tokens 'reading the brief, nothing numeric here' >/dev/null 2>&1; then
    fail "a pane with no counter still produced an observation"
  fi
  # No spelling this repo has not recorded is accepted: an unrecognised footer
  # leaves the guard silent rather than reading a number out of prose.
  if fm_noprogress_pane_tokens 'tokens used: 1,234' >/dev/null 2>&1; then
    fail "an unrecorded 'tokens used:' spelling was read as a counter"
  fi

  # FOOTER REGION ONLY. Scrollback is content a worker prints, and a counter
  # grammar applied to content is a grammar an agent can forge - so a number
  # next to "tokens" above the footer region is not an observation.
  got=$(fm_noprogress_pane_tokens "$(printf 'the log says 999999 tokens\n%s\n' \
    "$(for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'running the suite\n'; done)") Running  59 tokens")
  [ "$got" = 59 ] \
    || fail "a number next to 'tokens' in scrollback was read as the counter ('$got', not 59)"
  # And the compaction notice this repo has recorded live is prose about a past
  # total, not a counter, even when it lands inside the footer region.
  if fm_noprogress_pane_tokens 'Compacted from 7,697 tokens' >/dev/null 2>&1; then
    fail "a compaction notice was read as a token counter"
  fi
  got=$(fm_noprogress_pane_tokens 'Compacted from 7,697 tokens
 Running  59 tokens')
  [ "$got" = 59 ] || fail "a compaction notice outweighed the real counter ('$got', not 59)"
  pass "the pane counter grammar reads every recorded harness footer and refuses to guess"
}

# FOOTER-MOST, NOT LARGEST. A constant number next to "tokens" can sit in the
# footer region above the live counter - a context budget, a quota line. Under a
# largest-match rule that constant is the reading on every single poll, so the
# delta is always zero, the frozen-counter gate short-circuits, and the guard
# goes silent for that harness forever while docs/architecture.md still says the
# shape is covered. That is the same "documented as protected while it is not"
# failure this attempt exists to end, so it is asserted end to end: the parser
# picks the counter, and the window built from those readings escalates.
test_a_constant_above_the_counter_cannot_pin_the_reading() {
  local dir state verdict got n poll escalated
  dir=$(make_case footer-most); state="$dir/state"
  export FM_NOPROGRESS_SPEND=1000 FM_NOPROGRESS_SECS=100

  got=$(fm_noprogress_pane_tokens 'Context left: 175000 tokens
 ⠘⠆ Running  59 tokens')
  [ "$got" = 59 ] \
    || fail "a larger constant above the counter was read instead of the counter ('$got', not 59)"

  # The counter climbs by 200 a poll under an unchanging 175000; the artifact
  # never moves. Reading the constant instead would hold spend at 0 forever.
  escalated=
  n=100
  poll=0
  while [ "$poll" -lt 20 ] && [ -z "$escalated" ]; do
    verdict=$(fm_noprogress_observe "$state" t \
      "$(fm_noprogress_pane_tokens "$(printf 'Context left: 175000 tokens\n ⠘⠆ Running  %s tokens\n' "$n")")" \
      sig-unchanged "$(( 1000000 + poll * 60 ))")
    case "$verdict" in escalate\ *) escalated=$verdict ;; esac
    n=$(( n + 200 ))
    poll=$(( poll + 1 ))
  done
  [ -n "$escalated" ] || fail \
    "a counter climbing under a larger constant never escalated - the constant pinned the reading: record=[$(cat "$(fm_noprogress_record "$state" t)")]"

  unset FM_NOPROGRESS_SPEND FM_NOPROGRESS_SECS
  pass "the footer-most counter is the reading, so a larger constant above it cannot pin the guard silent"
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

# THE REGRESSION THIS GUARD'S SECOND ATTEMPT EXISTS FOR. Every harness footer
# this repo has recorded live is a PER-TURN counter that restarts at each turn
# boundary, not a running session total. The first attempt read the rendered
# number as a cumulative total and re-anchored its baseline whenever the number
# dropped, so an all-day burn of ordinary turns never accumulated past ONE
# turn's tokens and could never reach the threshold.
#
# So this drives the real recorded footer shapes - verbatim, including their
# spinner glyphs and separators - through the real parser and the real decision
# function, across many turn boundaries, at the SHIPPED thresholds (read out of
# the library so the test tracks what actually ships), against an artifact that
# never moves. It must escalate, and it must do so well inside the ~18 hours the
# motivating burn ran.
FOOTER_TURNS=()
# Claude, tests/fm-tmux-submit-busy.test.sh:270 - "k"-suffixed, one decimal.
FOOTER_TURNS+=('✢ Pollinating… (@Ss · ↓ @k tokens · thought for 1s)')
# Claude, docs/verification/runtime-backends.md:677 - bare integer.
FOOTER_TURNS+=('Sock-hopping… (@Ss · ↓ @N tokens)')
# cursor, tests/fm-backend-herdr.test.sh:3916 - bare integer behind a spinner.
FOOTER_TURNS+=(' ⠘⠆ Running  @N tokens')

# render_turn_footer: one poll's pane, rendering <turn-tokens> in the recorded
# footer shape this turn index selects. The counter RESTARTS at every turn,
# which is the whole point, and the pane carries scrollback above the footer so
# the footer-region narrowing is exercised on the way through.
render_turn_footer() {  # <shape-index> <turn-tokens>
  local shape=${FOOTER_TURNS[$(( $1 % ${#FOOTER_TURNS[@]} ))]} n=$2 k
  # "1.1k" from 1100, the way a footer renders a four-figure per-turn count.
  k="$(( n / 1000 )).$(( (n % 1000) / 100 ))k"
  shape=${shape//@k/$k}
  shape=${shape//@N/$n}
  shape=${shape//@S/$(( n / 70 ))}
  printf 'reading src/thing.rs\nrunning the suite\n%s\n' "$shape"
}

# The shipped default for a threshold: the value the library gives itself in a
# clean environment, so this test measures what the fleet actually runs rather
# than a number copied here that could drift away from it.
shipped_default() {  # <var>
  # The inner script runs in a child shell with the overrides cleared, so the
  # library assigns its own default; single quotes are deliberate - $1 and $2
  # are the child's positional parameters, not this shell's.
  # shellcheck disable=SC2016
  env -u FM_NOPROGRESS_SPEND -u FM_NOPROGRESS_SECS bash -c \
    '. "$1"; printf "%s" "${!2}"' _ "$ROOT/bin/fm-noprogress-lib.sh" "$1"
}

test_recorded_per_turn_footers_accumulate_across_turns() {
  local dir state spend_gate secs_gate verdict
  local turn poll now tokens per_turn polls_per_turn escalated_at escalated_spend
  dir=$(make_case recorded-footers); state="$dir/state"

  spend_gate=$(shipped_default FM_NOPROGRESS_SPEND)
  secs_gate=$(shipped_default FM_NOPROGRESS_SECS)
  case "$spend_gate" in ''|*[!0-9]*) fail "could not read the shipped FM_NOPROGRESS_SPEND default" ;; esac
  case "$secs_gate" in ''|*[!0-9]*) fail "could not read the shipped FM_NOPROGRESS_SECS default" ;; esac
  export FM_NOPROGRESS_SPEND=$spend_gate FM_NOPROGRESS_SECS=$secs_gate

  # A worker polled every 30s, turning over every 2 minutes, each turn rendering
  # a counter that climbs from 0 to 1100 and then restarts - the ordinary
  # Claude turn this repo has on record. Eighteen hours of it.
  per_turn=1100
  polls_per_turn=4
  now=1000000
  escalated_at=
  escalated_spend=
  turn=0
  # 540 turns is the full 18 hours; the loop stops at the first escalation
  # because everything after it is the pacing rule, covered separately.
  while [ "$turn" -lt 540 ] && [ -z "$escalated_at" ]; do
    poll=1
    while [ "$poll" -le "$polls_per_turn" ] && [ -z "$escalated_at" ]; do
      tokens=$(( per_turn * poll / polls_per_turn ))
      verdict=$(fm_noprogress_observe "$state" t \
        "$(fm_noprogress_pane_tokens "$(render_turn_footer "$turn" "$tokens")")" \
        sig-unchanged "$now")
      case "$verdict" in
        escalate\ *)
          if [ -z "$escalated_at" ]; then
            escalated_at=$(( now - 1000000 ))
            escalated_spend=$(printf '%s' "$verdict" | cut -d' ' -f2)
          fi
          ;;
      esac
      now=$(( now + 30 ))
      poll=$(( poll + 1 ))
    done
    turn=$(( turn + 1 ))
  done

  [ -n "$escalated_at" ] || fail \
    "540 turns of real per-turn footers - 18 hours, $(( 540 * per_turn )) tokens - against an unchanged artifact never escalated at the shipped gates ($spend_gate tokens / ${secs_gate}s); record=[$(cat "$(fm_noprogress_record "$state" t)")]"
  [ "$escalated_spend" -ge "$spend_gate" ] || fail \
    "the escalation reported $escalated_spend tokens of spend, below the $spend_gate gate it claims to have crossed"
  # Well inside the burn: the point is that it fires long before a human would
  # have to notice 18 hours had passed.
  [ "$escalated_at" -le 21600 ] || fail \
    "it took ${escalated_at}s to notice a continuous burn of ordinary turns"

  # The same shapes, FROZEN - the pane redrawing an identical footer poll after
  # poll, which is a worker waiting - must still never escalate, over a window
  # four times older than the age gate and far past the burn case's turn count.
  fm_noprogress_clear "$state" frozen
  poll=0
  while [ "$poll" -lt 240 ]; do
    verdict=$(fm_noprogress_observe "$state" frozen \
      "$(fm_noprogress_pane_tokens "$(render_turn_footer 0 "$per_turn")")" \
      sig-unchanged "$(( 1000000 + poll * 30 ))")
    [ "$verdict" = ok ] || fail "a frozen recorded footer escalated on poll $poll: $verdict"
    poll=$(( poll + 1 ))
  done

  unset FM_NOPROGRESS_SPEND FM_NOPROGRESS_SECS
  pass "the recorded per-turn footers accumulate across turn boundaries, so an all-day burn escalates while a frozen footer stays silent"
}

# THE FROZEN-COUNTER GATE, ISOLATED. The decision table above exercises the gate
# only in states where the spend gate or the re-escalation pacing would have
# produced the same silence, so deleting the gate leaves those assertions green.
# This drives the one state where the gate is the ONLY thing standing between
# the window and a wake: spend already past its gate, then the counter freezes
# while the clock crosses the age gate, with nothing ever flagged so pacing
# cannot suppress anything.
test_frozen_counter_gate_is_the_only_thing_keeping_this_silent() {
  local dir state verdict rec
  dir=$(make_case frozen-gate); state="$dir/state"
  export FM_NOPROGRESS_SPEND=1000 FM_NOPROGRESS_SECS=100

  fm_noprogress_observe "$state" t 5000 sig-a 1000 >/dev/null
  # Spend gate crossed (4000 > 1000), age gate NOT yet (10 < 100).
  verdict=$(fm_noprogress_observe "$state" t 9000 sig-a 1010)
  [ "$verdict" = ok ] || fail "the setup poll escalated before the age gate was reached: $verdict"
  rec=$(fm_noprogress_record "$state" t)
  [ "$(sed -n 's/^spend=//p' "$rec" | tail -1)" -ge 1000 ] \
    || fail "the setup did not leave spend past its gate, so this proves nothing: $(cat "$rec")"
  [ "$(sed -n 's/^flagged=//p' "$rec" | tail -1)" = 0 ] \
    || fail "the setup already flagged, so re-escalation pacing could stand in for the gate: $(cat "$rec")"

  # Now the counter FREEZES and the age gate crosses. Both gates are satisfied
  # and nothing is paced: the frozen-counter gate alone must produce this ok.
  verdict=$(fm_noprogress_observe "$state" t 9000 sig-a 1200)
  [ "$verdict" = ok ] \
    || fail "a worker that spent past the gate and then went quiet was flagged as a burn: $verdict"

  # And the state really was one poll away from a wake: the identical window
  # with the counter moving by a single token escalates.
  verdict=$(fm_noprogress_observe "$state" t 9001 sig-a 1200)
  case "$verdict" in
    escalate\ *) ;;
    *) fail "the window was not actually eligible, so the frozen poll above proves nothing: $verdict" ;;
  esac

  unset FM_NOPROGRESS_SPEND FM_NOPROGRESS_SECS
  pass "a counter that freezes after the spend gate is a wait, and only the frozen-counter gate keeps it silent"
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

WIRED_DIR=; WIRED_STATE=; WIRED_OUT=; WIRED_PID=; WIRED_TOKENS=; WIRED_TMUXLOG=

# Drive a real watcher against a pane the test rewrites between rounds. The pane
# always churns, so the staleness backbone never fires and only the guard can
# produce a wake. <mode> chooses what each round changes.
run_wired_case() {  # <name> <mode> <rounds>
  local name=$1 mode=$2 rounds=$3
  local dir state fakebin out pane window pid tokens i tmuxlog
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; pane="$dir/pane.txt"; tmuxlog="$dir/tmux.log"
  window="test:fm-$name"
  mkdir -p "$dir/data/$name"
  printf 'window=%s\nkind=ship\nharness=codex\n' "$window" > "$state/$name.meta"
  # Only the writing case records a worktree: the bounded write probe needs one,
  # and the other cases must reach the escalation decision without one so their
  # verdicts come from the token/artifact rules alone.
  if [ "$mode" = writing ]; then
    mkdir -p "$dir/wt"
    printf 'worktree=%s\n' "$dir/wt" >> "$state/$name.meta"
  fi
  tokens=100000
  printf 'apply_patch start\n. %s tokens\n' "$tokens" > "$pane"
  # The codex verdict verbatim: no verified semantic busy source, so nothing
  # else on the stale path can absorb or surface this pane on our behalf.
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_FAKE_TMUX_LOG="$tmuxlog" \
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
      # Tokens climb exactly as fast as in the burn case and NO artifact moves -
      # no commit, no report, no status line - but the crew is writing
      # uncommitted source in its own worktree. That is the crew docs/architecture.md
      # promises is deferred rather than flagged.
      writing)
        tokens=$((tokens + 4000))
        printf 'fn thing_%s() {}\n' "$i" >> "$dir/wt/lib.rs"
        ;;
    esac
    printf 'apply_patch frame-%s\n. %s tokens\n' "$i" "$tokens" > "$pane"
    sleep 0.4
    i=$((i + 1))
  done
  WIRED_DIR=$dir; WIRED_STATE=$state; WIRED_OUT=$out; WIRED_PID=$pid; WIRED_TOKENS=$tokens
  WIRED_TMUXLOG=$tmuxlog
}

# The guard may only raise a flag. tmux is the ONLY channel this watcher has to
# reach a worker, and the fixture records every command it issued through that
# channel, so a guard that interrupted, signalled, restarted, or tore one down
# has to show up here as a mutating verb.
assert_no_worker_control_issued() {  # <tmux-log>
  local log=$1 issued verb
  [ -s "$log" ] \
    || fail "the fixture recorded no tmux calls at all, so this proves nothing ($log)"
  issued=$(cat "$log")
  printf '%s\n' "$issued" | grep -q '^capture-pane' \
    || fail "the watcher never even read the pane, so the recorded commands prove nothing: [$issued]"
  while read -r verb _; do
    case "$verb" in
      send-keys|send-prefix|kill-window|kill-pane|kill-session|kill-server|respawn-pane|respawn-window)
        fail "the guard issued '$verb' on a burning worker; it may only escalate: [$issued]" ;;
    esac
  done <<EOF
$issued
EOF
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
  # ESCALATE, NEVER KILL - asserted on what the escalating watcher actually did,
  # not on what its source says. It flagged the burn and touched the worker's
  # window read-only throughout.
  assert_no_worker_control_issued "$WIRED_TMUXLOG"
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

# A crew writing uncommitted source in its own worktree is producing, even
# though none of the three cheap artifact signals moves. The guard defers to the
# same bounded write probe the wedge timer uses and restarts the window instead
# of escalating; without that branch this exact pane - tokens climbing, nothing
# committed, nothing reported, nothing appended - is the burn shape and wakes
# firstmate on a crew that is doing its job.
test_uncommitted_worktree_writes_defer_instead_of_escalating() {
  run_wired_case writing writing 25
  # NOT assert_guard_observed here: the deferral under test IS a
  # fm_noprogress_clear, so the per-task record this case is meant to prove the
  # guard wrote is the very file the absorb branch deletes, and whether it
  # survives to the end of the driver loop is a coin toss. The triage line
  # asserted below is the durable proof, and a stronger one - it can only be
  # written by a poll that observed the pane, accumulated past both gates,
  # reached the escalation branch, and deferred there.
  [ -s "$WIRED_DIR/wt/lib.rs" ] \
    || fail "the writing fixture never wrote into the worktree, so its silence proves nothing"
  [ "$WIRED_TOKENS" -gt 100000 ] \
    || fail "the writing fixture never spent any tokens, so its silence proves nothing"
  if queued_guard_wake "$WIRED_STATE"; then
    reap "$WIRED_PID"; unset FM_FAKE_CREW_STATE
    fail "a crew writing uncommitted source in its worktree was flagged as a burn: queue=[$(cat "$WIRED_STATE/.wake-queue" 2>/dev/null)]"
  fi
  # ...and the silence is the deferral, not a window that never became
  # eligible: the write probe is consulted only in the branch that was about to
  # escalate, so its absorb line is proof the decision was actually reached.
  grep -qF 'absorbed spend-without-artifact' "$WIRED_STATE/.watch-triage.log" 2>/dev/null \
    || { reap "$WIRED_PID"; unset FM_FAKE_CREW_STATE
         fail "the guard never reached the write probe, so nothing was deferred: triage=[$(cat "$WIRED_STATE/.watch-triage.log" 2>/dev/null)]"; }
  is_live_non_zombie "$WIRED_PID" \
    || { unset FM_FAKE_CREW_STATE
         fail "the watcher exited during the writing case, so its silence proves nothing: out=[$(cat "$WIRED_OUT")]"; }
  reap "$WIRED_PID"
  unset FM_FAKE_CREW_STATE
  pass "a crew writing uncommitted files in its worktree is deferred, not escalated"
}

test_pane_token_parsing
test_a_constant_above_the_counter_cannot_pin_the_reading
test_observe_decision_table
test_reescalation_and_counter_reset
test_recorded_per_turn_footers_accumulate_across_turns
test_frozen_counter_gate_is_the_only_thing_keeping_this_silent
test_artifact_fingerprint_tracks_each_signal
test_climbing_tokens_without_artifact_escalate
test_frozen_token_wait_stays_silent
test_growing_report_stays_silent
test_uncommitted_worktree_writes_defer_instead_of_escalating
