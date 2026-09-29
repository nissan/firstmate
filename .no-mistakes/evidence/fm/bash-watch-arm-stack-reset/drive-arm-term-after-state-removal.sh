#!/usr/bin/env bash
# Drive the real fm-watch.sh + fm-watch-arm.sh (no FUNCNEST, default native stack):
# seed a watcher in an isolated state home, attach an arm, tear the home down,
# TERM the arm, and report how the arm process ended.
set -u
ROOT=$1; LABEL=$2
. "$ROOT/tests/wake-helpers.sh"
TMP_ROOT=$(mktemp -d /tmp/fm-arm-drive.XXXX)
dir=$(make_case drive); state="$dir/state"; fakebin="$dir/fakebin"
PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2>&1 &
wpid=$!
for i in $(seq 60); do [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break; sleep 0.1; done
PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=30 "$ROOT/bin/fm-watch-arm.sh" > "$dir/arm.out" 2> "$dir/arm.err" &
armpid=$!
for i in $(seq 80); do grep -q "watcher: attached" "$dir/arm.out" && break; sleep 0.1; done
echo "[$LABEL] root=$ROOT"
echo "[$LABEL] arm stdout before teardown: $(cat "$dir/arm.out")"
rm -rf "$state"
SECONDS=0
kill -TERM "$armpid"
wait "$armpid"; st=$?

sig=""; [ "$st" -gt 128 ] && sig=" ($(kill -l $((st-128))))"
echo "[$LABEL] arm exit status=$st$sig after ${SECONDS}s"
echo "[$LABEL] arm stderr (last 5 lines):"; tail -5 "$dir/arm.err" | cut -c1-200
kill -TERM "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
rm -rf "$TMP_ROOT"
