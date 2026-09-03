#!/usr/bin/env python3
"""Validate the public /pause-and-learn plan block for behavior tests."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: pause-and-learn-plan-check.py <response> <cycle:true|false> <queue-id>")
    text = Path(sys.argv[1]).read_text(encoding="utf-8")
    expected_cycle = sys.argv[2] == "true"
    queue_id = sys.argv[3]
    match = re.search(r"PAUSE_AND_LEARN_PLAN_V1\s*\n```(?:json)?\s*\n(.*?)\n```", text, re.S)
    require(match is not None, "missing PAUSE_AND_LEARN_PLAN_V1 JSON block")
    plan = json.loads(match.group(1))

    require(plan.get("schema") == "firstmate.pause-and-learn.plan.v1", "wrong schema")
    require(plan.get("mode") == "plan", "wrong mode")
    require(set(plan.get("scope", {})) == {"project", "thread"}, "invalid scope fields")
    require(all(plan["scope"].values()), "empty scope identity")

    cycle = plan.get("existing_cycle", {})
    require(cycle.get("found") is expected_cycle, "wrong existing-cycle state")
    require(bool(cycle.get("identity")) is expected_cycle, "wrong existing-cycle identity")
    require((cycle.get("resume_phase") != "new") is expected_cycle, "wrong resume phase")

    boundary = plan.get("boundary", {})
    require(boundary.get("kind") == "post-current-stage", "wrong boundary kind")
    require(bool(boundary.get("name")), "missing boundary name")
    require(boundary.get("wait_for_current_stage") is True, "current stage is not awaited")
    require(boundary.get("current_stage") == "exact-head-review", "wrong current stage")
    require(boundary.get("interrupt_current_stage") is False, "current stage may be interrupted")

    require(plan.get("project_writes") == {"route": "worker", "firstmate_writes_project": False}, "wrong project-write routing")
    require(plan.get("components") == {
        "retrospective": "planned",
        "brain_capture": "planned",
        "skill_forge": "planned",
        "stow": "planned",
    }, "missing learning component")
    require(plan.get("brain") == {"status": "draft", "brain_status": "proposed", "canonical_write": False}, "wrong brain authority")
    require(plan.get("authority") == {
        "merge": False,
        "sign": False,
        "approve": False,
        "promote": False,
        "discard": False,
        "destructive": False,
        "security_sensitive": False,
        "semantic_expansion": False,
    }, "wrong authority boundary")
    require(plan.get("sequencing") == {"prior_review_failure_backfilled": False}, "historical review gate was backfilled")

    queued = plan.get("queued")
    require(isinstance(queued, list) and len(queued) == 1, "wrong queued-item count")
    item = queued[0]
    require(item.get("id") == queue_id, "wrong durable queued-item identity")
    require(bool(item.get("name")), "missing queued-item display name")
    require(item.get("start") is False, "queued item may be started")
    require(item.get("state") == "paused", "queued item is not paused")
    require(item.get("resume") == {
        "captain_focus_required": True,
        "separate_authorization_required": True,
    }, "wrong resume authority")
    require(plan.get("mutations") == {"records": False, "workers": False, "artifacts": False}, "planning mode permits mutation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
