#!/usr/bin/env bash

# Tests scripts/detect-changes.sh against a synthetic gh-pages repo.
#
# Needs only git - it fabricates Packages/Release files rather than running
# dpkg-scanpackages, so it runs anywhere, including a developer's machine.
#
# The cases that matter are the two "false" ones: a change-detector that cannot say "no"
# would make the aggregator sign and push an identical repo every hour, and one that
# cannot say "yes" is how an index-generation change went unpublished in the first place.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DETECT="$SCRIPT_DIR/detect-changes.sh"
failures=0

# Every fixture lives under one root, removed by a single trap. Deliberately not an array
# of directories appended to by fixture(): that function is called via $(...), so it runs
# in a subshell and any variable it set would be discarded - the cleanup would silently
# track nothing. One parent directory has no such failure mode. A template argument rather
# than -p keeps mktemp portable, since BSD mktemp has no -p.
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Build a repo with a committed index, then let the caller mutate the working tree.
fixture() {
    local dir
    dir=$(mktemp -d "$TMP_ROOT/fixture.XXXXXX")
    git -C "$dir" init -q
    git -C "$dir" config user.email t@example.com
    git -C "$dir" config user.name Test
    printf 'Package: alpha\nVersion: 1.0\n\nPackage: alpha\nVersion: 0.9\n' > "$dir/Packages"
    printf 'Date: Mon, 01 Jan 2026 00:00:00 +0000\nSHA256:\n abc 1 Packages\n' > "$dir/Release"
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
    got=$(cd "$dir" && bash "$DETECT" 2>/dev/null | grep '^changed=' | cut -d= -f2)
    if [ "$got" = "$expected" ]; then
        printf 'ok    %-46s changed=%s\n' "$name" "$got"
    else
        printf 'FAIL  %-46s expected changed=%s, got changed=%s\n' "$name" "$expected" "$got"
        failures=$((failures + 1))
    fi
}

# 1. Only Release moved - the unavoidable Date: stamp. Must NOT publish.
d=$(fixture)
printf 'Date: Tue, 02 Feb 2026 11:22:33 +0000\nSHA256:\n abc 1 Packages\n' > "$d/Release"
check "Release Date: churn only" false "$d"
# ...and the volatile file must have been restored, leaving a clean tree.
if [ -n "$(git -C "$d" status --porcelain)" ]; then
    echo "FAIL  Release was not restored - tree left dirty:"
    git -C "$d" status --short
    failures=$((failures + 1))
else
    echo "ok    Release restored, working tree clean"
fi

# 2. Same index content, different stanza order. Must NOT publish.
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

echo
if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed."
    exit 1
fi
echo "All change-detection checks passed."
