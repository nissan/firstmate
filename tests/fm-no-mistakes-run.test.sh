#!/usr/bin/env bash
# End-to-end contract for Firstmate's no-mistakes run entrypoint.
# A canonical local-validation repository terminates after local evidence and PR
# publication, while an unrelated hosted-check repository keeps waiting for CI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-no-mistakes-run.sh"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-run)
FAKEBIN="$TMP_ROOT/bin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/no-mistakes" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FM_TEST_ARGS"
found=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip)
      shift
      value=${1:-}
      ;;
    --skip=*) value=${1#--skip=} ;;
    *) value= ;;
  esac
  case ",$value," in *,ci,*) found=true ;; esac
  [ "$#" -gt 0 ] && shift
done
if [ "$found" = true ]; then
  printf 'result: passed\n' > "$FM_TEST_RESULT"
  exit 0
fi
printf 'step: ci\nstatus: pending\n' > "$FM_TEST_RESULT"
exit 23
FAKE
chmod +x "$FAKEBIN/no-mistakes"

make_repo() {
  local name=$1 remote=$2 dir gate
  dir="$TMP_ROOT/$name"
  gate="$TMP_ROOT/$name-gate.git"
  mkdir -p "$dir"
  git init -q "$dir"
  git init -q --bare "$gate"
  git --git-dir="$gate" remote add origin "$remote"
  git -C "$dir" remote add origin "$remote"
  git -C "$dir" remote add no-mistakes "$gate"
  printf '%s\n' "$dir"
}

run_case() {
  local dir=$1
  (
    cd "$dir" || exit 1
    PATH="$FAKEBIN:$PATH" \
      FM_TEST_ARGS="$dir/args" \
      FM_TEST_RESULT="$dir/result" \
      "$RUNNER" --intent 'Fix the delivery defect.'
  )
}

test_canonical_local_validation_repositories_finish_without_hosted_checks() {
  local dir remote
  for remote in \
    https://github.com/nissan/firstmate.git \
    git@github.com:nissan/Work.git
  do
    dir=$(make_repo "local-$(printf '%s' "$remote" | cksum | cut -d' ' -f1)" "$remote")
    run_case "$dir" || fail "$remote: local validation did not reach a terminal success"
    assert_grep 'result: passed' "$dir/result" \
      "$remote: fake pipeline did not observe terminal local completion"
    assert_grep 'axi run --intent Fix the delivery defect. --skip ci' "$dir/args" \
      "$remote: Firstmate did not explicitly omit the absent hosted-check phase"
  done
  pass "canonical local-validation repositories finish after required local evidence"
}

test_hosted_check_repository_keeps_waiting() {
  local dir rc=0
  dir=$(make_repo hosted https://github.com/example/hosted-checks.git)
  run_case "$dir" || rc=$?
  expect_code 23 "$rc" "hosted repository should retain its hosted-check wait"
  assert_grep 'step: ci' "$dir/result" \
    "hosted repository did not remain in its CI phase"
  assert_no_grep '--skip' "$dir/args" \
    "hosted repository inherited the canonical local-validation exception"
  pass "repositories outside the canonical allowlist retain hosted-check waiting"
}

test_mutable_checkout_origin_cannot_broaden_the_policy() {
  local dir rc=0
  dir=$(make_repo forged-origin https://github.com/example/hosted-checks.git)
  git -C "$dir" remote set-url origin https://github.com/nissan/firstmate.git
  run_case "$dir" || rc=$?
  expect_code 23 "$rc" "a checkout-only canonical origin must not omit hosted checks"
  assert_no_grep '--skip' "$dir/args" \
    "the mutable checkout origin broadened the canonical repository policy"
  pass "repository policy follows the initialized gate target, not mutable checkout origin"
}

test_existing_skip_is_extended_without_dropping_it() {
  local dir
  dir=$(make_repo local-existing-skip ssh://git@github.com/nissan/firstmate.git)
  (
    cd "$dir" || exit 1
    PATH="$FAKEBIN:$PATH" \
      FM_TEST_ARGS="$dir/args" \
      FM_TEST_RESULT="$dir/result" \
      "$RUNNER" --intent 'Fix the delivery defect.' --skip rebase
  ) || fail "local validation with an existing skip did not finish"
  assert_grep '--skip rebase,ci' "$dir/args" \
    "the local CI omission replaced the caller's existing skip"
  pass "the canonical CI omission composes with an existing no-mistakes skip"
}

test_canonical_local_validation_repositories_finish_without_hosted_checks
test_hosted_check_repository_keeps_waiting
test_mutable_checkout_origin_cannot_broaden_the_policy
test_existing_skip_is_extended_without_dropping_it
