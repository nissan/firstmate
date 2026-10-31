#!/usr/bin/env bash
# Per-task Treehouse allocation identity. An absent root leaves Treehouse's
# existing defaults untouched. Explicit roots must be existing canonical absolute
# directories, not symlinks, filesystem/home roots, or Git working copies.
# Metadata is data, never sourced. Duplicate, empty, or unsupported identities
# refuse before allocation/recovery/return. Only ordinary Herdr tasks support it.

fm_allocation_root_validate() {  # <root>
  local root=$1 canonical
  case "$root" in /*) ;; *) echo 'error: allocation root must be absolute' >&2; return 1 ;; esac
  case "$root" in *$'\n'*|*$'\r'*|/|"${HOME:-/}") echo 'error: unsafe allocation root' >&2; return 1 ;; esac
  [ -d "$root" ] && [ -w "$root" ] && [ ! -L "$root" ] || {
    echo 'error: allocation root must be an existing writable directory, not a symlink' >&2
    return 1
  }
  canonical=$(CDPATH='' cd -- "$root" && pwd -P) || return 1
  [ "$canonical" = "$root" ] || { echo 'error: allocation root must use its canonical path' >&2; return 1; }
  if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo 'error: allocation root cannot be inside a Git working copy' >&2
    return 1
  fi
}

fm_allocation_root_supported() {  # <root> <backend> <kind>
  [ -n "$1" ] || return 0
  if [ "$2" != herdr ] || { [ "$3" != ship ] && [ "$3" != scout ]; }; then
    echo 'error: --allocation-root supports ordinary Herdr ship/scout tasks only' >&2
    return 1
  fi
  fm_allocation_root_validate "$1"
}

fm_allocation_root_from_meta() {  # <meta>; prints root, or nothing for legacy
  local meta=$1 count root backend kind
  count=$(LC_ALL=C awk -F= '$1 == "allocation_root" { n++ } END { print n+0 }' "$meta") || return 1
  [ "$count" != 0 ] || return 0
  [ "$count" = 1 ] || { echo 'error: duplicate allocation_root identity' >&2; return 1; }
  root=$(LC_ALL=C awk '/^allocation_root=/ { sub(/^[^=]*=/, ""); print }' "$meta") || return 1
  [ -n "$root" ] || { echo 'error: empty allocation_root identity' >&2; return 1; }
  backend=$(LC_ALL=C awk -F= '$1 == "backend" { print $2 }' "$meta") || return 1
  kind=$(LC_ALL=C awk -F= '$1 == "kind" { print $2 }' "$meta") || return 1
  fm_allocation_root_supported "$root" "$backend" "$kind" || return 1
  printf '%s\n' "$root"
}

fm_allocation_treehouse() {  # <root-or-empty> <treehouse-args...>
  local root=$1
  shift
  if [ -n "$root" ]; then
    fm_allocation_root_validate "$root" || return 1
    treehouse --root "$root" "$@"
  else
    treehouse "$@"
  fi
}
