#!/usr/bin/env bash
# Native admission is intentionally unavailable; fm-spawn.sh --help owns the
# contract. Shared pre-stop/pre-launch metadata check for spawn and control.
# No caller may infer native admission from file-only boundary verification.

fm_exact_head_review_claude_plan() { # <existing private probe-root>; NO execution
  python3 - "$1" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-readonly-evidence.py" <<'PY'
from pathlib import Path
import hashlib
import json
import shutil
import sys

try:
    root = Path(sys.argv[1])
    if not root.is_absolute() or root.is_symlink() or not root.is_dir() or ".." in root.parts:
        raise ValueError("probe root must be an existing absolute non-symlink directory")
    if any(path.is_symlink() for path in root.parents):
        raise ValueError("probe root ancestry must not contain symlinks")
    for name in ("subject", "prompt.txt", "explicit-settings.json", "mcp-empty.json"):
        path = root / name
        if path.is_symlink() or (not path.is_dir() if name == "subject" else not path.is_file()):
            raise ValueError("probe inputs must be existing non-symlink files/directories")
    if json.loads((root / "mcp-empty.json").read_text()) != {"mcpServers": {}}:
        raise ValueError("probe MCP configuration must be explicitly empty")
    settings = json.loads((root / "explicit-settings.json").read_text())
    if (not isinstance(settings, dict)
            or set(settings) != {"disableAllHooks", "disableClaudeAiConnectors"}
            or any(value is not True for value in settings.values())):
        raise ValueError("probe settings must match the bounded restrictive recipe")
    for name in ("stdout.jsonl", "stderr.txt", "capture-receipt.json"):
        if (root / name).exists() or (root / name).is_symlink():
            raise ValueError("probe output already exists; no replay or overwrite recipe")
    command = shutil.which("claude")
    if not command:
        raise ValueError("Claude executable is unavailable; no harness substitution")
    executable = Path(command).resolve(strict=True)
    with executable.open("rb") as stream:
        executable_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    argv = [str(executable), "--print", "--model", "sonnet", "--effort", "low",
            "--permission-mode", "manual", "--permission-prompts", "none",
            "--restricted", "--tools", "Read,Glob,Grep", "--disallowedTools",
            "Write,Edit,Bash,PowerShell,WebFetch,WebSearch,mcp__*", "--strict-mcp-config",
            "--mcp-config", str(root / "mcp-empty.json"), "--safe-mode", "--settings",
            str(root / "explicit-settings.json"), "--disable-slash-commands", "--no-chrome",
            "--no-session-persistence", "--output-format", "stream-json", "--verbose"]
    plan = {"schema": "firstmate-readonly-probe-plan.v1", "harness": "claude",
            "native_execution_authorized": False, "native_permission_proved": False,
            "cwd": str(root / "subject"), "argv": argv,
            "executable_sha256": executable_hash,
            "environment": {"DISABLE_AUTOUPDATER": "1",
                            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                            "DISABLE_GROWTHBOOK": "1"},
            "stdin": str(root / "prompt.txt"), "stdout": str(root / "stdout.jsonl"),
            "stderr": str(root / "stderr.txt"), "timeout_seconds": 90,
            "termination_grace_seconds": 5,
            "parent_capture_argv": ["python3", sys.argv[2], "--stream", str(root / "stdout.jsonl"),
                                    "--guard-state", str(root / "boundary.json"),
                                    "--report", str(root / "capture-receipt.json")],
            "inbox_acknowledgement": "none: probe receipt is not a completed scout review"}
    print(json.dumps(plan, sort_keys=True))
except (OSError, ValueError, TypeError):
    print("error: unsupported or unsafe readonly probe inputs; no native process launched", file=sys.stderr)
    sys.exit(2)
PY
}

fm_exact_head_review_record_check() { # <locked validated task metadata>
  local recorded
  recorded=$(awk -F= '
    $1 == "exact_head_review" { count++; value=substr($0, index($0, "=") + 1) }
    END { printf "%d:%s", count, value }
  ' "$1") || return 1
  case "$recorded" in
  0: | 1:off) return 0 ;;
  1:on)
    echo "error: recorded exact_head_review=on is unsupported: complete native managed-policy/settings discovery is unproved; refusing relaunch without weakening permissions" >&2
    ;;
  *)
    echo "error: malformed or duplicate exact_head_review metadata; refusing an ambiguous relaunch" >&2
    ;;
  esac
  return 1
}
