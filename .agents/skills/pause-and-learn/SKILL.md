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

## Modes

A request containing `plan`, `dry-run`, or `preview` is read-only.
In that mode, perform the scope and evidence inventory, choose the proposed safe boundary, identify existing cycle artifacts and queued work, and report the plan without spawning work, changing records, invoking component skills, or writing artifacts.
All safety and authority checks still apply.

## 1. Resolve one scope and reuse any cycle already under way

1. Resolve the explicit project and thread independently from the current request.
   A clear follow-up may inherit one confident current referent.
   If multiple projects or threads plausibly match, ask one concise question and do nothing else.
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

Determine the retrospective owner from the scoped project's conventions.
When the Shared Brain capture owns the retrospective, load `brain-capture` and follow its retrospective procedure rather than restating its format here.
When the project has a stronger established retrospective owner, use that owner and give the later brain capture its exact path and source hash.
Every project write is performed by a worker in an isolated copy through that project's registered validation and delivery path.
Firstmate may coordinate, inspect, and report, but does not write the project directly.
Reuse an overlapping retrospective and amend it only with evidence that belongs to this cycle.

## 5. Mine and evaluate reusable skill candidates

1. Load `skill-forge` and follow its candidate qualification, candidate list, rejection accounting, authoring, fresh-context evaluation, ablation, stopping rule, and reporting procedure.
   Do not restate or weaken those contracts here.
2. Record every candidate and every rejection or fold, including overlap with an existing owner, knowledge-only shape, redundancy, and failure against the predeclared bar.
   Fold an overlapping procedure into its existing owner only when this invocation already has authority to change that owner; otherwise retain the recommendation without writing it.
3. Before authoring, predeclare a scenario-specific evaluation bar derived from the accepted outcome and safety boundaries.
   Require a fresh context that did not author the candidate and normal independent review of any retained artifact.
4. Keep no candidate that fails fresh-context evaluation, misses its predeclared bar, or whose verified no-skill baseline is materially equivalent.
   If a valid baseline cannot be isolated, record it as unmeasured exactly as `skill-forge` requires rather than claiming a delta.
5. Route candidate writes to a worker in the repository that owns the skill and use that repository's normal validation and delivery path.
   Evaluation permission does not grant merge, promotion, canonical installation, or approval authority.

## 6. Capture proposed Shared Brain content

1. Resolve the registered Shared Brain project through the project registry.
   If none is registered or more than one plausibly matches, ask one concise question rather than guessing a path.
2. Reuse an overlapping lesson or open capture whose identity and sources match.
   Do not create parallel corpus pages or retrospectives for the same learning cycle.
3. Dispatch the project change to a worker and require that worker to load `brain-capture` and follow the Shared Brain repository's own current policies, validators, and delivery path.
4. Supply the completed retrospective, exact source commits and hashes, candidate and rejection ledger, evaluation results, review evidence, failures, corrections, and privacy constraints as inputs.
5. Keep agent-authored corpus content private and marked `draft` and `proposed`.
   Preserve exact source hashes, privacy redaction, index and retrieval bindings, unsigned review evidence, repository gates, and normal independent review.
6. Do not sign, verify, promote, merge, or make the content canonical under this skill.
   If the registered delivery path opens a PR or leaves a local branch awaiting approval, preserve that boundary.

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
