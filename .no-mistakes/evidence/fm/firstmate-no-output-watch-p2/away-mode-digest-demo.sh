#!/usr/bin/env bash
# away-mode-digest-demo.sh - the captain's away-mode surface.
#
# The motivating burn ran UNATTENDED. In that posture the supervise daemon owns
# triage, and its cheaper status-log classification used to absorb the guard's
# escalation outright: a burning crew's last status line is a nonterminal
# `working:`/`paused:`, so the daemon self-handled the wake and the captain was
# never told. This drives the REAL guard, the REAL handle_wake, and the REAL
# escalate_flush, and prints the digest the captain actually receives.
set -u
WT=${1:?worktree}
export FM_TEST_DAEMON_SOURCED=1
# shellcheck source=/dev/null
. "$WT/tests/wake-helpers.sh"
# shellcheck source=/dev/null
. "$WT/bin/fm-supervise-daemon.sh"
# shellcheck source=/dev/null
. "$WT/bin/fm-noprogress-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-away-demo)

DIGEST=
# Capture what the daemon would inject into the captain's supervisor pane.
inject_msg() { printf '%s\n' "$1" >> "$DIGEST"; return 0; }

# Run the real guard until it escalates, and return its human-facing reason.
guard_reason() {  # <state> <task> <window> <data> <mode>
  local state=$1 task=$2 win=$3 data=$4 mode=$5 sig verdict n poll
  sig=$(fm_noprogress_artifact_sig "$state" "$task" "$data")
  fm_noprogress_clear "$state" "$task"
  verdict=ok; n=20000; poll=0
  while [ "$poll" -lt 8 ] && [ "${verdict%% *}" != escalate ]; do
    case "$mode" in
      burn)   verdict=$(fm_noprogress_observe "$state" "$task" "$n" "$sig" "$(( 1000000 + poll * 600 ))")
              n=$(( n + 20000 )) ;;
      frozen) verdict=$(fm_noprogress_observe "$state" "$task" 250000 "$sig" "$(( 1000000 + poll * 600 ))") ;;
    esac
    poll=$(( poll + 1 ))
  done
  case "$verdict" in
    escalate\ *) verdict=${verdict#escalate }
                 fm_noprogress_reason "$win" "${verdict%% *}" "${verdict##* }" ;;
    *) printf '' ;;
  esac
}

scene() {  # <label> <mode> <status-lines...>
  local label=$1 mode=$2; shift 2
  local dir state task win reason
  dir=$(make_supercase "away-$label"); state="$dir/state"
  task="w-$label"; win="sess:fm-$task"
  DIGEST="$dir/digest.txt"; : > "$DIGEST"
  mkdir -p "$dir/data/$task"
  fm_write_meta "$state/$task.meta" "window=$win" "backend=tmux"
  printf '%s\n' "$@" > "$state/$task.status"
  printf 'esc to interrupt\n' > "$dir/pane.txt"

  echo "  crew status log (what the daemon's cheap classifier reads):"
  sed 's/^/      /' "$state/$task.status"
  echo "  that classifier's own verdict for this pane:"
  printf '      %s\n' "$(FM_STATE_OVERRIDE="$state" classify_stale "$win" "$state")"

  reason=$(guard_reason "$state" "$task" "$win" "$dir/data" "$mode")
  if [ -z "$reason" ]; then
    echo "  the guard's verdict: ok on every poll - nothing to route"
  else
    LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 \
      handle_wake "$reason" "$state"
  fi
  FM_STATE_OVERRIDE="$state" escalate_flush "$state" || true
  echo
  echo "  >> what the captain receives while away:"
  if [ -s "$DIGEST" ]; then
    fold -s -w 76 "$DIGEST" | sed 's/^/      /'
  else
    echo "      (nothing - the captain is not paged)"
  fi
  echo
}

echo "================================================================================"
echo " AWAY MODE: what reaches the captain when nobody is watching"
echo "================================================================================"
echo
echo "### A. burning crew, still reporting progress"
scene progress burn 'working: still working through the audit'

echo "### B. burning crew behind a DECLARED WAIT (the unattended posture)"
scene paused burn 'working: started the audit' 'paused: the audit engine is running to completion'

echo "### C. same declared wait, counter FROZEN - a real wait, not a burn"
scene waiting frozen 'working: started the audit' 'paused: the audit engine is running to completion'

echo "### D. burning crew with an UNREAD actionable status event"
echo "    (the burn must not silently mark that event reported)"
scene blocked burn 'blocked: need prod credentials'
