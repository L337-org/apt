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
#     hour, forever. So Release is excluded from the general diff and compared separately,
#     with the Date: line filtered out.
#
#     Excluding it from comparison altogether - the previous behaviour - meant a change
#     confined to Release could never publish. The worked example is the fix that stopped
#     apt-ftparchive hashing a partially-written Release into its own output: it alters
#     Release and nothing else, so the old detector would have reported changed=false, put
#     the corrected file back, and left the bad one served until an unrelated .deb or
#     template happened to move. A Release-only change is precisely the "a change to HOW the
#     index is built" case above, and has to reach users the same way.
#
#   * The Packages.gz entry lines are filtered out of that Release comparison too, on the
#     same grounds as the exclusion of Packages.gz itself below: Release carries that file's
#     hash, so comparing it would reintroduce through Release exactly the churn that
#     excluding the file is there to absorb.
#
#   * Packages is compared as a sorted multiset of lines rather than byte-for-byte:
#     identical lines in any order means an identical index. dpkg-scanpackages does in fact
#     emit a deterministic order - it sorts by package name, then by version string, in
#     dpkg's own scripts/dpkg-scanpackages.pl - so this is insurance against that changing,
#     or against a different generator, rather than churn anyone has observed. An earlier
#     version of this comment said the order followed directory traversal. It does not.
#
#     That determinism is also what makes comparing Release's checksum entries safe. If the
#     stanza order really did vary, Release's hash of Packages would vary with it, and
#     comparing that hash would push an identical repo hourly - the very failure the multiset
#     comparison exists to prevent. The hashes are nonetheless kept in the Release comparison
#     deliberately: apt verifies Packages against the hashes in Release, so a wrong hash
#     there breaks `apt update` for every client, and a fix for one has to publish
#     immediately. Dropping the hash column would leave such a fix undetectable here,
#     because the sizes would not move.
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

# One scratch directory for the comparison files, removed by a single trap.
#
# Explicit mktemp template: a bare `mktemp -d` works on GNU and macOS alike, but macOS
# documents the form as requiring a template, so the documented spelling is the safer one to
# rely on for a script that also runs outside CI.
tmpdir=${TMPDIR:-/tmp}
tmpdir=${tmpdir%/}
work=$(mktemp -d "$tmpdir/detect-changes.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Everything in Release that a real change moves: its checksum entries, less the Date: stamp
# that churns on every run, and less the Packages.gz entries (see the header). grep -v exits 1
# when it filters every line away, which is a legitimate result here rather than a failure.
release_signal() {
    grep -vE '^Date: |[[:space:]]Packages\.gz$' || true
}

changed=false
reason=""

# 1. Anything outside the generated index files - a .deb added or pruned, a template
#    edited. Untracked files count, which is how a newly fetched .deb registers.
#
#    --untracked-files=all is load-bearing, not decoration. `git status` honours
#    status.showUntrackedFiles, and with that set to "no" a newly fetched .deb reports
#    nothing at all: this returns empty, Packages happens to match, and the detector says
#    changed=false. A brand new release would then never be published, silently. Ambient
#    git config must not be able to decide whether a package reaches users, so the flag is
#    passed explicitly rather than relying on the default.
status=$(git status --porcelain --untracked-files=all -- . \
    ':(exclude)Packages' ':(exclude)Packages.gz' ':(exclude)Release' \
    ':(exclude)Release.gpg' ':(exclude)InRelease')
if [ -n "$status" ]; then
    changed=true
    reason="package or template changes"
fi

# 2. The index content itself, compared order-insensitively.
if [ "$changed" = false ]; then
    committed="$work/committed-packages"
    regenerated="$work/regenerated-packages"
    # No Packages in HEAD (first ever run) leaves the file empty, so any generated index
    # counts as a change - which is what we want.
    # LC_ALL=C: byte order, which is a TOTAL order, so no two distinct lines ever compare
    # equal. Locale collation can rank lines differently between environments, but more
    # importantly it can treat lines differing only in punctuation or whitespace as EQUAL -
    # and sort is not stable by default, so tied lines may be emitted in either order. Two
    # sorts of identical content could then differ byte-for-byte, reporting a change that
    # does not exist and publishing an identical repo every hour. Debian index files carry
    # exactly the kind of lines that invites: checksum entries indented by a space.
    git show HEAD:Packages 2>/dev/null | LC_ALL=C sort > "$committed" || : > "$committed"
    LC_ALL=C sort Packages > "$regenerated"
    if ! cmp -s "$committed" "$regenerated"; then
        changed=true
        reason="index content changed"
    fi
fi

# 3. Release itself, ignoring the parts of it that churn without meaning anything. This is
#    what catches a change to how the index is generated when no package and no template
#    moved: the fix that stopped apt-ftparchive hashing a partially-written Release into its
#    own output altered nothing else in the tree, and so was invisible to steps 1 and 2.
if [ "$changed" = false ]; then
    committed_release="$work/committed-release"
    regenerated_release="$work/regenerated-release"
    # As above, no Release in HEAD leaves the file empty and any generated one counts.
    git show HEAD:Release 2>/dev/null | release_signal > "$committed_release" \
        || : > "$committed_release"
    release_signal < Release > "$regenerated_release"
    if ! cmp -s "$committed_release" "$regenerated_release"; then
        changed=true
        reason="generated Release changed"
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
