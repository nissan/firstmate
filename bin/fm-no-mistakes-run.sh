#!/usr/bin/env bash
# Start or reattach to a no-mistakes AXI run under Firstmate's repository policy.
#
# Usage: fm-no-mistakes-run.sh <no-mistakes axi run flags...>
#
# For the exact repositories listed by bin/fm-local-validation-lib.sh, routine
# validation ends after the local pipeline and PR publication, so this wrapper
# adds `--skip ci`. Identity comes from the initialized no-mistakes gate's own
# push target, not the checkout's mutable origin spelling.
# That explicit run input also bootstraps a migration whose
# trusted default-branch .no-mistakes.yaml does not declare no_ci yet. Every
# other repository is forwarded unchanged and therefore keeps its hosted-check
# wait. An existing --skip value is preserved and extended only with ci.
#
# This wrapper changes no review, test, document, lint, push, PR, red-check,
# attestation, merge-authority, or branch-custody behavior. no-mistakes remains
# the owner of those phases and persists the selected skip on the run.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-local-validation-lib.sh
. "$SCRIPT_DIR/fm-local-validation-lib.sh"

command -v git >/dev/null 2>&1 || {
  echo "error: git is required to resolve the validation policy" >&2
  exit 1
}
command -v no-mistakes >/dev/null 2>&1 || {
  echo "error: no-mistakes is required" >&2
  exit 1
}

GATE_REMOTE=$(git remote get-url no-mistakes 2>/dev/null || true)
case "$GATE_REMOTE" in
  file://*) GATE_GIT_DIR=${GATE_REMOTE#file://} ;;
  /*) GATE_GIT_DIR=$GATE_REMOTE ;;
  *) GATE_GIT_DIR= ;;
esac
GATE_TARGET=
if [ -n "$GATE_GIT_DIR" ] && [ -d "$GATE_GIT_DIR" ]; then
  GATE_TARGET=$(git --git-dir="$GATE_GIT_DIR" remote get-url origin 2>/dev/null || true)
fi
if ! fm_local_validation_repo_remote_url "$GATE_TARGET"; then
  exec no-mistakes axi run "$@"
fi

ARGS=()
FOUND_SKIP=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip)
      [ "$#" -ge 2 ] || {
        echo "error: --skip requires a comma-separated value" >&2
        exit 2
      }
      SKIPS=$2
      case ",$SKIPS," in
        *,ci,*) ;;
        *) SKIPS="${SKIPS:+$SKIPS,}ci" ;;
      esac
      ARGS+=(--skip "$SKIPS")
      FOUND_SKIP=true
      shift 2
      ;;
    --skip=*)
      SKIPS=${1#--skip=}
      case ",$SKIPS," in
        *,ci,*) ;;
        *) SKIPS="${SKIPS:+$SKIPS,}ci" ;;
      esac
      ARGS+=("--skip=$SKIPS")
      FOUND_SKIP=true
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [ "$FOUND_SKIP" = false ]; then
  ARGS+=(--skip ci)
fi
exec no-mistakes axi run "${ARGS[@]}"
