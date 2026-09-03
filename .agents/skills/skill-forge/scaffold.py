#!/usr/bin/env python3
"""Scaffold a skill in an explicitly selected owning repository.

Usage: python3 scaffold.py <skill-name> <destination-skill-root> [--force]

Creates <destination-skill-root>/<name>/SKILL.md and an evals directory.
The caller must select an isolated repository destination governed by its
normal delivery path; this helper has no home-directory default.

Provenance: captain-authorized adaptation of the captain-owned local
skill-forge helper on 2026-09-03.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

TEMPLATE = """---
name: {name}
description: >
  ONE SENTENCE saying what this does and when to use it, then the trigger
  phrases a user would actually type. A skill whose description does not match
  how people phrase the request will never fire.
---

# {title}

One line on what this produces.

## When NOT to use this

List the neighbouring cases that belong to another skill or to no skill.
This prevents the skill firing on work it will handle badly.

## Procedure

1. First step.
2. Second step.

## Hard constraints

State anything that silently corrupts state or fails late.
Mark any value in an example that must be re-derived rather than copied.

## Report

State what to report when finished, including verbatim validator output.
"""


def main() -> int:
    args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    force = "--force" in sys.argv
    if len(args) != 2:
        raise SystemExit(__doc__)

    name = args[0].strip().lower()
    if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
        raise SystemExit(f"invalid skill name {name!r}: use lowercase-with-hyphens")

    destination = Path(args[1]).expanduser()
    if not destination.is_absolute():
        destination = (Path.cwd() / destination).resolve()
    else:
        destination = destination.resolve()
    if not destination.is_dir():
        raise SystemExit(f"destination skill root is not a directory: {destination}")

    root = destination / name
    skill = root / "SKILL.md"
    if skill.exists() and not force:
        raise SystemExit(f"{skill} already exists (use --force to overwrite)")

    root.mkdir(parents=True, exist_ok=True)
    title = name.replace("-", " ").title()
    skill.write_text(TEMPLATE.format(name=name, title=title), encoding="utf-8")
    (root / "evals").mkdir(exist_ok=True)

    print(f"created {skill}")
    print("next: define the predeclared bar, evaluate exact candidate bytes from an isolated discovery location, and deliver through the owning repository")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
