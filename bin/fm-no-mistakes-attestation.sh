#!/usr/bin/env bash
# Verify the no-mistakes attestation carried in a pull-request body.
#
# This is the local replacement for the former automatic hosted compliance
# workflow. The body is read from standard input and must contain exactly one
# no-mistakes v1 attestation plus its pipeline signature. The attestation must
# bind to the supplied full Git head and report every locally authoritative
# phase as completed. A skipped, missing, duplicated, or stale phase refuses.
#
# Usage: fm-no-mistakes-attestation.sh <40-or-64-hex-head> < pr-body.md
#
# The caller must obtain both the head and body from one live forge read when
# using this as a merge gate. This command validates bytes; it does not fetch a
# pull request or grant merge authority.
set -eu

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'no-mistakes attestation: %s\n' "$*" >&2
  exit 1
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
HEAD_SHA=$1
case "$HEAD_SHA" in
  ''|*[!0-9a-fA-F]*) die "head must be a full hexadecimal commit id" ;;
esac
[ "${#HEAD_SHA}" -eq 40 ] || [ "${#HEAD_SHA}" -eq 64 ] \
  || die "head must be a full 40- or 64-character commit id"
HEAD_SHA_NORMALIZED=$(printf '%s' "$HEAD_SHA" | tr 'A-F' 'a-f')
command -v jq >/dev/null 2>&1 || die "jq is required"

SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
PREFIX='<!-- no-mistakes-pipeline-attestation:v1 '
SUFFIX=' -->'
BODY=$(cat)
signatures=$(printf '%s\n' "$BODY" | grep -Fxc "$SIGNATURE" || true)
[ "$signatures" -eq 1 ] || die "expected exactly one no-mistakes pipeline signature, found $signatures"

markers=0
ATTESTATION=
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "$PREFIX"*"$SUFFIX")
      markers=$((markers + 1))
      [ "$markers" -eq 1 ] || continue
      ATTESTATION=${line#"$PREFIX"}
      ATTESTATION=${ATTESTATION%"$SUFFIX"}
      ;;
  esac
done <<EOF
$BODY
EOF
[ "$markers" -eq 1 ] || die "expected exactly one no-mistakes v1 attestation, found $markers"

# Explicit per-phase counts keep the contract legible and reject duplicate
# phase rows as well as missing or skipped work.
if ! printf '%s' "$ATTESTATION" | jq -e --arg head "$HEAD_SHA_NORMALIZED" '
  type == "object"
  and ((.head_sha // "") | ascii_downcase) == $head
  and (.steps | type) == "array"
  and ([.steps[] | .step] | length) == ([.steps[] | .step] | unique | length)
  and ([.steps[] | select(.step == "review" and .status == "completed")] | length) == 1
  and ([.steps[] | select(.step == "test" and .status == "completed")] | length) == 1
  and ([.steps[] | select(.step == "document" and .status == "completed")] | length) == 1
  and ([.steps[] | select(.step == "lint" and .status == "completed")] | length) == 1
' >/dev/null 2>&1; then
  die "attestation is malformed, stale, duplicated, or missing a completed local review, test, document, or lint phase"
fi

printf 'verified no-mistakes local validation at head %s\n' "$HEAD_SHA_NORMALIZED"
