---
name: skill-forge
description: >
  Mine the current session for procedures worth encoding as reusable skills, author them in their owning repository, evaluate them against a defined bar, and keep only what passes.
  Use when the captain says "make this a skill", "what should we turn into a skill", "encode this", "find skills in this session", "write a skill and test it", or "make this reusable for Codex too".
  Also use before hand-writing a SKILL.md, so the candidate is filtered and evaluated rather than assumed.
user-invocable: true
metadata:
  internal: true
---

<!-- Provenance: captain-authorized import from the captain-owned local skill-forge source on 2026-09-03. -->

# Skill forge

Turn session experience into reusable, *evaluated* skills. A skill that has not
been run by a context that did not write it is a draft, not a skill.

## Is it a skill, or is it knowledge?

Decide this first; the two have different homes and mixing them produces skills
nobody invokes and lessons nobody can act on.

| | Skill | Knowledge |
|---|---|---|
| Shape | A procedure with steps and constraints | A claim about how something behaves |
| Test | "Could an agent *execute* this?" | "Would an agent *decide differently* knowing this?" |
| Home | The owning repository's skill surface | The corpus, via `brain-capture` |

"Run the validator before staging" is a skill. "The validator rejects any
non-entity Markdown under `knowledge/`" is knowledge. A skill may *cite*
knowledge, but do not encode a fact as a procedure.

## 1. Mine the session

Walk the session and collect candidates. A candidate qualifies if **any** holds:

- The same multi-step procedure was performed more than once.
- Getting it right required a correction, retry, or discovered constraint.
- It depends on a fact not discoverable from the code or `--help` output.
- The captain asked for the same outcome repeatedly in different words.

Reject a candidate when:

- It is a single command with no judgment (`git status` needs no skill).
- An existing skill already covers it - inventory the owning repository and currently discoverable skills, then read the overlapping owner before writing anything.
  Extend it instead.
- It is knowledge, not procedure (see above).
- It encodes a preference that may change, rather than a constraint that holds.

Report the candidate list with its rejects and reasons **before** authoring, so the captain can veto.
Do not author every candidate silently.

When there is no interactive turn - a single-shot task, or a delegated run
expected to hand back a finished skill - do not stall waiting for a veto that
cannot arrive. Author the strongest candidate, and put the full candidate list
with rejections at the top of your report so the decision is still reviewable
after the fact.

## 2. Author

Scaffold, then fill:

```bash
python3 <this-skill-directory>/scaffold.py <skill-name> <owning-repository-skill-root>
```

Resolve `<this-skill-directory>` as the directory containing this loaded `SKILL.md`.
Resolve the destination from the owning repository and its instructions rather than using a home-directory default.
Firstmate routes every repository write to a worker in an isolated copy through that repository's registered delivery path.

Requirements for the SKILL.md:

- `description` must contain the **trigger phrases** a user would actually type.
  A skill that never fires is worthless regardless of its body.
- State hard constraints explicitly, especially ones that silently corrupt
  state or fail late.
- Delegate error-prone mechanical steps to a helper script rather than to prose.
- Keep the body procedural; push contracts and tables into a sibling reference
  file the skill points at.

**Examples are instructions.** Anything shown in a template will be copied more
faithfully than the surrounding prose, including its mistakes. Mark fields that
must be re-derived rather than carried across, and never leave a value in an
example that is true only of the example.

## 3. Expose exact candidate bytes without installing fleet-visible bytes

Author the candidate in its owning repository, then expose those exact bytes to the evaluator from an isolated repository discovery location.
The evaluator must discover the candidate as that host normally discovers a skill, but the candidate must not be installed or updated on a fleet-visible path before reviewed delivery lands.
Bind evaluation evidence to the candidate's exact commit.
For cross-host behavior see `portability.md`.

## 4. Evaluate - and stop when you have an answer

Define the pass bar **before** running; see `evaluating.md` for the protocol,
the two harnesses, and the ablation mechanism that actually works.

**Stopping rule.** One fresh-context run that surfaces defects is sufficient
evidence to act on. If a valid ablation is not reachable - the preferred harness
is gated, or the baseline will not isolate - record that it was not measured and
decide on the delegate's evidence. Do not build evaluation infrastructure until
an ablation becomes possible; the harness exists to judge the artifact, and past
one working run its marginal value falls below its cost.

Keep, revise, or discard on the evidence you have, and state which of those
happened and on what basis.

## 5. Record

Capture what authoring and evaluating taught you with the `brain-capture` skill through its registered project and delivery path.
Evaluation failures are the highest-signal part because a skill that needed three revisions says something durable about writing skills.

## Report

Give the captain the candidates found and which were rejected and why, what was authored, the evaluation method and its verbatim result, what failed and what changed, and the owning repository and exact candidate commit.
State plainly when the preferred evaluation method or valid baseline was unavailable.
