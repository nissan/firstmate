#!/usr/bin/env bash
# Render the primary-harness supervision operating block for session start and
# the short repair line used by guards and turn-end hooks. On a non-Pi primary
# with a supervision protocol (claude, cursor, opencode, omp, grok, codex, agy) whose
# home runs the supervision host (fm_supervision_host_enabled in
# bin/fm-supervision-engine-lib.sh: by default on Claude, by
# config/supervision-host elsewhere, never with config/supervision-host-off), the block
# adds one state line and the host's main-side protocol
# (docs/supervision-protocols/supervision-host.md, whose lines tagged
# "{<harness>,...} " render only for the listed harnesses), and Grok's arm
# command becomes the host; on a home that does not run it the output is
# unchanged.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$REPO_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DOC_DIR="$REPO_ROOT/docs/supervision-protocols"

HARNESS=
READ_ONLY=0
AFK=0
AFK_MODE=away
X_MODE=0
REPAIR_LINE=0
QUEUE_PENDING=0
ACQUIRED_LOCK_PID=

usage() {
  cat <<'EOF'
Usage: fm-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--afk 0|1] [--afk-mode away|quiet] [--x-mode 0|1] [--repair-line] [--queue-pending 0|1] [--acquired-lock-pid <pid>]

Print the current primary harness's supervision operating instructions.
--acquired-lock-pid carries the exact owner pid a successful fm-lock.sh call
just returned to the composing session-start process; it is accepted as this
session's identity only while live lock status still names that same pid.
With --repair-line, print one concise repair instruction for guard and hook messages.
--afk-mode only matters when --afk 1 (present); it selects the away-mode vs
quiet-mode (kunchenguid/firstmate#2356) wording, and defaults to away.
EOF
}

bool_value() {
  case "$1" in
    1|true|TRUE|yes|YES) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      [ "$#" -gt 1 ] || { echo "error: --harness requires a value" >&2; exit 2; }
      HARNESS=$2
      shift 2
      ;;
    --read-only)
      [ "$#" -gt 1 ] || { echo "error: --read-only requires 0 or 1" >&2; exit 2; }
      READ_ONLY=$(bool_value "$2")
      shift 2
      ;;
    --afk)
      [ "$#" -gt 1 ] || { echo "error: --afk requires 0 or 1" >&2; exit 2; }
      AFK=$(bool_value "$2")
      shift 2
      ;;
    --afk-mode)
      [ "$#" -gt 1 ] || { echo "error: --afk-mode requires away or quiet" >&2; exit 2; }
      case "$2" in
        away|quiet) AFK_MODE=$2 ;;
        *) AFK_MODE=away ;;
      esac
      shift 2
      ;;
    --x-mode)
      [ "$#" -gt 1 ] || { echo "error: --x-mode requires 0 or 1" >&2; exit 2; }
      X_MODE=$(bool_value "$2")
      shift 2
      ;;
    --queue-pending)
      [ "$#" -gt 1 ] || { echo "error: --queue-pending requires 0 or 1" >&2; exit 2; }
      QUEUE_PENDING=$(bool_value "$2")
      shift 2
      ;;
    --repair-line)
      REPAIR_LINE=1
      shift
      ;;
    --acquired-lock-pid)
      [ "$#" -gt 1 ] || { echo "error: --acquired-lock-pid requires a pid" >&2; exit 2; }
      case "$2" in
        ''|*[!0-9]*) echo "error: --acquired-lock-pid requires a numeric pid" >&2; exit 2 ;;
        *) ACQUIRED_LOCK_PID=$2 ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$HARNESS" ]; then
  HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
fi

case "$HARNESS" in
  claude|codex|opencode|pi|grok|cursor|omp|agy) SNIPPET="$DOC_DIR/$HARNESS.md" ;;
  pi-signed) SNIPPET="$DOC_DIR/pi.md" ;;
  *) HARNESS=unknown; SNIPPET="$DOC_DIR/unknown.md" ;;
esac
[ -f "$SNIPPET" ] || SNIPPET="$DOC_DIR/unknown.md"
HOST_SNIPPET=
grok_arm='bin/fm-watch-arm.sh'
case "$HARNESS" in
  claude|cursor|opencode|omp|grok|codex|agy)
    # shellcheck source=bin/fm-supervision-engine-lib.sh
    . "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
    if fm_supervision_host_enabled "$CONFIG" "$HARNESS"; then
      HOST_SNIPPET="$DOC_DIR/supervision-host.md"
      grok_arm='bin/fm-supervision-host.sh park'
    fi
    ;;
esac

checkpoint_seconds=${FM_CODEX_WATCH_CHECKPOINT:-180}
pi_ext="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
pi_turnend_ext="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
omp_ext="$FM_ROOT/.omp/extensions/fm-primary-omp-watch.ts"
omp_turnend_ext="$FM_ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
x_mode_env="$CONFIG/x-mode.env"

# True when the active home is not the firstmate checkout: omp's extensions load
# from the checkout, and only the `fm <project>` launcher points them at another home.
omp_home_elsewhere=0
if [ "$(cd -P "$FM_HOME" 2>/dev/null && pwd -P || printf '%s' "$FM_HOME")" != "$(cd -P "$FM_ROOT" 2>/dev/null && pwd -P || printf '%s' "$FM_ROOT")" ]; then
  omp_home_elsewhere=1
fi
# shellcheck disable=SC2016  # backticks are literal markdown in the rendered text
if [ "$omp_home_elsewhere" -eq 1 ]; then
  omp_restart_long='exit omp and relaunch through `fm <project>`, which sets FM_HOME and --cwd; a bare omp or /resume from the firstmate checkout does not register the extensions for this home'
  omp_restart_short='exit omp and relaunch through `fm <project>`'
else
  omp_restart_long="restart omp inside this home; pass \`-e $omp_turnend_ext -e $omp_ext\` only when omp must start from another directory, because omp loads a file named both ways twice"
  omp_restart_short='restart omp inside this home'
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

x_mode_env_sh=$(shell_quote "$x_mode_env")

if [ "$X_MODE" -eq 0 ] && [ -f "$x_mode_env" ]; then
  X_MODE=1
fi

render_snippet() {  # [snippet]
  local line tags snippet=${1:-$SNIPPET}
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '{'*'} '*)
        tags=${line%%\} *}
        tags=${tags#\{}
        case ",$tags," in *",$HARNESS,"*) ;; *) continue ;; esac
        line=${line#*\} }
        ;;
    esac
    line=${line//__FM_PI_EXT__/$pi_ext}
    line=${line//__FM_PI_TURNEND_EXT__/$pi_turnend_ext}
    line=${line//__FM_OMP_RESTART_LONG__/$omp_restart_long}
    line=${line//__FM_OMP_RESTART_SHORT__/$omp_restart_short}
    line=${line//__FM_OMP_EXT__/$omp_ext}
    line=${line//__FM_OMP_TURNEND_EXT__/$omp_turnend_ext}
    line=${line//__FM_X_MODE_ENV_SH__/$x_mode_env_sh}
    line=${line//__FM_X_MODE_ENV__/$x_mode_env}
    line=${line//__FM_GROK_ARM__/$grok_arm}
    printf '%s\n' "$line"
  done < "$snippet"
}

repair_line() {
  if [ "$READ_ONLY" -eq 1 ]; then
    printf '%s\n' 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
    return 0
  fi
  if [ "$AFK" -eq 1 ]; then
    if [ "$AFK_MODE" = quiet ]; then
      printf '%s\n' 'Quiet mode owns watcher supervision; load /quiet and ensure the daemon is running instead of starting normal supervision directly.'
    else
      printf '%s\n' 'Away mode owns watcher supervision; load /afk and ensure the daemon is running instead of starting normal supervision directly.'
    fi
    return 0
  fi

  prefix=
  if [ "$QUEUE_PENDING" -eq 1 ]; then
    prefix='After draining queued wakes, '
  fi
  if [ "$X_MODE" -eq 1 ]; then
    prefix="${prefix}source ${x_mode_env_sh} first, then "
  fi

  case "$HARNESS" in
    claude)
      printf '%s%s\n' "$prefix" 'watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.'
      ;;
    codex)
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds ' "$checkpoint_seconds" '.'
      ;;
    pi|pi-signed)
      printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the Pi tool fm_watch_arm_pi, or restart Pi with -e ' "$pi_turnend_ext" ' -e ' "$pi_ext" ' if the extensions are not loaded.'
      ;;
    omp)
      # shellcheck disable=SC2016  # backticks are literal markdown in the rendered text
      if [ "$omp_home_elsewhere" -eq 1 ]; then
        printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the omp tool fm_watch_arm_omp, or exit omp and relaunch through `fm <project>` (the launcher sets FM_HOME and --cwd) so ' "$omp_turnend_ext" ' and ' "$omp_ext" ' load for this home; a bare omp or /resume from the firstmate checkout does not register the extensions for this home.'
      else
        printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the omp tool fm_watch_arm_omp, or restart omp inside this home so ' "$omp_turnend_ext" ' and ' "$omp_ext" ' auto-load from .omp/extensions/ (use -e with both paths only when starting omp from another directory).'
      fi
      ;;
    opencode)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision by letting the OpenCode TUI plugin arm after idle; use bin/fm-watch-arm.sh only as a manual recovery probe if the plugin reports failure.'
      ;;
    grok)
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with ' "$grok_arm" ' as its own Grok tracked background task, never shell &.'
      ;;
    cursor)
      printf '%s%s\n' "$prefix" 'watcher supervision is owned by the stop-hook park; inspect the hook registration and watcher startup path before ending the turn.'
      ;;
    agy)
      if [ -n "$HOST_SNIPPET" ]; then
        printf '%s%s\n' "$prefix" 'supervision is owned by the Stop-hook park (.agents/hooks.json -> bin/fm-turnend-guard-agy.sh running the supervision host); inspect the hook registration and supervision host startup path before ending the turn.'
      else
        printf '%s%s\n' "$prefix" 'watcher supervision is owned by the Stop-hook park (.agents/hooks.json -> bin/fm-turnend-guard-agy.sh); inspect the hook registration and watcher startup path before ending the turn.'
      fi
      ;;
    *)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision according to the session-start block for this harness; do not use shell &.'
      ;;
  esac
}

ordinary_wake_line() {
  case "$HARNESS" in
    claude)
      printf '%s\n' '- Ordinary wake: the Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    codex)
      printf '%s\n' '- Ordinary wake: take the next foreground bin/fm-watch-checkpoint.sh checkpoint as directed below.'
      ;;
    pi|pi-signed)
      printf '%s\n' '- Ordinary wake: the Pi extension already owns watcher continuity; do not arm another cycle.'
      ;;
    omp)
      printf '%s\n' '- Ordinary wake: the omp extension already owns watcher continuity; do not arm another cycle.'
      ;;
    opencode)
      printf '%s\n' '- Ordinary wake: the OpenCode TUI plugin already owns watcher continuity; do not arm manually.'
      ;;
    grok)
      printf '%s%s%s\n' '- Ordinary wake: re-arm exactly one ' "$grok_arm" ' Grok tracked background task as directed below.'
      ;;
    cursor)
      printf '%s\n' '- Ordinary wake: the stop-hook park (bin/fm-turnend-guard-cursor.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    agy)
      printf '%s\n' '- Ordinary wake: the Stop-hook park (bin/fm-turnend-guard-agy.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    *)
      printf '%s\n' '- Ordinary wake: follow the continuation in the harness protocol below; do not use shell &.'
      ;;
  esac
}

# The "Lock:" stanza reflects bin/fm-lock.sh status plus either the exact owner
# pid returned to the composing session-start process by its successful lock
# acquisition or this renderer process's own harness ancestry. --read-only 1 is
# the session-start refusal and always wins. The explicit pid is accepted only
# while live lock status still names it, so it cannot override a changed lock.
# Without that acquisition evidence, "held by this session" is printed only
# when the recorded owner is in THIS process's harness ancestry. A lock held by
# another live harness (the 2026-09-10 case: a Codex
# app-server owning the home a Claude session was started in) renders as
# foreign, and a free or stale lock says so, because a session that reads
# "held by this session" while it is not the owner will try to repair
# supervision it cannot repair.
lock_line() {
  local status lock_pid
  if [ "$READ_ONLY" -eq 1 ]; then
    printf '%s\n' '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
    return 0
  fi
  if [ ! -d "$STATE" ]; then
    status='lock: free'
  else
    status=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lock.sh" status 2>/dev/null) || status=''
  fi
  case "$status" in
    'lock: held by live harness pid '*)
      lock_pid=${status##* }
      # The session-start caller's freshly acquired identity avoids re-walking
      # from this renderer's deeper helper stack, while the status equality
      # prevents stale evidence from claiming a lock that changed afterward.
      # shellcheck source=bin/fm-session-lock-lib.sh
      if [ -n "$ACQUIRED_LOCK_PID" ] && [ "$lock_pid" = "$ACQUIRED_LOCK_PID" ]; then
        printf '%s\n' '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
      elif [ -f "$SCRIPT_DIR/fm-session-lock-lib.sh" ] && [ -f "$SCRIPT_DIR/fm-cursor-lib.sh" ] \
        && ( . "$SCRIPT_DIR/fm-session-lock-lib.sh" && fm_session_lock_owned_by_self "$STATE" ) 2>/dev/null; then
        printf '%s\n' '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
      elif [ ! -f "$SCRIPT_DIR/fm-session-lock-lib.sh" ] || [ ! -f "$SCRIPT_DIR/fm-cursor-lib.sh" ]; then
        printf -- '- Lock: held by live harness pid %s, ownership unverifiable (identity library missing); treat this session as not owning supervision until verified.\n' "${status##* }"
      else
        printf -- '- Lock: held by another live session (pid %s); that session owns supervision here - operate read-only and do not drain, arm, spawn, steer, merge, or repair fleet state.\n' "${status##* }"
      fi
      ;;
    'lock: free')
      printf '%s\n' '- Lock: free; this session has not acquired the fleet lock, so it does not own supervision until bin/fm-lock.sh succeeds.'
      ;;
    'lock: stale'*)
      printf -- '- Lock: %s; this session does not own supervision until bin/fm-lock.sh reclaims it.\n' "${status#lock: }"
      ;;
    *)
      printf '%s\n' '- Lock: status unknown (bin/fm-lock.sh status unavailable); treat this session as not owning supervision until verified.'
      ;;
  esac
}

if [ "$REPAIR_LINE" -eq 1 ]; then
  repair_line
  exit 0
fi

RULE='================================================================================'
printf '%s\n' "$RULE"
printf 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: %s\n' "$HARNESS"
printf '%s\n' "$RULE"
printf 'Current state:\n'
lock_line
if [ "$AFK" -eq 1 ]; then
  if [ "$AFK_MODE" = quiet ]; then
    printf '%s\n' '- Quiet mode: active; load /quiet and keep normal harness supervision paused while the daemon owns the watcher. Ordinary captain chat does NOT exit it - only an explicit /quiet off does.'
  else
    printf '%s\n' '- Away mode: active; load /afk and keep normal harness supervision paused while the daemon owns the watcher.'
  fi
else
  printf '%s\n' '- Away/quiet mode: inactive.'
fi
if [ "$X_MODE" -eq 1 ]; then
  printf '%s%s%s\n' '- X mode: active; source ' "$x_mode_env" ' before launching any watcher process so the 30s cadence is inherited.'
else
  printf '%s\n' '- X mode: inactive; use the default watcher cadence.'
fi
if [ -n "$HOST_SNIPPET" ]; then
  printf '%s\n' '- Supervision host: on; it takes away-posture wakes and, where the dialog mirror is verified, eligible attended wakes itself, and hands the rest to you (protocol at the end of this block).'
fi
ordinary_wake_line
printf '\n'
render_snippet
printf '\n'
if [ -n "$HOST_SNIPPET" ]; then
  render_snippet "$HOST_SNIPPET"
  printf '\n'
fi
