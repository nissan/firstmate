# shellcheck shell=bash
# fm-crew-cap-lib.sh - concurrency-cap primitives for bin/fm-spawn.sh.
# Usage: . bin/fm-crew-cap-lib.sh   (after bin/fm-backend.sh)
#
# Why this exists: eleven workers once ran at once in a single home, each paying
# its own startup cost re-reading the same repositories, and the provider
# allowance was exhausted before the work was. This library counts how many
# workers this home currently has running so fm-spawn can refuse a spawn beyond
# the configured cap and name what is already running.
#
# FAIL-SAFE DIRECTION - the whole risk of this gate. Every task in the fleet
# flows through spawn, so a gate that errs toward refusing bricks the fleet.
# Only positive evidence refuses:
#   * A worker is counted only when its recorded endpoint reads back a verified
#     live agent (fm_backend_agent_state's `alive`). Every other verdict -
#     dead, missing, ambiguous, unreadable, and the `unverified` a backend with
#     no recovery classifier returns - is uncertainty and is NOT counted, so
#     uncertainty always lowers the count and can never produce a refusal. A
#     backend with no recovery classifier therefore has no effective cap.
#   * An unsafe config directory or a malformed cap value yields no cap at all
#     rather than an inferred default, and sets FM_CREW_CAP_WARNING.
#   * fm_crew_cap_check returns FM_CREW_CAP_REFUSE_RC and nothing else to mean
#     refuse. Any other non-zero return - including an unexpected internal
#     failure - means proceed, so the failure of the check cannot stop a spawn.
# An ABSENT cap file is not uncertainty: absence has a documented default, which
# is materialized best-effort so the operator can see and edit it.
#
# Secondmates are excluded. They are persistent infrastructure that is idle by
# default, not workers burning an allowance on a task, and capping them would
# block secondmate provisioning. Remote records belong to another host's home.
#
# docs/configuration.md owns the operator-facing setting; this header owns the
# parsing and counting mechanics.

FM_CREW_CAP_FILE="crew-concurrency-cap"
FM_CREW_CAP_DEFAULT="3"
# The ONLY return code that means refuse. Kept distinct from 1 so an internal
# failure inside this library can never be read as positive evidence.
FM_CREW_CAP_REFUSE_RC=2

FM_CREW_CAP_VALUE=""
FM_CREW_CAP_COUNT=""
FM_CREW_CAP_ACTIVE=""
FM_CREW_CAP_WARNING=""

fm_crew_cap_warn() {
  FM_CREW_CAP_WARNING=$1
  return 1
}

fm_crew_cap_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

# fm_crew_cap_file_valid <path>
# Sets FM_CREW_CAP_VALUE only for a regular, single-linked file holding exactly
# one positive decimal value and one terminating newline.
fm_crew_cap_file_valid() {
  local path=$1 links value
  FM_CREW_CAP_VALUE=""
  if [ -L "$path" ]; then
    fm_crew_cap_warn "cap file is symlinked"
    return 1
  fi
  if [ ! -f "$path" ]; then
    fm_crew_cap_warn "cap file is not a regular file"
    return 1
  fi
  links=$(fm_crew_cap_link_count "$path") || links=""
  if [ "$links" != 1 ]; then
    fm_crew_cap_warn "cap file is hardlinked or its link count is unreadable"
    return 1
  fi
  value=$(cat "$path" 2>/dev/null) || {
    fm_crew_cap_warn "cap file could not be read"
    return 1
  }
  case "$value" in
    ''|0|*[!0-9]*|0*)
      fm_crew_cap_warn "cap value must be one positive decimal integer"
      return 1
      ;;
  esac
  if ! printf '%s\n' "$value" | cmp -s "$path" -; then
    fm_crew_cap_warn "cap file must contain exactly one value followed by one newline"
    return 1
  fi
  FM_CREW_CAP_VALUE=$value
  return 0
}

# fm_crew_cap_materialize <config-dir>
# Best-effort atomic publication of the visible default when the file is absent,
# so the operator can see and edit the setting. Every failure is silent: an
# unwritable config directory must never affect a spawn.
fm_crew_cap_materialize() {
  local config_dir=$1 path tmp
  path="$config_dir/$FM_CREW_CAP_FILE"
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 0
  mkdir -p "$config_dir" 2>/dev/null || return 0
  tmp=$(umask 077; mktemp "$config_dir/.crew-concurrency-cap.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$FM_CREW_CAP_DEFAULT" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# fm_crew_cap_resolve <config-dir>
# Sets FM_CREW_CAP_VALUE to the effective cap. An absent file or absent config
# directory resolves to the documented default; an unsafe directory or malformed
# value returns 1 with FM_CREW_CAP_WARNING set, so no cap is applied rather than
# one inferred. This sets variables instead of printing precisely so a caller
# never has to run it in a command substitution, where the warning explaining a
# skipped cap would be lost with the subshell.
fm_crew_cap_resolve() {
  local config_dir=$1 path
  FM_CREW_CAP_VALUE=""
  if [ -L "$config_dir" ]; then
    fm_crew_cap_warn "the config directory is symlinked"
    return 1
  fi
  if [ ! -d "$config_dir" ]; then
    FM_CREW_CAP_VALUE=$FM_CREW_CAP_DEFAULT
    return 0
  fi
  path="$config_dir/$FM_CREW_CAP_FILE"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    fm_crew_cap_materialize "$config_dir"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      FM_CREW_CAP_VALUE=$FM_CREW_CAP_DEFAULT
      return 0
    fi
  fi
  fm_crew_cap_file_valid "$path" || return 1
  return 0
}

# fm_crew_cap_read <config-dir>
# Prints the effective cap for callers that want the value alone.
fm_crew_cap_read() {
  fm_crew_cap_resolve "$1" || return 1
  printf '%s\n' "$FM_CREW_CAP_VALUE"
}

# fm_crew_cap_active <state-dir>
# Prints one "<id> (backend=<b> window=<w>)" line per non-secondmate direct
# report of THIS home whose recorded endpoint reads back a verified live agent.
# Anything unreadable, ambiguous, or unclassifiable is skipped rather than
# counted, which is what keeps the gate incapable of refusing on uncertainty.
fm_crew_cap_active() {
  local state_dir=$1 meta id kind window target backend
  [ -d "$state_dir" ] || return 0
  for meta in "$state_dir"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind 2>/dev/null) || kind=""
    if [ "$kind" = secondmate ]; then
      continue
    fi
    if [ -n "$(fm_meta_get "$meta" remote_host 2>/dev/null)" ]; then
      continue
    fi
    window=$(fm_meta_get "$meta" window 2>/dev/null) || window=""
    if [ -z "$window" ]; then
      continue
    fi
    backend=$(fm_backend_of_meta "$meta" 2>/dev/null) || backend=""
    if [ -z "$backend" ]; then
      continue
    fi
    target=$(fm_backend_target_of_meta "$meta" 2>/dev/null) || target=""
    if [ "$(fm_backend_agent_state "$backend" "${target:-$window}" 2>/dev/null)" != alive ]; then
      continue
    fi
    printf '%s (backend=%s window=%s)\n' "$id" "$backend" "$window"
  done
  return 0
}

# fm_crew_cap_check <config-dir> <state-dir>
# Returns 0 to proceed, FM_CREW_CAP_REFUSE_RC when the established live count
# has already reached the established cap, and any other non-zero value to
# proceed with FM_CREW_CAP_WARNING explaining why no cap could be applied.
# On a 0 or refusing return, FM_CREW_CAP_VALUE, FM_CREW_CAP_COUNT, and
# FM_CREW_CAP_ACTIVE describe what was measured.
fm_crew_cap_check() {
  local config_dir=$1 state_dir=$2 cap active count
  FM_CREW_CAP_VALUE=""
  FM_CREW_CAP_COUNT=""
  FM_CREW_CAP_ACTIVE=""
  FM_CREW_CAP_WARNING=""
  if ! type fm_backend_agent_state >/dev/null 2>&1 || ! type fm_meta_get >/dev/null 2>&1; then
    fm_crew_cap_warn "the backend liveness reader is unavailable"
    return 1
  fi
  fm_crew_cap_resolve "$config_dir" || return 1
  cap=$FM_CREW_CAP_VALUE
  case "$cap" in
    ''|*[!0-9]*)
      fm_crew_cap_warn "the resolved cap is not a decimal integer"
      return 1
      ;;
  esac
  FM_CREW_CAP_VALUE=$cap
  active=$(fm_crew_cap_active "$state_dir") || {
    fm_crew_cap_warn "this home's active workers could not be enumerated"
    return 1
  }
  if [ -z "$active" ]; then
    count=0
  else
    count=$(printf '%s\n' "$active" | wc -l | tr -d ' ')
  fi
  case "$count" in
    ''|*[!0-9]*)
      fm_crew_cap_warn "the active worker count could not be established"
      return 1
      ;;
  esac
  FM_CREW_CAP_COUNT=$count
  FM_CREW_CAP_ACTIVE=$active
  [ "$count" -ge "$cap" ] || return 0
  return "$FM_CREW_CAP_REFUSE_RC"
}
