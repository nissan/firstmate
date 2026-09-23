#!/usr/bin/env bash
# Runs the real (unpatched) old and new functions over every harness name plus
# unknown/empty/partial inputs and prints rc + stdout, so a diff shows equivalence.
dir=$1
. "$dir/fm-control-lib.sh" 2>/dev/null; . "$dir/fm-quota-axi-lib.sh" 2>/dev/null
for h in claude codex opencode pi pi-signed grok kimi cursor gemini muse rovo omp agy '' bogus clau 'claude codex' meta; do
  o=$(fm_control_harness_supported "$h"); r=$?; printf 'supported(%q) rc=%s out=%q\n' "$h" "$r" "$o"
  o=$(fm_quota_single_provider_for_harness "$h"); r=$?; printf 'provider(%q) rc=%s out=%q\n' "$h" "$r" "$o"
done
o=$(fm_control_harness_supported); printf 'supported(no-arg) rc=%s\n' $?
