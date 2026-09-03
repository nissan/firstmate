---
name: pause-and-learn
description: >-
  Find a safe natural pause point for one current project or thread, finish only its already-authorized tranche, capture the retrospective and Shared Brain lessons, mine and independently evaluate reusable skill candidates, run /stow, and leave later work queued.
  Use when the captain invokes /pause-and-learn or says "pause and learn", "find a natural pause point", "pause this and capture the lessons", "wrap this up so we can focus elsewhere", "finish this tranche and learn from it", or asks to pause a project and preserve its lessons.
user-invocable: true
metadata:
  internal: true
---

# pause-and-learn

Bring one project or thread to the safest bounded pause, complete its learning cycle, and leave the next tranche visibly queued without beginning it.
This skill orchestrates existing owners rather than replacing their procedures.

## Planning mode

Only the exact command form `/pause-and-learn plan`, with optional surrounding whitespace but no other arguments, is read-only.
In that mode, perform the scope and evidence inventory, choose the proposed safe boundary, identify existing cycle artifacts and queued work, and report the plan without spawning work, changing records, invoking component skills, or writing artifacts.
All safety and authority checks still apply.

In that mode, and only there, end the response with exactly one fenced JSON object introduced by the line `PAUSE_AND_LEARN_PLAN_V1`.
That object is the stable planning contract and contains these fields:

```json
{
  "schema": "firstmate.pause-and-learn.plan.v1",
  "mode": "plan",
  "scope": {"project": "resolved project", "thread": "resolved thread"},
  "existing_cycle": {"found": true, "identity": "stable identity or empty string", "resume_phase": "phase or new"},
  "boundary": {"kind": "post-current-stage", "name": "named stable boundary", "wait_for_current_stage": true, "current_stage": "current stage", "interrupt_current_stage": false},
  "project_writes": {"route": "worker", "firstmate_writes_project": false},
  "components": {"retrospective": "planned", "brain_capture": "planned", "skill_forge": "planned", "stow": "planned"},
  "brain": {"status": "draft", "brain_status": "proposed", "canonical_write": false},
  "authority": {"merge": false, "sign": false, "approve": false, "promote": false, "discard": false, "destructive": false, "security_sensitive": false, "semantic_expansion": false},
  "sequencing": {"prior_review_failure_backfilled": false},
  "queued": [{"id": "durable queued-item identity", "name": "display name", "start": false, "state": "paused", "resume": {"captain_focus_required": true, "separate_authorization_required": true}}],
  "mutations": {"records": false, "workers": false, "artifacts": false}
}
```

Derive every placeholder string from current evidence rather than copying the example values.
For each downstream tranche, preserve its durable record identity in `id`, keep human wording only in `name`, and express resume requirements through the fixed booleans rather than free-form vocabulary.
Emit one entry per downstream tranche in `queued`, each with its own durable identity, or an empty array when none exists.
Do not negate or qualify the boolean values in prose; the object is authoritative for the plan.

### Refused command forms

Refuse `/pause-and-learn plan` carrying any trailing argument.
Do not enter planning mode and do not fall through to the mutating cycle: change no record, worker, or artifact, emit no `PAUSE_AND_LEARN_PLAN_V1` block, say the read-only form takes no arguments, name the exact accepted form, and let the captain reissue it.
[`plan-check.py`](plan-check.py) next to this skill is the check-only authority for both that classification and the plan contract above; it validates and never writes, spawns, or changes anything.

## 1. Resolve one scope and reuse any cycle already under way

1. Resolve the project and thread exactly under `AGENTS.md` section 7, "Intake and authority".
2. Form a stable cycle identity from the registered project identity and the named thread or current authorized tranche, never from a temporary branch, worker, session, or version.
3. Inventory structured backlog records, work already under way, completed artifacts, project delivery records, and registered project locations for that identity.
   Treat conversational prose as a lead, not proof of repository or review reality.
4. Reuse the existing pause-cycle work item, retrospective, corpus entry, candidate ledger, evaluation, review, and delivery work whenever their identity, source hashes, or artifact links match.
   Update an existing record in place instead of appending a duplicate.
   A repeated invocation resumes at the first incomplete phase and never creates a second cycle merely because the first is waiting for review, delivery, or a captain decision.
5. If no cycle record exists and this is not planning mode, file one ordinary backlog item using the configured backlog owner.
   Give it the stable cycle identity and record the selected boundary, phase outcomes, artifact links, exact source commits, and candidate dispositions in its considered body.
   This is an ordinary work record, not a new state format or control plane.

## 2. Choose the natural pause boundary

1. Inventory the current tranche's accepted intent, current delivery stage, dependencies, externally stable milestones, and the next queued roadmap tranche.
2. Prefer the earliest boundary that leaves the accepted tranche coherent, testable, recoverable, and externally stable.
   A terminal completed change, a green review-ready change, a completed investigation report, or a documented external wait can qualify.
3. Never interrupt an active validation run, exact-head review, merge, irreversible operation, or worker-owned branch stage merely to pause.
   Name the next safe terminal boundary after that operation and supervise the existing work until it reaches that boundary.
4. Finish only work already authorized and necessary to make the current tranche coherent at that boundary.
   Preserve the selected delivery path, branch custody, review sequence, and merge authority.
5. Do not start the next roadmap tranche, opportunistic cleanup, or a recommended implementation that lacks separate authorization.
   Keep each downstream item durable and explicitly held as paused for focus until the captain returns to it, preserving real dependencies and existing priority.
6. The invocation grants no merge, signing, approval, promotion, canonical-write, discard, destructive, irreversible, security-sensitive, or semantic authority.
   Stop for the authority owner whenever the bounded cycle reaches one of those decisions.
7. If a merge happened before required review consensus, record the sequencing failure plainly.
   Later agreement may verify the exact merged bytes retrospectively, but it never backfills the historical gate or converts the sequence into a compliant one.

## 3. Wait for terminal evidence

Do not begin retrospective or corpus capture until the terminal evidence needed to make it accurate exists.
That evidence includes the exact source commit, final test and review outcomes, delivery result, material failures and corrections, and the disposition of the current tranche.
A completed earlier change may supply part of the evidence, but an active exact-head review remains unfinished evidence and must reach its safe boundary first.
Use the ordinary supervision protocol while waiting and do not create a second worker for work already owned by the active worker.

## 4. Run the retrospective through its owner

Determine the retrospective owner from the scoped project's conventions, then load that owner and follow it without copying its format here.
When [`brain-capture`](../brain-capture/SKILL.md) owns the retrospective, its procedure is authoritative.
Every project write is performed by a worker in an isolated copy through that project's registered validation and delivery path.
Reuse an overlapping retrospective and amend it only with evidence that belongs to this cycle.

## 5. Mine and evaluate reusable skill candidates

Load [`skill-forge`](../skill-forge/SKILL.md) and follow its candidate, rejection, evaluation, ablation, stopping, and reporting contracts.
This Firstmate safety rule overrides `skill-forge`'s live-install-first instruction: author in the owning repository, expose the exact candidate bytes to the evaluator from an isolated repository discovery location, and install or update fleet-visible bytes only after the ordinary reviewed delivery path lands.
Route every candidate write to a worker in its owning repository, predeclare the scenario-specific bar, require a fresh context and normal independent review, and retain no failing or materially redundant candidate.
Evaluation grants no merge, promotion, canonical installation, or approval authority.

## 6. Capture proposed Shared Brain content

Resolve the registered Shared Brain project through the intake owner named in step 1, then reuse any capture with matching identity and sources.
Dispatch its project change to a worker that loads [`brain-capture`](../brain-capture/SKILL.md); that skill owns the retrospective, corpus format, source stamping, redaction, indexing, validation, evaluation, and report procedure.
Supply the exact completed evidence and skill-candidate disposition ledger as inputs.
Keep agent-authored content private, `draft`, and `proposed`, with unsigned review evidence and the project's normal independent review and delivery path.
This skill never signs, verifies, promotes, merges, or makes that content canonical.

## 7. Stow local operating memory

After the retrospective, candidate dispositions, brain-capture result, queued work, and unresolved decisions are durably recorded, invoke `/stow` by loading [`../stow/SKILL.md`](../stow/SKILL.md) and following it exactly.
`stow` alone owns Firstmate-local memory curation, open-work persistence, budget handling, and its second-mate cascade.
Do not reproduce those mechanics here, and do not turn this orchestration into a prose scrape that reconciles backlog or repository reality.
An unresolved `stow` exception remains an incomplete learning cycle and must appear in the pause report.

## 8. Complete and report the pause

Mark the cycle complete only when the safe boundary is reached, terminal evidence exists, the retrospective is durable, every skill candidate has a recorded disposition, Shared Brain draft delivery has reached its authorized boundary, `/stow` has completed or named its exception, and downstream work remains paused.
Preserve any required captain approval as an explicit remaining decision rather than implying completion beyond authority.
Report, in plain captain-facing language:

- the scoped project or thread and the exact pause boundary reached;
- the current tranche's outcome and exact source commit when relevant;
- the retrospective and proposed Shared Brain artifact locations and delivery state;
- skill candidates kept, rejected, or folded, plus the independent evaluation and baseline result;
- the `/stow` outcome and any unresolved exception;
- every downstream tranche still queued and the concrete condition for resuming it;
- any sequencing failure, approval, or other decision still outstanding.

For planning mode, prefix the report with `Plan only:` and state that no records, workers, or artifacts changed.
For a repeated invocation, say which existing cycle and artifacts were reused and which phase resumed.
Do not describe the project as paused until the boundary is actually stable, and do not describe proposed corpus content or a reviewed candidate as approved, promoted, canonical, or merged.
