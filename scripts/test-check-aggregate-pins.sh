#!/usr/bin/env bash

# Tests scripts/check-aggregate-pins.sh against fixture workflows, so the guard that keeps the
# signing keys out of a moved shared tag's reach is shown to refuse, not only to pass.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK="$SCRIPT_DIR/check-aggregate-pins.sh"
SHA=3d3c42e5aac5ba805825da76410c181273ba90b1
failures=0

tmpdir=${TMPDIR:-/tmp}
root=$(mktemp -d "$tmpdir/test-check-aggregate-pins.XXXXXX")
trap 'rm -rf "$root"' EXIT

# expect PASS|FAIL NAME USES-LINE...
expect() {
  local want=$1 name=$2
  shift 2
  local file="$root/$name.yaml"
  {
    echo "jobs:"
    echo "  a:"
    echo "    steps:"
    for line in "$@"; do echo "      - uses: $line"; done
  } >"$file"
  if "$CHECK" "$file" >/dev/null 2>&1; then got=PASS; else got=FAIL; fi
  if [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected $want, got $got"
    failures=$((failures + 1))
  fi
}

expect PASS sha "actions/checkout@$SHA # v7.0.1"
expect PASS quoted-sha "'actions/checkout@$SHA'"
expect PASS local "./.github/actions/thing"
expect FAIL shared-at-tag "L337-org/github-workflows/actions/repo-hygiene@v2"
expect FAIL shared-at-sha "L337-org/github-workflows/actions/repo-hygiene@$SHA"
expect FAIL shared-lowercase "l337-org/github-workflows/actions/repo-hygiene@$SHA"
expect FAIL third-party-tag "actions/checkout@v7"
expect FAIL third-party-branch "actions/checkout@main"
expect FAIL short-sha "actions/checkout@${SHA:0:12}"
expect FAIL one-bad-of-two "actions/checkout@$SHA" "actions/setup-python@v6"

# No `uses:` at all must not read as a pass.
printf 'jobs:\n  a:\n    steps:\n      - run: true\n' >"$root/empty.yaml"
if "$CHECK" "$root/empty.yaml" >/dev/null 2>&1; then
  echo "FAIL empty: expected FAIL, got PASS"
  failures=$((failures + 1))
else
  echo "ok   empty"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "All cases passed."
