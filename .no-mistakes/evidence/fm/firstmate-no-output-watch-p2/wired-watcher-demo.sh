#!/usr/bin/env bash
# wired-watcher-demo.sh - drive the REAL bin/fm-watch.sh against a live-churning
# pane and show the operator surface it produces: the watcher's own stdout (the
# line that wakes firstmate) and the durable wake queue a human reads.
#
# Three panes, all churning on every poll so the pane-staleness backbone can
# never fire and only the spend-without-artifact guard can produce anything:
#   burn      tokens climbing, nothing produced          -> must escalate
#   waiting   token counter frozen                       -> must stay silent
#   producing tokens climbing, report growing            -> must stay silent
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
WT=${1:?worktree}
# shellcheck source=/dev/null
. "$WT/tests/wake-helpers.sh"
WATCH="$WT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-wired-demo)

run_pane() {  # <name> <mode> <rounds>
  local name=$1 mode=$2 rounds=$3
  local dir state fakebin out pane window pid tokens i tmuxlog
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; pane="$dir/pane.txt"; tmuxlog="$dir/tmux.log"
  window="ops:fm-$name"
  mkdir -p "$dir/data/$name"
  printf 'window=%s\nkind=ship\nharness=claude\n' "$window" > "$state/$name.meta"
  tokens=900
  printf '%s\n' "ᐧ Reading src/engine/planner.rs" "✢ Pollinating… (16s · ↓ $tokens tokens · thought for 1s)" > "$pane"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_FAKE_TMUX_LOG="$tmuxlog" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$dir/data" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_NOPROGRESS_SPEND=5000 FM_NOPROGRESS_SECS=0 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt "$rounds" ]; do
    kill -0 "$pid" 2>/dev/null || break
    grep -qF 'spending without producing' "$state/.wake-queue" 2>/dev/null && break
    case "$mode" in
      burn)      tokens=$((tokens + 700)) ;;
      waiting)   : ;;
      producing) tokens=$((tokens + 700))
                 printf 'finding %s: the retry path drops the correlation id\n' "$i" \
                   >> "$dir/data/$name/report.md" ;;
    esac
    printf '%s\n' "ᐧ Editing src/engine/planner.rs (frame $i)" \
      "✢ Pollinating… (16s · ↓ $tokens tokens · thought for 1s)" > "$pane"
    sleep 0.4
    i=$((i + 1))
  done
  DEMO_DIR=$dir; DEMO_STATE=$state; DEMO_OUT=$out; DEMO_PID=$pid; DEMO_LOG=$tmuxlog
}

reapd() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

echo "================================================================================"
echo " REAL WATCHER (bin/fm-watch.sh), REAL PANE CAPTURE, THREE LIVE WORKERS"
echo "================================================================================"
echo

echo "### 1. ops:fm-burn - token counter climbing, nothing produced"
run_pane burn burn 60
echo
echo "  the pane the watcher last captured:"
sed 's/^/    | /' "$DEMO_DIR/pane.txt"
echo
echo "  what the watcher printed (this line is what wakes firstmate):"
sed 's/^/    /' "$DEMO_OUT"
echo
echo "  the durable wake queue a human reads (state/.wake-queue):"
sed 's/^/    /' "$DEMO_STATE/.wake-queue"
echo
echo "  every tmux command the watcher issued against that worker:"
sort -u "$DEMO_LOG" | sed 's/^/    /'
echo "    ^ read-only. The guard escalated; it never interrupted, signalled, or killed."
wait "$DEMO_PID" 2>/dev/null || true
reapd "$DEMO_PID"
echo

echo "### 2. ops:fm-waiting - token counter FROZEN (a worker parked on a pipeline)"
run_pane waiting waiting 25
echo "  pane still churning, counter frozen at:"
grep -o '↓ [0-9]* tokens' "$DEMO_DIR/pane.txt" | sed 's/^/    /'
echo "  guard record written (so the silence is an observation, not a no-op):"
sed 's/^/    /' "$DEMO_STATE/.noprogress-waiting" 2>/dev/null
echo "  wake queue:"
if [ -s "$DEMO_STATE/.wake-queue" ]; then sed 's/^/    /' "$DEMO_STATE/.wake-queue"; else echo "    (empty - nothing was raised)"; fi
echo "  watcher still polling: $(kill -0 "$DEMO_PID" 2>/dev/null && echo yes || echo NO)"
reapd "$DEMO_PID"
echo

echo "### 3. ops:fm-producing - tokens climbing AND the report growing"
run_pane producing producing 25
echo "  report the scout wrote while spending:"
sed -n '1,3p' "$DEMO_DIR/data/producing/report.md" | sed 's/^/    /'
echo "    ... $(wc -l < "$DEMO_DIR/data/producing/report.md" | tr -d ' ') findings"
echo "  counter reached:"
grep -o '↓ [0-9]* tokens' "$DEMO_DIR/pane.txt" | sed 's/^/    /'
echo "  wake queue:"
if [ -s "$DEMO_STATE/.wake-queue" ]; then sed 's/^/    /' "$DEMO_STATE/.wake-queue"; else echo "    (empty - nothing was raised)"; fi
echo "  watcher still polling: $(kill -0 "$DEMO_PID" 2>/dev/null && echo yes || echo NO)"
reapd "$DEMO_PID"
unset FM_FAKE_CREW_STATE
