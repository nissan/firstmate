#!/usr/bin/env bash
# Audits every git object reachable from this branch but not from origin/main
# for leaked private material. Prints check names and verdicts only - never the
# private tokens it searches for.
set -eu
BASE=$1
echo "objects reachable from HEAD but not origin/main:"
mapfile -t OBJS < <(git rev-list --objects "$BASE..HEAD" | awk '{print $1}')
echo "  $(git rev-list "$BASE..HEAD" | wc -l) commits, ${#OBJS[@]} total objects (commits+trees+blobs)"
mapfile -t BLOBS < <(for o in "${OBJS[@]}"; do
  [ "$(git cat-file -t "$o")" = blob ] && echo "$o"; done)
echo "  ${#BLOBS[@]} blobs scanned"

dump() { for b in "${BLOBS[@]}"; do git cat-file -p "$b"; done; }
CONTENT=$(dump)
# Also scan commit messages and every path name introduced on the branch.
CONTENT="$CONTENT
$(git log --format='%B' "$BASE..HEAD")
$(git rev-list --objects "$BASE..HEAD" | cut -d' ' -f2-)"

check() { # name, ERE
  local name=$1 re=$2 n
  n=$(printf '%s' "$CONTENT" | grep -Ecai -- "$re" || true)
  if [ "$n" -eq 0 ]; then printf '  PASS  %s\n' "$name"
  else printf '  FAIL  %s (%s matching lines)\n' "$name" "$n"; fi
}
echo
echo "leak checks over blob contents, introduced path names, and commit messages"
echo "(git authorship metadata is the change's expected author and is not scanned):"
check "no captain home / absolute machine paths (/home/<user>, /Users/<user>)" '(/home/[a-z0-9._-]+/|/Users/[A-Za-z0-9._-]+/)'
check "no captain account identity in file contents, paths, or messages" 'nissan'
check "no private fleet or session host records" '(fleet\.md|sessions\.md|state/[0-9a-z]{6,}\.meta|\.ssh/)'

# Registered project names from the captain's real home must not appear except
# the one this integration names on purpose (shared-brain).
REG=${FM_HOME:?set FM_HOME to your Firstmate home}/data/projects.md
if [ -r "$REG" ]; then
  leaked=0; total=0
  while read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = shared-brain ] && continue
    total=$((total+1))
    printf '%s' "$CONTENT" | grep -Fqa -- "$name" && leaked=$((leaked+1))
  done < <(awk '$1=="-" {print $2}' "$REG")
  if [ "$leaked" -eq 0 ]; then
    printf '  PASS  no private project record names (%s checked, shared-brain excluded by design)\n' "$total"
  else
    printf '  FAIL  %s private project record name(s) leaked\n' "$leaked"
  fi
else
  printf '  SKIP  no real project registry available to cross-check\n'
fi

# Shared Brain payload material must not be vendored.
check "no Shared Brain corpus/evidence payload markers" '(okf[_-]?v0\.2|corpus/[a-z0-9-]+/lesson|evidence/[a-z0-9-]+/signed)'
