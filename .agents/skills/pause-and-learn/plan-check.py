#!/usr/bin/env python3
"""Check-only classifier and validator for the /pause-and-learn plan contract.

This helper never writes a file, spawns work, or changes a record. It reads only
its arguments and the response file it is given.

Usage:
  plan-check.py classify <command-text>
      Print how the invoked command form is treated:
      "plan"   the exact read-only planning command, surrounding whitespace allowed
      "refuse" the planning command with trailing arguments: refuse, change nothing
      "cycle"  an ordinary mutating /pause-and-learn invocation
      "none"   not a /pause-and-learn invocation at all

  plan-check.py validate <response-file> <existing-cycle:true|false> <queue-id>
      Exit 0 when the response carries exactly one well-formed
      PAUSE_AND_LEARN_PLAN_V1 block whose fields mean a safe bounded pause.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

COMMAND = "/pause-and-learn"
PLAN_WORD = "plan"
MARKER = "PAUSE_AND_LEARN_PLAN_V1"
BLOCK_RE = re.compile(MARKER + r"\s*\n```(?:json)?\s*\n(.*?)\n```", re.S)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def classify(text: str) -> str:
    tokens = text.split()
    if not tokens or tokens[0] != COMMAND:
        return "none"
    if len(tokens) == 1:
        return "cycle"
    if tokens[1] != PLAN_WORD:
        return "cycle"
    return "plan" if len(tokens) == 2 else "refuse"


def same(actual: object, expected: object) -> bool:
    """Compare by meaning, treating booleans as booleans.

    Python equates False with 0 and True with 1, so a plan could otherwise
    smuggle a negated or stringified safety flag past an equality check.
    """
    if isinstance(expected, bool):
        return actual is expected
    if isinstance(expected, dict):
        return (
            isinstance(actual, dict)
            and set(actual) == set(expected)
            and all(same(actual[key], value) for key, value in expected.items())
        )
    return type(actual) is type(expected) and actual == expected


def nonempty_text(value: object) -> bool:
    return isinstance(value, str) and value.strip() != ""


def validate(response: Path, expected_cycle: bool, queue_id: str) -> None:
    text = response.read_text(encoding="utf-8")
    blocks = BLOCK_RE.findall(text)
    require(len(blocks) == 1, "response does not carry exactly one PAUSE_AND_LEARN_PLAN_V1 block")
    require(text.count(MARKER) == 1, "response repeats the plan marker")
    try:
        plan = json.loads(blocks[0])
    except ValueError as exc:
        raise SystemExit(f"plan block is not valid JSON: {exc}")
    require(isinstance(plan, dict), "plan block is not a JSON object")

    require(plan.get("schema") == "firstmate.pause-and-learn.plan.v1", "wrong schema")
    require(plan.get("mode") == "plan", "wrong mode")

    scope = plan.get("scope")
    require(isinstance(scope, dict) and set(scope) == {"project", "thread"}, "invalid scope fields")
    require(all(nonempty_text(v) for v in scope.values()), "empty scope identity")

    cycle = plan.get("existing_cycle")
    require(isinstance(cycle, dict), "missing existing-cycle state")
    require(same(cycle.get("found"), expected_cycle), "wrong existing-cycle state")
    require(nonempty_text(cycle.get("identity")) is expected_cycle, "wrong existing-cycle identity")
    require(isinstance(cycle.get("resume_phase"), str), "missing resume phase")
    require((cycle.get("resume_phase") != "new") is expected_cycle, "wrong resume phase")

    boundary = plan.get("boundary")
    require(isinstance(boundary, dict), "missing boundary")
    require(boundary.get("kind") == "post-current-stage", "wrong boundary kind")
    require(nonempty_text(boundary.get("name")), "missing boundary name")
    require(same(boundary.get("wait_for_current_stage"), True), "current stage is not awaited")
    require(nonempty_text(boundary.get("current_stage")), "missing current stage")
    require(same(boundary.get("interrupt_current_stage"), False), "current stage may be interrupted")

    require(
        same(plan.get("project_writes"), {"route": "worker", "firstmate_writes_project": False}),
        "wrong project-write routing",
    )
    require(
        same(
            plan.get("components"),
            {
                "retrospective": "planned",
                "brain_capture": "planned",
                "skill_forge": "planned",
                "stow": "planned",
            },
        ),
        "missing learning component",
    )
    require(
        same(plan.get("brain"), {"status": "draft", "brain_status": "proposed", "canonical_write": False}),
        "wrong brain authority",
    )
    require(
        same(
            plan.get("authority"),
            {
                "merge": False,
                "sign": False,
                "approve": False,
                "promote": False,
                "discard": False,
                "destructive": False,
                "security_sensitive": False,
                "semantic_expansion": False,
            },
        ),
        "wrong authority boundary",
    )
    require(
        same(plan.get("sequencing"), {"prior_review_failure_backfilled": False}),
        "historical review gate was backfilled",
    )

    queued = plan.get("queued")
    require(isinstance(queued, list) and len(queued) == 1, "wrong queued-item count")
    item = queued[0]
    require(isinstance(item, dict), "queued item is not an object")
    require(item.get("id") == queue_id, "wrong durable queued-item identity")
    require(nonempty_text(item.get("name")), "missing queued-item display name")
    require(same(item.get("start"), False), "queued item may be started")
    require(item.get("state") == "paused", "queued item is not paused")
    require(
        same(
            item.get("resume"),
            {"captain_focus_required": True, "separate_authorization_required": True},
        ),
        "wrong resume authority",
    )
    require(
        same(plan.get("mutations"), {"records": False, "workers": False, "artifacts": False}),
        "planning mode permits mutation",
    )


def main() -> int:
    argv = sys.argv[1:]
    if len(argv) == 2 and argv[0] == "classify":
        print(classify(argv[1]))
        return 0
    if len(argv) == 4 and argv[0] == "validate":
        require(argv[2] in ("true", "false"), "existing-cycle argument must be true or false")
        validate(Path(argv[1]), argv[2] == "true", argv[3])
        return 0
    raise SystemExit(__doc__)


if __name__ == "__main__":
    raise SystemExit(main())
