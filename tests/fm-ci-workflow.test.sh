#!/usr/bin/env bash
# Semantic contract tests for hosted workflows after routine validation moved local.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"
ATTESTATION_WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
REPO_CONFIG="$ROOT/.no-mistakes.yaml"

command -v ruby >/dev/null 2>&1 || fail "ruby is required to parse workflow YAML"

workflow_contract() {
  ruby -ryaml -ropen3 - "$CI_WORKFLOW" "$ATTESTATION_WORKFLOW" "$REPO_CONFIG" "$ROOT" <<'RUBY'
ci = YAML.load_file(ARGV[0])
attestation = YAML.load_file(ARGV[1])
config = YAML.load_file(ARGV[2])

def triggers(doc)
  doc.fetch(true) # YAML 1.1 parses the unquoted workflow key `on` as true.
end

ci_triggers = triggers(ci)
raise "CI must be manual-only" unless ci_triggers.keys == ["workflow_dispatch"]
raise "manual CI must not cancel another deliberate dispatch" unless ci.dig("concurrency", "cancel-in-progress") == false

expected_jobs = %w[
  lint test-coverage tests-portable-parallel-1 tests-portable-parallel-2
  tests-portable-serial tests-herdr tests-timing-aggregate macos-stock-bash invariants
].sort
raise "manual CI lost a fallback validation job" unless ci.fetch("jobs").keys.sort == expected_jobs
ci.fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  raise "#{name} has no finite timeout" unless timeout.is_a?(Integer) && timeout.positive?
end
fast = %w[test-coverage invariants tests-timing-aggregate]
normal = %w[lint tests-portable-parallel-1 tests-portable-parallel-2 tests-portable-serial macos-stock-bash]
heavy = %w[tests-herdr]
raise "fast fallback timeout drifted" unless fast.all? { |name| ci.dig("jobs", name, "timeout-minutes") == 5 }
raise "normal fallback timeout drifted" unless normal.all? { |name| ci.dig("jobs", name, "timeout-minutes") == 30 }
raise "heavy fallback timeout drifted" unless heavy.all? { |name| ci.dig("jobs", name, "timeout-minutes") == 75 }
herdr_steps = ci.dig("jobs", "tests-herdr", "steps")
run_step = herdr_steps.find { |step| step["id"] == "run-real-herdr-family" }
cleanup_step = herdr_steps.find { |step| step["id"] == "cleanup-herdr-lab-sessions" }
raise "Herdr step tripwire drifted" unless run_step&.fetch("timeout-minutes", nil) == 20
raise "Herdr cleanup lost always()" unless cleanup_step&.fetch("if", nil) == "always()"

serial = ci.dig("jobs", "tests-portable-serial", "strategy")
raise "serial fallback must report every shard" unless serial["fail-fast"] == false
shards = serial.dig("matrix", "shard")
lanes, status = Open3.capture2(File.join(ARGV[3], "bin/fm-test-run.sh"), "--list-lanes")
raise "cannot list local runner lanes" unless status.success?
actual = lanes.lines.map(&:strip).grep(/\Aportable-serial-\d+of\d+\z/)
expected = shards.map { |shard| "portable-serial-#{shard}of#{shards.length}" }
raise "hosted fallback matrix and local runner disagree" unless actual.sort == expected.sort

attestation_triggers = triggers(attestation)
manual = attestation_triggers.fetch("workflow_dispatch")
input = manual.fetch("inputs").fetch("pull_request")
raise "manual attestation needs a required numeric PR input" unless input["required"] == true && input["type"] == "number"
check = attestation.fetch("jobs").fetch("check")
raise "manual attestation context changed" unless check["name"] == "PR must be raised via no-mistakes"
steps = check.fetch("steps")
checkout = steps.find { |step| step["uses"] == "actions/checkout@v6" }
raise "attestation fallback must check out the trusted default branch" unless checkout&.dig("with", "ref") == "${{ github.event.repository.default_branch }}"

raise "trusted no_ci declaration is not enabled" unless config["no_ci"] == true
puts "ok"
RUBY
}

test_hosted_workflows_are_manual_fallbacks() {
  workflow_contract >/dev/null || fail "hosted workflow local-validation contract"
  pass "hosted workflows are manual fallbacks and no-mistakes declares zero-check local delivery"
}

# Print the manual attestation job's run script, the executable step contract.
attestation_run_script() {
  ruby -ryaml -e '
    steps = YAML.load_file(ARGV[0]).dig("jobs", "check", "steps")
    runs = steps.filter_map { |step| step["run"] }
    raise "expected one run step" unless runs.length == 1
    print runs.first
  ' "$ATTESTATION_WORKFLOW"
}

# A realistic `GET /repos/{owner}/{repo}/pulls/{n}` payload whose body carries
# a no-mistakes attestation bound to attested_head.
write_pull_payload() {
  local file=$1 live_head=$2 attested_head=$3
  jq -n --arg live "$live_head" --arg attested "$attested_head" '{
    url: "https://api.github.com/repos/nissan/firstmate/pulls/36",
    number: 36, state: "open", draft: false,
    title: "feat(bin): add teardown --record-only to retire stale slot records",
    body: ("## Summary\n\nRetire stale slot records.\n\nUpdates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)\n\n<!-- no-mistakes-pipeline-attestation:v1 "
      + ({head_sha: $attested, steps: [
          {step: "review", status: "completed"},
          {step: "test", status: "completed"},
          {step: "document", status: "completed"},
          {step: "lint", status: "completed"}
        ]} | tojson)
      + " -->\n"),
    head: {ref: "fm/teardown-record-only", sha: $live, repo: {full_name: "nissan/firstmate"}},
    base: {ref: "main", sha: "1195692000000000000000000000000000000000", repo: {full_name: "nissan/firstmate"}}
  }' > "$file"
}

run_attestation_step() {
  local case_dir=$1
  (
    cd "$ROOT" || exit 1
    PATH="$case_dir/bin:$PATH" \
    FM_TEST_GH_LOG="$case_dir/gh.log" \
    FM_TEST_PULL_JSON="$case_dir/pull.json" \
    GITHUB_REPOSITORY=nissan/firstmate \
    PR_NUMBER=36 \
    RUNNER_TEMP="$case_dir/runner" \
      bash -e "$case_dir/step.sh"
  ) > "$case_dir/stdout" 2> "$case_dir/stderr"
}

test_manual_attestation_step_verifies_the_live_head_and_body() {
  local tmp case_dir head old rc
  tmp=$(fm_test_tmproot fm-ci-workflow)
  head=537f2bbc95e7f42905cdbc48318514333f02f56d
  old=1111111111111111111111111111111111111111

  for case_dir in "$tmp/current" "$tmp/stale"; do
    mkdir -p "$case_dir/bin" "$case_dir/runner"
    attestation_run_script > "$case_dir/step.sh" || fail "cannot extract the manual attestation step"
    cat > "$case_dir/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
[ "$1 $2" = "api repos/nissan/firstmate/pulls/36" ] || exit 1
cat "$FM_TEST_PULL_JSON"
GH
    chmod +x "$case_dir/bin/gh"
  done

  write_pull_payload "$tmp/current/pull.json" "$head" "$head"
  run_attestation_step "$tmp/current" \
    || fail "manual attestation step refused a body attested to the live head: $(cat "$tmp/current/stderr")"
  grep -qxF "api repos/nissan/firstmate/pulls/36" "$tmp/current/gh.log" \
    || fail "manual attestation step did not read the dispatched pull request"
  grep -qxF "verified no-mistakes local validation at head $head" "$tmp/current/stdout" \
    || fail "manual attestation step did not verify the live head: $(cat "$tmp/current/stdout")"

  write_pull_payload "$tmp/stale/pull.json" "$head" "$old"
  rc=0
  run_attestation_step "$tmp/stale" || rc=$?
  [ "$rc" -ne 0 ] || fail "manual attestation step accepted a body attested to another head"
  grep -qF 'attestation is malformed, stale' "$tmp/stale/stderr" \
    || fail "manual attestation step refused a stale body for the wrong reason: $(cat "$tmp/stale/stderr")"
  pass "the manual attestation step feeds the live pull-request head and body to the verifier"
}

test_hosted_workflows_are_manual_fallbacks
test_manual_attestation_step_verifies_the_live_head_and_body
