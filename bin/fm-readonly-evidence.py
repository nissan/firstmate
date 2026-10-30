#!/usr/bin/env python3
"""Summarize parent-captured Claude 2.1.312 stream evidence without model claims.

Usage: fm-readonly-evidence.py --stream FILE
       fm-readonly-evidence.py --stream FILE --guard-state FILE --report FILE

With --report, the trusted parent may atomically publish one private probe
receipt only after exact read-only inventory checks and the existing strict
exact-head/settings postguard. No inbox is acknowledged and no scout completion
or review verdict is produced. Report paths must be new and outside the subject.

This reads a complete, trusted-parent-owned native stream, never launches a
model or acknowledges an inbox. Output contains only fixed labels,
validated native tool names, and counts, never prompts, arguments, credentials
or assistant prose. Tool removal is distinct from an actual invocation and
from a native permission_denials receipt. Missing receipt fields, partial or
failed streams refuse rather than assuming zero denials or successful review.
This is NOT reviewer GO, authentication proof, postguard verification, or an
attestation that a caller-provided stream is genuine. The parent owns provenance.
Positive-denial fixtures test parsing only; they are not native permission proof.
"""
from __future__ import annotations

import argparse
import collections
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys

MAX_BYTES = 16 * 1024 * 1024
REQUIRED_ABSENT = ("Bash", "Edit", "Write")
KNOWN_TOOL_NAMES = frozenset({"Read", "Glob", "Grep", "Write", "Edit", "Bash", "PowerShell",
                              "WebFetch", "WebSearch", "Agent", "Task", "Skill", "EndConversation"})


def tool_name(value: object) -> str:
    if (not isinstance(value, str) or value not in KNOWN_TOOL_NAMES
            or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,127}", value)):
        raise ValueError("invalid native tool name")
    return value


def summarize(path: str) -> dict:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_BYTES:
            raise ValueError("native stream must be a bounded regular file")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read(MAX_BYTES + 1)
        after = os.fstat(fd)
        if (len(data) > MAX_BYTES or before.st_ino != after.st_ino
                or before.st_size != after.st_size or before.st_mtime_ns != after.st_mtime_ns
                or before.st_ctime_ns != after.st_ctime_ns):
            raise ValueError("native stream changed while reading")
    finally:
        os.close(fd)
    def unique(pairs: list) -> dict:
        result = {}
        for name, value in pairs:
            if name in result:
                raise ValueError("duplicate native JSON key")
            result[name] = value
        return result

    try:
        events = [json.loads(line, object_pairs_hook=unique) for line in data.splitlines() if line.strip()]
    except (ValueError, UnicodeError):
        raise ValueError("invalid native JSON stream") from None
    if not events or any(not isinstance(event, dict) for event in events):
        raise ValueError("invalid native event shape")
    init = [event for event in events if event.get("type") == "system" and event.get("subtype") == "init"]
    final = [event for event in events if event.get("type") == "result"]
    if len(init) != 1 or len(final) != 1 or events[0] is not init[0] or events[-1] is not final[0]:
        raise ValueError("native stream must have one initialization and a final complete result")
    start, result = init[0], final[0]
    if start.get("claude_code_version") != "2.1.312":
        raise ValueError("unsupported Claude evidence version; verify the installed native contract")
    if (result.get("is_error") is not False or result.get("subtype") != "success"
            or result.get("terminal_reason") != "completed"):
        raise ValueError("native process did not report successful completion")
    session = start.get("session_id")
    if (not isinstance(session, str) or not session or result.get("session_id") != session
            or any(event.get("session_id", session) != session for event in events)):
        raise ValueError("native stream session identity mismatch")
    if not isinstance(start.get("tools"), list) or not isinstance(start.get("mcp_servers"), list):
        raise ValueError("missing native tool/server inventory")
    tools = [tool_name(name) for name in start["tools"]]
    if len(tools) != len(set(tools)):
        raise ValueError("duplicate native tool inventory")
    if not isinstance(result.get("permission_denials"), list):
        raise ValueError("missing native permission denial receipt; absence is not zero")
    denials = []
    for denial in result["permission_denials"]:
        if not isinstance(denial, dict):
            raise ValueError("invalid native denial receipt")
        denials.append(tool_name(denial.get("tool_name")))
    calls = {}
    for event in events:
        if event.get("type") != "assistant":
            continue
        message = event.get("message")
        if not isinstance(message, dict) or not isinstance(message.get("content"), list):
            raise ValueError("invalid native assistant event shape")
        for block in message["content"]:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            name, call_id = tool_name(block.get("name")), block.get("id")
            if not isinstance(call_id, str) or not call_id:
                raise ValueError("missing native tool invocation identity")
            if call_id in calls and calls[call_id] != name:
                raise ValueError("conflicting native tool invocation identity")
            calls[call_id] = name
    return {"schema": "firstmate-readonly-evidence.v1", "native_version": "2.1.312",
            "available_tools": sorted(tools), "mcp_server_count": len(start["mcp_servers"]),
            "unavailable_tools": [name for name in REQUIRED_ABSENT if name not in tools],
            "actual_invocations": dict(sorted(collections.Counter(calls.values()).items())),
            "native_permission_denials_reported": dict(sorted(collections.Counter(denials).items())),
            "denial_event_count": len(denials), "assistant_prose_used_as_evidence": False,
            "native_completion_observed": True, "reviewer_go": False,
            "admission": "NOT-evaluated-requires-independent-identity-settings-postguards"}


def publish_probe(summary: dict, state_path: str, report_path: str) -> dict:
    if (set(summary["available_tools"]) != {"Read", "Glob", "Grep"}
            or summary["mcp_server_count"] != 0
            or set(summary["actual_invocations"]) - {"Read", "Glob", "Grep"}):
        raise ValueError("unexpected native capability; no probe receipt published")
    # Reuse the boundary owner's path/private-file and exact-head checks rather
    # than inventing another settings guard. This trusted sibling never launches
    # a reviewer; disabling bytecode affects this Python process only.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(
        "fm_exact_head_guard", Path(__file__).with_name("fm-exact-head-guard.py"))
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    state = guard.absolute(state_path)
    state_record, state_data = guard.file_record(state, private=True)
    with contextlib.redirect_stdout(io.StringIO()):
        guard.verify(argparse.Namespace(state=str(state)))
    saved = json.loads(state_data)["boundary"]
    report, repo = guard.absolute(report_path), guard.absolute(saved["repo"])
    if report == repo or repo in report.parents or report == state:
        raise ValueError("probe receipt must be outside subject/state")
    report_chain = guard.chain(report)
    if report_chain[-1]["identity"] is not None:
        raise ValueError("probe receipt already exists")
    receipt = {"schema": "firstmate-readonly-probe-capture.v1", "head": saved["target"],
               "base": saved["base"], "moving_ref": saved["moving_ref"],
               "evidence": summary, "postguard_passed": True, "reviewer_go": False,
               "native_admission": False, "inbox_acknowledged": False,
               "capture_kind": "permission-probe-only-not-scout-review"}
    parent = guard.open_parent(report)
    temporary = ".readonly-capture-" + secrets.token_hex(16)
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=parent)
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(receipt, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if (report_chain != guard.chain(report)
                or state_record != guard.file_record(state, private=True)[0]):
            raise ValueError("probe publication boundary changed")
        os.link(temporary, report.name, src_dir_fd=parent, dst_dir_fd=parent,
                follow_symlinks=False)
        os.fsync(parent)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stream", required=True)
    parser.add_argument("--guard-state")
    parser.add_argument("--report")
    args = parser.parse_args()
    if bool(args.guard_state) != bool(args.report):
        parser.error("--guard-state and --report must be supplied together")
    try:
        summary = summarize(args.stream)
        if args.report:
            summary = publish_probe(summary, args.guard_state, args.report)
        print(json.dumps(summary, sort_keys=True))
    except (OSError, ValueError, TypeError, KeyError, RecursionError, subprocess.SubprocessError):
        # Do not print vendor content or exceptions containing sensitive data.
        print("refused: incomplete, unsupported or invalid native evidence; no permission conclusion", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
