#!/usr/bin/env bash
# The notice ledger state/.turnend-claude-foreign-owner is append-only, one line
# per (session, owner): two non-owner sessions sharing one home each get exactly
# one notice, and neither erases the other's record. Sandbox home only.
set -u
WORKTREE=$1
SANDBOX=$(mktemp -d /tmp/fm-ledger-XXXXXX); trap 'rm -rf "$SANDBOX"' EXIT
H="$SANDBOX/home"; mkdir -p "$H/state" "$H/bin" "$H/docs"
cp "$WORKTREE"/bin/*.sh "$H/bin/"; chmod +x "$H"/bin/*.sh
cp -R "$WORKTREE/docs/supervision-protocols" "$H/docs/supervision-protocols"
git init -q "$H"; git -C "$H" commit -q --allow-empty -m init; : > "$H/AGENTS.md"
: > "$H/state/task1.meta"
ln -sf /bin/bash "$SANDBOX/fake-codex"; "$SANDBOX/fake-codex" -c 'sleep 120; exit 0' >/dev/null 2>&1 &
OWNER=$!; printf '%s\n' "$OWNER" > "$H/state/.lock"
stop() { printf '{"stop_hook_active":true,"session_id":"%s"}' "$1" \
  | CLAUDECODE=1 FM_HOME="$H" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 bash "$H/bin/fm-turnend-guard.sh" --claude 2>&1; }
for s in sess-A sess-A sess-B sess-A sess-B; do
  out=$(stop "$s"); rc=$?
  printf '%-8s turn-end -> exit=%s  %s\n' "$s" "$rc" \
    "$([ -n "$out" ] && echo 'NOTICE shown to the session' || echo '(silent)')"
done
kill "$OWNER" 2>/dev/null; wait "$OWNER" 2>/dev/null
echo
echo "persisted ledger  state/.turnend-claude-foreign-owner:"
sed 's/^/  /' "$H/state/.turnend-claude-foreign-owner"
echo
echo "block budget untouched by the stand-down (state/.turnend-claude-blocks):"
[ -e "$H/state/.turnend-claude-blocks" ] && sed 's/^/  /' "$H/state/.turnend-claude-blocks" || echo "  (never created - the guard never re-blocked)"
