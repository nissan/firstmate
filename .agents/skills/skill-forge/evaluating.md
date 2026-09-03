# Evaluating a skill before keeping it

This reference is a captain-authorized import from the captain-owned local skill-forge source on 2026-09-03.
An unevaluated skill is a hypothesis. The failure modes below were all observed
in practice, not imagined.

## Define the bar first

Write down, before any run, what counts as passing. Deciding afterwards turns
any result into a pass. A usable default:

1. The delegate **invoked the skill** rather than improvising past it.
2. The artifact passes whatever validator governs it (exit 0, quoted verbatim).
3. Every hard constraint in the skill held in the output.
4. Nothing needed correcting that the skill was supposed to prevent.
5. The delegate reports no blocking ambiguity.

Criterion 1 is the one most often skipped and most often violated: a skill that
does not fire has failed even when the output is good.

Note the two harnesses treat firing differently. Under `claude plugin eval`,
`tool_used: Skill` graders are a plugin-fired **indicator** rather than part of
the score. Under Harness B, treat firing as a pass/fail criterion - an
improvised result tells you nothing about the skill.

## Harness A - `claude plugin eval` (preferred)

```bash
claude plugin eval --help                      # confirm availability first
claude plugin eval <target> --ablation with-without
claude plugin eval <target> --threshold 0.8    # non-zero exit below the bar
```

Cases live under `evals/` as `case.yaml`, or `prompt.md` plus `graders/*.md`.
`claude plugin eval init --bare <name>` writes a blank template.

The ablation arm is the point: it runs the same cases **without** the skill and
reports the delta. A skill that scores well in both arms is not earning its
place - the model could already do the task.

This command is early access. If it is unavailable it prints so and writes
nothing; do not silently fall through. Tell the user the preferred harness was
unavailable, then use Harness B.

## Harness B - fresh-context delegate (fallback)

Spawn an agent with **no** context from the authoring session.

### Getting a genuine no-skill arm

**Moving the skill directory aside does not work.** A running session snapshots
its skill registry at startup, and subagents inherit that snapshot. A delegate
spawned from your session still has the skill text even after the directory is
gone, and will use it - producing a "baseline" that silently measures the
with-skill arm.

A fresh `claude -p ...` session rescans skills on startup, so it can provide real isolation when pointed at an isolated repository discovery location.
Verify it rather than assuming: have the baseline list the skills available to it and confirm the one under test is absent before trusting any number it produces.

If isolation cannot be confirmed, the ablation is **not measured**. Say so.
An unmeasured ablation reported as a baseline is worse than no ablation.

### Never mutate state under a running delegate

Only a completion notification means a delegate has finished. Transcript
idleness does not - an agent between tool calls looks identical to one that has
stopped. Resetting a fixture, restoring a moved file, or reusing a log while a
delegate is still running interleaves two arms into one record and voids both.

### Keep harness internals out of the delegate's reach

Pass bars, scoring rubrics, and grader notes must not sit in any directory the
delegate is pointed at. A delegate that can read the rubric is being tested on
reading comprehension.

**Give it material unrelated to recent work.**
A delegate handed the same subject the author just worked on can pattern-match its way to a correct result without the skill carrying it.
Unrelated material is what makes the run informative.

**Give it the task, not the procedure.** Phrase the prompt as a user request
("add these learnings to the brain"), never as steps. The skill must supply the
steps; if you supply them, you have tested nothing.

**Ask for a defect report.** Require it to state what was ambiguous, missing,
wrong, or guessed at. This is the feedback an author cannot generate about their
own instructions, and it is usually where the real defect appears.

**Verify the artifacts yourself.** Run the validators, read the frontmatter,
check the constraints. A delegate's self-report is a claim, not a result.

## Hygiene

- **Never write fabricated material into a durable store as if it were
  experience.** Test output that describes work nobody did corrupts a corpus
  more quietly than a bug.
- **Snapshot exact prior state before the run** (`git status --porcelain`, file
  copies) and diff against it when reverting.
- **Deliver before cleaning up.** A test run on someone's behalf is not finished
  until they have seen its output. Reverting first destroys the deliverable.

## Interpreting failure

- The delegate ignored the skill → fix `description` triggers, not the body.
- The delegate produced a wrong field copied from a template → fix the
  **example**; the prose was probably already correct.
- The delegate asked for something the skill assumed → make the assumption
  explicit; it will not be obvious to the next context either.
- The delegate succeeded but the ablation arm also succeeded → the skill is
  redundant. Discard it.
