#!/usr/bin/env bash
# Unsupported native posture must never fall through to a bypass template or
# produce report/inbox side effects. Fake endpoint tests, NOT native evidence.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
LAB=$(fm_test_tmproot fm-exact-head-review-refusal)
HOME_DIR="$LAB/home"
PROJ="$LAB/subject"
WT="$LAB/isolated"
FAKEBIN=$(fm_test_make_spawn_fakebin "$LAB/fake")
fm_test_spawn_home "$HOME_DIR" codex
fm_git_worktree "$PROJ" "$WT" refusal
ID=refusal
fm_test_spawn_brief "$HOME_DIR" "$ID"
mkdir -p "$HOME_DIR/state/$ID.inbox/handled"
printf 'pending steer\n' > "$HOME_DIR/state/$ID.inbox/001.msg"
printf 'existing report\n' > "$HOME_DIR/data/$ID/report.md"
LAUNCH_LOG="$LAB/launch"
: > "$LAUNCH_LOG"

refuse() {
  local out rc
  set +e
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$@")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unsupported posture admitted: $out"
  assert_contains "$out" 'unsupported' "missing explicit unsupported result: $out"
  [ ! -s "$LAUNCH_LOG" ] || fail 'refusal delivered a command to an endpoint'
  assert_grep 'pending steer' "$HOME_DIR/state/$ID.inbox/001.msg" 'refusal acknowledged pending steer'
  assert_absent "$HOME_DIR/state/$ID.inbox/handled/001.msg" 'refusal moved pending steer'
  [ "$(<"$HOME_DIR/data/$ID/report.md")" = 'existing report' ] || fail 'refusal published/replaced a report'
  assert_absent "$HOME_DIR/state/$ID.status" 'refusal published a completion/status'
}

for harness in codex claude pi; do
  refuse "$ID" "$PROJ" --scout --harness "$harness" --exact-head-review
  assert_absent "$HOME_DIR/state/$ID.meta" 'unsupported fresh spawn published metadata'
done
refuse "$ID" "$PROJ" --mode local-only --yolo off --harness codex --exact-head-review
refuse "$ID" "$HOME_DIR" --secondmate --harness claude --exact-head-review
refuse "$ID" "$PROJ" --scout 'printf unsafe-raw-launch' --exact-head-review
refuse "$ID" "$PROJ" --scout --harness claude --claude-review --exact-head-review
refuse "$ID" "$PROJ" --scout --harness codex --exact-head-review=off
for backend in tmux herdr zellij orca cmux; do
  refuse "$ID" "$PROJ" --scout --harness codex --backend "$backend" --exact-head-review
done

# A future/imported restrictive record must refuse even without the flag, and
# even when an explicit harness override would otherwise select ordinary bypass.
META="$HOME_DIR/state/$ID.meta"
cat > "$META" <<EOF
backend=tmux
window=firstmate:fm-$ID
endpoint_task_id=$ID
worktree=$WT
project=$PROJ
harness=codex
kind=scout
exact_head_review=on
EOF
cp "$META" "$LAB/meta-before"
for harness in codex claude pi; do
  refuse "$ID" --relaunch --harness "$harness"
  cmp -s "$META" "$LAB/meta-before" || fail 'refusal rewrote restrictive identity'
done

# The supported lifecycle entry must refuse BEFORE stopping the current agent.
for harness in codex claude pi; do
  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-control.sh" "$ID" relaunch \
    --harness "$harness" --note 'keep existing reviewer untouched' 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'control admitted restrictive relaunch'
  assert_contains "$out" 'unsupported' "control did not refuse before stop: $out"
  [ ! -s "$LAUNCH_LOG" ] || fail 'control sent a stop/launch command before refusing'
  cmp -s "$META" "$LAB/meta-before" || fail 'control changed restrictive metadata'
done

for value in '' ON invalid 'on=off'; do
  printf 'exact_head_review=%s\n' "$value" > "$META"
  set +e
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$ID" --relaunch)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'malformed posture admitted'
  assert_contains "$out" 'malformed or duplicate' "malformed posture was not identified: $out"
done
printf 'exact_head_review=off\nexact_head_review=on\n' > "$META"
set +e
out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$ID" --relaunch)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'duplicate posture admitted'
assert_contains "$out" 'malformed or duplicate' 'duplicate posture was not identified'
[ ! -s "$LAUNCH_LOG" ] || fail 'invalid metadata delivered an endpoint command'
# Explicit off is not a restrictive record: normal endpoint validation, rather
# than the new native-policy refusal, remains authoritative for legacy tasks.
printf 'exact_head_review=off\n' > "$META"
set +e
out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$ID" --relaunch)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'incomplete legacy fixture unexpectedly relaunched'
assert_not_contains "$out" 'managed-policy/settings discovery' 'off posture incorrectly treated as restrictive'
assert_not_contains "$out" 'malformed or duplicate' 'off posture incorrectly treated as malformed'
pass 'unsupported exact-head posture refuses fresh/raw/ship/secondmate and restrictive relaunch without output or acknowledgement'
