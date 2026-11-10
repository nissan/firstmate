---
name: builder-discretion
description: Load before stopping to ask whether a routine build step needs approval - reviewing your own work, running extra checks, closing an issue already met on the default branch, picking a Ready issue, fixing your own pull request's CI or conflicts, regenerating generated files, or choosing a subagent's model and effort.
user-invocable: false
metadata:
  internal: true
---

# builder-discretion

Use this list to decide whether a routine build step needs the captain's word.
In this repository "the owner" is the captain.
`AGENTS.md` hard rules, its merge authority, and the fail-closed rule in its shared agent settings win over anything here; this list grants no authority they withhold.

The block below is managed by Reddi Workbench's `scripts/adopt.py`, which refreshes it in this file.
Change its wording in Workbench's `planning/adoption-rules.json`, not here, and keep both marker comments.

<!-- workbench:discretion:begin (managed by scripts/adopt.py; edit planning/adoption-rules.json) -->
## What the builder decides without asking (Workbench adoption)

- Reviewing its own work as a build step: whole diff re-read, checks and negative cases run, each claim checked against a result.
- Which additional checks to run beyond the required ones, and in what order.
- Closing an issue whose acceptance is already met on the default branch, with the commit, command and output as evidence.
- Picking the smallest issue marked Ready when none is assigned.
- Fixing CI failures and merge conflicts on its own pull request.
- Regenerating generated files, mirrors and manifests with the repository's own tooling.
- Choosing the model and effort for its own subagents within the approved providers.

Still needs the owner:

- Merging, unless this repository gives standing merge authority.
- Deploying, spending, changing settings, handling credentials, sending anything outside the repository, and any destructive or irreversible action.
- Anything behind a denied, failed or timed-out control: that is a stop.
<!-- workbench:discretion:end -->
