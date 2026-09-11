#!/usr/bin/env bash
# fm-noprogress-lib.sh - the spend-without-artifact guard.
#
# Sourced, never executed.
#
# WHY THIS EXISTS. The pane-staleness backbone in bin/fm-watch.sh only ever
# fires on a FROZEN pane: it hashes the last 40 lines, and a hash that keeps
# moving is treated as liveness. That is exactly the hole a real burn walked
# through - a worker ran roughly 18 hours and spent 292.7k tokens producing
# nothing at all, twice on the same task, and nothing in the system noticed
# either time. Its pane never stopped moving (a climbing token counter, a
# spinner, scrolling tool output), so it never went stale, never wedged, and
# never surfaced. This library is the orthogonal check for that shape: work
# that is SPENDING but not PRODUCING.
#
# THE DISTINCTION THAT MATTERS. Idleness is not the signal, and must never be
# treated as one - the staleness backbone already owns quiet panes, and a
# declared wait behind a running pipeline is admitted there deliberately. The
# signal here is strictly token spend that buys no artifact:
#
#   frozen token count  -> the worker is WAITING. Always silent. A worker idle
#                          for 40 minutes on a background pipeline spends
#                          nothing and produces nothing, and that is healthy.
#   artifact grew       -> the worker is PRODUCING. Always silent, and the
#                          window restarts. A scout appending findings to its
#                          report as it establishes them (the incremental-report
#                          contract in the scout brief) is progress, and reads
#                          as progress here.
#   tokens climbing and
#   no artifact moved   -> the burn shape. Escalate for a human.
#
# ARTIFACTS. What counts as production is deliberately the same set a
# supervisor would look at: a commit landing in the task worktree, the scout
# report growing, a status line appended, or files written in the worktree.
# The first three are cheap stats read every poll; the worktree write probe is
# the bounded walk bin/fm-classify-lib.sh already owns
# (crew_worktree_written_since) and, like the wedge timer, it runs ONLY at the
# moment this guard would otherwise escalate - never per poll.
#
# ESCALATE, NEVER KILL. This guard raises a flag and stops. It never
# interrupts, signals, restarts, or tears down a worker. Two workers on one
# day proved why: one that looked finished was mid-pipeline, and one that
# looked wedged was legitimately waiting. An automatic killer would have
# destroyed real work in both cases. The captain kills workers.
#
# UNREADABLE IS SILENT. No parseable token counter means no observation, and
# no observation means no escalation. A harness whose footer this library
# cannot read simply keeps the coverage it had before (the staleness backbone),
# rather than gaining a guard that fires on a guess.
#
# PER-TURN COUNTERS, ACCUMULATED SPEND. Every harness footer this repo has
# recorded live renders a PER-TURN counter that restarts at each turn boundary,
# not a running session total:
#
#   "✢ Pollinating… (16s · ↓ 1.1k tokens · thought for 1s)"   (claude)
#   "Sock-hopping… (11s · ↓ 234 tokens)"                      (claude)
#   " ⠘⠆ Running  59 tokens"                                  (cursor)
#
# tests/fm-watch-noprogress.test.sh drives those three shapes verbatim, so the
# claim above is a test, not a comment.
#
# So the rendered number is a rate, not a total, and the only total this guard
# can have is one it accumulates itself. Every poll contributes a DELTA: the
# rise since the previous poll while a turn is still running, and the whole
# rendered value when the counter dropped, because a drop is the start of a new
# turn rather than a reason to forget what the previous turns cost. That sum is
# what the spend gate measures, so eighteen hours of turns that each render a
# thousand tokens and produce nothing reach the threshold exactly the way one
# imaginary session counter climbing to the same number would. A counter that
# does not move contributes nothing, which is what keeps a wait silent.
#
# STATE. One record per task at state/.noprogress-<task>, in the same
# private-marker family as .hash-/.count-/.stale-. It carries:
#
#   tokens=<n>      the counter rendered on the previous poll, so the next
#                   poll's delta - and a frozen counter - are recognisable.
#   spend=<n>       tokens accumulated against the current artifact fingerprint
#                   across every turn since the window opened.
#   art=<sig>       the artifact fingerprint the window is anchored to.
#   since=<epoch>   when that fingerprint was first seen.
#   flagged=<n>     the accumulated spend at the last escalation, so
#                   re-escalation is paced by further spend, not by the clock.
#
# A record written by an older release carries base= instead of spend=; it is
# read as unparseable and simply opens a fresh window, which is the same thing
# every other corrupt-record path here does.
#
# Callers: bin/fm-watch.sh, bin/fm-teardown.sh.
set -u

# Tokens accumulated across turns against one unchanged artifact fingerprint
# before the guard escalates - roughly a day and a half of Claude's recorded
# ~1.1k-token turns, or a fifth of the 292.7k the motivating burn spent, all of
# it against a worktree with no commit, no report write, no status line, and no
# file written. It is deliberately far above what any single turn renders: one
# long reasoning turn that then writes a file must not trip this, and with the
# time gate below it cannot, because a window that young is never eligible.
FM_NOPROGRESS_SPEND=${FM_NOPROGRESS_SPEND:-60000}

# Seconds the artifact fingerprint must have been unchanged before the guard
# escalates. Both gates must be crossed: a fast burst of spend that lands an
# artifact minutes later is not the shape being caught.
FM_NOPROGRESS_SECS=${FM_NOPROGRESS_SECS:-1800}

# fm_noprogress_record: absolute path of a task's guard record.
fm_noprogress_record() {  # <state> <task>
  printf '%s/.noprogress-%s' "$1" "$2"
}

# fm_noprogress_anchor: absolute path of a task's window anchor - an empty file
# whose MTIME is the start of the current window. It exists because the
# worktree write probe this guard defers to
# (crew_worktree_written_since in bin/fm-classify-lib.sh) compares file times
# against a file, not an epoch. The record itself is rewritten on every poll and
# so is useless as an anchor; this one is touched only when the window restarts.
fm_noprogress_anchor() {  # <state> <task>
  printf '%s/.noprogress-since-%s' "$1" "$2"
}

# fm_noprogress_clear: drop a task's guard record and anchor, so the next
# observation opens a fresh window rather than inheriting a stale one. Called
# from the watcher's absorb branch, when a bounded worktree walk proves the
# window bought uncommitted writes after all, and from bin/fm-teardown.sh, so a
# retired task leaves no record behind for an id the home may reuse.
fm_noprogress_clear() {  # <state> <task>
  rm -f "$(fm_noprogress_record "$1" "$2")" "$(fm_noprogress_anchor "$1" "$2")" 2>/dev/null || true
}

# _fm_noprogress_field: one field out of a record, empty when absent.
_fm_noprogress_field() {  # <record> <name>
  local rec=$1 name=$2 line
  [ -f "$rec" ] || return 0
  line=$(grep "^$name=" "$rec" 2>/dev/null | tail -1) || return 0
  printf '%s' "${line#*=}"
}

# _fm_noprogress_uint: echo <value> when it is a plain non-negative integer,
# else <default>. Every number this library reads back off disk or out of a
# pane goes through here, so a corrupt record degrades to a fresh window
# instead of poisoning arithmetic under `set -u`/`set -e`.
_fm_noprogress_uint() {  # <value> <default>
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *)           printf '%s' "$1" ;;
  esac
}

# fm_noprogress_pane_tokens: the token counter rendered in a pane capture, as a
# plain integer, or nothing when the capture carries none.
#
# Every verified harness renders its counter as a number next to the word
# "tokens" ("· 292.7k tokens", "Running  59 tokens", "tokens used: 1,234"), so
# that is the whole grammar: an optional k/m/g suffix, optional thousands
# commas, optional one decimal place. Anything else is not a token counter and
# is ignored - a guess here would become a false escalation, and the cost of
# reading nothing is only that this guard stays silent for that harness.
#
# FOOTER REGION ONLY. The match is narrowed to the last 12 non-blank lines, the
# same TUI footer region every other rendered-string contract in this repo reads
# (fm_busy_grok_tail_busy and fm_busy_rovo_tail_busy in bin/fm-busy-lib.sh, and
# window_is_busy's narrowing in bin/fm-watch.sh), because scrollback is content
# a worker can print and a counter grammar applied to content is a grammar an
# agent can forge. Within that region, "from <n> tokens" is dropped as well: the
# compaction notice this repo has recorded live ("Compacted from 7,697 tokens",
# docs/verification/supervision.md) is prose about a past total, not a counter.
#
# The LARGEST remaining match wins. A footer can render more than one number
# next to "tokens", and the largest is the stable choice across polls; picking a
# smaller one would make the reading jitter between shapes. Which of them is
# per-turn no longer matters, because fm_noprogress_observe accumulates deltas
# and treats a drop as a turn boundary rather than as a reset.
fm_noprogress_pane_tokens() {  # <pane-capture>
  local capture=${1:-} best=0 seen=1 raw num frac unit scaled
  while read -r raw; do
    [ -n "$raw" ] || continue
    # raw arrives as "<digits>[.<digit>][k|m|g]" with commas already stripped.
    unit=${raw##*[0-9]}
    num=${raw%"$unit"}
    case "$num" in
      *.*) frac=${num#*.}; num=${num%.*} ;;
      *)   frac=0 ;;
    esac
    frac=$(_fm_noprogress_uint "$frac" 0)
    num=$(_fm_noprogress_uint "$num" 0)
    case "$unit" in
      k|K) scaled=$(( num * 1000 + frac * 100 )) ;;
      m|M) scaled=$(( num * 1000000 + frac * 100000 )) ;;
      g|G) scaled=$(( num * 1000000000 + frac * 100000000 )) ;;
      *)   scaled=$num ;;
    esac
    [ "$scaled" -le "$best" ] || best=$scaled
    seen=0
  done <<EOF
$(printf '%s\n' "$capture" \
  | grep -v '^[[:space:]]*$' \
  | tail -12 \
  | tr -d ',' \
  | sed -E 's/[Ff][Rr][Oo][Mm][[:space:]]+[0-9]+(\.[0-9])?[kKmMgG]?[[:space:]]+[Tt][Oo][Kk][Ee][Nn][Ss]//g' \
  | grep -oiE '[0-9]+(\.[0-9])?[kmg]?[[:space:]]+tokens|tokens([[:space:]]+used)?:[[:space:]]*[0-9]+(\.[0-9])?[kmg]?' \
  | sed -E 's/[[:space:]]*tokens([[:space:]]+used)?:?[[:space:]]*//I')
EOF
  [ "$seen" -eq 0 ] || return 1
  printf '%s' "$best"
}

# fm_noprogress_artifact_sig: the cheap artifact fingerprint for a task - the
# head commit of its worktree, the size of its report, and the size of its
# status log, joined. Any of the three moving means the worker produced
# something. A component that cannot be read contributes a fixed placeholder
# rather than a changing value, so an unreadable worktree can never masquerade
# as continuous progress.
fm_noprogress_artifact_sig() {  # <state> <task> <data>
  local state=$1 task=$2 data=$3 wt head report status
  wt=$(grep '^worktree=' "$state/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  head='-'
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || head='-'
    [ -n "$head" ] || head='-'
  fi
  report='-'
  if [ -f "$data/$task/report.md" ]; then
    report=$(_fm_noprogress_uint "$(LC_ALL=C wc -c < "$data/$task/report.md" | tr -d ' ')" -)
  fi
  status='-'
  if [ -f "$state/$task.status" ]; then
    status=$(_fm_noprogress_uint "$(LC_ALL=C wc -c < "$state/$task.status" | tr -d ' ')" -)
  fi
  printf '%s:%s:%s' "$head" "$report" "$status"
}

# fm_noprogress_observe: fold one poll's observation into the task's window and
# say what the supervisor should do about it.
#
# Prints exactly one verdict line:
#   ok                            nothing to do
#   escalate <spend> <secs>       the burn shape crossed both gates
#
# and returns 0 in both cases; a non-zero return means the observation could
# not be recorded and the caller should treat this poll as unobserved.
#
# <tokens> is the counter RENDERED this poll, which on every verified harness is
# a per-turn number (see the header). What this folds into the window is the
# delta that number represents:
#
#   rose since the previous poll -> the running turn spent that much more
#   dropped                      -> a turn boundary; the new turn has already
#                                   spent what it renders, and the turns before
#                                   it still cost what they cost, so the whole
#                                   rendered value is added rather than the
#                                   accumulated total being forgotten
#   unchanged                    -> nothing was spent at all
#
# Silence is the default and every uncertainty resolves to it: an unreadable
# token count, a first sighting with no window, a record too corrupt to parse,
# and above all a counter that did not move at all.
fm_noprogress_observe() {  # <state> <task> <tokens> <artifact-sig> <now>
  local state=$1 task=$2 tokens=$3 sig=$4 now=$5
  local rec prev_tokens prev_sig spend since flagged delta age

  rec=$(fm_noprogress_record "$state" "$task")
  case "$tokens" in
    ''|*[!0-9]*) printf 'ok\n'; return 0 ;;
  esac
  case "$now" in
    ''|*[!0-9]*) printf 'ok\n'; return 0 ;;
  esac

  prev_sig=$(_fm_noprogress_field "$rec" art)
  prev_tokens=$(_fm_noprogress_uint "$(_fm_noprogress_field "$rec" tokens)" '')
  spend=$(_fm_noprogress_uint "$(_fm_noprogress_field "$rec" spend)" '')
  since=$(_fm_noprogress_uint "$(_fm_noprogress_field "$rec" since)" '')
  flagged=$(_fm_noprogress_uint "$(_fm_noprogress_field "$rec" flagged)" 0)

  # A moved fingerprint is production: restart the window outright, and the
  # spend the previous window accumulated goes with it. This is the branch that
  # keeps a scout writing its report incrementally silent. An unreadable or
  # older-format record lands here too, so it opens a clean window instead of
  # poisoning the accounting.
  if [ "$sig" != "$prev_sig" ] || [ -z "$spend" ] || [ -z "$since" ] || [ -z "$prev_tokens" ]; then
    _fm_noprogress_write "$rec" "$tokens" 0 "$sig" "$now" 0 || return 1
    : > "$(fm_noprogress_anchor "$state" "$task")" 2>/dev/null || true
    printf 'ok\n'
    return 0
  fi

  # The delta this poll contributes. A drop is a turn boundary, never a reset:
  # forgetting the accumulated spend there is exactly how a per-turn counter
  # would hide an all-day burn.
  if [ "$tokens" -ge "$prev_tokens" ]; then
    delta=$(( tokens - prev_tokens ))
  else
    delta=$tokens
  fi
  spend=$(( spend + delta ))

  _fm_noprogress_write "$rec" "$tokens" "$spend" "$sig" "$since" "$flagged" || return 1

  # THE FROZEN-COUNTER GATE. Nothing spent since the previous poll means the
  # worker is waiting, not burning, and this guard says nothing - however long
  # the wait runs and however much was spent before it began.
  [ "$delta" -gt 0 ] || { printf 'ok\n'; return 0; }

  age=$(( now - since ))
  [ "$age" -ge 0 ] || age=0
  if [ "$spend" -lt "$FM_NOPROGRESS_SPEND" ] || [ "$age" -lt "$FM_NOPROGRESS_SECS" ]; then
    printf 'ok\n'
    return 0
  fi
  # Re-escalation is paced by further spend, not by the clock: a flagged burn
  # that keeps burning earns another flag only after another full threshold.
  if [ "$flagged" -gt 0 ] && [ "$(( spend - flagged ))" -lt "$FM_NOPROGRESS_SPEND" ]; then
    printf 'ok\n'
    return 0
  fi
  _fm_noprogress_write "$rec" "$tokens" "$spend" "$sig" "$since" "$spend" || return 1
  printf 'escalate %s %s\n' "$spend" "$age"
}

# _fm_noprogress_write: publish a record atomically, so a watcher killed
# mid-write leaves the previous window rather than a half-parsed one.
_fm_noprogress_write() {  # <record> <tokens> <spend> <sig> <since> <flagged>
  local rec=$1 tmp
  tmp="$rec.tmp.$$"
  {
    printf 'tokens=%s\n' "$2"
    printf 'spend=%s\n' "$3"
    printf 'art=%s\n' "$4"
    printf 'since=%s\n' "$5"
    printf 'flagged=%s\n' "$6"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  mv -f "$tmp" "$rec" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
}

# fm_noprogress_reason: the supervisor-facing wake reason for one escalation.
# Says what was observed and what to check, and states plainly that nothing was
# stopped - the reader decides whether to kill the worker.
fm_noprogress_reason() {  # <window> <spend> <secs>
  printf 'stale: %s (spending without producing: %s tokens since the last commit, report write, or status line %ss ago, demand-deep-inspection: read the pane before absorbing - nothing was stopped, killing this worker is the captain'\''s call)' \
    "$1" "$2" "$3"
}
