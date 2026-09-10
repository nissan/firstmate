#!/usr/bin/env bash
# What a session is TOLD at session start about who owns the fleet lock.
# bin/fm-supervision-instructions.sh renders the "Current state:" block that is
# injected into the session; before this change the "- Lock:" line read
# "held by this session" unconditionally whenever --read-only was not set.
# Sandbox home only; /Users/nissan/Advanced/firstmate/state is untouched.
set -u
WORKTREE=$1
BASE_REF=$2
SANDBOX=$(mktemp -d /tmp/fm-lockstanza-XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/base"
git -C "$WORKTREE" archive "$BASE_REF" bin docs | tar -x -C "$SANDBOX/base"

HOME_DIR="$SANDBOX/home"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"

render() {  # <bin-root>
  FM_HOME="$HOME_DIR" "$1/bin/fm-supervision-instructions.sh" --harness claude \
    ${2:+--read-only 1} 2>&1 | sed -n '/^Current state:/,/^- /p' | grep -E '^- Lock:'
}

scenario() {  # <title>
  echo "------------------------------------------------------------------------------"
  echo "SCENARIO: $1"
  echo "  BEFORE : $(render "$SANDBOX/base" "${2:-}")"
  echo "  AFTER  : $(render "$WORKTREE" "${2:-}")"
}

echo "=============================================================================="
echo "  Session-start 'Current state:' block - the '- Lock:' line the session reads"
echo "=============================================================================="

scenario "no lock file at all (nobody holds the home)"

# the 2026-09-10 shape: a live Codex app-server owns the lock, we are a Claude session
ln -sf /bin/bash "$SANDBOX/fake-codex"
"$SANDBOX/fake-codex" -c 'sleep 300; exit 0' >/dev/null 2>&1 &
OWNER=$!
printf '%s\n' "$OWNER" > "$HOME_DIR/state/.lock"
scenario "lock held by a LIVE foreign harness, pid $OWNER (the 2026-09-10 incident shape)"
kill "$OWNER" 2>/dev/null; wait "$OWNER" 2>/dev/null

scenario "same lock file, owner now dead (stale lock)"

scenario "--read-only 1 refusal still wins" readonly

# the lock owner's OWN session: the lock pid is a harness-shaped ancestor of the renderer
ln -sf /bin/bash "$SANDBOX/fake-claude"
echo "------------------------------------------------------------------------------"
echo "SCENARIO: lock held by THIS session's own harness ancestor (the genuine owner)"
for root in "$SANDBOX/base" "$WORKTREE"; do
  label=BEFORE; [ "$root" = "$WORKTREE" ] && label=AFTER
  line=$(FM_HOME="$HOME_DIR" ROOT="$root" "$SANDBOX/fake-claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$ROOT/bin/fm-supervision-instructions.sh" --harness claude | grep -E "^- Lock:"
      exit 0' 2>&1)
  printf '  %-7s: %s\n' "$label" "$line"
done
echo "------------------------------------------------------------------------------"
echo
echo "Full AFTER session-start block in the incident shape (live foreign owner):"
echo
"$SANDBOX/fake-codex" -c 'sleep 60; exit 0' >/dev/null 2>&1 &
OWNER=$!
printf '%s\n' "$OWNER" > "$HOME_DIR/state/.lock"
FM_HOME="$HOME_DIR" "$WORKTREE/bin/fm-supervision-instructions.sh" --harness claude 2>&1 | sed -n '1,12p'
kill "$OWNER" 2>/dev/null; wait "$OWNER" 2>/dev/null
