#!/usr/bin/env bash
# replay-incident.sh - replay the motivating burn incident through the REAL
# guard library at PRODUCTION defaults, and against the pre-fix library from
# this branch's own first commit (dd431fc), so the difference is measured on
# shipped code rather than described.
#
# The incident: a worker ran ~18 hours and spent 292.7k tokens producing
# nothing at all, twice on the same task, and nothing noticed either time.
#
# The pane is driven with the harness footer shapes this repo has recorded
# live, rendered as the PER-TURN counters they actually are: the number climbs
# through a turn and restarts at the next turn boundary.
set -u
WT=${1:?worktree}
OLDLIB=${2:?old lib path}

TURN_TOKENS=1100          # the recorded claude per-turn footer: "↓ 1.1k tokens"
POLLS_PER_TURN=4          # polled every 60s through a ~4 minute turn
POLL_SECS=60
TURNS=266                 # 266 x 1100 = 292.6k, the incident's spend
# Production defaults, untouched.
export FM_NOPROGRESS_SPEND=60000
export FM_NOPROGRESS_SECS=1800

hms() { printf '%dh%02dm' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )); }

# Render the pane the way the harness does at poll <p> of a turn.
render_pane() {  # <tokens-so-far-this-turn>
  local t=$1 k
  k=$(awk -v n="$t" 'BEGIN{printf "%.1f", n/1000}')
  printf 'ᐧ Reading src/engine/planner.rs\nᐧ Thinking about the retry path\n'
  printf '✢ Pollinating… (16s · ↓ %sk tokens · thought for 1s)\n' "$k"
}

# One replay. <lib> <mode> <label>
replay() {  # <lib> <mode>
  local lib=$1 mode=$2
  local dir state data now turn p tokens pane sig verdict escalations first_turn first_spend first_age first_reason
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-replay.XXXXXX")
  state="$dir/state"; data="$dir/data"
  mkdir -p "$state" "$data/burner"
  printf 'window=ops:fm-burner\nkind=ship\nharness=claude\n' > "$state/burner.meta"
  # shellcheck disable=SC1090
  ( set +u; . "$lib" ) 2>/dev/null
  # shellcheck disable=SC1090
  . "$lib"
  now=$(date +%s)
  escalations=0; first_turn=; first_spend=; first_age=; first_reason=
  turn=1
  while [ "$turn" -le "$TURNS" ]; do
    p=1
    while [ "$p" -le "$POLLS_PER_TURN" ]; do
      case "$mode" in
        burn|producing) tokens=$(( TURN_TOKENS * p / POLLS_PER_TURN )) ;;
        frozen)         tokens=$TURN_TOKENS ;;   # counter never moves: a wait
      esac
      pane=$(render_pane "$tokens")
      if [ "$mode" = producing ] && [ "$p" -eq "$POLLS_PER_TURN" ]; then
        # A scout appending findings to its report as it establishes them.
        printf 'finding %s: the retry path drops the correlation id\n' "$turn" \
          >> "$data/burner/report.md"
      fi
      sig=$(fm_noprogress_artifact_sig "$state" burner "$data")
      verdict=$(fm_noprogress_observe "$state" burner \
        "$(fm_noprogress_pane_tokens "$pane" || true)" "$sig" "$now")
      case "$verdict" in
        escalate\ *)
          escalations=$(( escalations + 1 ))
          if [ -z "$first_turn" ]; then
            first_turn=$turn
            first_spend=${verdict#escalate }; first_spend=${first_spend%% *}
            first_age=${verdict##* }
            first_reason=$(fm_noprogress_reason 'ops:fm-burner' "$first_spend" "$first_age")
          fi ;;
      esac
      now=$(( now + POLL_SECS ))
      p=$(( p + 1 ))
    done
    turn=$(( turn + 1 ))
  done
  REPLAY_ESCALATIONS=$escalations
  REPLAY_FIRST_TURN=$first_turn
  REPLAY_FIRST_SPEND=$first_spend
  REPLAY_FIRST_AGE=$first_age
  REPLAY_FIRST_REASON=$first_reason
  REPLAY_WALL=$(( TURNS * POLLS_PER_TURN * POLL_SECS ))
  rm -rf "$dir"
}

echo "================================================================================"
echo " THE INCIDENT, REPLAYED: 18 hours, 292.7k tokens, zero output"
echo "================================================================================"
echo " pane footer replayed (recorded live, docs/verification/runtime-backends.md):"
render_pane 1100 | sed 's/^/   | /'
echo "   per-turn counter: restarts at every turn boundary (266 turns x 1.1k tokens)"
echo "   artifacts: no commit, no report write, no status line - for the whole run"
echo "   gates: FM_NOPROGRESS_SPEND=$FM_NOPROGRESS_SPEND  FM_NOPROGRESS_SECS=$FM_NOPROGRESS_SECS  (production defaults)"
echo

echo "--------------------------------------------------------------------------------"
echo " BEFORE  bin/fm-noprogress-lib.sh @ dd431fc (this branch's first commit)"
echo "--------------------------------------------------------------------------------"
( replay "$OLDLIB" burn
  echo "   escalations over $(hms "$REPLAY_WALL") of unproductive spend: $REPLAY_ESCALATIONS"
  echo "   >> the burn runs all day and nobody is told."
)
echo

echo "--------------------------------------------------------------------------------"
echo " AFTER   bin/fm-noprogress-lib.sh @ HEAD"
echo "--------------------------------------------------------------------------------"
( replay "$WT/bin/fm-noprogress-lib.sh" burn
  echo "   escalations over $(hms "$REPLAY_WALL") of unproductive spend: $REPLAY_ESCALATIONS"
  echo "   first escalation at turn $REPLAY_FIRST_TURN, $(hms "$REPLAY_FIRST_AGE") into the run, ${REPLAY_FIRST_SPEND} tokens accumulated"
  echo
  echo "   what the human is told:"
  printf '%s\n' "$REPLAY_FIRST_REASON" | fold -s -w 74 | sed 's/^/     /'
)
echo

echo "================================================================================"
echo " THE TWO SHAPES THAT MUST STAY SILENT (same 18 hours, same library @ HEAD)"
echo "================================================================================"
( replay "$WT/bin/fm-noprogress-lib.sh" frozen
  echo "   frozen counter (a worker waiting on a background pipeline)"
  echo "     escalations: $REPLAY_ESCALATIONS   -> a wait is never flagged"
)
( replay "$WT/bin/fm-noprogress-lib.sh" producing
  echo "   counter climbing AND the report growing (a scout writing findings)"
  echo "     escalations: $REPLAY_ESCALATIONS   -> production is never flagged"
)
