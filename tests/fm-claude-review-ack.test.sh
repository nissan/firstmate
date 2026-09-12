#!/usr/bin/env bash
# Behavior tests for the generated Claude review inbox acknowledgement helper.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-review-ack)
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
WT="$TMP_ROOT/wt"
ID=review-ack
LAUNCH_LOG="$TMP_ROOT/launch"
FAKEBIN=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_spawn_home "$HOME_DIR" claude
fm_git_worktree "$PROJ" "$WT" review-ack
fm_test_spawn_brief "$HOME_DIR" "$ID"

out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" \
  "$ID" "$PROJ" --scout --harness claude --claude-review)
expect_code 0 "$?" "Claude review scout spawn failed: $out"
HELPER="$HOME_DIR/state/$ID.claude-review-ack.sh"
INBOX="$HOME_DIR/state/$ID.inbox"
HANDLED="$INBOX/handled"
OTHER="$HOME_DIR/state/other.inbox"
assert_present "$HELPER" "spawn did not publish the acknowledgement helper"
[ "$(stat -c '%a' "$HELPER")" = 700 ] || fail "acknowledgement helper mode is not 0700"

mkdir -p "$HANDLED" "$OTHER/handled"
printf 'second\n' > "$INBOX/002.msg"
printf 'first\n' > "$INBOX/001.msg"
printf 'foreign\n' > "$OTHER/001.msg"

out=$("$HELPER" forbidden 2>&1); rc=$?
expect_code 2 "$rc" "helper must refuse every argument"
assert_contains "$out" 'accepts no arguments' "argument refusal was unclear"
assert_present "$INBOX/001.msg" "argument refusal acknowledged a message"

"$HELPER" || fail "helper failed to acknowledge the oldest own message"
assert_absent "$INBOX/001.msg" "oldest own message remained pending"
assert_grep first "$HANDLED/001.msg" "oldest own message was not moved intact"
assert_present "$INBOX/002.msg" "one invocation acknowledged more than one message"
assert_present "$OTHER/001.msg" "helper touched another task's inbox"

"$HELPER" || fail "helper failed to acknowledge the next own message"
assert_grep second "$HANDLED/002.msg" "second own message was not moved intact"
assert_present "$OTHER/001.msg" "second invocation touched another task's inbox"

printf 'existing\n' > "$HANDLED/003.msg"
printf 'pending\n' > "$INBOX/003.msg"
out=$("$HELPER" 2>&1); rc=$?
expect_code 1 "$rc" "helper must refuse an existing acknowledgement destination"
assert_contains "$out" 'already exists' "existing-destination refusal was unclear"
assert_present "$INBOX/003.msg" "existing-destination refusal lost the pending message"
rm "$HANDLED/003.msg" "$INBOX/003.msg"

ln -s "$OTHER/001.msg" "$INBOX/004.msg"
out=$("$HELPER" 2>&1); rc=$?
expect_code 1 "$rc" "helper must refuse a symlinked pending message"
assert_contains "$out" 'unsafe' "symlink refusal was unclear"
assert_present "$OTHER/001.msg" "symlink refusal touched its target"
rm "$INBOX/004.msg"

cp "$HOME_DIR/state/$ID.meta" "$TMP_ROOT/meta"
printf 'endpoint_task_id=another\n' > "$HOME_DIR/state/$ID.meta"
out=$("$HELPER" 2>&1); rc=$?
expect_code 1 "$rc" "helper must refuse cross-task metadata identity"
assert_contains "$out" 'identity does not match' "cross-task identity refusal was unclear"
mv "$TMP_ROOT/meta" "$HOME_DIR/state/$ID.meta"

SEND_LOG="$TMP_ROOT/send"
: > "$SEND_LOG"
out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SEND_SETTLE=0 FM_FAKE_LAUNCH_LOG="$SEND_LOG" FM_FAKE_DUPLICATE_WINDOW="fm-$ID" \
  PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-send.sh" "$ID" "steered review instruction" 2>&1)
expect_code 0 "$?" "fm-send did not durably steer the review task: $out"
assert_grep 'steered review instruction' "$INBOX/003.msg" \
  "fm-send did not record the steer in the review task's own inbox"
assert_grep "list '$INBOX'/*.msg" "$SEND_LOG" "fm-send did not ring the review task's doorbell"
assert_no_grep 'steered review instruction' "$SEND_LOG" "fm-send typed the steer payload into the review pane"
"$HELPER" || fail "helper failed to acknowledge a steer delivered by fm-send"
assert_absent "$INBOX/003.msg" "fm-send steer remained pending after acknowledgement"
assert_grep 'steered review instruction' "$HANDLED/003.msg" \
  "fm-send steer was not moved intact into its own handled directory"
assert_present "$OTHER/001.msg" "acknowledging an fm-send steer touched another task's inbox"

"$HELPER" || fail "empty own inbox should be an idempotent success"
assert_present "$OTHER/001.msg" "empty own-inbox acknowledgement touched another task"
pass "Claude review acknowledgement helper is task-bound, one-at-a-time, argument-free, symlink-safe, and acknowledges real fm-send steers"
