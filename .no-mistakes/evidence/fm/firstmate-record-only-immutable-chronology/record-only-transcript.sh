#!/usr/bin/env bash
# Manual CLI drive of fm-teardown --record-only after completion bookkeeping,
# Sandbox-only: FM_GATE_REFUSE_BYPASS=1 is the documented test-harness exemption (tests/lib.sh); FM_HOME is a throwaway temp dir.
# using the real slot-claim writer from bin/fm-wake-lib.sh and real fm-captain-hold.
set -u
ROOT=${ROOT:?}
T=$(mktemp -d /tmp/fm-ro-XXXX)
setup() {  # <case>
  local d=$T/$1
  mkdir -p $d/home/state $d/home/data $d/home/config $d/fakebin $d/project $d/pool/1
  git init -q $d/project
  git -C $d/project -c user.name=t -c user.email=t@t commit --allow-empty -qm pool
  git -C $d/project worktree add -q --detach $d/pool/1/project
  ln -s pool/1/project $d/worktree
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' $d/pool/1/project > $d/pool/treehouse-state.json
  : > $d/worktree/sentinel; : > $d/runtime.log
  for b in tmux treehouse; do printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$FM_RUNTIME_LOG"\n' $b > $d/fakebin/$b; chmod +x $d/fakebin/$b; done
  echo $d
}
run() { local d=$1; shift; FM_GATE_REFUSE_BYPASS=1 FM_HOME=$d/home FM_ROOT_OVERRIDE=$ROOT FM_RUNTIME_LOG=$d/runtime.log PATH=$d/fakebin:$PATH "$@"; }
now=$(date +%s)
claim() {  # <case-dir> <owner>
  local d=$1 o=$2
  # Real claim writer, as fm-spawn uses it.
  FM_HOME=$d/home bash -c ". '$ROOT/bin/fm-wake-lib.sh'; fm_treehouse_slot_owner_claim '$d/pool/1/project' '$o' '$d/home' && echo \$FM_TREEHOUSE_SLOT_CLAIM_GEN" 
}
scenario() {  # <case> <stale spawn_gen> <owner-gen-override|-> <force>
  local name=$1 sg=$2 override=$3 force=$4 d gen rc
  echo; echo "################ $name"
  d=$(setup $name)
  printf 'window=firstmate:fm-stale-task\nendpoint_task_id=stale-task\nworktree=%s\nproject=%s\nkind=scout\nspawn_gen=%s\n' $d/worktree $d/project "$sg" > $d/home/state/stale-task.meta
  touch -d @$((now-500)) $d/home/state/stale-task.meta
  printf 'window=firstmate:fm-live-task\nendpoint_task_id=live-task\nworktree=%s\nproject=%s\nkind=scout\n' $d/worktree $d/project > $d/home/state/live-task.meta
  gen=$(claim $d live-task)
  if [ "$sg" = CLAIM_EPOCH ]; then e=${gen#c}; e=${e%%.*}; sed -i "s/^spawn_gen=.*/spawn_gen=s$e.11.12/" $d/home/state/stale-task.meta; touch -d @$((now-500)) $d/home/state/stale-task.meta; echo "stale spawn_gen=s$e.11.12 (same second as claim); stale meta mtime forced 500s before claim"; fi
  [ "$override" = - ] && echo "slot_claim_gen=$gen" >> $d/home/state/live-task.meta || echo "slot_claim_gen=$override" >> $d/home/state/live-task.meta
  echo "\$ cat pool/1/.fm-slot-owner"; sed "s#$d#<case>#" $d/pool/1/.fm-slot-owner
  sleep 1
  echo "\$ fm-captain-hold.sh complete stale-task --none   # completion bookkeeping"
  run $d $ROOT/bin/fm-captain-hold.sh complete stale-task --none 2>&1 | grep -v '^●' | sed "s#$d#<case>#g"
  echo "stale meta mtime=$(stat -c %Y $d/home/state/stale-task.meta)  claim epoch=${gen#c}  (now=$(date +%s))"
  echo "\$ fm-teardown.sh stale-task --record-only $force"
  run $d $ROOT/bin/fm-teardown.sh stale-task --record-only $force > $d/out 2>&1; rc=$?
  grep -v '^●' $d/out | sed "s#$d#<case>#g" | tail -8
  echo "exit=$rc"
  echo "stale record: $([ -e $d/home/state/stale-task.meta ] && echo PRESENT || echo removed)"
  echo "owner record: $([ -e $d/home/state/live-task.meta ] && echo PRESENT || echo removed)"
  echo "slot claim:   $(grep ^task= $d/pool/1/.fm-slot-owner 2>/dev/null || echo MISSING)"
  echo "slot sentinel: $([ -e $d/worktree/sentinel ] && echo PRESENT || echo removed)"
  echo "treehouse calls: $(grep -c ^treehouse $d/runtime.log)"
}
scenario A-modern-stale-after-bookkeeping "s$((now-300)).11.12" - --force
scenario B-no-discard-without-force "s$((now-300)).11.12" - ""
scenario C-spawn-gen-equals-claim-epoch CLAIM_EPOCH - --force
scenario D-owner-claim-gen-contradicts "s$((now-300)).11.12" "c$((now-50)).1.1" --force
scenario E-malformed-spawn-gen "s$((now-300)).x.12" - --force
scenario F-future-spawn-gen "s$((now+100000)).11.12" - --force
rm -rf $T
