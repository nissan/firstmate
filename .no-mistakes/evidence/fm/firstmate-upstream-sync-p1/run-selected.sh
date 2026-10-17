#!/usr/bin/env bash
# run-selected.sh <worktree> <tests/x.test.sh> <test_fn>...
# Sources a firstmate test file with its trailing top-level test invocations
# stripped, then runs only the named test functions. Used to produce targeted
# evidence without executing the whole file.
WT=$1; FILE=$2; shift 2
cd "$WT/tests" || exit 2
src=$(sed -E \
  -e '/^test_[A-Za-z0-9_]+$/d' \
  -e '/^echo "# all .* tests passed"$/d' \
  -e 's#\. "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/(fixtures|lib)\.sh"#. "'"$WT"'/tests/\1.sh"#' \
  "$WT/$FILE")
eval "$src"
rc=0
for t in "$@"; do
  if ! declare -F "$t" >/dev/null; then echo "runner: $t is not defined in $FILE" >&2; rc=2; continue; fi
  "$t" || rc=$?
done
exit "$rc"
