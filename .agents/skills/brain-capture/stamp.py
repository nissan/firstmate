#!/usr/bin/env python3
"""Rebind a Shared Brain lesson page to its sources.

Captain-authorized import from the captain-owned local brain-capture helper,
adapted for Firstmate on 2026-09-03. The Firstmate copy binds every hash within
its own JSON source object and refuses malformed frontmatter, where the imported
original paired "resource" and "content_hash" by line order across the whole
frontmatter.

Recomputes the sha256 content_hash of every local source, binding the documented
"sha256:<64 hex>" placeholder from the referenced bytes, and sets updated_at to
now in the brain's configured timezone. --check refuses an unbound placeholder
rather than reporting it current. Formatting and field order are preserved
by rewriting hash values in place rather than re-serializing the frontmatter.

Usage:  python3 stamp.py <path-to-lesson.md> [--check]
        --check  report drift and exit non-zero; write nothing
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
import tomllib
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

HASH_RE = re.compile(r'"content_hash"\s*:\s*"([^"]*)"')
UPDATED_RE = re.compile(r'"updated_at"\s*:\s*"([^"]*)"')
SHA256_RE = re.compile(r"^sha256:[a-f0-9]{64}$")
PLACEHOLDER = "sha256:<64 hex>"


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


def unique_keys(pairs: list[tuple[str, object]]) -> dict:
    out: dict = {}
    for key, value in pairs:
        if key in out:
            raise ValueError(f"duplicate key {key!r}")
        out[key] = value
    return out


def parse_frontmatter(front: str, page: Path) -> dict:
    try:
        data = json.loads(front, object_pairs_hook=unique_keys)
    except ValueError as exc:
        raise SystemExit(f"{page.name}: unreadable frontmatter: {exc}")
    if not isinstance(data, dict):
        raise SystemExit(f"{page.name}: frontmatter is not a JSON object")
    return data


def declared_sources(data: dict, page: Path) -> list[tuple[str, str]]:
    sources = data.get("sources", [])
    if not isinstance(sources, list):
        raise SystemExit(f"{page.name}: sources must be an array")
    bound = []
    for index, entry in enumerate(sources):
        if not isinstance(entry, dict):
            raise SystemExit(f"{page.name}: sources[{index}] is not an object")
        resource = entry.get("resource")
        digest = entry.get("content_hash")
        if not isinstance(resource, str) or not resource:
            raise SystemExit(f"{page.name}: sources[{index}] has no resource for its content_hash")
        if not isinstance(digest, str) or not (SHA256_RE.match(digest) or digest == PLACEHOLDER):
            raise SystemExit(f"{page.name}: sources[{index}] has no well-formed content_hash")
        bound.append((resource, digest))
    return bound


def hash_spans(front: str, sources: list[tuple[str, str]], page: Path) -> list[re.Match]:
    spans = list(HASH_RE.finditer(front))
    if len(spans) != len(sources):
        raise SystemExit(
            f"{page.name}: {len(spans)} content_hash fields for {len(sources)} sources"
        )
    for span, (_, digest) in zip(spans, sources):
        if span.group(1) != digest:
            raise SystemExit(f"{page.name}: content_hash fields do not follow their source objects")
    return spans


def main() -> int:
    argv = sys.argv[1:]
    flags = [a for a in argv if a.startswith("--")]
    unknown = [flag for flag in flags if flag != "--check"]
    if unknown:
        raise SystemExit(f"unknown option: {unknown[0]}\n{__doc__}")
    args = [a for a in argv if not a.startswith("--")]
    check = "--check" in flags
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
    data = parse_frontmatter(front, page)
    sources = declared_sources(data, page)
    spans = hash_spans(front, sources, page)

    edits, changed = [], []
    for span, (resource, digest) in zip(spans, sources):
        unbound = digest == PLACEHOLDER
        if ":" in resource or resource.startswith("/"):
            if unbound:
                raise SystemExit(f"{page.name}: cannot bind a placeholder hash for {resource}")
            continue
        if unbound and check:
            raise SystemExit(f"{page.name}: unbound placeholder hash: {resource}")
        target = (page.parent / resource).resolve()
        if not target.is_file():
            raise SystemExit(f"{page.name}: source missing: {resource}")
        actual = "sha256:" + hashlib.sha256(target.read_bytes()).hexdigest()
        if actual != digest:
            changed.append(resource)
            edits.append((span.start(1), span.end(1), actual))

    if check:
        if changed:
            print("STALE hashes: " + ", ".join(changed))
            return 1
        print("OK all source hashes current")
        return 0

    if "updated_at" in data:
        stamps = list(UPDATED_RE.finditer(front))
        if len(stamps) != 1:
            raise SystemExit(f"{page.name}: expected exactly one updated_at field")
        edits.append((stamps[0].start(1), stamps[0].end(1), now))

    out, cursor = [], 0
    for start, end, value in sorted(edits):
        out.append(front[cursor:start])
        out.append(value)
        cursor = end
    out.append(front[cursor:])

    page.write_text("---\n" + "".join(out) + "\n---\n" + body, encoding="utf-8")
    print(f"rehashed: {', '.join(changed) if changed else '(no hash drift)'}")
    print(f"updated_at: {now}")
    print("now run: .venv/bin/python scripts/validate.py && .venv/bin/python scripts/evaluate.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
