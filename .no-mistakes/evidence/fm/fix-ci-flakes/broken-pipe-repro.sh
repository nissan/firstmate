#!/usr/bin/env bash
# Reproduces the Linux CI race deterministically on any host: the writer that
# feeds fm_control_harness_supported / fm_quota_single_provider_for_harness is
# slowed (first line, then a pause, then the rest) and SIGPIPE is ignored as on
# the CI runner, so an early `return` from the pipe-fed loop leaves the writer
# mid-printf. Runs the real function bodies from the old (base) and new (fixed)
# libs and prints what the caller's captured stderr contains.
lib_dir=$1; label=$2
trap '' PIPE
. "$lib_dir/fm-control-lib.sh" 2>/dev/null
. "$lib_dir/fm-quota-axi-lib.sh" 2>/dev/null
fm_control_harnesses() { printf '%s\n' claude; sleep 0.3; printf '%s\n' codex opencode pi; }
fm_quota_single_provider_table() { printf '%s\n' 'claude claude'; sleep 0.3; printf '%s\n' 'codex codex' 'muse meta'; }
err=$( { fm_control_harness_supported claude; echo "rc=$?" >&3; } 3>&1 2>&1 >/dev/null ); sleep 0.5
out=$( { fm_control_harness_supported claude && echo supported; } 2>&1 ); sleep 0.5
echo "[$label] fm_control_harness_supported claude -> captured output: '$(printf '%s' "$out" | tr '\n' ' ')'"
out=$( { fm_quota_single_provider_for_harness claude; } 2>&1 ); sleep 0.5
echo "[$label] fm_quota_single_provider_for_harness claude -> captured output: '$(printf '%s' "$out" | tr '\n' ' ')'"
