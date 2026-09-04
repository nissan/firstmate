#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$ROOT/.agents/skills/pause-and-learn/SKILL.md" ] || fail "discovery stub is absent"
[ ! -e "$ROOT/skills/pause-and-learn" ] || fail "authoritative skill was bundled in the public skill tree"
[ ! -e "$ROOT/.agents/skills/pause-and-learn/references" ] || fail "authoritative references were copied into Firstmate"
[ ! -e "$ROOT/.agents/skills/pause-and-learn/scripts" ] || fail "authoritative helpers were copied into Firstmate"
[ ! -e "$ROOT/.agents/skills/pause-and-learn/fixtures" ] || fail "authoritative fixtures were copied into Firstmate"
[ ! -e "$ROOT/corpus" ] || fail "a Shared Brain corpus was copied into Firstmate"

python - "$ROOT/docs/documentation-audiences.json" <<'PY'
import json, sys
surfaces = json.load(open(sys.argv[1]))['surfaces']
rows = [row for row in surfaces if row['path'] == '.agents/skills/pause-and-learn/SKILL.md']
if rows != [{'path': '.agents/skills/pause-and-learn/SKILL.md', 'audience': 'agent-runtime'}]:
    raise SystemExit('FAIL: documentation inventory must contain exactly one discovery-stub owner')
PY

grep -q '/pause-and-learn' "$ROOT/README.md" || fail "built-in skill inventory does not expose /pause-and-learn"
echo "PASS: pause-and-learn inventory keeps Shared Brain as the sole behavior owner"
