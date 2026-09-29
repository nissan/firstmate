#!/usr/bin/env bash
# Manual drive of bin/fm-teardown.sh against the historical four-records-one-slot shape.
set -u
ROOT=${ROOT:?}; T=$(mktemp -d /tmp/fm-4rec.XXXX)
. "$ROOT/tests/lib.sh" >/dev/null 2>&1 || true
mkdir -p $T/home/{state,data,config} $T/fakebin $T/pool/1 $T/project
for b in tmux treehouse; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$FM_RUNTIME_LOG"\nexit 0\n' $b > $T/fakebin/$b; chmod +x $T/fakebin/$b; done
git init -q $T/project; git -C $T/project -c user.name=t -c user.email=t@x commit -q --allow-empty -m x
git -C $T/project worktree add -q --detach $T/pool/1/project; ln -s pool/1/project $T/worktree; : > $T/worktree/sentinel
printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' $T/pool/1/project > $T/pool/treehouse-state.json
for id in brain-a brain-b brain-c live-owner; do
  printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=scout\n' $id $id $T/worktree $T/project > $T/home/state/$id.meta
done
printf 'task=live-owner\nhome=%s\n' $T/home > $T/pool/1/.fm-slot-owner
touch -d @1700000000 $T/home/state/brain-{a,b,c}.meta; touch -d @1700000010 $T/pool/1/.fm-slot-owner
: > $T/runtime.log
run(){ echo; echo "\$ fm-teardown.sh $*"; FM_HOME=$T/home FM_ROOT_OVERRIDE=$ROOT FM_RUNTIME_LOG=$T/runtime.log PATH=$T/fakebin:$PATH "$ROOT/bin/fm-teardown.sh" "$@" 2>&1 | grep -v '^●'; echo "exit=${PIPESTATUS[0]}"; echo "records: $(cd $T/home/state; ls *.meta | tr '\n' ' ')"; }
echo "== Scenario A: plain teardown of a stale record still refuses (slot reassigned)"; run brain-a --force
echo "== Scenario B: brain-b rewritten after claim (ambiguous chronology) blocks brain-a"; touch -d @1700000020 $T/home/state/brain-b.meta; run brain-a --record-only --force
touch -d @1700000000 $T/home/state/brain-b.meta
echo "== Scenario C: retire the three stale records one at a time"; run brain-a --record-only --force; run brain-b --record-only --force; run brain-c --record-only --force
echo "== Scenario D: record-only on the live owner itself refuses"; run live-owner --record-only --force
echo; echo "claim: $(tr '\n' ' ' < $T/pool/1/.fm-slot-owner)"; echo "sentinel present: $([ -e $T/worktree/sentinel ] && echo yes)"
echo "runtime.log (tmux/treehouse calls):"; grep -E 'kill-window|treehouse' $T/runtime.log || echo "  (no kill-window, no treehouse return)"
rm -rf "$T"
