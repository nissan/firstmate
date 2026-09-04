#!/usr/bin/env bash
# Deterministic public-contract regression for /pause-and-learn plan output.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/.agents/skills/pause-and-learn/plan-check.py"
FIXTURES="$ROOT/tests/fixtures/pause-and-learn-plan"

accept() {
  local fixture=$1 message=$2
  shift 2
  python3 "$CHECK" validate "$FIXTURES/$fixture" "$@" || fail "$message"
}

reject() {
  local fixture=$1 message=$2
  shift 2
  if python3 "$CHECK" validate "$FIXTURES/$fixture" "$@" > /dev/null 2>&1; then
    fail "$message"
  fi
}

accept control.txt "canonical plan was rejected" false next-tranche
accept reordered-wrapped.txt "semantically identical reordered and wrapped plan was rejected" \
  true next-tranche

reject unsafe-start.txt "a plan that starts the queued tranche was accepted" false next-tranche
reject control.txt "a fresh-cycle plan satisfied an existing-cycle expectation" true next-tranche
reject negated-boolean.txt "a numeric zero passed as a mutation flag" false next-tranche
reject stringified-boolean.txt "a stringified boolean passed as a safety flag" false next-tranche
reject duplicate-block.txt "a second contradicting plan block was accepted" false next-tranche
reject malformed-json.txt "an unparseable plan block was accepted" false next-tranche
reject missing-block.txt "prose alone satisfied the machine-readable contract" false next-tranche
pass "plan contract accepts ordering and wording variants while rejecting unsafe and malformed plans"

accept no-queued.txt "the documented empty queue was rejected" false
accept multi-queued.txt "the documented multi-tranche queue was rejected" false next-tranche
accept multi-queued.txt "a queued tranche past the first was unreachable" false later-tranche

reject no-queued.txt "an empty queue satisfied a named downstream tranche" false next-tranche
reject control.txt "a queued tranche was accepted where none should exist" false
reject multi-queued.txt "an unqueued identity was accepted" false absent-tranche
reject duplicate-queued.txt "two tranches shared one durable identity" false next-tranche
reject unsafe-second-queued.txt "a later tranche marked to start was accepted" false next-tranche
reject malformed-queued.txt "a later tranche with no paused state or resume authority was accepted" \
  false next-tranche
pass "every queued tranche is validated for zero, one, and many downstream items"

accept boundary-terminal-change.txt "a terminal completed change was rejected" false next-tranche
accept boundary-review-ready.txt "a green review-ready change was rejected" false next-tranche
accept boundary-investigation-report.txt "a completed investigation report was rejected" false next-tranche
accept boundary-external-wait.txt "a documented external wait was rejected" false next-tranche

reject boundary-unknown-kind.txt "a boundary outside the documented vocabulary was accepted" \
  false next-tranche
reject boundary-terminal-awaits-stage.txt "a terminal change claimed to await an active stage" \
  false next-tranche
reject boundary-review-ready-names-stage.txt "a review-ready change named an active stage" \
  false next-tranche
reject boundary-report-interrupts.txt "an investigation-report boundary interrupted the current stage" \
  false next-tranche
reject boundary-external-wait-unnamed.txt "an external wait with no named boundary was accepted" \
  false next-tranche
reject boundary-stage-not-awaited.txt "a post-current-stage boundary awaited no stage" \
  false next-tranche
pass "each documented boundary kind carries its own invariants"

reject blank-resume-phase.txt "a resumed cycle named no phase at all" true next-tranche
reject direct-project-write.txt "Firstmate was allowed to write the project directly" \
  false next-tranche
reject missing-component.txt "a plan that drops a learning component was accepted" false next-tranche
reject brain-canonical-write.txt "a canonical Shared Brain write was accepted" false next-tranche
reject brain-promoted-status.txt "promoted Shared Brain status was accepted" false next-tranche
reject sequencing-backfilled.txt "a backfilled historical review gate was accepted" \
  false next-tranche

for flag in merge sign approve promote discard destructive security-sensitive semantic-expansion; do
  reject "authority-$flag.txt" "the plan claimed $flag authority" false next-tranche
done
pass "routing, components, brain status, every authority boolean, and sequencing are enforced"
