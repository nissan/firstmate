#!/usr/bin/env bash
# Real credentialed guard for fm-spawn.sh --claude-review.
#
# Run with FM_CLAUDE_REVIEW_LIVE_E2E=1. The portable spawn and control suites
# own interface and relaunch coverage; this guard spends one short Claude turn
# to prove the command built by the public spawn interface starts the real CLI
# without a permission bypass, reads a bounded repository file in plan mode,
# and leaves the repository plus user/project/local settings unchanged.
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
Inspect only: read review-sentinel.txt from this repository and reply with exactly its one-line contents. Do not edit files, settings, Git state, or run network commands.

## Firstmate spec
This is a bounded live review-launch check. Use a read-only file inspection and return only the sentinel text.
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
assert_contains "$LAUNCH" 'claude --permission-mode plan --settings' \
  "public spawn did not render Claude plan permissions"
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

snapshot "$LAB/before"
RUNNER="$LAB/run-review.sh"
{
  printf '#!/usr/bin/env bash\nset -eu\ncd %q\nexec ' "$WT"
  printf '%s\n' "$LAUNCH"
} > "$RUNNER"
chmod +x "$RUNNER"
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -- "$RUNNER"

i=0
seen=0
while [ "$i" -lt "$TIMEOUT" ]; do
  pane=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true)
  if printf '%s\n' "$pane" | grep -qF "$TOKEN"; then
    seen=1
    break
  fi
  sleep 1
  i=$((i + 1))
done
if [ "$seen" -ne 1 ]; then
  printf 'not ok - Claude %s: bounded read did not return its sentinel within %ss\n' "$(claude --version 2>/dev/null | head -1)" "$TIMEOUT" >&2
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null | grep '[^[:space:]]' | tail -12 | sed 's/^/#   /' >&2
  exit 1
fi
# Let Stop hooks and any ordinary persistence finish before comparing.
sleep 3
snapshot "$LAB/after"
cmp -s "$LAB/before" "$LAB/after" || {
  printf 'not ok - Claude %s: repository or watched settings changed during the review\n' "$(claude --version 2>/dev/null | head -1)" >&2
  diff -u "$LAB/before" "$LAB/after" >&2 || true
  exit 1
}
printf 'ok - Claude %s: public --claude-review launch omitted bypass, read the bounded sentinel, and preserved repository/settings state\n' \
  "$(claude --version 2>/dev/null | head -1)"
