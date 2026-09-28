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
run = steps.filter_map { |step| step["run"] }.join("\n")
raise "attestation fallback must read the live PR" unless run.include?("pulls/${PR_NUMBER}")
raise "attestation fallback must execute the local verifier" unless run.include?("bin/fm-no-mistakes-attestation.sh")

raise "trusted no_ci declaration is not enabled" unless config["no_ci"] == true
puts "ok"
RUBY
}

test_hosted_workflows_are_manual_fallbacks() {
  workflow_contract >/dev/null || fail "hosted workflow local-validation contract"
  pass "hosted workflows are manual fallbacks and no-mistakes declares zero-check local delivery"
}

test_hosted_workflows_are_manual_fallbacks
