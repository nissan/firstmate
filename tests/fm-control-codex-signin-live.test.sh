#!/usr/bin/env bash
# Token-free Codex sign-in exit against an isolated real Herdr endpoint.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CONTROL_CODEX_SIGNIN_LIVE codex herdr jq

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
D=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-signin.XXXXXX") || exit 1
FM_HOME="$D/fm"; export FM_HOME
"$HOME_HELPER" create "$FM_HOME" >/dev/null || exit 1
T=$("$HOME_HELPER" tmux-dir "$FM_HOME") || exit 1
S=$("$LAB_HELPER" name codex-signin) || exit 1
ready=0
cleanup() {
  local rc=$?
  trap - EXIT
  TMUX_TMPDIR="$T" tmux kill-server 2>/dev/null || true
  "$HOME_HELPER" teardown "$FM_HOME" || rc=1
  if [ "$ready" = 1 ]; then "$LAB_HELPER" teardown "$S" || rc=1; fi
  rm -rf "$D"
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$S" || fail 'cannot provision isolated Herdr session'
ready=1
lab() { "$LAB_HELPER" run "$S" "$@"; }
X=$(lab workspace create --cwd "$D" --label fm-codex-signin --no-focus) || fail 'workspace creation failed'
P=$(printf '%s' "$X" | jq -er '.result.root_pane.pane_id') || fail 'missing pane'
W=$(printf '%s' "$X" | jq -er '.result.workspace.workspace_id') || fail 'missing workspace'
TAB=$(printf '%s' "$X" | jq -er '.result.tab.tab_id') || fail 'missing tab'
mkdir -p "$D/codex" "$D/user" "$D/bin" "$FM_HOME/data/signin"
cat > "$D/bin/herdr" <<'SH'
#!/usr/bin/env bash
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  if [ "${args[i]}" = --session ]; then
    [ "${args[i+1]:-}" = "$LAB_SESSION" ] || exit 1
    unset 'args[i]' 'args[i+1]'
    args=("${args[@]}")
    break
  fi
done
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "${args[@]}"
SH
chmod +x "$D/bin/herdr"
export LAB_SESSION="$S" LAB_HELPER ORIGINAL_PATH="$PATH" HERDR_SESSION="$S"
VERSION=$(codex --version)
lab pane run "$P" "env -i HOME=$D/user CODEX_HOME=$D/codex PATH=$PATH TERM=xterm-256color codex --no-daemon" >/dev/null || fail "$VERSION: launch failed"
# Poll the real viewport without answering any onboarding prompt.
for _ in $(seq 1 50); do
  screen=$(lab pane read "$P" --source visible 2>/dev/null) || screen=
  case "$screen" in *'Press enter to continue'*) break ;; esac
  sleep 0.2
done
printf 'window=%s:%s\nendpoint_task_id=signin\nworktree=%s\nproject=%s\nharness=codex\nkind=ship\nmode=local-only\nyolo=off\nbackend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' "$S" "$P" "$D" "$D" "$S" "$W" "$TAB" "$P" > "$FM_HOME/state/signin.meta"
# Herdr publishes process identity asynchronously after the screen appears.
sleep 4
out=$(PATH="$D/bin:$PATH" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=5 "$ROOT/bin/fm-control.sh" signin exit 2>&1) || fail "$VERSION: sign-in exit refused: $out"
case "$out" in 'stopped signin '*) ;; *) fail "$VERSION: unexpected exit outcome: $out" ;; esac
lab pane get "$P" >/dev/null || fail "$VERSION: endpoint was removed"
pass "$VERSION: sign-in exits while the endpoint survives"
