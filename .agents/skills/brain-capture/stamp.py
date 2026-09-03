#!/usr/bin/env python3
"""Rebind a Shared Brain lesson page to its sources.

Captain-authorized import from the captain-owned local brain-capture helper,
adapted for Firstmate on 2026-09-03.

Recomputes the sha256 content_hash of every local source and sets updated_at to
now in the brain's configured timezone. Formatting and field order are preserved
by editing lines in place rather than re-serializing the frontmatter.

Usage:  python3 stamp.py <path-to-lesson.md> [--check]
        --check  report drift and exit non-zero; write nothing
"""
from __future__ import annotations

import hashlib
import re
import sys
import tomllib
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


def find_brain_root(start: Path) -> Path:
    for parent in [start, *start.parents]:
        if (parent / "brain.toml").is_file():
            return parent
    raise SystemExit(f"no brain.toml found above {start}")


def split_frontmatter(text: str, path: Path) -> tuple[str, str]:
    if not text.startswith("---\n"):
        raise SystemExit(f"{path}: missing frontmatter")
    end = text.find("\n---\n", 4)
    if end < 0:
        raise SystemExit(f"{path}: unterminated frontmatter")
    return text[4:end], text[end + 5:]


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = "--check" in sys.argv
    if len(args) != 1:
        raise SystemExit(__doc__)

    page = Path(args[0]).resolve()
    if not page.is_file():
        raise SystemExit(f"not a file: {page}")

    root = find_brain_root(page.parent)
    cfg = tomllib.loads((root / "brain.toml").read_text(encoding="utf-8"))
    tz = ZoneInfo(cfg.get("timezone", "UTC"))
    now = datetime.now(tz).strftime("%Y-%m-%dT%H:%M:%S%z")
    now = now[:-2] + ":" + now[-2:]

    text = page.read_text(encoding="utf-8")
    front, body = split_frontmatter(text, page)

    out, resource, changed = [], None, []
    for line in front.split("\n"):
        m = re.search(r'"resource":\s*"([^"]+)"', line)
        if m:
            resource = m.group(1)

        m = re.search(r'"content_hash":\s*"(sha256:[a-f0-9]{64})"', line)
        if m and resource:
            if ":" in resource or resource.startswith("/"):
                resource = None
                out.append(line)
                continue
            target = (page.parent / resource).resolve()
            if not target.is_file():
                raise SystemExit(f"{page.name}: source missing: {resource}")
            actual = "sha256:" + hashlib.sha256(target.read_bytes()).hexdigest()
            if actual != m.group(1):
                changed.append(resource)
                line = line.replace(m.group(1), actual)
            resource = None

        m = re.search(r'"updated_at":\s*"([^"]+)"', line)
        if m and not check:
            line = line.replace(m.group(1), now)

        out.append(line)

    if check:
        if changed:
            print("STALE hashes: " + ", ".join(changed))
            return 1
        print("OK all source hashes current")
        return 0

    page.write_text("---\n" + "\n".join(out) + "\n---\n" + body.lstrip("\n"), encoding="utf-8")
    print(f"rehashed: {', '.join(changed) if changed else '(no hash drift)'}")
    print(f"updated_at: {now}")
    print("now run: .venv/bin/python scripts/validate.py && .venv/bin/python scripts/evaluate.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
