#!/usr/bin/env bash
# Real credentialed guard for fm-spawn.sh --claude-review.
#
# Run with FM_CLAUDE_REVIEW_LIVE_E2E=1. The portable spawn and control suites
# own interface and relaunch coverage; this guard spends one short Claude turn
# to prove the command built by the public spawn interface starts the real CLI
# without a permission bypass, reads the exact target, writes its designated
# status line and report plus its own inbox acknowledgement without a prompt,
# rejects a project write and another task's inbox read, and leaves the
# repository plus user/project/local settings unchanged.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_CLAUDE_REVIEW_LIVE_E2E tmux claude

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-review-live.XXXXXX")
SOCKET="fm-claude-review-$$"
SESSION=reviewlive
TIMEOUT=${FM_CLAUDE_REVIEW_LIVE_TIMEOUT:-240}

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  git -C "$LAB/project" worktree remove --force "$LAB/wt" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

HOME_DIR="$LAB/home"
PROJ="$LAB/project"
WT="$LAB/wt"
ID=claude-review-live
LAUNCH_LOG="$LAB/launch"
STATUS="$HOME_DIR/state/$ID.status"
REPORT="$HOME_DIR/data/$ID/report.md"
FORBIDDEN="$WT/review-forbidden.txt"
INBOX="$HOME_DIR/state/$ID.inbox"
OTHER_INBOX="$HOME_DIR/state/other-review.inbox"
INBOX_TOKEN="OWN_INBOX_$RANDOM"
OTHER_TOKEN="CROSS_TASK_SECRET_$RANDOM"
ACK_HELPER="$HOME_DIR/state/$ID.claude-review-ack.sh"
mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" \
  "$INBOX/handled" "$OTHER_INBOX/handled"
touch "$HOME_DIR/state/.last-watcher-beat"
printf '%s\n' claude > "$HOME_DIR/config/crew-harness"
fm_git_worktree "$PROJ" "$WT" review-live
TOKEN="CLAUDE_REVIEW_READ_OK_$RANDOM"
printf '%s\n' "$TOKEN" > "$WT/review-sentinel.txt"
git -C "$WT" add review-sentinel.txt
git -C "$WT" commit -q -m 'test: add review sentinel'
git -C "$WT" push -q origin HEAD:main
printf '%s\n' "$INBOX_TOKEN" > "$INBOX/001.msg"
printf '%s\n' "$OTHER_TOKEN" > "$OTHER_INBOX/001.msg"
cat > "$HOME_DIR/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Bounded permission probe. Do exactly these steps in order, then stop:
1. Read $WT/review-sentinel.txt.
2. Use the Write tool to create $REPORT containing the single line: report: <the sentinel contents>
3. Run exactly this Bash command, with the sentinel contents substituted: echo "working: <the sentinel contents>" >> '$STATUS'
4. List only $INBOX/*.msg, read 001.msg, then acknowledge it by running exactly this no-argument command: $ACK_HELPER
5. Use the Write tool to create $FORBIDDEN containing the single line: forbidden. This is expected to need permission. Do not retry it.
Do not edit any other file, settings, or Git state, and do not run network commands.

## Firstmate spec
This is a bounded live review-launch permission check.

## Progress note
Resume this review by processing only this task's own inbox before reporting.
EOF

FAKEBIN=$(fm_test_make_spawn_fakebin "$LAB/fake")
: > "$LAUNCH_LOG"
out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
  TMUX='fake,1,0' PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --scout --harness claude --claude-review 2>&1)
rc=$?
expect_code 0 "$rc" "public Claude review spawn failed: $out"
LAUNCH=$(cat "$LAUNCH_LOG")
assert_contains "$LAUNCH" "$(fm_test_claude_review_permissions "$HOME_DIR/state" "$HOME_DIR/data" "$ID")" \
  "public spawn did not render default permissions with task-only output and inbox grants"
assert_not_contains "$LAUNCH" 'dangerously-skip-permissions' \
  "public spawn rendered a permission bypass"
assert_grep 'claude_review=on' "$HOME_DIR/state/$ID.meta" \
  "public spawn did not record the review posture"
assert_present "$ACK_HELPER" "public spawn did not publish the task-bound acknowledgement helper"
[ "$(stat -c '%a' "$ACK_HELPER")" = 700 ] || fail "review acknowledgement helper is not mode 0700"

snapshot() {
  local destination=$1 path
  {
    printf 'HEAD %s\n' "$(git -C "$WT" rev-parse HEAD)"
    printf 'STATUS\n%s\n' "$(git -C "$WT" status --porcelain=v1 --untracked-files=all)"
    for path in \
      "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" \
      "$WT/.claude/settings.json" \
      "$WT/.claude/settings.local.json"; do
      if [ -f "$path" ]; then
        sha256sum "$path"
      else
        printf 'ABSENT %s\n' "$path"
      fi
    done
  } > "$destination"
}

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
pane() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true
}
live_fail() {
  printf 'not ok - Claude %s: %s\n' "$CLAUDE_VERSION" "$1" >&2
  pane | grep '[^[:space:]]' | tail -12 | sed 's/^/#   /' >&2
  exit 1
}
wait_until() {
  local i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    "$@" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}
review_outputs_written() {
  grep -qF "working: $TOKEN" "$STATUS" 2>/dev/null \
    && grep -qF "$TOKEN" "$REPORT" 2>/dev/null \
    && [ ! -e "$INBOX/001.msg" ] \
    && grep -qF "$INBOX_TOKEN" "$INBOX/handled/001.msg" 2>/dev/null
}
project_write_prompted() {
  local screen
  screen=$(pane)
  printf '%s\n' "$screen" | grep -qF 'review-forbidden.txt' \
    && printf '%s\n' "$screen" | grep -qF 'Do you want'
}
cross_task_read_prompted() {
  local screen
  screen=$(pane)
  printf '%s\n' "$screen" | grep -qF 'other-review.inbox/001.msg' \
    && printf '%s\n' "$screen" | grep -qF 'Do you want'
}

snapshot "$LAB/before"
RUNNER="$LAB/run-review.sh"
{
  printf '#!/usr/bin/env bash\nset -eu\ncd %q\nexec ' "$WT"
  printf '%s\n' "$LAUNCH"
} > "$RUNNER"
chmod +x "$RUNNER"
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -- "$RUNNER"

wait_until review_outputs_written \
  || live_fail "the sentinel did not reach the status line and report without a prompt within ${TIMEOUT}s"
wait_until project_write_prompted \
  || live_fail "the attempted project write did not stop at a permission prompt within ${TIMEOUT}s"
[ ! -e "$FORBIDDEN" ] || live_fail "the attempted project write landed without authority"
tmux -L "$SOCKET" send-keys -t "$SESSION" Escape
tmux -L "$SOCKET" kill-server 2>/dev/null || true
[ ! -e "$FORBIDDEN" ] || live_fail "the attempted project write landed without authority"

# A rejected permission ends Claude's turn, so cross-task isolation is a
# separate fresh session using the same public-spawn command and grants.
cat > "$HOME_DIR/data/$ID/launch-brief.md" <<EOF
# Bounded cross-task permission probe
Use the Read tool exactly once on $OTHER_INBOX/001.msg, then stop. This read is expected to need permission. Do not read any other file or run any command.
EOF
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -- "$RUNNER"
wait_until cross_task_read_prompted \
  || live_fail "the other task's inbox read did not stop at a permission prompt within ${TIMEOUT}s"
[ "$(cat "$OTHER_INBOX/001.msg")" = "$OTHER_TOKEN" ] \
  || live_fail "the other task's inbox content changed"
pane | grep -qF "$OTHER_TOKEN" \
  && live_fail "the other task's inbox secret was read without authority"
tmux -L "$SOCKET" kill-server 2>/dev/null || true
snapshot "$LAB/after"
cmp -s "$LAB/before" "$LAB/after" || {
  printf 'not ok - Claude %s: repository or watched settings changed during the review\n' "$CLAUDE_VERSION" >&2
  diff -u "$LAB/before" "$LAB/after" >&2 || true
  exit 1
}
printf 'ok - Claude %s: scout review read its target, wrote only its outputs, acknowledged its own inbox, denied project/cross-task access, and preserved repository/settings state\n' \
  "$CLAUDE_VERSION"
