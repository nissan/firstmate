#!/usr/bin/env bash
# Real credentialed guard for fm-spawn.sh --claude-review.
#
# Run with FM_CLAUDE_REVIEW_LIVE_E2E=1. The portable spawn and control suites
# own interface and relaunch coverage; this guard spends one short Claude turn
# to prove the command built by the public spawn interface starts the real CLI
# without a permission bypass, reads the exact target, writes its designated
# status line and report without a prompt, holds an attempted project write at
# Claude's permission prompt, and leaves the repository plus user/project/local
# settings unchanged.
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
mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
touch "$HOME_DIR/state/.last-watcher-beat"
printf '%s\n' claude > "$HOME_DIR/config/crew-harness"
fm_git_worktree "$PROJ" "$WT" review-live
TOKEN="CLAUDE_REVIEW_READ_OK_$RANDOM"
printf '%s\n' "$TOKEN" > "$WT/review-sentinel.txt"
git -C "$WT" add review-sentinel.txt
git -C "$WT" commit -q -m 'test: add review sentinel'
git -C "$WT" push -q origin HEAD:main
cat > "$HOME_DIR/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Bounded permission probe. Do exactly these four steps in order, then stop:
1. Read $WT/review-sentinel.txt.
2. Use the Write tool to create $REPORT containing the single line: report: <the sentinel contents>
3. Run exactly this Bash command, with the sentinel contents substituted: echo "working: <the sentinel contents>" >> '$STATUS'
4. Use the Write tool to create $FORBIDDEN containing the single line: forbidden
Step 4 is expected to need permission. Do not retry it, and do not reach that path any other way.
Do not edit any other file, settings, or Git state, and do not run network commands.

## Firstmate spec
This is a bounded live review-launch permission check.
EOF

FAKEBIN=$(fm_test_make_spawn_fakebin "$LAB/fake")
: > "$LAUNCH_LOG"
out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
  TMUX='fake,1,0' PATH="$FAKEBIN:$PATH" CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --mode no-mistakes --yolo off \
    --harness claude --claude-review 2>&1)
rc=$?
expect_code 0 "$rc" "public Claude review spawn failed: $out"
LAUNCH=$(cat "$LAUNCH_LOG")
assert_contains "$LAUNCH" "$(fm_test_claude_review_permissions "$HOME_DIR/state" "$HOME_DIR/data" "$ID")" \
  "public spawn did not render Manual permissions with grants for only the status file and report"
assert_not_contains "$LAUNCH" 'dangerously-skip-permissions' \
  "public spawn rendered a permission bypass"
assert_grep 'claude_review=on' "$HOME_DIR/state/$ID.meta" \
  "public spawn did not record the review posture"

snapshot() {
  local destination=$1 path
  {
    printf 'HEAD %s\n' "$(git -C "$WT" rev-parse HEAD)"
    printf 'STATUS\n%s\n' "$(git -C "$WT" status --porcelain=v1 --untracked-files=all)"
    for path in \
      "$HOME/.claude/settings.json" \
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
  grep -qF "working: $TOKEN" "$STATUS" 2>/dev/null && grep -qF "$TOKEN" "$REPORT" 2>/dev/null
}
project_write_prompted() {
  local screen
  screen=$(pane)
  printf '%s\n' "$screen" | grep -qF 'review-forbidden.txt' \
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
tmux -L "$SOCKET" kill-server 2>/dev/null || true
[ ! -e "$FORBIDDEN" ] || live_fail "the attempted project write landed without authority"
snapshot "$LAB/after"
cmp -s "$LAB/before" "$LAB/after" || {
  printf 'not ok - Claude %s: repository or watched settings changed during the review\n' "$CLAUDE_VERSION" >&2
  diff -u "$LAB/before" "$LAB/after" >&2 || true
  exit 1
}
printf 'ok - Claude %s: public --claude-review launch omitted bypass, read the exact target, wrote only its status line and report, held a project write at the permission prompt, and preserved repository/settings state\n' \
  "$CLAUDE_VERSION"
