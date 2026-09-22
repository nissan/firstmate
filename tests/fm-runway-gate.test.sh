#!/usr/bin/env bash
# tests/fm-runway-gate.test.sh - the pre-spawn remaining-allowance gate owned by
# bin/fm-runway-lib.sh and enforced in bin/fm-spawn.sh.
#
# The incident (data/captain.md): a documentation review dispatched at the top
# tier consumed an entire weekly allowance and produced nothing, and the same
# review re-run one tier lower produced a better report with three material
# findings. No delegated work may consume a provider allowance and deliver
# nothing, so a spawn checks the runway before spending it.
#
# The guarantees under test, in the order they matter:
#   - THE FAIL-SAFE DIRECTION IS THE WHOLE RISK. Every task flows through spawn,
#     so a gate that errs toward refusing bricks the fleet. A missing, old,
#     failing, hanging, empty, malformed, stale, or unreadable quota signal, a
#     provider the report does not cover, and an unidentifiable worker runtime
#     must ALL warn and permit - proved against a fixture that genuinely
#     refuses, so none of those cases can pass vacuously.
#   - "Cannot finish" refuses; "might not finish" does not. Each of the three
#     independent spellings of a gone allowance refuses on its own, while
#     quota-axi's own projected_exhaustion warns and allows, because refusing on
#     a projection teaches the operator to override every dispatch.
#   - Ample runway is silent: no warning, no refusal, no noise on a healthy
#     dispatch.
#   - A refusal names the evidence and the way past it, and the documented
#     override actually gets past it.
#   - Only the applicable scopes decide. One snapshot refuses the exhausted
#     model and permits the same harness's healthy default in the same test, so
#     the verdict cannot be coming from the provider row alone.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-runway-gate)
fm_git_identity fmtest fmtest@example.com

# tests/lib.sh pins ample evidence for the whole suite so no test depends on the
# developer's real allowance. This suite drives the gate itself, so every case
# here supplies its own evidence or deliberately takes it away.
unset FM_RUNWAY_SNAPSHOT

# --- evidence fixtures ------------------------------------------------------

# One claude row whose provider-wide scope is healthy and whose fable model
# scope is gone three different ways, plus a codex row quota-axi expects to run
# out before its reset, and a provider it can say nothing about.
write_snapshot() {
  cat > "$1" <<'JSON'
{
  "schemaVersion": 5,
  "providers": [
    {"provider": "claude", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 90,
       "runway": {"status": "through_reset"}},
      {"scope": "model:fable", "status": "known", "effectivePercentRemaining": 0,
       "runway": {"status": "exhausted_now", "usableRunwaySeconds": 0}}]}},
    {"provider": "codex", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 1,
       "runway": {"status": "projected_exhaustion", "usableRunwaySeconds": 3580}}]}},
    {"provider": "cursor", "quotaSemantics": {"status": "unknown",
      "effectiveAvailability": []}}
  ]
}
JSON
}

# Each spelling of "the allowance is gone", on its own, with nothing else in the
# row that could carry the verdict.
write_gone_snapshot() {
  local path=$1 spelling=$2 body
  case "$spelling" in
    exhausted_now)
      body='{"scope": "all_models", "status": "known", "effectivePercentRemaining": 40,
             "runway": {"status": "exhausted_now"}}' ;;
    zero_percent)
      body='{"scope": "all_models", "status": "known", "effectivePercentRemaining": 0,
             "runway": {"status": "through_reset"}}' ;;
    zero_seconds)
      body='{"scope": "all_models", "status": "known", "effectivePercentRemaining": 40,
             "runway": {"status": "projected_exhaustion", "usableRunwaySeconds": 0}}' ;;
    *) fail "unknown gone spelling: $spelling" ;;
  esac
  cat > "$path" <<JSON
{"schemaVersion": 5, "providers": [
  {"provider": "claude", "quotaSemantics": {"status": "known",
    "effectiveAvailability": [$body]}}]}
JSON
}

# run_check <harness> <model> [env assignments...]
# Runs fm_runway_check in a real subprocess against the real library and prints
# "<rc>|<evidence>|<warning>".
# shellcheck disable=SC2016 # The subprocess body is literal shell for `bash -c`.
run_check() {
  local harness=$1 model=$2
  shift 2
  env "$@" bash -c '
      . "$0/bin/fm-runway-lib.sh"
      rc=0
      fm_runway_check "$1" "$2" || rc=$?
      printf "%s|%s|%s\n" "$rc" "$FM_RUNWAY_EVIDENCE" "$FM_RUNWAY_WARNING"
    ' "$ROOT" "$harness" "$model"
}

rc_of() { printf '%s\n' "${1%%|*}"; }
evidence_of() { printf '%s\n' "$1" | cut -d'|' -f2; }
warning_of() { printf '%s\n' "$1" | cut -d'|' -f3; }

REFUSE_RC=2

# --- library: what refuses and what only warns ------------------------------

# The verdict must come from the scopes that bind THIS harness and model, so the
# same snapshot has to answer differently for two models of one provider.
test_only_the_applicable_scope_decides() {
  local snap record
  snap="$TMP_ROOT/applicable.json"
  write_snapshot "$snap"

  record=$(run_check claude fable FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$record")" = "$REFUSE_RC" ] \
    || fail "an exhausted model scope must refuse the spawn: $record"
  case "$(evidence_of "$record")" in
    *model:fable*) ;;
    *) fail "the refusal must name the scope it read: $record" ;;
  esac

  record=$(run_check claude default FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$record")" = 0 ] \
    || fail "the same provider's healthy default model must be permitted: $record"
  [ -z "$(warning_of "$record")" ] \
    || fail "ample runway must be silent, not warned about: $record"

  # A bridging runtime spends another vendor's allowance, and WHICH vendor comes
  # from the model, so the same exhausted claude scope must refuse it - reached
  # through the routing prefix quota-axi's own scopes never carry.
  record=$(run_check omp claude-bridge/fable FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$record")" = "$REFUSE_RC" ] \
    || fail "a bridged model must be judged against the vendor it spends: $record"
  case "$(evidence_of "$record")" in
    *model:fable*) ;;
    *) fail "the bridged refusal must name the vendor's own model scope: $record" ;;
  esac
  pass "fm-runway: only the scopes applicable to the harness and model decide"
}

# Each spelling of a gone allowance must refuse on its own, so a vendor that
# reports only one of them still produces the refusal.
test_every_spelling_of_a_gone_allowance_refuses() {
  local snap record spelling
  snap="$TMP_ROOT/gone.json"
  for spelling in exhausted_now zero_percent zero_seconds; do
    write_gone_snapshot "$snap" "$spelling"
    record=$(run_check claude default FM_RUNWAY_SNAPSHOT="$snap")
    [ "$(rc_of "$record")" = "$REFUSE_RC" ] \
      || fail "a '$spelling' allowance must refuse the spawn: $record"
    [ -n "$(evidence_of "$record")" ] \
      || fail "a '$spelling' refusal must carry the evidence it read: $record"
  done
  pass "fm-runway: every spelling of a spent allowance refuses"
}

# The line the whole design rests on: a projection is not an impossibility.
test_a_projection_warns_instead_of_refusing() {
  local snap record
  snap="$TMP_ROOT/projection.json"
  write_snapshot "$snap"
  record=$(run_check codex default FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "an allowance quota-axi merely expects to run out must not refuse: $record"
  [ "$(rc_of "$record")" != 0 ] \
    || fail "a runway that may not last must still be reported: $record"
  case "$(warning_of "$record")" in
    *projection*) ;;
    *) fail "the warning must say the shortfall is a projection: $record" ;;
  esac
  pass "fm-runway: a runway that might not last warns rather than refusing"
}

# Schema 6: once a provider expands to several accounts, quota-axi keys every
# row by provider + accountKey, and a spawn spends only the account its lane
# names. The healthy default row comes FIRST in each provider, so a reader that
# ignored the lane and took the first row would permit every spawn here.
write_schema6_snapshot() {
  cat > "$1" <<'JSON'
{
  "schemaVersion": 6,
  "providers": [
    {"provider": "codex", "accountKey": "default", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 80,
       "runway": {"status": "through_reset"}}]}},
    {"provider": "codex", "accountKey": "codex-home", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 0,
       "runway": {"status": "exhausted_now", "usableRunwaySeconds": 0}}]}},
    {"provider": "pi", "accountKey": "default", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 70,
       "runway": {"status": "through_reset"}}]}},
    {"provider": "pi", "accountKey": "openai-codex", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 0,
       "runway": {"status": "exhausted_now"}}]}},
    {"provider": "claude", "accountKey": "default", "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "all_models", "status": "known", "effectivePercentRemaining": 90,
       "runway": {"status": "through_reset"}}]}}
  ]
}
JSON
}

# The verdict must come from the account the spawn's lane binds to, with the
# default account standing in only when the lane has no row of its own.
test_a_schema6_verdict_reads_the_lanes_own_account() {
  local snap record
  snap="$TMP_ROOT/schema6.json"
  write_schema6_snapshot "$snap"

  record=$(run_check codex default FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$record")" = "$REFUSE_RC" ] \
    || fail "a codex spawn must be judged on its codex-home account, not the first row: $record"

  record=$(run_check pi openai-codex/gpt-5 FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$record")" = "$REFUSE_RC" ] \
    || fail "a Pi spawn must be judged on the account its model prefix names: $record"

  record=$(run_check pi xai/grok-4 FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$record")" = 0 ] \
    || fail "a lane with no row of its own must fall back to the healthy default account: $record"

  record=$(run_check claude default FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$record")" = 0 ] \
    || fail "a harness with no lane must bind the default account: $record"
  [ -z "$(warning_of "$record")" ] \
    || fail "ample runway on the default account must be silent: $record"
  pass "fm-runway: a schema 6 verdict reads the spawn lane's own account"
}

# --- library: the fail-safe direction ---------------------------------------

# The fleet-bricking class. Every case starts from evidence that DOES refuse and
# breaks exactly one input, so a pass here can never be vacuous.
test_no_missing_or_broken_signal_can_refuse() {
  local snap record baseline
  snap="$TMP_ROOT/failsafe.json"
  write_gone_snapshot "$snap" exhausted_now

  baseline=$(run_check claude default FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$baseline")" = "$REFUSE_RC" ] \
    || fail "the refusing baseline must refuse, or nothing below proves anything: $baseline"

  # The snapshot is gone, unreadable, empty, malformed, or not a regular file.
  record=$(run_check claude default FM_RUNWAY_SNAPSHOT="$TMP_ROOT/no-such-file.json")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] || fail "an absent snapshot must not refuse: $record"
  [ -n "$(warning_of "$record")" ] || fail "an absent snapshot must explain itself: $record"

  : > "$TMP_ROOT/empty.json"
  record=$(run_check claude default FM_RUNWAY_SNAPSHOT="$TMP_ROOT/empty.json")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] || fail "an empty snapshot must not refuse: $record"

  printf 'not json at all\n' > "$TMP_ROOT/garbage.json"
  record=$(run_check claude default FM_RUNWAY_SNAPSHOT="$TMP_ROOT/garbage.json")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] || fail "a malformed snapshot must not refuse: $record"

  # Schema-shaped but not this schema: rejected as evidence, not read as bad news.
  printf '{"schemaVersion": 4, "providers": []}\n' > "$TMP_ROOT/oldschema.json"
  record=$(run_check claude default FM_RUNWAY_SNAPSHOT="$TMP_ROOT/oldschema.json")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "an unsupported snapshot schema must not refuse: $record"

  ln -s "$snap" "$TMP_ROOT/linked.json"
  record=$(run_check claude default FM_RUNWAY_SNAPSHOT="$TMP_ROOT/linked.json")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "a symlinked snapshot must not refuse: $record"

  # Evidence about a time that is not now. The same refusing bytes, aged out.
  cp "$snap" "$TMP_ROOT/stale.json"
  touch -t 202001010000 "$TMP_ROOT/stale.json"
  record=$(run_check claude default FM_RUNWAY_SNAPSHOT="$TMP_ROOT/stale.json")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "a snapshot too old to describe the allowance now must not refuse: $record"
  case "$(warning_of "$record")" in
    *stale*|*"not from the last"*) ;;
    *) fail "a stale snapshot must say so: $record" ;;
  esac

  # A provider the report does not cover, and one it covers with no known scope.
  record=$(run_check grok default FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "a provider the report does not cover must not refuse: $record"
  write_snapshot "$TMP_ROOT/unknown-provider.json"
  record=$(run_check cursor default FM_RUNWAY_SNAPSHOT="$TMP_ROOT/unknown-provider.json")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "a provider with no known scope must not refuse: $record"

  # A worker runtime with no tracked provider family at all.
  record=$(run_check some-unverified-runtime default FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "an unmapped worker runtime must not refuse: $record"
  record=$(run_check "" default FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "an unidentifiable worker runtime must not refuse: $record"

  # The map is keyed on the model too, so a bridging runtime routed at a vendor
  # it has no mapping for is one more unreadable signal: absent evidence, never
  # bad news.
  record=$(run_check omp ollama/qwen3:8b FM_RUNWAY_SNAPSHOT="$snap")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "an unmapped bridged model must not refuse: $record"
  [ -n "$(warning_of "$record")" ] \
    || fail "an unmapped bridged model must explain itself: $record"
  pass "fm-runway: no missing or broken quota signal can refuse a spawn"
}

# --- library: reading the tool itself ---------------------------------------

# fake_quota_axi <dir> <version> <mode> [payload-file]
# A quota-axi that answers --version and --json separately, so a case can break
# one without touching the other. Modes: json (print the payload), fail (exit
# nonzero), garbage (print non-JSON), hang (outlive any sane bound).
fake_quota_axi() {
  local dir=$1 version=$2 mode=$3 payload=${4:-} fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  -v|--version) printf '%s\n' 'quota-axi $version'; exit 0 ;;
esac
case '$mode' in
  fail) printf 'quota-axi: cannot reach the vendor\n' >&2; exit 1 ;;
  garbage) printf 'not json\n'; exit 0 ;;
  hang) sleep 120; exit 0 ;;
  json) cat '$payload'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# With no captured snapshot the gate reads the tool, and every way that read can
# come back useless must still permit the spawn.
test_reading_the_tool_refuses_only_on_real_evidence() {
  local snap record fakebin
  snap="$TMP_ROOT/tool-gone.json"
  write_gone_snapshot "$snap" exhausted_now

  # Baseline: a real read of real evidence refuses, so the cases below are not
  # vacuous and the live read path is genuinely exercised.
  fakebin=$(fake_quota_axi "$TMP_ROOT/tool-ok" 0.1.35 json "$snap")
  record=$(run_check claude default PATH="$fakebin:$PATH")
  [ "$(rc_of "$record")" = "$REFUSE_RC" ] \
    || fail "reading a spent allowance from the tool must refuse: $record"

  # Below the supported floor: not a build this gate was checked against.
  fakebin=$(fake_quota_axi "$TMP_ROOT/tool-old" 0.0.9 json "$snap")
  record=$(run_check claude default PATH="$fakebin:$PATH")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "a quota tool below the supported floor must not refuse: $record"

  fakebin=$(fake_quota_axi "$TMP_ROOT/tool-fail" 0.1.35 fail)
  record=$(run_check claude default PATH="$fakebin:$PATH")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "a failing quota read must not refuse: $record"

  fakebin=$(fake_quota_axi "$TMP_ROOT/tool-garbage" 0.1.35 garbage)
  record=$(run_check claude default PATH="$fakebin:$PATH")
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "an unreadable quota read must not refuse: $record"

  # A wedged vendor CLI must not wedge the dispatch: the bound has to fire and
  # the answer has to be "proceed".
  local started elapsed
  fakebin=$(fake_quota_axi "$TMP_ROOT/tool-hang" 0.1.35 hang)
  started=$(date +%s)
  record=$(run_check claude default PATH="$fakebin:$PATH" FM_RUNWAY_READ_TIMEOUT=2)
  elapsed=$(( $(date +%s) - started ))
  [ "$(rc_of "$record")" != "$REFUSE_RC" ] \
    || fail "a hung quota read must not refuse: $record"
  [ "$elapsed" -lt 60 ] \
    || fail "a hung quota read must be bounded, not waited out (${elapsed}s): $record"
  pass "fm-runway: reading the tool refuses only on real evidence"
}

# --- end to end through the real bin/fm-spawn.sh ----------------------------

# make_spawn_home <name>
# A real spawn home with a real isolated worktree. Echoes "home|wt|fakebin|proj".
make_spawn_home() {
  local name=$1 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$name-new"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  printf '%s|%s|%s|%s\n' "$home" "$wt" "$fakebin" "$proj"
}

# run_gated_spawn <home> <wt> <fakebin> <proj> <id> [env assignments...]
run_gated_spawn() {
  local home=$1 wt=$2 fakebin=$3 proj=$4 id=$5
  shift 5
  env "$@" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="${TMUX:-fake,1,0}" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --mode local-only --yolo off 2>&1
}

test_spawn_is_silent_with_runway_and_refused_without_it() {
  local rec home wt fakebin proj snap out status
  snap="$TMP_ROOT/e2e-ample.json"
  write_snapshot "$snap"

  # Positive control: with runway, the spawn succeeds AND says nothing about the
  # allowance, or every "was not blocked" assertion below would be meaningless.
  rec=$(make_spawn_home ample)
  IFS='|' read -r home wt fakebin proj <<EOF
$rec
EOF
  mkdir -p "$home/user-home"
  out=$(run_gated_spawn "$home" "$wt" "$fakebin" "$proj" ample-new \
    FM_RUNWAY_SNAPSHOT="$snap"); status=$?
  expect_code 0 "$status" "a spawn with ample runway must succeed: $out"
  assert_contains "$out" "spawned ample-new" "the healthy spawn did not report success"
  assert_not_contains "$out" "allowance" "ample runway must be silent, not narrated"

  # The same home, the same worker runtime, and a model whose allowance is gone.
  snap="$TMP_ROOT/e2e-gone.json"
  write_gone_snapshot "$snap" exhausted_now
  rec=$(make_spawn_home gone)
  IFS='|' read -r home wt fakebin proj <<EOF
$rec
EOF
  mkdir -p "$home/user-home"
  out=$(run_gated_spawn "$home" "$wt" "$fakebin" "$proj" gone-new \
    FM_RUNWAY_SNAPSHOT="$snap"); status=$?
  [ "$status" -ne 0 ] || fail "a spawn with no allowance left must be refused: $out"
  assert_contains "$out" "spawn refused" "the refusal must say the spawn was refused"
  assert_contains "$out" "all_models" "the refusal must name the evidence it read"
  assert_contains "$out" "FM_RUNWAY_OVERRIDE=1" "the refusal must name the way past it"
  assert_absent "$home/state/gone-new.meta" "a refused spawn must not create task state"
  pass "fm-spawn: ample runway spawns silently and a spent allowance is refused by name"
}

test_documented_override_spawns_past_the_refusal_loudly() {
  local rec home wt fakebin proj snap out status
  snap="$TMP_ROOT/e2e-override.json"
  write_gone_snapshot "$snap" exhausted_now
  rec=$(make_spawn_home override)
  IFS='|' read -r home wt fakebin proj <<EOF
$rec
EOF
  mkdir -p "$home/user-home"
  out=$(run_gated_spawn "$home" "$wt" "$fakebin" "$proj" override-new \
    FM_RUNWAY_SNAPSHOT="$snap" FM_RUNWAY_OVERRIDE=1); status=$?
  expect_code 0 "$status" "the documented override must spawn past the refusal: $out"
  assert_contains "$out" "spawned override-new" "the overridden spawn did not report success"
  assert_contains "$out" "FM_RUNWAY_OVERRIDE" "using the override must be loud, not silent"
  assert_contains "$out" "allowance left" "the override warning must still carry the evidence"
  pass "fm-spawn: the documented override spawns past the refusal and says so"
}

# The fleet-bricking case end to end: the same home that refuses with evidence
# must spawn when the evidence is simply unavailable.
test_an_unavailable_signal_warns_and_never_blocks_a_spawn() {
  local rec home wt fakebin proj snap out status
  snap="$TMP_ROOT/e2e-failsafe.json"
  write_gone_snapshot "$snap" exhausted_now
  rec=$(make_spawn_home failsafe)
  IFS='|' read -r home wt fakebin proj <<EOF
$rec
EOF
  mkdir -p "$home/user-home"

  if out=$(run_gated_spawn "$home" "$wt" "$fakebin" "$proj" failsafe-first \
    FM_RUNWAY_SNAPSHOT="$snap"); then
    fail "the intact fixture must refuse, or this case proves nothing: $out"
  fi

  fm_test_spawn_brief "$home" failsafe-broken
  out=$(run_gated_spawn "$home" "$wt" "$fakebin" "$proj" failsafe-broken \
    FM_RUNWAY_SNAPSHOT="$TMP_ROOT/no-such-snapshot.json"); status=$?
  expect_code 0 "$status" "an unreadable allowance signal must not block a spawn: $out"
  assert_contains "$out" "spawning failsafe-broken anyway" \
    "a skipped allowance check must warn, not stay silent"
  assert_contains "$out" "spawned failsafe-broken" "the spawn must still complete: $out"

  # No quota evidence at all: no captured snapshot, and no tool on PATH either.
  fm_test_spawn_brief "$home" failsafe-blind
  out=$(run_gated_spawn "$home" "$wt" "$fakebin" "$proj" failsafe-blind \
    FM_RUNWAY_SNAPSHOT='' PATH="$fakebin:/usr/bin:/bin"); status=$?
  expect_code 0 "$status" "an absent quota tool must not block a spawn: $out"
  assert_contains "$out" "spawned failsafe-blind" "the spawn must still complete: $out"
  pass "fm-spawn: an unavailable allowance signal warns and never blocks a spawn"
}

# tests/runway-evidence-helpers.sh is the fixture the real-spawn end-to-end suites
# depend on - tests/fm-backend-autodetect-smoke.test.sh and the real-herdr e2e
# family drive the real bin/fm-spawn.sh, source no shared test library, and are
# excluded from the portable CI lanes, so nothing CI runs would notice them
# going back to reading the machine's live quota. Their contract is therefore
# proved here: pinned, a real spawn is silent AND never reaches the vendor tool.
# The unpinned control in the same case proves the tool IS reached otherwise, so
# this cannot pass vacuously.
test_the_shared_evidence_fixture_keeps_a_real_spawn_off_the_vendor() {
  local rec home wt fakebin proj out status marker evidence pinned
  rec=$(make_spawn_home fixture)
  IFS='|' read -r home wt fakebin proj <<EOF
$rec
EOF
  mkdir -p "$home/user-home"

  marker="$TMP_ROOT/fixture-quota-axi-calls"
  cat > "$fakebin/quota-axi" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$marker"
exit 1
STUB
  chmod +x "$fakebin/quota-axi"

  fm_test_spawn_brief "$home" fixture-live
  out=$(run_gated_spawn "$home" "$wt" "$fakebin" "$proj" fixture-live \
    FM_RUNWAY_SNAPSHOT=''); status=$?
  expect_code 0 "$status" "an unpinned spawn must still succeed: $out"
  [ -s "$marker" ] \
    || fail "unpinned, the gate must reach the vendor tool, or this case proves nothing"

  rm -f "$marker"
  evidence="$TMP_ROOT/fixture-evidence"
  mkdir -p "$evidence"
  ( . "$ROOT/tests/runway-evidence-helpers.sh"
    fm_test_pin_runway_evidence "$evidence" >/dev/null ) \
    || fail "the shared evidence fixture could not be applied"
  # Read it back the way a pinned suite would, rather than trusting the path.
  pinned=$( . "$ROOT/tests/runway-evidence-helpers.sh"
    fm_test_pin_runway_evidence "$evidence" >/dev/null
    printf '%s\n' "$FM_RUNWAY_SNAPSHOT" )
  [ -s "$pinned" ] || fail "the shared evidence fixture wrote no snapshot"

  fm_test_spawn_brief "$home" fixture-pinned
  out=$(run_gated_spawn "$home" "$wt" "$fakebin" "$proj" fixture-pinned \
    FM_RUNWAY_SNAPSHOT="$pinned"); status=$?
  expect_code 0 "$status" "a spawn on the pinned evidence must succeed: $out"
  assert_contains "$out" "spawned fixture-pinned" "the pinned spawn did not report success"
  assert_not_contains "$out" "allowance" "the pinned evidence must spawn silently, not narrate"
  [ ! -s "$marker" ] \
    || fail "the pinned evidence must keep a spawn off the vendor tool, called: $(cat "$marker")"
  pass "fm-runway: the shared evidence fixture spawns silently and never reads the vendor"
}

test_only_the_applicable_scope_decides
test_every_spelling_of_a_gone_allowance_refuses
test_a_projection_warns_instead_of_refusing
test_a_schema6_verdict_reads_the_lanes_own_account
test_no_missing_or_broken_signal_can_refuse
test_reading_the_tool_refuses_only_on_real_evidence
test_spawn_is_silent_with_runway_and_refused_without_it
test_documented_override_spawns_past_the_refusal_loudly
test_an_unavailable_signal_warns_and_never_blocks_a_spawn
test_the_shared_evidence_fixture_keeps_a_real_spawn_off_the_vendor
