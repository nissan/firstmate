# shellcheck shell=bash
# fm-runway-lib.sh - the pre-spawn remaining-allowance gate for bin/fm-spawn.sh.
# Usage: . bin/fm-runway-lib.sh   (sourced, never executed)
#
# Why this exists: a documentation review dispatched at the top tier consumed an
# entire weekly allowance and produced nothing, and the same review re-run one
# tier lower produced a better report with three material findings. The captain's
# rule is that no delegated work may consume a provider allowance and deliver
# nothing - check the runway BEFORE spending it, and prefer a lower tier that
# finishes over a higher tier that exhausts. This library is the "before" half:
# it reads quota-axi's remaining-runway evidence for the harness and model a
# spawn is about to launch on, and answers one question - can this work start at
# all, or is the allowance it would spend already gone.
#
# WHAT IT CAN AND CANNOT KNOW - the honesty this gate lives or dies on. Nothing
# here can project how many tokens the worker about to launch will spend: task
# size is not knowable at dispatch, so any "this job needs N tokens" number would
# be invented. So the gate never pretends to compare a projected spend against a
# projected runway. It refuses ONLY on evidence that the allowance is already
# gone - a scope quota-axi reports as exhausted_now, a known scope with zero
# percent remaining, or zero usable runway seconds - which is impossibility, not
# pessimism. Everything short of that, including quota-axi's own
# projected_exhaustion, is "might not finish" and WARNS while allowing the spawn.
# Refusing on a projection would train the operator to reach for the override on
# every dispatch, and an override that is always used protects nothing.
#
# FAIL-SAFE DIRECTION - the whole risk of this gate. Every task in the fleet
# flows through spawn, so a gate that errs toward refusing converts a soft
# overspend problem into a hard fleet outage. An unavailable or unparseable
# quota signal therefore WARNS AND ALLOWS, and never blocks:
#   * quota-axi missing, below the supported floor, failing, timing out, or
#     emitting anything fm_quota_json_valid rejects is absent evidence.
#   * A harness with no known provider family, a provider quota-axi does not
#     report, and a provider whose every applicable scope is `unknown` are all
#     absent evidence too. Absent evidence is never read as bad news.
#   * fm_runway_check returns FM_RUNWAY_REFUSE_RC and nothing else to mean
#     refuse. Every other non-zero return - including an unexpected internal
#     failure - means proceed, so the failure of the check cannot stop a spawn.
# The refusal is also overridable by design, and bin/fm-spawn.sh's message names
# the remedy: a gate people cannot get past becomes a gate people route around.
#
# The read is bounded and strictly read-only. `--no-credential-refresh` keeps a
# spawn from delegating a vendor session renewal (which can prompt for a
# keychain), and fm_run_timed bounds the whole process group so a hung vendor
# CLI cannot wedge a dispatch. A read that does not answer in time is absent
# evidence like any other.
#
# FM_RUNWAY_SNAPSHOT names an already-captured quota-axi JSON snapshot to read
# instead of running quota-axi again. Firstmate already reads quota-axi when it
# picks the harness and model for a dispatch, so this lets the gate judge the
# SAME evidence that chose the tier rather than a second, slightly different
# read. It is evidence, not a bypass: the snapshot is validated exactly like a
# live read, and it must be FRESH - freshness is judged from the file's
# modification time, so a snapshot has to be written when it is captured, and
# one older than FM_RUNWAY_SNAPSHOT_MAX_AGE is absent evidence rather than a
# quiet pass. That decay is deliberate: a forgotten snapshot path degrades to a
# warning within the hour instead of disabling the gate forever.
#
# bin/fm-quota-axi-lib.sh owns the provider map, the scope-model normalisation,
# and the applicable-scope rule; bin/fm-spawn.sh's header owns which spawns are
# gated and the operator-facing messages.

_FM_RUNWAY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$_FM_RUNWAY_LIB_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_RUNWAY_LIB_DIR/fm-timeout-lib.sh"

# The ONLY return code that means refuse. Kept distinct from 1 so an internal
# failure inside this library can never be read as positive evidence.
FM_RUNWAY_REFUSE_RC=2
# Bounds for the two reads. quota-axi may talk to several vendors, so the
# snapshot gets the larger budget; both are hard bounds, not retries.
FM_RUNWAY_VERSION_TIMEOUT=${FM_RUNWAY_VERSION_TIMEOUT:-10}
FM_RUNWAY_READ_TIMEOUT=${FM_RUNWAY_READ_TIMEOUT:-45}
# How old a captured snapshot may be before it stops counting as evidence about
# now. Quota windows move over hours, so an hour is the outer edge of useful.
FM_RUNWAY_SNAPSHOT_MAX_AGE=${FM_RUNWAY_SNAPSHOT_MAX_AGE:-3600}

FM_RUNWAY_PROVIDER=""
FM_RUNWAY_EVIDENCE=""
FM_RUNWAY_WARNING=""
FM_RUNWAY_SNAPSHOT_DATA=""

fm_runway_warn() {
  FM_RUNWAY_WARNING=$1
  return 1
}

# fm_runway_file_mtime <path>
# Prints the file's modification time in epoch seconds on macOS or Linux.
fm_runway_file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_runway_captured_snapshot <path>
# Sets FM_RUNWAY_SNAPSHOT_DATA to the validated contents of an already-captured
# snapshot, or returns 1 with FM_RUNWAY_WARNING naming why that capture is not
# evidence about now.
fm_runway_captured_snapshot() {
  local path=$1 mtime now age snapshot
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    fm_runway_warn "the captured allowance snapshot at $path is not a regular file"
    return 1
  fi
  mtime=$(fm_runway_file_mtime "$path") || mtime=""
  now=$(date +%s 2>/dev/null) || now=""
  case "$mtime$now" in
    ''|*[!0-9]*)
      fm_runway_warn "the age of the captured allowance snapshot at $path could not be established"
      return 1
      ;;
  esac
  age=$((now - mtime))
  if [ "$age" -lt 0 ] || [ "$age" -gt "$FM_RUNWAY_SNAPSHOT_MAX_AGE" ]; then
    fm_runway_warn "the captured allowance snapshot at $path is not from the last ${FM_RUNWAY_SNAPSHOT_MAX_AGE}s, so it says nothing about the allowance now"
    return 1
  fi
  snapshot=$(cat -- "$path" 2>/dev/null) || {
    fm_runway_warn "the captured allowance snapshot at $path could not be read"
    return 1
  }
  [ -n "$snapshot" ] || {
    fm_runway_warn "the captured allowance snapshot at $path is empty"
    return 1
  }
  printf '%s\n' "$snapshot" | fm_quota_json_valid || {
    fm_runway_warn "the captured allowance snapshot at $path could not be read as allowance data"
    return 1
  }
  FM_RUNWAY_SNAPSHOT_DATA=$snapshot
  return 0
}

# fm_runway_read_snapshot
# Sets FM_RUNWAY_SNAPSHOT_DATA to one strictly read-only, bounded,
# schema-validated quota-axi snapshot, or returns 1 with FM_RUNWAY_WARNING
# naming what could not be read. This sets a variable instead of printing
# precisely so a caller never has to run it in a command substitution, where the
# warning explaining a skipped check would be lost with the subshell.
fm_runway_read_snapshot() {
  local snapshot
  FM_RUNWAY_SNAPSHOT_DATA=""
  command -v jq >/dev/null 2>&1 || {
    fm_runway_warn "jq is not installed, so the remaining allowance cannot be read"
    return 1
  }
  if [ -n "${FM_RUNWAY_SNAPSHOT:-}" ]; then
    fm_runway_captured_snapshot "$FM_RUNWAY_SNAPSHOT"
    return
  fi
  fm_quota_axi_compatible "$FM_RUNWAY_VERSION_TIMEOUT" || {
    fm_runway_warn "quota-axi is missing or older than $FM_QUOTA_AXI_MIN"
    return 1
  }
  snapshot=$(fm_run_timed "$FM_RUNWAY_READ_TIMEOUT" \
    quota-axi --json --no-credential-refresh 2>/dev/null </dev/null) || {
    fm_runway_warn "quota-axi did not report the remaining allowance within ${FM_RUNWAY_READ_TIMEOUT}s"
    return 1
  }
  [ -n "$snapshot" ] || {
    fm_runway_warn "quota-axi reported no allowance data"
    return 1
  }
  printf '%s\n' "$snapshot" | fm_quota_json_valid || {
    fm_runway_warn "quota-axi's allowance report could not be read"
    return 1
  }
  FM_RUNWAY_SNAPSHOT_DATA=$snapshot
  return 0
}

# fm_runway_verdict <provider> <model> [<lane>]
# <lane> is the schema 6 account key from fm_quota_lane. Reads a validated snapshot on stdin and prints one
# "<verdict>|<human evidence>" line. The verdict is `refuse` only for evidence
# that the allowance is already gone, `warn` for evidence that it may not last,
# `ok` for established headroom, and `none` when no applicable known scope
# exists at all.
fm_runway_verdict() {
  local provider=$1 model=${2:-default} lane=${3:-}
  fm_quota_applicable_availability "$provider" "$model" "$lane" | jq -r '
    def describe:
      "\(.scope): " +
      (if (.effectivePercentRemaining | type) == "number"
       then "\(.effectivePercentRemaining)% remaining"
       else "headroom unknown" end) +
      ", runway \(.runway.status // "unknown")" +
      (if (.runway.usableRunwaySeconds | type) == "number"
       then ", about \(.runway.usableRunwaySeconds)s of usable runway left"
       else "" end);
    . as $applicable |
    # Gone: no allowance remains to finish anything on this scope. Any of the
    # three independent spellings quota-axi uses counts, so a vendor that
    # reports only one of them still produces the refusal.
    ($applicable | map(select(
      (.runway.status // "") == "exhausted_now" or
      (.status == "known" and .effectivePercentRemaining == 0) or
      ((.runway.usableRunwaySeconds | type) == "number" and .runway.usableRunwaySeconds == 0)
    )) | first) as $gone |
    ($applicable | map(select(.status == "known"))) as $known |
    if $gone != null then "refuse|" + ($gone | describe)
    elif ($known | length) == 0 then "none|"
    else
      # Established headroom that quota-axi does not expect to last through the
      # reset, or whose runway it cannot place, is a projection: warn, allow.
      ($known | map(select((.runway.status // "unknown") != "through_reset")) | first) as $thin |
      if $thin != null then "warn|" + ($thin | describe)
      else "ok|" + ($known | min_by(.effectivePercentRemaining) | describe)
      end
    end
  ' 2>/dev/null
}

# fm_runway_check <harness> <model>
# Returns 0 to proceed silently, FM_RUNWAY_REFUSE_RC when the allowance this
# spawn would spend is already gone, and any other non-zero value to proceed
# with FM_RUNWAY_WARNING explaining what was not established. On a 0 or refusing
# return, FM_RUNWAY_PROVIDER and FM_RUNWAY_EVIDENCE describe what was measured.
# shellcheck disable=SC2034 # FM_RUNWAY_PROVIDER/EVIDENCE/WARNING are this
# function's out-parameters, read by the sourcing caller (bin/fm-spawn.sh).
fm_runway_check() {
  local harness=$1 model=${2:-default} provider line verdict
  FM_RUNWAY_PROVIDER=""
  FM_RUNWAY_EVIDENCE=""
  FM_RUNWAY_WARNING=""
  [ -n "$model" ] || model=default
  [ -n "$harness" ] || {
    fm_runway_warn "the worker runtime for this launch command could not be identified, so its remaining allowance was not checked"
    return 1
  }
  # The map is keyed on the model as well as the harness because a bridging
  # runtime (omp) spends another vendor's allowance, and which vendor depends on
  # the model. A harness or model pair with no known family is absent evidence,
  # never bad news: warn and allow, like every other unreadable signal.
  provider=$(fm_quota_provider_for_harness "$harness" "$model") || {
    fm_runway_warn "no provider allowance is tracked for the '$harness' worker runtime on model $model"
    return 1
  }
  FM_RUNWAY_PROVIDER=$provider
  fm_runway_read_snapshot || return 1
  line=$(printf '%s\n' "$FM_RUNWAY_SNAPSHOT_DATA" |
    fm_runway_verdict "$provider" "$(fm_quota_scope_model "$harness" "$model")" "$(fm_quota_lane "$harness" "$model")") || line=""
  verdict=${line%%|*}
  FM_RUNWAY_EVIDENCE=${line#*|}
  case "$verdict" in
    refuse) return "$FM_RUNWAY_REFUSE_RC" ;;
    ok) return 0 ;;
    warn)
      # "Might not finish" is deliberately a warning, not a refusal: see the
      # header. The caller says so in the message it prints.
      fm_runway_warn "the remaining $provider allowance may not be enough to finish this work ($FM_RUNWAY_EVIDENCE); this is a projection, not a certainty, so prefer a lower tier that finishes over a higher tier that exhausts"
      return 1
      ;;
    none)
      fm_runway_warn "$provider reports no allowance data for this worker runtime and model"
      return 1
      ;;
    *)
      fm_runway_warn "the remaining $provider allowance could not be established"
      return 1
      ;;
  esac
}
