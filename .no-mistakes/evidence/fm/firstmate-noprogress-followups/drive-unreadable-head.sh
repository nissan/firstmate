#!/usr/bin/env bash
# Drive fm-noprogress-lib against a real git worktree whose HEAD is unreadable
# when the window opens, then becomes readable with a first commit.
set -u
LIB=$1
. "$LIB"
T=$(mktemp -d); STATE=$T/state; DATA=$T/data; WT=$T/wt
mkdir -p "$STATE" "$DATA/t" "$WT"
printf 'worktree=%s\n' "$WT" > "$STATE/t.meta"
export FM_NOPROGRESS_SPEND=1000 FM_NOPROGRESS_SECS=100
poll() { local tok=$1 now=$2 sig v; sig=$(fm_noprogress_artifact_sig "$STATE" t "$DATA"); v=$(fm_noprogress_observe "$STATE" t "$tok" "$sig" "$now");
  printf 'now=%s tokens=%s sig=%s verdict=[%s] record: %s\n' "$now" "$tok" "$sig" "$v" "$(tr '\n' ' ' < "$(fm_noprogress_record "$STATE" t)")"; }
echo "# worktree dir exists but is not a git repo -> HEAD unreadable"
poll 100 1000
echo "# first commit lands; HEAD becomes readable"
git -C "$WT" init -q && git -C "$WT" -c user.email=a@b -c user.name=x commit -q --allow-empty -m first
poll 600 1050
poll 1200 1100
echo "# a later real commit (known sha -> different sha) is still production"
git -C "$WT" -c user.email=a@b -c user.name=x commit -q --allow-empty -m second
poll 1300 1200
echo "# HEAD read hangs (FM_NOPROGRESS_TIMEOUT=1, slow git on PATH) -> carries last known head"
mkdir -p $T/fakebin; printf '#!/bin/sh\nsleep 5\n' > $T/fakebin/git; chmod +x $T/fakebin/git
PATH=$T/fakebin:$PATH FM_NOPROGRESS_TIMEOUT=1 poll 1400 1250
rm -rf "$T"
