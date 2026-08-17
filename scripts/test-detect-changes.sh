#!/usr/bin/env bash

# Tests scripts/detect-changes.sh against a synthetic gh-pages repo.
#
# Needs only git - it fabricates Packages/Release files rather than running
# dpkg-scanpackages, so it runs anywhere, including a developer's machine.
#
# The cases that matter are the "false" ones: a change-detector that cannot say "no" would
# make the aggregator sign and push an identical repo every hour, and one that cannot say
# "yes" is how an index-generation change went unpublished in the first place. The Release
# cases below cover the same failure in the harder direction: a fix confined to Release - as
# the correction to the generator's self-entry was - moves nothing else in the tree, so only
# a comparison of Release itself can notice it.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DETECT="$SCRIPT_DIR/detect-changes.sh"
failures=0

# Every fixture lives under one root, removed by a single trap. Deliberately not an array
# of directories appended to by fixture(): that function is called via $(...), so it runs
# in a subshell and any variable it set would be discarded - the cleanup would silently
# track nothing. One parent directory has no such failure mode.
#
# Every mktemp call passes an explicit template. A bare `mktemp -d` does work on both GNU
# and macOS, but macOS's documented synopsis is `mktemp [-d] [-p tmpdir] [-q] [-t prefix]
# [-u] template ...` - the bare form is a real but undocumented fallback. Since this suite
# is meant to run on a developer machine, resting on the documented form costs nothing.
tmpdir=${TMPDIR:-/tmp}
tmpdir=${tmpdir%/}
TMP_ROOT=$(mktemp -d "$tmpdir/detect-changes-tests.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# A Release close enough in shape to a real one to exercise the comparison rules: a Date:
# stamp that churns on every run, an entry for Packages, and an entry for Packages.gz whose
# churn has to be ignored on the same terms as the file itself.
release_file() {
    local date=$1 packages_hash=$2 gz_hash=$3
    printf 'Date: %s\nSHA256:\n %s 46 Packages\n %s 8 Packages.gz\n' \
        "$date" "$packages_hash" "$gz_hash"
}

# Build a repo with a committed index, then let the caller mutate the working tree.
fixture() {
    local dir
    dir=$(mktemp -d "$TMP_ROOT/fixture.XXXXXX")
    git -C "$dir" init -q
    git -C "$dir" config user.email t@example.com
    git -C "$dir" config user.name Test
    printf 'Package: alpha\nVersion: 1.0\n\nPackage: alpha\nVersion: 0.9\n' > "$dir/Packages"
    release_file 'Mon, 01 Jan 2026 00:00:00 +0000' packageshash gzhash > "$dir/Release"
    printf 'gzipped\n' > "$dir/Packages.gz"
    printf 'template\n' > "$dir/README.md"
    : > "$dir/alpha_1.0_all.deb"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "initial index"
    echo "$dir"
}

check() {
    local name=$1 expected=$2 dir=$3
    local got
    # Deliberately tolerant. Under `set -euo pipefail`, a detector that errored or printed
    # no changed= line would make grep exit non-zero, fail the assignment, and abort the
    # whole run with NO summary - the least useful thing a harness can do at precisely the
    # moment something is broken. Swallow it here and let the comparison below record a
    # failure, so every case still gets a verdict and the run ends with a count.
    got=$( (cd "$dir" && bash "$DETECT" 2>/dev/null) | grep '^changed=' | cut -d= -f2 || true )
    [ -n "$got" ] || got="(no changed= line)"
    if [ "$got" = "$expected" ]; then
        printf 'ok    %-46s changed=%s\n' "$name" "$got"
    else
        printf 'FAIL  %-46s expected changed=%s, got changed=%s\n' "$name" "$expected" "$got"
        failures=$((failures + 1))
    fi
}

# 1. Only Release moved - the unavoidable Date: stamp. Must NOT publish.
d=$(fixture)
release_file 'Tue, 02 Feb 2026 11:22:33 +0000' packageshash gzhash > "$d/Release"
check "Release Date: churn only" false "$d"
# ...and the volatile file must have been restored, leaving a clean tree.
if [ -n "$(git -C "$d" status --porcelain)" ]; then
    echo "FAIL  Release was not restored - tree left dirty:"
    git -C "$d" status --short
    failures=$((failures + 1))
else
    echo "ok    Release restored, working tree clean"
fi

# 2. Same index content, different stanza order. Must NOT publish. Note that dpkg-scanpackages
#    sorts its output, so this cannot arise from the real generator - the case pins the
#    multiset property against a future generator that does not sort. Release is left
#    untouched here for the same reason: with a sorting generator, a reorder never happens, so
#    a reorder never moves Release's hash of Packages either.
d=$(fixture)
printf 'Package: alpha\nVersion: 0.9\n\nPackage: alpha\nVersion: 1.0\n' > "$d/Packages"
check "Packages reordered, same content" false "$d"

# 3. Index content genuinely different - this is the --multiversion case. Must publish.
d=$(fixture)
printf 'Package: alpha\nVersion: 1.0\n\nPackage: alpha\nVersion: 0.9\n\nPackage: alpha\nVersion: 0.8\n' > "$d/Packages"
check "index gained a version" true "$d"

# 4. A newly fetched .deb, untracked. Must publish.
d=$(fixture)
: > "$d/alpha_2.0_all.deb"
check "new untracked .deb" true "$d"

# 4b. The same new .deb, but with status.showUntrackedFiles=no set. Must STILL publish.
#     Without --untracked-files=all in the detector this reports changed=false and a brand
#     new release never reaches users - a missed publication, which is the worse direction
#     for a package channel than an extra one.
d=$(fixture)
: > "$d/alpha_2.0_all.deb"
git -C "$d" config status.showUntrackedFiles no
check "new .deb, showUntrackedFiles=no" true "$d"

# 5. A pruned .deb. Must publish.
d=$(fixture)
rm "$d/alpha_1.0_all.deb"
check "pruned .deb" true "$d"

# 6. A template edit. Must publish.
d=$(fixture)
printf 'template changed\n' > "$d/README.md"
check "template edited" true "$d"

# 7. No Packages in HEAD at all - first ever run. Must publish. Built by hand rather than
#    via fixture(), since the point is that no index has ever been committed - but still
#    under TMP_ROOT so the trap reaches it.
d=$(mktemp -d "$TMP_ROOT/firstrun.XXXXXX")
git -C "$d" init -q
git -C "$d" config user.email t@example.com
git -C "$d" config user.name Test
printf 'placeholder\n' > "$d/README.md"
git -C "$d" add -A
git -C "$d" commit -q -m "empty repo"
printf 'Package: alpha\nVersion: 1.0\n' > "$d/Packages"
printf 'Date: now\n' > "$d/Release"
printf 'gz\n' > "$d/Packages.gz"
check "first run, no committed index" true "$d"

# 8. A real checksum entry in Release moved while Packages itself did not. Must publish: the
#    only way this happens is the index being GENERATED differently, which is exactly the
#    change that has to reach the published repo on the next run.
d=$(fixture)
release_file 'Mon, 01 Jan 2026 00:00:00 +0000' differenthash gzhash > "$d/Release"
check "Release checksum entry changed" true "$d"

# 9. Only Release's Packages.gz entry moved. Must NOT publish - Release carries that file's
#    hash, and Packages.gz is deliberately excluded from comparison (a regression in the gzip
#    step would otherwise differ every run and push an identical repo hourly). Comparing that
#    entry through Release would undo the exclusion by the back door.
d=$(fixture)
release_file 'Mon, 01 Jan 2026 00:00:00 +0000' packageshash differentgzhash > "$d/Release"
check "Release Packages.gz entry changed" false "$d"
# ...and, as in case 1, the tree must be left clean.
if [ -n "$(git -C "$d" status --porcelain)" ]; then
    echo "FAIL  Release was not restored after a Packages.gz-only entry change:"
    git -C "$d" status --short
    failures=$((failures + 1))
else
    echo "ok    Release restored after Packages.gz-only entry change"
fi

# 10. Release loses a self-entry while the Date: also churns. Must publish. This is the fix to
#     the generator reaching users: apt-ftparchive was hashing its own partially-written
#     output into Release, so the committed copy carries a 38-byte entry for "Release" that
#     the regenerated one does not, and NOTHING else in the tree differs. The churned Date:
#     is deliberate - it must not be what makes the comparison notice.
d=$(fixture)
{
    release_file 'Mon, 01 Jan 2026 00:00:00 +0000' packageshash gzhash
    printf ' selfhash 38 Release\n'
} > "$d/Release"
git -C "$d" commit -qam "index with a Release self-entry"
release_file 'Tue, 02 Feb 2026 11:22:33 +0000' packageshash gzhash > "$d/Release"
check "Release self-entry dropped" true "$d"

# 11. The Packages.gz FILE moved, with Packages and Release identical. Must NOT publish, and
#     the file must be restored. This is the companion to case 9: that one covers the .gz's
#     entry inside Release, this one covers the .gz itself, and both have to stay ignored for
#     the reason the file is excluded at all.
d=$(fixture)
printf 'differently gzipped\n' > "$d/Packages.gz"
check "Packages.gz file changed" false "$d"
if [ -n "$(git -C "$d" status --porcelain)" ]; then
    echo "FAIL  Packages.gz was not restored - tree left dirty:"
    git -C "$d" status --short
    failures=$((failures + 1))
else
    echo "ok    Packages.gz restored, working tree clean"
fi

echo
if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed."
    exit 1
fi
echo "All change-detection checks passed."
