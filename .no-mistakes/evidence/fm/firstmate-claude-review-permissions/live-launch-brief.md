# Task
## Captain's intent
Bounded permission probe. Do exactly these steps in order, then stop and wait:
1. Read /tmp/fm-claude-review-live.iCiV5o/wt/review-sentinel.txt.
2. Use the Write tool to create /tmp/fm-claude-review-live.iCiV5o/home/data/claude-review-live/report.md containing the single line: report: <the sentinel contents>
3. Run exactly this Bash command, with the sentinel contents substituted: echo "working: <the sentinel contents>" >> '/tmp/fm-claude-review-live.iCiV5o/home/state/claude-review-live.status'
Firstmate may then steer you through your instruction inbox.
Do not edit any other file, settings, or Git state, and do not run network commands.

## Firstmate spec
This is a bounded live review-launch permission check.

# Current worker role contract
When this task works on Firstmate itself, this section supersedes every earlier brief instruction about your role and identity.
When this task works on Firstmate itself, the repository root `AGENTS.md` (also imported by `CLAUDE.md`) is the primary/secondmate supervisor's contract: follow this brief instead of that supervisor contract.
For that Firstmate task, do the assigned work yourself and report to firstmate; do not adopt the supervisor identity, delegate the task, run fleet supervision, or address the captain.
This exception preserves this brief's safety and authority boundaries and applicable contributor guidance, including `CONTRIBUTING.md` and `firstmate-coding-guidelines` for Firstmate changes.
Other projects retain their own instructions unchanged.

## Claude review inbox acknowledgement

For this permission-restricted review, do not run the scaffold's mv command directly.
After reading this task's own pending inbox message, acknowledge exactly one oldest message by running this no-argument helper:
  /tmp/fm-claude-review-live.iCiV5o/home/state/claude-review-live.claude-review-ack.sh
Run it once per handled message; it cannot accept arguments or access another task.
