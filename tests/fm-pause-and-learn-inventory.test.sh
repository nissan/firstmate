#!/usr/bin/env bash
# Ownership guard for the /pause-and-learn consumer integration: Firstmate may
# carry the discovery stub and its inventory rows, and nothing else the Shared
# Brain owns.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STUB_DIR="$ROOT/.agents/skills/pause-and-learn"

# Top-level payload trees the Shared Brain owns (its corpus, evidence, helpers,
# references, fixtures, and working state). None of them may appear in Firstmate.
SHARED_BRAIN_PAYLOAD_TREES=(
  knowledge evaluations fixtures prompts corpus evidence references helpers log work
)

entries=$(cd "$STUB_DIR" 2>/dev/null && ls -A) || fail "the /pause-and-learn discovery stub directory is absent"
[ "$entries" = "SKILL.md" ] ||
  fail "the discovery stub directory must hold exactly SKILL.md, found:"$'\n'"$entries"
pass "the discovery stub carries only its own SKILL.md"

assert_absent "$ROOT/skills/pause-and-learn" "the authoritative skill was bundled into the public skill tree"
for tree in "${SHARED_BRAIN_PAYLOAD_TREES[@]}"; do
  assert_absent "$ROOT/$tree" "a Shared Brain-owned payload tree ($tree/) was copied into Firstmate"
done
pass "no Shared Brain-owned payload tree was copied into Firstmate"

python3 - "$ROOT/docs/documentation-audiences.json" <<'PY'
import json
import sys

surfaces = json.load(open(sys.argv[1], encoding="utf-8"))["surfaces"]
owned = [row for row in surfaces if row["path"].startswith(".agents/skills/pause-and-learn/")]
expected = [{"path": ".agents/skills/pause-and-learn/SKILL.md", "audience": "agent-runtime"}]
if owned != expected:
    raise SystemExit(
        f"documentation inventory must declare exactly the discovery stub, got: {owned}"
    )
PY
pass "the documentation inventory declares exactly the discovery stub"

python3 - "$ROOT/README.md" <<'PY'
import pathlib
import sys

rows = []
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    stripped = line.strip()
    if not (stripped.startswith("|") and stripped.endswith("|")):
        continue
    cells = [cell.strip() for cell in stripped.strip("|").split("|")]
    if len(cells) != 2 or set(cells[0]) <= set("-: "):
        continue
    rows.append(cells)

matches = [description for command, description in rows if command == "`/pause-and-learn`"]
if len(matches) != 1:
    raise SystemExit(
        f"the captain-invocable command inventory must list /pause-and-learn once, found {len(matches)}"
    )
if not matches[0]:
    raise SystemExit("the /pause-and-learn inventory row has no description")
PY
pass "the captain-invocable command inventory exposes /pause-and-learn"
