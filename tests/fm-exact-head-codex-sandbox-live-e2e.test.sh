#!/usr/bin/env bash
# Token-free native shell-sandbox canary, NOT model/reviewer/policy admission.
# Runs no app server, model, daemon, hooks, or reviewer. Claude remains unsupported
# and is NOT covered by this Codex-specific sandbox primitive test.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_EXACT_HEAD_CODEX_SANDBOX_LIVE codex
case "$(uname -s)" in
Linux) ;;
*) fail 'native Codex sandbox primitive test currently supports Linux only' ;;
esac
LAB=$(fm_test_tmproot fm-exact-head-codex-sandbox)
CODEX=$(command -v codex)
VERSION=$("$CODEX" --version)
mkdir -p "$LAB/subject" "$LAB/codex-home"
export CODEX_HOME="$LAB/codex-home"
printf 'unchanged\n' > "$LAB/subject/canary"
printf 'unchanged\n' > "$LAB/settings.json"
# Unsandboxed positive control: ordinary Unix permissions allow each write.
printf 'control\n' > "$LAB/subject/canary"
printf 'control\n' > "$LAB/settings.json"
printf 'unchanged\n' > "$LAB/subject/canary"
printf 'unchanged\n' > "$LAB/settings.json"
cd "$LAB/subject"
set +e
out=$("$CODEX" sandbox -c 'sandbox_mode="read-only"' -- /bin/sh -c 'cat canary' 2>"$LAB/read.stderr")
rc=$?
set -e
[ "$rc" -eq 0 ] && [ "$out" = unchanged ] || fail "$VERSION: native read control failed: $out (stderr in $LAB/read.stderr)"
for target in canary "$LAB/settings.json"; do
  set +e
  # The sandboxed child shell, not this parent, expands its positional argument.
  # shellcheck disable=SC2016
  out=$("$CODEX" sandbox -c 'sandbox_mode="read-only"' -- /bin/sh -c \
    'printf "ATTEMPTED\n"; printf changed > "$1"' sh "$target" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$VERSION: native sandbox allowed write to $target"
  assert_contains "$out" ATTEMPTED "$VERSION: denial was only a launcher/parser failure"
  case "$out" in
  *'Read-only file system'* | *'Permission denied'*) ;;
  *) fail "$VERSION: no native filesystem refusal evidence: $out" ;;
  esac
  [ "$(<"$target")" = unchanged ] || fail "$VERSION: canary changed despite error"
  printf 'ok - %s: native denied write: %s\n' "$VERSION" "$out"
done
pass "$VERSION: native subject/outside-settings writes denied; NOT Claude/model/MCP/network or managed-policy admission"
