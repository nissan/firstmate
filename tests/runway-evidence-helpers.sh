# shellcheck shell=bash
# tests/runway-evidence-helpers.sh - the ample-allowance evidence that every
# test driving a real bin/fm-spawn.sh reads instead of the machine's live
# provider allowance.
# Usage: . tests/runway-evidence-helpers.sh   (sourced, never executed)
#
# Why this is separate from tests/lib.sh: bin/fm-runway-lib.sh gates EVERY fresh
# spawn on the remaining provider allowance, so an unpinned spawn test pays a
# live vendor read and takes its verdict from whoever happens to be running it -
# the same spawn is silent on a full allowance and prints
# "warning: ... spawning <id> anyway" on a thin one. tests/lib.sh pinned that
# evidence for the tests that source it, but the real-spawn end-to-end family
# (tests/fm-backend-autodetect-smoke.test.sh and the real-herdr e2e tests) build
# their own harness and source no shared library, so they were left reading the
# developer's real quota. Owning the fixture here lets both reach it.
#
# This is evidence, not a bypass: the gate still runs end to end on every spawn,
# it just judges a fixture instead of a vendor. tests/fm-runway-gate.test.sh
# unsets FM_RUNWAY_SNAPSHOT to drive the real refusing, warning, and silent
# paths.

# fm_test_pin_runway_evidence <directory>
# Writes the snapshot into <directory> and points the gate at it. The file is
# written at call time because bin/fm-runway-lib.sh judges a snapshot's
# freshness from its modification time, so a long suite cannot age its own
# fixture out into a warning. The caller owns <directory> and its cleanup.
fm_test_pin_runway_evidence() {
  local dir=${1:-}
  [ -n "$dir" ] && [ -d "$dir" ] || {
    echo "fm_test_pin_runway_evidence: needs an existing directory" >&2
    return 1
  }
  cat > "$dir/quota.json" <<'JSON'
{
  "schemaVersion": 5,
  "providers": [
    {"provider": "claude", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 90,
       "runway": {"status": "through_reset"}}]}},
    {"provider": "codex", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 90,
       "runway": {"status": "through_reset"}}]}},
    {"provider": "pi", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 90,
       "runway": {"status": "through_reset"}}]}},
    {"provider": "grok", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 90,
       "runway": {"status": "through_reset"}}]}},
    {"provider": "kimi", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 90,
       "runway": {"status": "through_reset"}}]}},
    {"provider": "cursor", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 90,
       "runway": {"status": "through_reset"}}]}},
    {"provider": "meta", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 90,
       "runway": {"status": "through_reset"}}]}}
  ]
}
JSON
  export FM_RUNWAY_SNAPSHOT="$dir/quota.json"
}
