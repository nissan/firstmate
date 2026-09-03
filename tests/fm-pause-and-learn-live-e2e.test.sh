#!/usr/bin/env bash
# Credentialed public-behavior regression for /pause-and-learn planning.
#
# The test starts a fresh Pi context with only the installed skill and a
# synthetic fleet. It observes the user-facing plan, not instruction bytes.
set -u

if [ "${FM_PAUSE_AND_LEARN_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PAUSE_AND_LEARN_LIVE_E2E=1 to run the credentialed Pi pause-and-learn regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$ROOT/.agents/skills/pause-and-learn/SKILL.md"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

require_line() {
  local output=$1 pattern=$2 label=$3
  printf '%s\n' "$output" | grep -Eiq "$pattern" || fail "$label: output was: $output"
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
[ -f "$OWNER" ] || fail "pause-and-learn skill not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pause-and-learn-live.XXXXXX")
PROJECT="$LAB/project"
cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.agents/skills/pause-and-learn" "$PROJECT/fleet"
cp "$OWNER" "$PROJECT/.agents/skills/pause-and-learn/SKILL.md"
cat > "$PROJECT/fleet/current.txt" <<'EOF'
Registered project: Signal Atlas
Current thread: resilient import tranche
Current authorized change: commit 0123456789abcdef0123456789abcdef01234567
Current stage: independent exact-head review is actively evaluating that commit
Completed related change: parser normalization, commit abcdefabcdefabcdefabcdefabcdefabcdefabcd, tests passed and delivered
Queued next tranche: distributed cache migration, not authorized to start in this cycle
Existing pause-and-learn cycle: Signal Atlas / resilient import tranche
Existing retrospective: none
Existing corpus capture: none
Existing skill candidate ledger: none
EOF

out=$(
  cd "$PROJECT" &&
    pi --print --approve --no-session --no-context-files --no-extensions \
      --no-skills --skill .agents/skills --tools read \
      --model openai-codex/gpt-5.6-sol --thinking high \
      '/pause-and-learn plan for the Signal Atlas resilient import thread. The synthetic fleet record is fleet/current.txt. Give the complete plan and clearly state the boundary, ownership of writes, learning components, authority limits, reuse behavior, and queued work.'
) || fail "fresh Pi skill run failed: $out"

require_line "$out" 'Plan only' "planning mode did not identify itself"
require_line "$out" '(wait|after).*(exact-head review)|exact-head review.*(finish|complete)' "plan did not wait for the active exact-head review"
require_line "$out" 'post-review|after.*review.*(boundary|pause)|boundary.*after.*review' "plan did not name the post-review pause boundary"
require_line "$out" '(worker|delegate).*(project write|retrospective|brain|corpus|skill)' "plan did not route project writes to a worker"
require_line "$out" 'retrospective' "plan omitted the retrospective"
require_line "$out" 'brain-capture|Shared Brain' "plan omitted Shared Brain capture"
require_line "$out" 'skill-forge|skill candidate' "plan omitted skill candidate mining and evaluation"
require_line "$out" '/stow|stow' "plan omitted stow"
require_line "$out" 'draft|proposed' "plan omitted proposed corpus status"
require_line "$out" 'reus(e|ing)|existing pause-and-learn cycle' "plan did not reuse the existing cycle"
require_line "$out" 'distributed cache migration.*(queued|paused|not start|remain)' "plan did not leave the next tranche queued"
require_line "$out" '(no records|no .*changed|read-only|no workers|no artifacts)' "plan did not preserve planning-mode immutability"
printf '%s\n' "$out"
printf 'ok - pause-and-learn plans the safe post-review learning boundary and reuses its cycle\n'
