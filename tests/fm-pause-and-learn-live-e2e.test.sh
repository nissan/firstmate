#!/usr/bin/env bash
# Credentialed public-behavior regression for /pause-and-learn plan.
#
# The control starts a fresh Pi context with only the installed skill and a
# synthetic fleet. Assertions consume the public machine-readable plan block,
# never instruction bytes or unconstrained explanatory prose.
set -u

if [ "${FM_PAUSE_AND_LEARN_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PAUSE_AND_LEARN_LIVE_E2E=1 to run the credentialed Pi pause-and-learn regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$ROOT/.agents/skills/pause-and-learn/SKILL.md"
BRAIN_OWNER="$ROOT/.agents/skills/brain-capture"
FORGE_OWNER="$ROOT/.agents/skills/skill-forge"
PLAN_CHECK="$ROOT/tests/pause-and-learn-plan-check.py"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ -f "$OWNER" ] || fail "pause-and-learn skill not found"
[ -f "$BRAIN_OWNER/SKILL.md" ] || fail "brain-capture skill not found"
[ -f "$FORGE_OWNER/SKILL.md" ] || fail "skill-forge skill not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pause-and-learn-live.XXXXXX")
PROJECT="$LAB/project"
cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.agents/skills/pause-and-learn" "$PROJECT/fleet"
cp "$OWNER" "$PROJECT/.agents/skills/pause-and-learn/SKILL.md"
cp -R "$BRAIN_OWNER" "$FORGE_OWNER" "$PROJECT/.agents/skills/"

run_control() {
  local label=$1 cycle_record=$2 expected_cycle=$3 out_path="$LAB/$1.out"
  cat > "$PROJECT/fleet/current.txt" <<EOF
Registered project: Signal Atlas
Current thread: resilient import tranche
Current authorized change: commit 0123456789abcdef0123456789abcdef01234567
Current stage: exact-head-review
Current-stage detail: independent exact-head review is actively evaluating that commit
Completed related change: parser normalization, commit abcdefabcdefabcdefabcdefabcdefabcdefabcd, tests passed and delivered
Queued next tranche ID: distributed-cache-migration
Queued next tranche: distributed cache migration, not authorized to start in this cycle
$cycle_record
Existing retrospective: none
Existing corpus capture: none
Existing skill candidate ledger: none
EOF

  (
    cd "$PROJECT" &&
      pi --print --approve --no-session --no-context-files --no-extensions \
        --no-skills --skill .agents/skills --tools read \
        --model openai-codex/gpt-5.6-sol --thinking medium \
        '/pause-and-learn plan for the Signal Atlas resilient import thread. The synthetic fleet record is fleet/current.txt.'
  ) > "$out_path" || fail "$label: fresh Pi skill run failed"
  if ! python3 "$PLAN_CHECK" "$out_path" "$expected_cycle" distributed-cache-migration; then
    printf '%s\n' "--- $label raw response ---" >&2
    cat "$out_path" >&2
    fail "$label: invalid public plan contract"
  fi
  printf 'ok - %s\n' "$label"
}

run_control repeated-cycle 'Existing pause-and-learn cycle: Signal Atlas / resilient import tranche; resume phase: retrospective' true
