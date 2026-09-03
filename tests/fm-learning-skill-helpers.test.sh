#!/usr/bin/env bash
# Deterministic behavior checks for the vendored learning-skill helpers.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-learning-skill-helpers)
SCAFFOLD="$ROOT/.agents/skills/skill-forge/scaffold.py"
STAMP="$ROOT/.agents/skills/brain-capture/stamp.py"

skills="$TMP_ROOT/owner/.agents/skills"
mkdir -p "$skills"
HOME="$TMP_ROOT/home" python3 "$SCAFFOLD" reusable-check "$skills" > "$TMP_ROOT/scaffold.out"
assert_present "$skills/reusable-check/SKILL.md" "scaffold did not create SKILL.md"
assert_present "$skills/reusable-check/evals" "scaffold did not create the evaluation directory"
assert_absent "$TMP_ROOT/home/.claude/skills/reusable-check" \
  "scaffold installed fleet-visible bytes outside the owning repository"
assert_grep "created $skills/reusable-check/SKILL.md" "$TMP_ROOT/scaffold.out" \
  "scaffold did not report its explicit owning-repository destination"
if HOME="$TMP_ROOT/home" python3 "$SCAFFOLD" reusable-check "$skills" > /dev/null 2>&1; then
  fail "scaffold overwrote an existing candidate without --force"
fi
if python3 "$SCAFFOLD" missing-destination > /dev/null 2>&1; then
  fail "scaffold accepted a missing explicit destination"
fi
pass "skill-forge scaffolds only into the explicit owning repository"

ZEROS="sha256:0000000000000000000000000000000000000000000000000000000000000000"

# new_brain <name> writes a two-source brain and echoes its lesson page path.
new_brain() {
  local brain="$TMP_ROOT/$1"
  mkdir -p "$brain/knowledge/lessons" "$brain/docs/retrospectives"
  printf 'timezone = "UTC"\n' > "$brain/brain.toml"
  printf '# Alpha\n\nGeneric alpha evidence.\n' > "$brain/docs/retrospectives/alpha.md"
  printf '# Beta\n\nGeneric beta evidence.\n' > "$brain/docs/retrospectives/beta.md"
  printf '%s\n' "$brain/knowledge/lessons/page.md"
}

sha_of() {
  python3 - "$1" <<'PY'
import hashlib
import sys
print("sha256:" + hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
}

lesson=$(new_brain single)
source="$(dirname "$lesson")/../../docs/retrospectives/alpha.md"
cat > "$lesson" <<EOF
---
{
  "updated_at": "2030-01-01T00:00:00+00:00",
  "sources": [
    {
      "resource": "../../docs/retrospectives/alpha.md",
      "content_hash": "$ZEROS"
    }
  ]
}
---
# Page
EOF
python3 "$STAMP" "$lesson" > "$TMP_ROOT/stamp.out"
assert_grep "\"content_hash\": \"$(sha_of "$source")\"" "$lesson" \
  "brain-capture helper did not bind the local source hash"
check_out=$(python3 "$STAMP" "$lesson" --check)
[ "$check_out" = "OK all source hashes current" ] \
  || fail "brain-capture helper did not accept its freshly bound source"
printf '\nChanged evidence.\n' >> "$source"
if python3 "$STAMP" "$lesson" --check > /dev/null 2>&1; then
  fail "brain-capture helper accepted a stale source hash"
fi
pass "brain-capture stamps and checks exact local source bytes"

# Each source must be bound within its own object, whatever the key order.
lesson=$(new_brain reordered)
brain=$(dirname "$(dirname "$(dirname "$lesson")")")
cat > "$lesson" <<EOF
---
{
  "updated_at": "2030-01-01T00:00:00+00:00",
  "sources": [
    {
      "content_hash": "$ZEROS",
      "resource": "../../docs/retrospectives/alpha.md"
    },
    {
      "content_hash": "$ZEROS",
      "resource": "../../docs/retrospectives/beta.md"
    }
  ]
}
---
# Page
EOF
python3 "$STAMP" "$lesson" > /dev/null
alpha=$(sha_of "$brain/docs/retrospectives/alpha.md")
beta=$(sha_of "$brain/docs/retrospectives/beta.md")
assert_no_grep "$ZEROS" "$lesson" \
  "a hash-first source object kept its placeholder hash"
assert_grep "\"content_hash\": \"$alpha\"," "$lesson" \
  "the first source was not bound to its own bytes"
assert_grep "\"content_hash\": \"$beta\"," "$lesson" \
  "the second source was not bound to its own bytes"
python3 "$STAMP" "$lesson" --check > /dev/null \
  || fail "correctly bound reordered sources were reported stale"

# Compact frontmatter puts several sources on one line.
lesson=$(new_brain compact)
brain=$(dirname "$(dirname "$(dirname "$lesson")")")
cat > "$lesson" <<EOF
---
{"updated_at": "2030-01-01T00:00:00+00:00", "sources": [{"resource": "../../docs/retrospectives/alpha.md", "content_hash": "$ZEROS"}, {"resource": "../../docs/retrospectives/beta.md", "content_hash": "$ZEROS"}]}
---
# Page
EOF
python3 "$STAMP" "$lesson" > /dev/null
assert_no_grep "$ZEROS" "$lesson" "a source on a shared line was left unstamped"
python3 "$STAMP" "$lesson" --check > /dev/null \
  || fail "compact frontmatter was reported stale after stamping"
pass "brain-capture binds each source object regardless of key order or layout"

# stamp_rejects <label> <frontmatter> asserts a refusal that writes nothing.
stamp_rejects() {
  local label=$1 body=$2 lesson before
  lesson=$(new_brain "reject-$label")
  printf '%s\n---\n# Page\n' "$body" > "$lesson"
  before=$(sha_of "$lesson")
  if python3 "$STAMP" "$lesson" > /dev/null 2>&1; then
    fail "brain-capture helper accepted $label"
  fi
  [ "$(sha_of "$lesson")" = "$before" ] || fail "brain-capture helper rewrote a page carrying $label"
}

stamp_rejects "an orphan content_hash" "---
{
  \"updated_at\": \"2030-01-01T00:00:00+00:00\",
  \"sources\": [
    {\"content_hash\": \"$ZEROS\"},
    {\"resource\": \"../../docs/retrospectives/beta.md\", \"content_hash\": \"$ZEROS\"}
  ]
}"

stamp_rejects "a duplicated source field" "---
{
  \"updated_at\": \"2030-01-01T00:00:00+00:00\",
  \"sources\": [
    {
      \"resource\": \"../../docs/retrospectives/alpha.md\",
      \"content_hash\": \"$ZEROS\",
      \"content_hash\": \"$ZEROS\"
    }
  ]
}"

stamp_rejects "a malformed content_hash" "---
{
  \"updated_at\": \"2030-01-01T00:00:00+00:00\",
  \"sources\": [
    {\"resource\": \"../../docs/retrospectives/alpha.md\", \"content_hash\": \"sha256:not-a-digest\"}
  ]
}"

stamp_rejects "a content_hash outside any source" "---
{
  \"updated_at\": \"2030-01-01T00:00:00+00:00\",
  \"content_hash\": \"$ZEROS\",
  \"sources\": [
    {\"resource\": \"../../docs/retrospectives/alpha.md\", \"content_hash\": \"$ZEROS\"}
  ]
}"

pass "brain-capture refuses orphan, duplicate, and malformed source fields"
