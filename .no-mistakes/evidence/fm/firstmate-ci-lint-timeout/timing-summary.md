# fm-lint.test.sh cost: base vs head (same 12-core Linux host, pinned ShellCheck 0.11.0)

| Measurement | Base 6b449e1 | Head 1533015 |
|---|---|---|
| `bash tests/fm-lint.test.sh` wall clock (unloaded) | 1m27.4s (user 2m0.9s) | 13.6s (user 12.3s) |
| Full-root completeness sweep location | inside the suite (Behavior portable parallel 1, 10-min lane cap) | CI Lint job step `bin/fm-lint.sh --check-local-exclusions` (15-min step cap, 60-min job cap) |
| `CI=true GITHUB_ACTIONS=true bin/fm-lint.sh --check-local-exclusions` over the real tree | n/a (flag did not exist) | exit 0, 384 roots, ~60s |

Logs: fm-lint-test-base.log, fm-lint-test-head.log, check-local-exclusions-real-repo.log,
check-local-exclusions-catches-sc2154.log, ci-routing-test-fails-on-base-ci-yml.log,
ci-routing-test-rejects-duplicate-sweep.log
