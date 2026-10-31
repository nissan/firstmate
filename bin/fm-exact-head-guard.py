#!/usr/bin/env python3
"""File-backed exact-head boundary checks; NOT native reviewer admission.

snapshot --repo DIR --state FILE --target FULL_SHA --base FULL_SHA
         --moving-ref refs/heads/NAME --watch ABSOLUTE_SETTINGS_PATH [--watch ...]
verify --state FILE
profile-snapshot --profile FILE --state FILE
profile-verify --state FILE
profile-diff --state FILE --after-profile FILE

profile-diff compares a separately preserved before-image with an after-profile
for diagnosis only; it can NEVER return integrity success or waive a failed run.
Profile capture is a diagnostic companion, not an integrity exception. It stores
only opaque per-node HMACs, JSON types and fixed non-sensitive policy labels;
never raw profile values, unknown key names, credentials or a profile copy.
Dedicated credential stores and recognized credential-bearing JSON keys refuse
capture; they are not a way to obtain a credential before-image. Profile JSON is
parsed only in memory. Profile verification still refuses EVERY content, identity or metadata
change. It distinguishes policy/unknown changes and an exactly observed +1 of
numStartups, but a counter observation is NOT authority to ignore the change.
No bookkeeping classification retroactively admits an earlier failed probe.

The trusted parent owns both invocations and keeps state outside the subject.
Snapshot requires a clean, non-sparse, submodule-free subject, immutable commit arguments and an
explicit moving ref. Settings paths may be absent but must be absolute and may
not contain symlinks, including in ancestor directories. Verify compares path
identity as well as content, so replacing an alias or parent cannot silently
change what settings the reviewer would discover. State is exclusive and 0600.

This deliberately does not discover settings, claim policy completeness, run a
reviewer, publish a verdict, acknowledge an inbox, or resolve a remote ref.
Unknown/non-file managed policy cannot be made safe by a successful file check.
Use alongside the parent's fresh authenticated forge resolution, never instead
of it. Native admission remains unsupported in fm-spawn.sh.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys

SCHEMA = "firstmate-file-exact-head.v1"
MAX_BYTES = 16 * 1024 * 1024


def git(repo: Path, *args: str, optional: bool = False) -> bytes:
    result = subprocess.run(
        ["git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c",
         "core.untrackedCache=false", "-C", str(repo), *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False,
    )
    if result.returncode and not optional:
        raise ValueError(f"git {args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def absolute(value: str) -> Path:
    # Do not resolve() here: lexical path identity is the property being checked.
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("paths must be absolute without '..'")
    return path


def identity(info: os.stat_result) -> list[int]:
    return [info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid]


def chain(path: Path) -> list[dict]:
    result = []
    for item in [*reversed(path.parents), path]:
        try:
            info = item.lstat()
        except FileNotFoundError:
            result.append({"path": str(item), "identity": None})
            continue
        if stat.S_ISLNK(info.st_mode):
            raise ValueError(f"symlinked settings/state/subject path is unsupported: {item}")
        if item != path and not stat.S_ISDIR(info.st_mode):
            raise ValueError(f"non-directory path ancestor: {item}")
        result.append({"path": str(item), "identity": identity(info)})
    return result


def open_parent(path: Path) -> int:
    """Pin an ancestor chain without following directory symlinks."""
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parent.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def file_record(path: Path, private: bool = False) -> tuple[dict, bytes]:
    before = chain(path)
    if before[-1]["identity"] is None:
        return {"chain": before, "exists": False}, b""
    if not stat.S_ISREG(before[-1]["identity"][2]):
        raise ValueError(f"not a regular file: {path}")
    parent = open_parent(path)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"not a regular file: {path}")
        if private and (info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600):
            raise ValueError("state must be owned by this user with mode 0600")
        if info.st_size > MAX_BYTES:
            raise ValueError(f"file exceeds {MAX_BYTES} byte guard limit: {path}")
        chunks = []
        remaining = MAX_BYTES + 1
        while remaining:
            block = os.read(fd, min(65536, remaining))
            if not block:
                break
            chunks.append(block)
            remaining -= len(block)
        data = b"".join(chunks)
        after_info = os.fstat(fd)
        stable = (identity(info) == identity(after_info)
                  and info.st_size == after_info.st_size
                  and info.st_mtime_ns == after_info.st_mtime_ns
                  and info.st_ctime_ns == after_info.st_ctime_ns)
        if len(data) > MAX_BYTES or not stable or identity(info) != before[-1]["identity"]:
            raise ValueError(f"file changed during capture: {path}")
    finally:
        os.close(fd)
    if before != chain(path):
        raise ValueError(f"path changed during capture: {path}")
    return {"chain": before, "exists": True, "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data), "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns}, data


def capture(repo: Path, target: str, base: str, moving_ref: str, watches: list[str]) -> dict:
    root_chain = chain(repo)
    root = Path(git(repo, "rev-parse", "--show-toplevel").decode().strip())
    if root != repo:
        raise ValueError("--repo must name the subject root directly")
    object_format = git(repo, "rev-parse", "--show-object-format").decode().strip()
    length = {"sha1": 40, "sha256": 64}.get(object_format)
    if not length or any(not re.fullmatch(f"[0-9a-f]{{{length}}}", sha) for sha in (target, base)):
        raise ValueError("target and base must be full lowercase immutable commit SHAs")
    for sha in (target, base):
        if git(repo, "rev-parse", "--verify", f"{sha}^{{commit}}").decode().strip() != sha:
            raise ValueError("target/base must identify commits, not annotated tag objects")
    if git(repo, "rev-parse", "HEAD^{commit}").decode().strip() != target:
        raise ValueError("subject HEAD does not equal target")
    if not moving_ref.startswith("refs/"):
        raise ValueError("moving ref must be a full refs/ name")
    git(repo, "check-ref-format", moving_ref)
    resolved_ref = git(repo, "rev-parse", "--verify", f"{moving_ref}^{{commit}}").decode().strip()
    if resolved_ref != target:
        raise ValueError("moving ref does not equal target")
    sparse = git(repo, "config", "--bool", "core.sparseCheckout", optional=True).strip()
    if sparse not in (b"", b"false"):
        raise ValueError("sparse subjects are unsupported")
    flags = git(repo, "ls-files", "-v", "-z").split(b"\0")
    if any(line and (line[:1].islower() or line[:1] == b"S") for line in flags):
        raise ValueError("assume-unchanged/skip-worktree paths are unsupported")
    if git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"):
        raise ValueError("subject is dirty, including untracked files/submodules")
    # A parent's clean status cannot prove children have no hidden changes
    # (for example, child assume-unchanged bits). Do not claim recursive proof.
    stages = git(repo, "ls-files", "--stage", "-z").split(b"\0")
    if any(entry.startswith(b"160000 ") for entry in stages):
        raise ValueError("submodule subjects are unsupported by this file-only guard")
    settings = {item: file_record(absolute(item))[0] for item in watches}
    if root_chain != chain(repo):
        raise ValueError("subject path changed during capture")
    return {"repo": str(repo), "repo_chain": root_chain, "target": target, "base": base,
            "moving_ref": moving_ref, "moving_ref_resolution": resolved_ref,
            "watched": settings}


def snapshot(args: argparse.Namespace) -> None:
    repo, state = absolute(args.repo), absolute(args.state)
    state_chain = chain(state)
    if state_chain[-1]["identity"] is not None:
        raise ValueError("state already exists")
    if state == repo or repo in state.parents:
        raise ValueError("state must be outside the subject")
    if str(state) in args.watch:
        raise ValueError("state cannot watch itself")
    if not state.parent.is_dir():
        raise ValueError("state parent must already exist")
    current = capture(repo, args.target, args.base, args.moving_ref, args.watch)
    # A second pass rejects mutations that occurred while later settings/git
    # inputs were being read. This is a boundary check, not continuous locking.
    if current != capture(repo, args.target, args.base, args.moving_ref, args.watch):
        raise ValueError("inputs changed during snapshot")
    if state_chain != chain(state):
        raise ValueError("state path changed before publication")
    parent = open_parent(state)
    try:
        fd = os.open(state.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=parent)
    finally:
        os.close(parent)
    with os.fdopen(fd, "w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump({"schema": SCHEMA, "boundary": current}, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    if state_chain[:-1] != chain(state)[:-1]:
        raise ValueError("state ancestors changed during publication; snapshot is not admitted")
    print("snapshot: file-backed boundary recorded; native policy completeness NOT established")


def verify(args: argparse.Namespace) -> None:
    state = absolute(args.state)
    record, data = file_record(state, private=True)
    if not record["exists"]:
        raise ValueError("state does not exist")
    saved = json.loads(data)
    if not isinstance(saved, dict) or saved.get("schema") != SCHEMA:
        raise ValueError("unsupported state schema")
    expected = saved["boundary"]
    if (not isinstance(expected, dict)
            or any(not isinstance(expected.get(key), str)
                   for key in ("repo", "target", "base", "moving_ref"))
            or not isinstance(expected.get("watched"), dict) or not expected["watched"]):
        raise ValueError("malformed boundary state")
    repo = absolute(expected["repo"])
    if state == repo or repo in state.parents:
        raise ValueError("state must be outside the subject")
    current = capture(repo, expected["target"], expected["base"], expected["moving_ref"],
                      list(expected["watched"]))
    if expected != current or current != capture(
            repo, expected["target"], expected["base"], expected["moving_ref"], list(expected["watched"])):
        raise ValueError("subject/ref/settings boundary changed")
    if record != file_record(state, private=True)[0]:
        raise ValueError("state changed during verification")
    print("verified: file-backed boundary unchanged; NOT reviewer GO or native policy admission")


# These labels are fixed schema names, not a user-provided key-name whitelist.
# All other names, including project paths and unknown credential-like keys,
# remain opaque. A label classifies a diagnostic; it grants no mutation rights.
PROFILE_POLICY_KEYS = frozenset({
    "permissions", "hooks", "mcpServers", "projects", "env", "settings",
    "defaultMode", "apiKeyHelper", "allowedTools", "disallowedTools",
    "enabledPlugins", "extraKnownMarketplaces", "trustedDirectories",
})
PROFILE_SCHEMA = "firstmate-profile-hmac.v1"


def profile_capture(path: Path, key: bytes) -> dict:
    if path.name.lower() in {".credentials.json", "credentials.json", "auth.json"}:
        raise ValueError("credential stores are not supported profile inputs")
    record, data = file_record(path)
    if not record["exists"]:
        raise ValueError("profile must already exist")

    def unique(pairs: list) -> dict:
        value = {}
        for name, item in pairs:
            credential_key = name.lower().replace("_", "").replace("-", "")
            if credential_key in {"accesstoken", "refreshtoken", "primaryapikey", "apikey",
                                  "anthropicapikey", "anthropicauthtoken", "claudeaioauth"}:
                raise ValueError("credential-bearing JSON is not a profile before-image")
            if name in value:
                raise ValueError("profile contains duplicate JSON keys")
            value[name] = item
        return value

    def reject_constant(_value: str) -> None:
        raise ValueError("profile contains non-finite JSON numbers")

    try:
        document = json.loads(data, object_pairs_hook=unique, parse_constant=reject_constant)
    except (ValueError, RecursionError, UnicodeError):
        # Parser exceptions must never echo raw profile strings or keys.
        raise ValueError("profile must be valid unique-key finite JSON") from None
    if not isinstance(document, dict):
        raise ValueError("profile root must be a JSON object")

    def digest(value: object) -> str:
        encoded = json.dumps(value, sort_keys=True, separators=(",", ":"),
                             ensure_ascii=True, allow_nan=False).encode()
        return hmac.new(key, encoded, hashlib.sha256).hexdigest()

    nodes = {}

    def visit(value: object, parts: list, category: str, label: str) -> None:
        if len(parts) > 64 or len(nodes) >= 10000:
            raise ValueError("profile structure exceeds diagnostic bounds")
        kind = ("object" if isinstance(value, dict) else "array" if isinstance(value, list)
                else "null" if value is None else "boolean" if isinstance(value, bool)
                else "number" if isinstance(value, (int, float)) else "string")
        node = {"kind": kind, "hmac": digest(value), "category": category, "label": label}
        if parts == ["numStartups"] and type(value) is int and 0 <= value < 2**53 - 1:
            node["next_counter_hmac"] = digest(value + 1)
        nodes[digest(["path", parts])] = node
        if isinstance(value, dict):
            for name, child in value.items():
                child_category, child_label = category, label
                if not parts:
                    child_category = "policy" if name in PROFILE_POLICY_KEYS else "unknown"
                    child_label = name if name in PROFILE_POLICY_KEYS or name == "numStartups" else "opaque"
                visit(child, [*parts, name], child_category, child_label)
        elif isinstance(value, list):
            for index, child in enumerate(value):
                visit(child, [*parts, index], category, label)

    visit(document, [], "root", "root")
    return {"file": record, "nodes": nodes}


def profile_snapshot(args: argparse.Namespace) -> None:
    profile, state = absolute(args.profile), absolute(args.state)
    if state == profile:
        raise ValueError("profile state must be separate from profile")
    state_chain = chain(state)
    if state_chain[-1]["identity"] is not None or not state.parent.is_dir():
        raise ValueError("profile state must be new with an existing parent")
    key = secrets.token_bytes(32)
    before = profile_capture(profile, key)
    if before != profile_capture(profile, key) or state_chain != chain(state):
        raise ValueError("profile/state changed during capture")
    parent = open_parent(state)
    try:
        fd = os.open(state.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=parent)
    finally:
        os.close(parent)
    with os.fdopen(fd, "w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump({"schema": PROFILE_SCHEMA, "profile": str(profile),
                   "key": key.hex(), "before": before}, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    if state_chain[:-1] != chain(state)[:-1]:
        raise ValueError("profile state ancestors changed during publication")
    print("snapshot: private hashed profile structure recorded; no mutation exception granted")


def profile_verify(args: argparse.Namespace) -> None:
    state = absolute(args.state)
    state_record, data = file_record(state, private=True)
    try:
        saved = json.loads(data)
        if not isinstance(saved, dict) or saved.get("schema") != PROFILE_SCHEMA:
            raise ValueError("unsupported profile state schema")
        key = bytes.fromhex(saved["key"])
        if len(key) != 32:
            raise ValueError("invalid profile hash key")
        before = saved["before"]
        profile = absolute(saved["profile"])
        if state == profile or not isinstance(before["nodes"], dict) or not before["nodes"]:
            raise ValueError("malformed profile state")
        labels = PROFILE_POLICY_KEYS | {"root", "opaque", "numStartups"}
        for token, node in before["nodes"].items():
            if (not re.fullmatch(r"[0-9a-f]{64}", token) or not isinstance(node, dict)
                    or node.get("label") not in labels
                    or node.get("category") not in {"root", "policy", "unknown"}
                    or node.get("kind") not in {"object", "array", "null", "boolean", "number", "string"}
                    or not re.fullmatch(r"[0-9a-f]{64}", node.get("hmac", ""))
                    or not re.fullmatch(r"[0-9a-f]{64}", node.get("next_counter_hmac", "0" * 64))):
                raise ValueError("malformed profile node")
    except (ValueError, KeyError, TypeError):
        raise ValueError("malformed private profile state") from None
    after_profile = absolute(args.after_profile) if args.command == "profile-diff" else profile
    after = profile_capture(after_profile, key)
    if after != profile_capture(after_profile, key) or state_record != file_record(state, private=True)[0]:
        raise ValueError("profile/state changed during verification")
    changes = []
    for token in sorted(before["nodes"].keys() | after["nodes"].keys()):
        old, new = before["nodes"].get(token), after["nodes"].get(token)
        if old == new:
            continue
        node = old or new
        category = node["category"]
        # The root necessarily changes whenever any descendant changes; report
        # the more precise opaque descendants rather than duplicating it.
        if category == "root":
            continue
        if old and new and old.get("next_counter_hmac") == new["hmac"]:
            category = "counter-increment-observed-NOT-authorized"
        changes.append({"node": token, "category": category, "label": node["label"],
                        "before_hmac": old["hmac"] if old else None,
                        "after_hmac": new["hmac"] if new else None,
                        "before_kind": old["kind"] if old else None,
                        "after_kind": new["kind"] if new else None,
                        "change": "added" if old is None else "removed" if new is None else "changed"})
    summary = {"schema": "firstmate-profile-delta.v1", "changes": changes,
               "file_boundary_changed": before["file"] != after["file"],
               "before_file_sha256": before["file"]["sha256"],
               "after_file_sha256": after["file"]["sha256"],
               "path_identity_changed": before["file"]["chain"] != after["file"]["chain"],
               "integrity_passed": before == after and args.command != "profile-diff",
               "comparison_only": args.command == "profile-diff",
               "bookkeeping_exceptions_applied": 0, "native_admission": False}
    print(json.dumps(summary, sort_keys=True))
    if args.command == "profile-diff":
        raise ValueError("profile-diff is diagnostic only; no integrity admission")
    if before != after:
        raise ValueError("profile boundary changed; diagnostic classification does not waive integrity")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    snap = commands.add_parser("snapshot")
    for flag in ("repo", "state", "target", "base", "moving-ref"):
        snap.add_argument(f"--{flag}", required=True)
    snap.add_argument("--watch", action="append", required=True)
    check = commands.add_parser("verify")
    check.add_argument("--state", required=True)
    profile_snap = commands.add_parser("profile-snapshot")
    profile_snap.add_argument("--profile", required=True)
    profile_snap.add_argument("--state", required=True)
    profile_check = commands.add_parser("profile-verify")
    profile_check.add_argument("--state", required=True)
    profile_diff = commands.add_parser("profile-diff")
    profile_diff.add_argument("--state", required=True)
    profile_diff.add_argument("--after-profile", required=True)
    args = parser.parse_args()
    try:
        {"snapshot": snapshot, "verify": verify, "profile-snapshot": profile_snapshot,
         "profile-verify": profile_verify, "profile-diff": profile_verify}[args.command](args)
    except (OSError, ValueError, KeyError, TypeError, RecursionError, subprocess.SubprocessError) as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
