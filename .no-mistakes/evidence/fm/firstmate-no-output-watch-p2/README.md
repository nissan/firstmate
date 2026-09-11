# Guard 3 (spend-without-artifact) — end-to-end evidence

Branch `fm/firstmate-no-output-watch-p2`, `e5c388d..52fdc0a`.

The incident this guard is commissioned to catch: a worker ran roughly 18 hours
and spent 292.7k tokens producing nothing, twice on the same task, and nothing
noticed either time.

| Artifact | What it shows |
|---|---|
| `incident-replay.txt` | The incident replayed at **production defaults** through the real library — before/after. |
| `wired-watcher-transcript.txt` | The real `bin/fm-watch.sh` escalating a live burning pane, and staying silent on the two shapes that must never be flagged. |
| `away-mode-digest.txt` | What the captain actually receives while away, for four crews. |
| `mutation-evidence.txt` | Each load-bearing line deleted; the new coverage fails without it. |

Drivers are checked in beside their output (`replay-incident.sh`,
`wired-watcher-demo.sh`, `away-mode-digest-demo.sh`) and
`noprogress-lib-dd431fc.sh` is the pre-fix library taken verbatim from this
branch's own first commit, so the before/after is measured on shipped code
rather than on a model of it.

## 1. The incident, replayed — `incident-replay.txt`

266 turns of the recorded claude footer
`✢ Pollinating… (16s · ↓ 1.1k tokens · thought for 1s)`, rendered as the
per-turn counter it actually is (it restarts at every turn boundary), against a
worktree where nothing is ever produced. `FM_NOPROGRESS_SPEND=60000` and
`FM_NOPROGRESS_SECS=1800`, untouched.

    BEFORE  bin/fm-noprogress-lib.sh @ dd431fc
      escalations over 17h44m of unproductive spend: 0
      >> the burn runs all day and nobody is told.

    AFTER   bin/fm-noprogress-lib.sh @ HEAD
      escalations over 17h44m of unproductive spend: 4
      first escalation at turn 55, 3h39m into the run, 60200 tokens accumulated

      stale: ops:fm-burner (spending without producing: 60200 tokens with no
      commit, report write, or status line for the last 13140s - read the pane
      before absorbing; nothing was stopped, killing this worker is the
      captain's call)

    frozen counter (a worker waiting on a background pipeline)   escalations: 0
    counter climbing AND the report growing (a scout at work)    escalations: 0

The 3h39m matches the re-derived threshold documented at
`bin/fm-noprogress-lib.sh:110-124` ("at the motivating burn's own rate ... in
under four" hours), and the four escalations over the full run are the
spend-paced re-escalation, not a wake storm.

## 2. The real watcher — `wired-watcher-transcript.txt`

Three live workers, real `bin/fm-watch.sh`, real pane captures, every pane
churning on every poll so the pane-staleness backbone can never fire.

The burning worker produces the line that wakes firstmate and the durable row a
human reads out of `state/.wake-queue`, and the complete list of tmux commands
the watcher issued against that worker is

    capture-pane -p -t ops:fm-burn -S -40
    display-message -p -t ops:fm-burn #{pane_id}

read-only: it escalated and never interrupted, signalled, or killed. The frozen
worker and the report-writing worker are both silent, and their watchers are
still polling.

## 3. Away mode — `away-mode-digest.txt`

The motivating burn ran unattended, which is the posture where the daemon's
cheap status-log classification used to absorb the guard outright. Four crews,
driven through the real guard, the real `handle_wake`, and the real
`escalate_flush`:

- **still reporting progress** — classifier says `self|transient stale`; the
  captain is paged anyway.
- **behind a declared wait** — classifier says `pause|paused (awaiting
  external)`; the captain is paged anyway, because a status line is prose about
  idleness and this guard's signal is spend.
- **same declared wait, counter frozen** — the guard returns `ok` on every poll;
  nothing reaches the captain.
- **an unread `blocked: need prod credentials`** — one digest carrying *both*
  the blocked line and the burn evidence, so the event is never marked reported
  without having been reported.
