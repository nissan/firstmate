---
name: brain-capture
description: >
  Capture the durable lessons from this session into the registered Shared Brain project as an indexed, validated OKF v0.2 corpus entry.
  Use at the end of a work session when the captain says "add this to the brain", "capture the lessons", "update the shared brain", "record this session", "OKF lesson", "corpus entry", or "retrospective for the brain".
  Handles both creating a new lesson and updating an existing one.
user-invocable: true
metadata:
  internal: true
---

<!-- Provenance: captain-authorized import from the captain-owned local brain-capture source on 2026-09-03. -->

# Shared Brain capture

Turn a work session into a durable corpus entry: a retrospective holding the
evidence, plus an OKF concept page holding the reusable lessons, indexed and
passing the repository's own validators.

## Locate the brain first

Firstmate resolves the registered Shared Brain project under `AGENTS.md` section 7 before dispatching any project write.
Use the isolated project root supplied in the worker's instructions and confirm that its `brain.toml` names the canonical root, timezone, and OKF version.
If no Shared Brain project is registered or the supplied root is ambiguous, return the blocker to firstmate rather than guessing a default path.

## Read the conventions before writing anything

Never invent the format. Read, in this order:

1. An existing page in `knowledge/lessons/` - this is the template.
2. `policies/privacy.md` and `policies/memory-policy.md` - these bind you.
3. `src/shared_brain/validation.py` - the rules that will reject your file.

`reference.md` next to this skill summarizes the frontmatter contract and the
validator's checks. Read it, but the repository is authoritative if they differ.

## New page or update?

List `knowledge/lessons/` and read any page whose subject overlaps. Prefer
**updating** an existing page over creating a near-duplicate. When updating,
add lessons and bump `updated_at`; do not rewrite history that still holds.

## What belongs in a lesson

The lesson page carries **method, not narrative**. Subject-matter specifics,
chronology, and raw evidence live in the retrospective.

- Write lessons that transfer to unrelated tasks. "Include a positive control in
  any experiment whose expected result is absence" transfers; "the VPN kill
  switch broke the mesh" does not - that is evidence, and belongs in the
  retrospective.
- Include the agent's **own** errors. They are usually the highest-signal
  content in a session, and the corpus exists to stop them recurring.
- Record negative results with the evidence that established them.
- Every lesson must be actionable as an instruction, not an observation.

## Procedure

1. **Retrospective** → `docs/retrospectives/<slug>.md`. Plain Markdown, no
   frontmatter. Follow the structure of the existing retrospectives: Purpose,
   Outcome, What went wrong (one `###` per distinct failure, each ending in a
   `Lesson:` line), Practices adopted (numbered), Evidence notes, and
   retrospective questions for future sessions.

2. **Lesson page** → `knowledge/lessons/<slug>.md`. Copy the frontmatter shape
   from an existing lesson. See `reference.md` for every required field.

3. **Bind hashes and timestamps** - do not hand-compute:

   ```bash
   python3 <this-skill-directory>/stamp.py "$BRAIN/knowledge/lessons/<slug>.md"
   ```

   Resolve `<this-skill-directory>` as the directory containing this loaded `SKILL.md`; never copy a path from an example or another workstation.

   Re-run this after **any** edit to a referenced retrospective. A one-byte
   change breaks the hash and fails validation.

4. **Index** - add one line to `knowledge/index.md` for a new page. The root
   index's frontmatter may contain `okf_version` and nothing else.

5. **Validate** - both must pass before you report success:

   ```bash
   cd $BRAIN
   .venv/bin/python scripts/validate.py
   .venv/bin/python scripts/evaluate.py
   ```

   `pytest` may not be installed in the venv; these two scripts are the gates.

6. **Deliver through the registered project path.** Check `git log` first because a prior capture may already exist, then stage the retrospective, lesson, and index changes.
   Commit, validate, push, and open a PR only as authorized by the worker's Firstmate instructions and the Shared Brain project's registered delivery path.
   Never merge, promote, sign, verify, or make the proposed entry canonical under this skill.

## Hard constraints

**Status.** Agent-authored pages are `status: "draft"`, `brain_status: "proposed"`, and `generated.by: "agent:<current-worker>"`, re-derived for the worker that authors the page.
An agent cannot mark its own work verified.
Promoting to `active` or `stable`, or adding a `verified` entry, requires the human approval path in `policies/memory-policy.md`.

**Redaction.** The repository is scanned for secrets on every validation, and
the privacy policy forbids more than the scanner catches. Never write:
credentials, auth or login URLs, tokens, private keys, email addresses, public
IP addresses, or account identifiers. Generalize evidence instead - routing
priority bands, error text, and version numbers survive redaction and stay
useful.

**Citations.** A page with `sources` **must** cite at least one in its body as
`[^source-id]`, and every `[^id]` must match a declared source `id`. Validation
fails on either violation.

**Relationships.** Every `relationships[].target_id` must resolve to an `id`
that exists under `knowledge/`. Link to a real page or omit the field.

A relationship is a factual claim, not decoration. Copying one from the template
page because it is there will assert something false - `learned_during
project:<x>` means the work happened *as part of* that project, which is untrue
for a session that merely used the repository to store its lessons. Assert only
what holds; `reinforces` between two lessons that teach the same method is
usually the honest link, and omitting `relationships` entirely is always
allowed.

## Report

Tell the captain what was created or updated, the validator and gate results verbatim, what was deliberately redacted, that the entry is `proposed` pending approval, and the exact delivery boundary reached.
