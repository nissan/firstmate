#!/usr/bin/env bash
# Drive real arm generations in an isolated state home: a fresh start, then two
# --restart generations, each confirming a live watcher that owns the lock.
set -u
ROOT=$1
. "$ROOT/tests/wake-helpers.sh"
TMP_ROOT=$(mktemp -d /tmp/fm-arm-restart.XXXX)
dir=$(make_case drive); state="$dir/state"; fakebin="$dir/fakebin"
export PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=30
arms=()
for gen in 1 2 3; do
  flag=; [ "$gen" -gt 1 ] && flag=--restart
  "$ROOT/bin/fm-watch-arm.sh" $flag > "$dir/arm$gen.out" 2> "$dir/arm$gen.err" &
  arms+=($!)
  for i in $(seq 100); do grep -q "^watcher: " "$dir/arm$gen.out" && break; sleep 0.1; done
  sleep 0.5
  lockpid=$(cat "$state/.watch.lock/pid" 2>/dev/null)
  alive=no; kill -0 "$lockpid" 2>/dev/null && alive=yes
  echo "gen$gen arm ${flag:-(plain)}: $(head -1 "$dir/arm$gen.out") | lock pid=$lockpid alive=$alive"
done
for gen in 1 2; do
  wait "${arms[$((gen-1))]}"; echo "gen$gen arm exited status=$? stdout: $(tr '\n' ' ' < "$dir/arm$gen.out")"
done
grep -h -i -E 'segmentation|nesting|FAILED' "$dir"/arm*.err "$dir"/arm*.out || echo "no segfault/nesting/FAILED output in any generation"
kill -TERM "$(cat "$state/.watch.lock/pid")" 2>/dev/null; wait "${arms[2]}"; echo "gen3 arm exited status=$? after watcher TERM"
rm -rf "$TMP_ROOT"
