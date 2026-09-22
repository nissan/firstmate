#!/usr/bin/env bash
# Point this checkout's git hooks at the tracked .githooks/ directory, once.
#
# Usage: fm-githooks-wire.sh [<checkout>]
#   <checkout>  The checkout to wire. Defaults to CLAUDE_PROJECT_DIR, then this
#               script's own repository root.
#
# Why a session-start hook runs this: the pre-push gate in .githooks/ only fires
# when core.hooksPath names it, and that setting is per-clone local config that
# no clone inherits. A fresh clone - which is what a cloud session always gets,
# and the case that produced most of the billed minutes the gate exists to save -
# starts with no gate at all unless something wires it.
#
# It sets that value ONLY when it is empty, so a clone already pointing at its
# own hooks directory is left exactly as its owner left it, and
# `git config --unset core.hooksPath` is a durable opt-out rather than something
# the next session silently reverses. It never writes global or system config.
#
# Exit status: always 0. Wiring a convenience is never worth failing a session
# open over, so an unwritable config, an absent .githooks/, or no git at all
# leaves the checkout unwired and says so on stderr.
set -u

target=${1:-${CLAUDE_PROJECT_DIR:-}}
if [ -z "$target" ]; then
  target=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || exit 0
fi

command -v git >/dev/null 2>&1 || exit 0
git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Only wire what is actually there: a checkout without the tracked directory
# would otherwise get a hooksPath naming nothing, which silently disables the
# repository's hooks rather than adding one.
[ -d "$target/.githooks" ] || exit 0

current=$(git -C "$target" config --local --get core.hooksPath 2>/dev/null || true)
if [ -n "$current" ]; then
  exit 0
fi

if git -C "$target" config --local core.hooksPath .githooks 2>/dev/null; then
  printf 'fm-githooks-wire.sh: wired %s to .githooks (git config --unset core.hooksPath opts out).\n' \
    "$target" >&2
else
  printf 'fm-githooks-wire.sh: could not set core.hooksPath in %s; the local pre-push gate stays off.\n' \
    "$target" >&2
fi
exit 0
