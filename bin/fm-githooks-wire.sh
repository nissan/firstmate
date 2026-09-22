#!/usr/bin/env bash
# Point this checkout's git hooks at the tracked .githooks/ directory, once.
#
# Usage: fm-githooks-wire.sh [<checkout>]
#   <checkout>  The checkout to wire. Defaults to this script's own repository
#               root.
#
# Why a session start runs this: the push check in .githooks/ only fires when
# core.hooksPath names it, and that setting is per-clone local config that no
# clone inherits, so a fresh clone starts with no check at all unless something
# wires it.
#
# It sets that value ONLY when core.hooksPath is unset in EVERY scope. A global
# or system hooksPath is somebody's existing hook setup, often org-wide signing
# or secret scanning, and a local value would shadow it silently; this script
# says so and changes nothing instead. It never writes global or system config.
#
# Opting out therefore means naming a hooks directory of your own, not clearing
# the setting: `git config core.hooksPath .git/hooks` restores git's default
# hooks and is respected from then on, while `git config --unset` leaves the
# value empty and the next session wires it again.
#
# It writes an ABSOLUTE path. core.hooksPath is stored in the shared config, so
# every linked worktree of the clone reads the same value; a relative .githooks
# resolves against each worktree in turn and names nothing in a worktree whose
# checkout predates the directory, which would silently disable that worktree's
# hooks rather than add one.
#
# Output: one line on stdout naming the outcome, for a caller that classifies
# it - `wired`, `kept` (someone else's hooksPath left in force), `skipped` (no
# checkout, no git, a bare repository, or no .githooks/), or `failed` (the
# config write was refused). A human-readable line goes to stderr except when
# the outcome is `kept`, which is a routine confirmation rather than news.
#
# Exit status: always 0. Wiring a convenience is never worth failing a session
# open over, so an unwritable config, an absent .githooks/, or no git at all
# leaves the checkout unwired and says so.
set -u

done_with() {  # <stdout-token> [<stderr-line>]
  printf '%s\n' "$1"
  [ "$#" -lt 2 ] || printf 'fm-githooks-wire.sh: %s\n' "$2" >&2
  exit 0
}

target=${1:-}
if [ -z "$target" ]; then
  target=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P) \
    || done_with skipped 'cannot resolve my own repository root.'
fi

command -v git >/dev/null 2>&1 || done_with skipped 'git is not installed.'
git -C "$target" rev-parse --git-dir >/dev/null 2>&1 \
  || done_with skipped "$target is not a git checkout."

# A bare repository has no working tree for the hooks to belong to.
[ "$(git -C "$target" rev-parse --is-bare-repository 2>/dev/null)" = false ] \
  || done_with skipped "$target is a bare repository."

# Only wire what is actually there.
top=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) \
  || done_with skipped "$target has no working tree."
hooks="$top/.githooks"
[ -d "$hooks" ] || done_with skipped "$top has no .githooks/ to point at."

# --get with no scope flag reads the effective value: local, then global, then
# system. Anything already set belongs to whoever set it.
current=$(git -C "$target" config --get core.hooksPath 2>/dev/null || true)
if [ -n "$current" ]; then
  [ "$current" = "$hooks" ] && done_with kept
  done_with kept "core.hooksPath is already $current; leaving it alone."
fi

git -C "$target" config --local core.hooksPath "$hooks" 2>/dev/null \
  || done_with failed "could not set core.hooksPath in $top; the local push check stays off."
done_with wired "wired $top to .githooks."
