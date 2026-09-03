#!/usr/bin/env bash
# Deterministic behavior checks for the vendored learning-skill helpers.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-learning-skill-helpers)
SCAFFOLD="$ROOT/.agents/skills/skill-forge/scaffold.py"
STAMP="$ROOT/.agents/skills/brain-capture/stamp.py"

assert_not_exists() {
  [ ! -e "$1" ] || fail "unexpected path exists: $1"
}

skills="$TMP_ROOT/owner/.agents/skills"
mkdir -p "$skills"
HOME="$TMP_ROOT/home" python3 "$SCAFFOLD" reusable-check "$skills" > "$TMP_ROOT/scaffold.out"
assert_present "$skills/reusable-check/SKILL.md" "scaffold did not create SKILL.md"
assert_present "$skills/reusable-check/evals" "scaffold did not create the evaluation directory"
assert_not_exists "$TMP_ROOT/home/.claude/skills/reusable-check"
assert_grep "created $skills/reusable-check/SKILL.md" "$TMP_ROOT/scaffold.out" \
  "scaffold did not report its explicit owning-repository destination"
if HOME="$TMP_ROOT/home" python3 "$SCAFFOLD" reusable-check "$skills" > /dev/null 2>&1; then
  fail "scaffold overwrote an existing candidate without --force"
fi
if python3 "$SCAFFOLD" missing-destination > /dev/null 2>&1; then
  fail "scaffold accepted a missing explicit destination"
fi
pass "skill-forge scaffolds only into the explicit owning repository"

brain="$TMP_ROOT/brain"
lesson="$brain/knowledge/lessons/reliable-checks.md"
source="$brain/docs/retrospectives/reliable-checks.md"
mkdir -p "$(dirname "$lesson")" "$(dirname "$source")"
printf 'timezone = "UTC"\n' > "$brain/brain.toml"
printf '# Reliable checks\n\nGeneric source evidence.\n' > "$source"
cat > "$lesson" <<'EOF'
---
{
  "updated_at": "2030-01-01T00:00:00+00:00",
  "sources": [
    {
      "resource": "../../docs/retrospectives/reliable-checks.md",
      "content_hash": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
---
# Reliable checks
EOF
python3 "$STAMP" "$lesson" > "$TMP_ROOT/stamp.out"
expected=$(python3 - "$source" <<'PY'
import hashlib
import sys
print("sha256:" + hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)
assert_grep "\"content_hash\": \"$expected\"" "$lesson" \
  "brain-capture helper did not bind the local source hash"
check_out=$(python3 "$STAMP" "$lesson" --check)
[ "$check_out" = "OK all source hashes current" ] \
  || fail "brain-capture helper did not accept its freshly bound source"
printf '\nChanged evidence.\n' >> "$source"
if python3 "$STAMP" "$lesson" --check > /dev/null 2>&1; then
  fail "brain-capture helper accepted a stale source hash"
fi
pass "brain-capture stamps and checks exact local source bytes"
