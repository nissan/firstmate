#!/usr/bin/env bash
# End-to-end reproduction of the 2026-09-10 ~06:00 UTC incident, and the fix.
#
# Shape: a Claude Code desktop session ends its turn in a firstmate home whose
# state/.lock is held by pid N - a LIVE Codex app-server that is NOT in the
# Claude session's ancestry. The Stop-owned auto-arm is inert by identity there,
# so no failed epoch is ever recorded and the attended fail-open is unreachable.
#
# Everything below runs in a throwaway sandbox home. The real
# /Users/nissan/Advanced/firstmate/state is never read or written.
set -u
WORKTREE=$1        # target commit (the fix)
BASE_REF=$2        # base commit (pre-fix)
SANDBOX=$(mktemp -d /tmp/fm-incident-XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

make_home() {  # <home> <bin-source-dir>
  local home=$1 src=$2
  mkdir -p "$home/state" "$home/bin" "$home/docs"
  cp "$src"/*.sh "$home/bin/" 2>/dev/null
  cp -R "$WORKTREE/docs/supervision-protocols" "$home/docs/supervision-protocols"
  chmod +x "$home"/bin/*.sh
  git init -q "$home"; git -C "$home" commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  : > "$home/state/task1.meta"     # one task in flight, no watcher => unhealthy
  printf 'session=sess-claude-desktop\ncount=1\nepoch=197\n' > "$home/state/.turnend-claude-blocks"
}

stop_event() {  # <home> -> prints hook stdout, returns hook exit code
  printf '{"stop_hook_active":true,"session_id":"sess-claude-desktop"}' \
    | CLAUDECODE=1 FM_HOME="$1" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
      bash "$1/bin/fm-turnend-guard.sh" --claude 2>&1
}

# --- the live foreign lock owner: a Codex app-server, not our ancestor --------
ln -sf /bin/bash "$SANDBOX/fake-codex"
"$SANDBOX/fake-codex" -c 'sleep 300; exit 0' >/dev/null 2>&1 &
OWNER=$!

# base bin/ at the pre-fix commit
mkdir -p "$SANDBOX/base-bin"
git -C "$WORKTREE" archive "$BASE_REF" bin | tar -x -C "$SANDBOX/base-bin"

turns() {  # <label> <home>
  local label=$1 home=$2 i out rc blocks=0 allows=0 notices=0
  printf '%s\n' "$OWNER" > "$home/state/.lock"
  echo "=============================================================================="
  echo "  $label"
  echo "  home lock owner: pid $OWNER (live 'fake-codex' harness, foreign to this session)"
  echo "=============================================================================="
  for i in $(seq 1 15); do
    out=$(stop_event "$home"); rc=$?
    if [ "$rc" -eq 2 ]; then blocks=$((blocks + 1)); else allows=$((allows + 1)); fi
    [ -n "$out" ] && notices=$((notices + 1))
    if [ "$i" -le 2 ] || [ "$i" -eq 15 ]; then
      echo "--- turn $i: hook exit=$rc ($([ "$rc" -eq 2 ] && echo 'TURN BLOCKED - session forced to continue' || echo 'turn allowed to end')) ---"
      if [ -n "$out" ]; then printf '%s\n' "$out" | head -14; else echo "(no output shown to the session)"; fi
      echo
    elif [ "$i" -eq 3 ]; then
      echo "... turns 3-14 elided ..."; echo
    fi
  done
  echo ">> over 15 consecutive turn-ends: $blocks blocked, $allows allowed, $notices carried output"
  echo ">> block budget ledger state/.turnend-claude-blocks:"
  sed 's/^/     /' "$home/state/.turnend-claude-blocks"
  echo
}

make_home "$SANDBOX/before" "$SANDBOX/base-bin/bin"
turns "BEFORE the fix (base $BASE_REF) - the incident" "$SANDBOX/before"

make_home "$SANDBOX/after" "$WORKTREE/bin"
turns "AFTER the fix (branch fix/turnend-guard-foreign-lock-owner)" "$SANDBOX/after"

echo "=============================================================================="
echo "  Negative control: the guard did NOT just go permissive"
echo "=============================================================================="
kill "$OWNER" 2>/dev/null; wait "$OWNER" 2>/dev/null
DEAD=$OWNER
make_home "$SANDBOX/dead" "$WORKTREE/bin"
printf '%s\n' "$DEAD" > "$SANDBOX/dead/state/.lock"
out=$(stop_event "$SANDBOX/dead"); rc=$?
echo "--- same home, same pid, but the owner is now DEAD: hook exit=$rc ---"
printf '%s\n' "$out" | head -8
echo
[ -e "$SANDBOX/dead/state/.turnend-claude-foreign-owner" ] \
  && echo ">> BAD: a dead owner recorded a foreign-owner stand-down" \
  || echo ">> dead owner => no stand-down ledger entry; the cooperative re-block is preserved"
