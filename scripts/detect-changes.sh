#!/usr/bin/env bash

# Decide whether the published repo has anything worth committing.
#
# Run from inside the gh-pages working tree, AFTER build-index.sh has regenerated the
# index. Prints "changed=true" or "changed=false" on stdout, and appends the same line to
# $GITHUB_OUTPUT when that variable is set.
#
# Why this is not just `git status --porcelain`:
#
#   * The index is now regenerated on every run, so that a change to HOW it is built (say
#     dpkg-scanpackages gaining --multiversion) reaches the published repo on the next run
#     rather than waiting for an unrelated .deb or template to change. Detecting changes
#     before generating the index was the previous behaviour and meant such a change could
#     sit unpublished indefinitely.
#
#   * But Release is not reproducible: apt-ftparchive stamps a Date: field into it, so it
#     differs on every single run. A plain `git status` would therefore always report a
#     change, and the aggregator would sign and push an otherwise-identical repo every
#     hour, forever. Release is excluded here and restored when nothing else moved.
#
#   * Packages stanza ORDER can vary between runs without the content differing, since it
#     follows directory traversal. A byte comparison would churn on that too, so Packages
#     is compared as a sorted multiset of lines: identical lines in any order means an
#     identical index.
#
#   * Packages.gz is excluded and restored alongside the other two DELIBERATELY, even
#     though build-index.sh passes gzip -n and it is therefore a deterministic function of
#     Packages today. It is excluded because it is derived: `Packages` is the thing worth
#     comparing, and a difference in the .gz that its source does not explain could only
#     come from the compression step changing - a different gzip, or -n being dropped -
#     which would make it differ on every run and push an identical repo hourly. Excluding
#     it means such a regression is harmless here rather than catastrophic. The trade-off
#     is that it would also go unnoticed by this script, which is the right way round.

set -euo pipefail

VOLATILE=(Packages Packages.gz Release)

changed=false
reason=""

# 1. Anything outside the generated index files - a .deb added or pruned, a template
#    edited. Untracked files count, which is how a newly fetched .deb registers.
status=$(git status --porcelain -- . \
    ':(exclude)Packages' ':(exclude)Packages.gz' ':(exclude)Release' \
    ':(exclude)Release.gpg' ':(exclude)InRelease')
if [ -n "$status" ]; then
    changed=true
    reason="package or template changes"
fi

# 2. The index content itself, compared order-insensitively.
if [ "$changed" = false ]; then
    committed=$(mktemp)
    regenerated=$(mktemp)
    trap 'rm -f "$committed" "$regenerated"' EXIT
    # No Packages in HEAD (first ever run) leaves the file empty, so any generated index
    # counts as a change - which is what we want.
    git show HEAD:Packages 2>/dev/null | sort > "$committed" || : > "$committed"
    sort Packages > "$regenerated"
    if ! cmp -s "$committed" "$regenerated"; then
        changed=true
        reason="index content changed"
    fi
fi

if [ "$changed" = false ]; then
    # Only the unavoidable Date: churn in Release. Put the generated files back so the
    # tree is clean and the caller commits nothing.
    git checkout -- "${VOLATILE[@]}" 2>/dev/null || true
    echo "No package, template or index changes - nothing to publish." >&2
else
    echo "Changes to publish: ${reason}." >&2
    git status --short >&2
fi

echo "changed=${changed}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "changed=${changed}" >> "$GITHUB_OUTPUT"
fi
