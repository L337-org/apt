#!/usr/bin/env bash

# Fails unless every `uses:` in the publishing workflow is a full commit SHA or a local path.
#
# aggregate.yaml imports the APT signing key and the commit signing key.  Elsewhere the shared
# workflows repository is called at its major-version tag, so a change released there runs here
# without a pull request; here that would put the signing keys within reach of whoever moves the
# tag.  So this workflow takes nothing from L337-org/github-workflows, and nothing at a tag or
# branch from anyone: each action is a 40-hex SHA, or this repository's own code at `./`.
#
# Usage: check-aggregate-pins.sh [WORKFLOW]  (default .github/workflows/aggregate.yaml)

set -euo pipefail

workflow=${1:-.github/workflows/aggregate.yaml}
if [ ! -f "$workflow" ]; then
  echo "::error::$workflow does not exist, so there is nothing to check: pass the publishing workflow's path" >&2
  exit 1
fi

# Every `uses:` line, as `line:reference`, with quotes and a trailing comment removed.
refs=$(grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:' "$workflow" \
  | sed -E "s/^([0-9]+):[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[\"']?([^[:space:]\"']*).*/\1:\3/" \
  || true)
if [ -z "$refs" ]; then
  # A publishing workflow with no actions at all is not what this repository has; an empty
  # listing more likely means the pattern stopped matching, which must not read as a pass.
  echo "::error::Found no \`uses:\` in $workflow, so this check verified nothing" >&2
  exit 1
fi

bad=0
while IFS=: read -r line ref; do
  if grep -qiE '^l337-org/github-workflows(/|@|$)' <<<"$ref"; then
    echo "::error file=$workflow,line=$line::$ref comes from L337-org/github-workflows, which this workflow must not call: it holds the signing keys" >&2
    bad=1
  elif ! grep -qE '^(\./|[^@[:space:]]+@[0-9a-fA-F]{40}$)' <<<"$ref"; then
    echo "::error file=$workflow,line=$line::$ref is not pinned to a 40-hex commit SHA, which this workflow requires because it holds the signing keys" >&2
    bad=1
  fi
done <<<"$refs"

if [ "$bad" -ne 0 ]; then
  exit 1
fi
echo "Every \`uses:\` in $workflow is a 40-hex commit SHA or a local path, and none is from L337-org/github-workflows."
