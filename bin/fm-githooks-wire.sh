#!/usr/bin/env bash
# Point this checkout's git hooks at the tracked .githooks/ directory, once.
#
# Usage: fm-githooks-wire.sh [<checkout>]
#   <checkout>  The checkout to wire. Defaults to CLAUDE_PROJECT_DIR, then this
#               script's own repository root.
#
# Why a session start runs this: the push check in .githooks/ only fires when
# core.hooksPath names it, and that setting is per-clone local config that no
# clone inherits. A fresh clone - which is what a cloud session always gets -
# starts with no check at all unless something wires it.
#
# It sets that value ONLY when core.hooksPath is unset in EVERY scope. A global
# or system hooksPath is somebody's existing hook setup, often org-wide signing
# or secret scanning, and a local value would shadow it silently; this script
# says so and changes nothing instead. `git config --unset core.hooksPath` is
# therefore a durable opt-out rather than something the next session reverses.
# It never writes global or system config.
#
# It writes an ABSOLUTE path. core.hooksPath is stored in the shared config, so
# every linked worktree of the clone reads the same value; a relative .githooks
# resolves against each worktree in turn and names nothing in a worktree whose
# checkout predates the directory, which would silently disable that worktree's
# hooks rather than add one.
#
# Exit status: always 0. Wiring a convenience is never worth failing a session
# open over, so an unwritable config, an absent .githooks/, or no git at all
# leaves the checkout unwired and says so on stderr.
set -u

target=${1:-${CLAUDE_PROJECT_DIR:-}}
if [ -z "$target" ]; then
  target=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P) || exit 0
fi

command -v git >/dev/null 2>&1 || exit 0
git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# A bare repository has no working tree for the hooks to belong to.
[ "$(git -C "$target" rev-parse --is-bare-repository 2>/dev/null)" = false ] || exit 0

# Only wire what is actually there.
top=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || exit 0
hooks="$top/.githooks"
[ -d "$hooks" ] || exit 0

# --get with no scope flag reads the effective value: local, then global, then
# system. Anything already set belongs to whoever set it.
current=$(git -C "$target" config --get core.hooksPath 2>/dev/null || true)
if [ -n "$current" ]; then
  if [ "$current" != "$hooks" ]; then
    printf 'fm-githooks-wire.sh: core.hooksPath is already %s; leaving it alone.\n' \
      "$current" >&2
  fi
  exit 0
fi

if git -C "$target" config --local core.hooksPath "$hooks" 2>/dev/null; then
  printf 'fm-githooks-wire.sh: wired %s to .githooks (git config --unset core.hooksPath opts out).\n' \
    "$top" >&2
else
  printf 'fm-githooks-wire.sh: could not set core.hooksPath in %s; the local push check stays off.\n' \
    "$top" >&2
fi
exit 0
