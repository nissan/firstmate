#!/usr/bin/env bash
# Credentialed public-behavior regression for /pause-and-learn plan.
#
# Each control starts a fresh Pi context with only the installed skill and a
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

check_plan() {
  local output_path=$1 expected_cycle=$2
  python3 - "$output_path" "$expected_cycle" <<'PY'
import json
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"PAUSE_AND_LEARN_PLAN_V1\s*\n```(?:json)?\s*\n(.*?)\n```", text, re.S)
if not match:
    raise SystemExit("missing PAUSE_AND_LEARN_PLAN_V1 JSON block")
plan = json.loads(match.group(1))
expected_cycle = sys.argv[2] == "true"

assert plan["schema"] == "firstmate.pause-and-learn.plan.v1"
assert plan["mode"] == "plan"
assert plan["scope"] == {"project": "Signal Atlas", "thread": "resilient import tranche"}
assert plan["existing_cycle"]["found"] is expected_cycle
assert bool(plan["existing_cycle"]["identity"]) is expected_cycle
assert plan["existing_cycle"]["resume_phase"] != "new" if expected_cycle else plan["existing_cycle"]["resume_phase"] == "new"
assert plan["boundary"]["kind"] == "post-current-stage"
assert plan["boundary"]["name"]
assert plan["boundary"]["wait_for_current_stage"] is True
assert plan["boundary"]["current_stage"] == "exact-head-review"
assert plan["boundary"]["interrupt_current_stage"] is False
assert plan["project_writes"] == {"route": "worker", "firstmate_writes_project": False}
assert plan["components"] == {
    "retrospective": "planned",
    "brain_capture": "planned",
    "skill_forge": "planned",
    "stow": "planned",
}
assert plan["brain"] == {"status": "draft", "brain_status": "proposed", "canonical_write": False}
assert plan["authority"] == {
    "merge": False,
    "sign": False,
    "approve": False,
    "promote": False,
    "discard": False,
    "destructive": False,
    "security_sensitive": False,
    "semantic_expansion": False,
}
assert plan["sequencing"] == {"prior_review_failure_backfilled": False}
assert plan["queued"] == [{
    "name": "distributed cache migration",
    "start": False,
    "state": "paused",
    "resume_condition": "captain returns focus",
}]
assert plan["mutations"] == {"records": False, "workers": False, "artifacts": False}
PY
}

run_control() {
  local label=$1 cycle_record=$2 expected_cycle=$3 out_path="$LAB/$1.out"
  cat > "$PROJECT/fleet/current.txt" <<EOF
Registered project: Signal Atlas
Current thread: resilient import tranche
Current authorized change: commit 0123456789abcdef0123456789abcdef01234567
Current stage: exact-head-review
Current-stage detail: independent exact-head review is actively evaluating that commit
Completed related change: parser normalization, commit abcdefabcdefabcdefabcdefabcdefabcdefabcd, tests passed and delivered
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
        --model openai-codex/gpt-5.6-sol --thinking high \
        '/pause-and-learn plan for the Signal Atlas resilient import thread. The synthetic fleet record is fleet/current.txt.'
  ) > "$out_path" || fail "$label: fresh Pi skill run failed"
  check_plan "$out_path" "$expected_cycle" || fail "$label: invalid public plan contract"
  printf 'ok - %s\n' "$label"
}

run_control new-cycle 'Existing pause-and-learn cycle: none' false
run_control repeated-cycle 'Existing pause-and-learn cycle: Signal Atlas / resilient import tranche; resume phase: retrospective' true
