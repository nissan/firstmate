#!/usr/bin/env bash
# Per-task allocation identity and pool/Git ownership, no hosted tools or agents.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-allocation-root-lib.sh
. "$ROOT/bin/fm-allocation-root-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-allocation-root)
root="$TMP_ROOT/dedicated pool"
mkdir -p "$root" "$TMP_ROOT/other" "$TMP_ROOT/project"

test_root_validation_and_support() {
  local bad backend
  fm_allocation_root_validate "$root" || fail 'valid root refused'
  for bad in '' relative / "$HOME" "$root/" "$root/../other" "$TMP_ROOT/missing" $'/tmp/bad\nroot'; do
    if fm_allocation_root_validate "$bad" >/dev/null 2>&1; then fail "invalid root accepted: $bad"; fi
  done
  ln -s "$root" "$TMP_ROOT/link"
  if fm_allocation_root_validate "$TMP_ROOT/link" >/dev/null 2>&1; then fail 'symlink accepted'; fi
  for backend in tmux zellij cmux paseo rex tern orca t3code; do
    if fm_allocation_root_supported "$root" "$backend" scout >/dev/null 2>&1; then fail "unsupported $backend accepted"; fi
  done
  if fm_allocation_root_supported "$root" herdr secondmate >/dev/null 2>&1; then fail 'secondmate root accepted'; fi
  fm_allocation_root_supported '' tmux ship
  fm_allocation_root_supported "$root" herdr scout
  fm_allocation_root_supported "$root" herdr ship
  pass 'explicit roots validated; defaults unchanged; unsupported combinations refused'
}

test_metadata_identity() {
  local meta="$TMP_ROOT/task.meta"
  printf 'kind=scout\nbackend=herdr\nallocation_root=%s\n' "$root" > "$meta"
  [ "$(fm_allocation_root_from_meta "$meta")" = "$root" ] || fail 'root identity lost'
  printf 'allocation_root=%s\n' "$root" >> "$meta"
  if fm_allocation_root_from_meta "$meta" >/dev/null 2>&1; then fail 'duplicate root accepted'; fi
  printf 'kind=scout\nbackend=herdr\nallocation_root=\n' > "$meta"
  if fm_allocation_root_from_meta "$meta" >/dev/null 2>&1; then fail 'empty root accepted'; fi
  printf 'kind=scout\n' > "$meta"
  [ -z "$(fm_allocation_root_from_meta "$meta")" ] || fail 'legacy root changed'
  pass 'metadata preserves exact root and refuses duplicate/empty identity'
}

test_pool_git_identity() {
  local pool="$root/.treehouse/pool"
  # A real linked fixture proves layout alone cannot substitute for Git ownership.
  git init -q "$TMP_ROOT/project"
  git -C "$TMP_ROOT/project" commit -qm baseline --allow-empty
  mkdir -p "$pool/1"
  git -C "$TMP_ROOT/project" worktree add -q --detach "$pool/1/repo"
  printf '{}\n' > "$pool/treehouse-state.json"
  fm_treehouse_pool_slot "$TMP_ROOT/project" "$pool/1/repo" "$root" || fail 'owned pool rejected'
  if fm_treehouse_pool_slot "$TMP_ROOT/project" "$pool/1/repo" "$TMP_ROOT/other"; then fail 'wrong root accepted'; fi
  git init -q "$TMP_ROOT/other"
  if fm_treehouse_pool_slot "$TMP_ROOT/other" "$pool/1/repo" "$root"; then fail 'foreign Git identity accepted'; fi
  if fm_allocation_root_validate "$TMP_ROOT/project" >/dev/null 2>&1; then fail 'working-copy root accepted'; fi
  # A malformed placement must not pass merely because its prefix is the root.
  if fm_treehouse_pool_slot "$TMP_ROOT/project" "$pool/1/repo" "$root/.treehouse"; then fail 'nested root prefix accepted'; fi
  pass 'pool layout, explicit root and Git common-directory ownership required together'
}

test_treehouse_argument_identity() {
  local out pool="$root/.treehouse/pool"
  # A function stub sees argument boundaries, not a flattened shell command.
  treehouse() { printf '<%s>\n' "$@"; }
  out=$(fm_allocation_treehouse "$root" return --force "$pool/1/repo")
  [ "$out" = "$(printf '<%s>\n' --root "$root" return --force "$pool/1/repo")" ] || fail 'return argument identity lost'
  [ "$(fm_allocation_treehouse '' status)" = '<status>' ] || fail 'default command changed'
  unset -f treehouse
  pass 'Treehouse operations use exact task root without changing absent/default calls'
}

fm_test_run test_root_validation_and_support test_metadata_identity test_pool_git_identity test_treehouse_argument_identity
