# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic, the
# --json snapshot validator, and the provider-row join dispatch consumers use.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.
#
# Snapshot schemas: fm_quota_json_valid accepts quota-axi schema 5 (one row per
# provider, no accountKey) and schema 6 (every row carries accountKey, unique on
# provider + accountKey; quota-axi emits it once any provider expands to more
# than one account). Schema 5 keeps its exact pre-schema-6 rules so an older
# quota-axi keeps working unchanged. FM_QUOTA_ROW_JQ is the one join used to
# bind a candidate to its row under either schema.
#
# It is also the single owner of the reading rules every consumer of a
# quota-axi snapshot needs and must agree on: which provider family a firstmate
# harness spends against, which account lane it binds to, and which
# availability scopes apply to one harness/model tuple. bin/fm-quota-choose.sh
# (worker-side candidate ranking) and bin/fm-runway-lib.sh (the spawn-side
# runway gate) reach opposite kinds of verdict from the same evidence, so the
# rules live here rather than in either of them.

FM_QUOTA_AXI_MIN=0.1.51
FM_QUOTA_PROVIDER_ID_RE='^[a-z0-9]+(-[a-z0-9]+)*\z'

# The eligibility section of .agents/skills/quota-array-dispatch/SKILL.md
# owns the account-matching contract these jq definitions implement.
# Prepend them to a consumer's program:
#   quota_lane($harness; $model)   the candidate's account key, or "" when none
#                                  is identified by the contract.
#   quota_row($snapshot; $provider; $lane)
#                                  the one provider row the candidate binds to,
#                                  or null; schema 5 ignores $lane.
# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_QUOTA_ROW_JQ='
  def quota_lane($harness; $model):
    if $harness == "codex" then "codex-home"
    elif ($harness == "pi" or $harness == "pi-signed") and (($model // "") | contains("/"))
    then ($model | split("/") | first | if . == "codex-native" then "codex-home" else . end)
    else "" end;
  def quota_row($snapshot; $provider; $lane):
    ([$snapshot.providers[]? | select(.provider == $provider)]) as $rows |
    if $snapshot.schemaVersion == 6 then
      (([$rows[] | select(.accountKey == $lane)] | first) //
       ([$rows[] | select(.accountKey == "default")] | first) // null)
    else ($rows | first) // null
    end;
'

# fm_quota_axi_version_compatible <version-output>
# True when the printed `quota-axi --version` text meets FM_QUOTA_AXI_MIN.
# Callers that already captured a bounded --version pass that text here so they
# do not launch a second, unbounded version probe.
fm_quota_axi_version_compatible() {
  local output=${1-} parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_quota_axi_compatible() {
  local timeout=${1:-} output
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    [ "$(type -t fm_run_timed)" = function ] || return 1
    output=$(fm_run_timed "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  fm_quota_axi_version_compatible "$output"
}

fm_quota_json_valid() {
  jq -se --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
    length == 1 and
    (.[0] | type) == "object" and
    (.[0] |
      (.providers | type) == "array" and
      (if .schemaVersion == 5 then
         (([.providers[].provider] | length) == ([.providers[].provider] | unique | length))
       elif .schemaVersion == 6 then
         all(.providers[];
           (.accountKey | type) == "string" and
           (.accountKey | length) > 0 and
           ((.accountKey | test("\\s")) | not)) and
         (([.providers[] | [.provider, .accountKey]] | length) ==
          ([.providers[] | [.provider, .accountKey]] | unique | length))
       else false
       end) and
      all(.providers[];
      (.provider | type) == "string" and
      (.provider | test($provider_re)) and
      (.quotaSemantics | type) == "object" and
      (.quotaSemantics.status as $semantics_status |
        (["known", "partial", "unknown"] | index($semantics_status)) != null and
        (.quotaSemantics.effectiveAvailability | type) == "array" and
        (if $semantics_status == "known" then
           ((.quotaSemantics.effectiveAvailability | length) > 0 and
            all(.quotaSemantics.effectiveAvailability[];
              .status == "known" or .status == "unknown"
            ))
         elif $semantics_status == "unknown" then
           all(.quotaSemantics.effectiveAvailability[]; .status == "unknown")
         else true
         end) and
        all(.quotaSemantics.effectiveAvailability[];
          type == "object" and
          (.scope | type) == "string" and
          (.scope | length) > 0 and
          ((.scope | test("^\\s|\\s$")) | not) and
          ((.status == "known" and
            (.runway.status as $runway_status |
            ((.effectivePercentRemaining | type) == "number" and
             .effectivePercentRemaining >= 0 and
             .effectivePercentRemaining <= 100 and
             (.runway | type) == "object" and
             ($runway_status | type) == "string" and
             (["through_reset", "projected_exhaustion", "exhausted_now", "unknown"] |
               index($runway_status)) != null))) or
           (.status == "unknown" and
            (has("effectivePercentRemaining") | not) and
            ((has("runway") | not) or
             ((.runway | type) == "object" and
              (.runway.status as $unknown_runway_status |
               (["unknown", "exhausted_now"] | index($unknown_runway_status)) != null)))))
        )
      )
    )
    )
  ' >/dev/null 2>&1
}

fm_quota_single_provider_table() {
  printf '%s\n' \
    'claude claude' \
    'codex codex' \
    'grok grok' \
    'kimi kimi' \
    'cursor cursor' \
    'agy agy' \
    'muse meta'
}

# Reads the whole table before answering: leaving the loop early closes the
# pipe mid-write, and where SIGPIPE is ignored the writer prints a broken-pipe
# error on stderr.
fm_quota_single_provider_for_harness() {
  local harness provider found=''
  while read -r harness provider; do
    [ -z "$found" ] && [ "$harness" = "$1" ] && found=$provider || :
  done < <(fm_quota_single_provider_table)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# fm_quota_provider_for_harness <harness> [<model>]
# Map a firstmate harness name to the quota-axi provider family it spends
# against. Multi-provider harnesses (Pi, OpenCode) map to their PRIMARY family
# only: a candidate whose established provider differs from that family is
# checked against the wrong row. omp has no family of its own - it bridges to
# another vendor - so it is keyed on the candidate model prefix instead, and any
# other prefix has no known family. Authoritative multi-provider routing is
# owned by AGENTS.md section 4 and the quota-array-dispatch skill, not by this
# map. Returns 1 for a harness with no known family, which every caller must
# treat as absent evidence rather than as bad news about the allowance.
fm_quota_provider_for_harness() {
  case "$1" in
    omp)
      case "${2:-}" in
        openai-codex/*)  printf 'codex\n' ;;
        claude-bridge/*) printf 'claude\n' ;;
        *)               return 1 ;;
      esac
      ;;
    claude)       printf 'claude\n' ;;
    codex)        printf 'codex\n' ;;
    opencode)     printf 'codex\n' ;;
    pi|pi-signed) printf 'pi\n' ;;
    grok)         printf 'grok\n' ;;
    kimi)         printf 'kimi\n' ;;
    cursor)       printf 'cursor\n' ;;
    muse)         printf 'meta\n' ;;
    *)            return 1 ;;
  esac
}

# fm_quota_scope_model <harness> <model>
# Print the model token to match quota-axi scopes against for that harness. Only
# omp differs: its candidate models carry a routing prefix (`openai-codex/gpt-5`)
# that quota-axi's own scopes never use, so the prefix is stripped and the
# vendor's own model name is what gets matched. Every other harness names its
# model the same way quota-axi does.
fm_quota_scope_model() {
  case "$1" in
    omp) printf '%s\n' "${2#*/}" ;;
    *)   printf '%s\n' "${2:-}" ;;
  esac
}

# fm_quota_lane <harness> <model>
# Print the schema 6 account key the candidate binds to (quota_lane in
# FM_QUOTA_ROW_JQ), or an empty line when the contract identifies none.
fm_quota_lane() {
  jq -rn --arg h "$1" --arg m "${2:-}" "$FM_QUOTA_ROW_JQ"'quota_lane($h; $m)'
}

# fm_quota_applicable_availability <provider> <model> [<lane>]
# Reads one validated snapshot on stdin and prints the JSON array of
# availability entries that BIND a spawn on that provider/model tuple: the
# provider-wide scopes plus the exact model or product scope for that model. The
# row is bound through quota_row, so <lane> matters only on a schema 6 snapshot.
# A `default` or empty model matches the provider-wide scopes only, and an
# unknown provider yields an empty array - absent evidence, not good news.
fm_quota_applicable_availability() {
  local provider=$1 model=${2:-default} lane=${3:-}
  jq -c --arg provider "$provider" --arg model "$model" --arg lane "$lane" "$FM_QUOTA_ROW_JQ"'
    ($model | sub("^model:"; "")) as $model_token |
    quota_row(.; $provider; $lane) as $p |
    if ($p // null) == null then []
    else ($p.quotaSemantics.effectiveAvailability // []) |
      map(select(.scope as $scope |
        $scope == "all_models" or $scope == "all_products" or
        ($model_token != "" and $model_token != "default" and
         (($scope | startswith("model:")) or ($scope | startswith("product:"))) and
         ($model_token == ($scope | sub("^(model|product):"; ""))))
      ))
    end
  ' 2>/dev/null
}
