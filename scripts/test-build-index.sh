#!/usr/bin/env bash

# Tests the Release guard in scripts/build-index.sh against a deliberately broken generator.
#
# The guard is what stands between a malformed index and the signing step, in the hourly
# publishing run as well as the pull-request dry run. aggregate-dry-run proves the guard
# ACCEPTS a real index; nothing else proves it still REJECTS a bad one, and a guard that has
# quietly stopped firing looks exactly like a guard that passed. That is what this covers.
#
# dpkg-scanpackages and apt-ftparchive are stubbed on PATH so the suite runs anywhere,
# including a developer's machine - the same property that makes test-detect-changes.sh
# useful. The stub apt-ftparchive computes real sizes and hashes from the real files for the
# entries a scenario wants correct, so the well-formed case has to genuinely agree with the
# tree rather than passing by coincidence.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD="$SCRIPT_DIR/build-index.sh"
failures=0

# One parent directory for every fixture, removed by a single trap. Explicit mktemp template
# for the same reason as test-detect-changes.sh: macOS documents the form as requiring one.
tmpdir=${TMPDIR:-/tmp}
tmpdir=${tmpdir%/}
TMP_ROOT=$(mktemp -d "$tmpdir/build-index-tests.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

STUBS="$TMP_ROOT/stubs"
mkdir -p "$STUBS"

cat > "$STUBS/dpkg-scanpackages" <<'STUB'
#!/usr/bin/env bash
# Enough of a Packages file to be hashed and gzipped; the guard never parses it.
printf 'Package: alpha\nVersion: 1.0\nFilename: ./alpha_1.0_all.deb\n'
STUB

# $MODE selects the malformation. Only the SHA256 section is emitted: the guard checks every
# entry it finds regardless of section, so one section exercises it, and a second would only
# duplicate the assertions. The unknown-algorithm case adds a section header on purpose.
cat > "$STUBS/apt-ftparchive" <<'STUB'
#!/usr/bin/env bash
size() { wc -c < "$1" | tr -d '[:space:]'; }
hash() { sha256sum "$1" | cut -d' ' -f1; }
p=$(size Packages); g=$(size Packages.gz)
ph=$(hash Packages); gh=$(hash Packages.gz)
printf 'Date: Mon, 17 Aug 2026 08:00:00 +0000\nSHA256:\n'
case $MODE in
    good)
        printf ' %s %s Packages\n %s %s Packages.gz\n' "$ph" "$p" "$gh" "$g" ;;
    self)
        # What the generator used to do: hash its own partially-written output.
        printf ' %s %s Packages\n %s %s Packages.gz\n %s 38 Release\n' \
            "$ph" "$p" "$gh" "$g" "$ph" ;;
    absent)
        printf ' %s %s Packages\n %s %s Packages.gz\n %s 12 Sources\n' \
            "$ph" "$p" "$gh" "$g" "$ph" ;;
    size)
        printf ' %s 99999 Packages\n %s %s Packages.gz\n' "$ph" "$gh" "$g" ;;
    hash)
        printf ' %s %s Packages\n %s %s Packages.gz\n' \
             0000000000000000000000000000000000000000000000000000000000000000 "$p" "$gh" "$g" ;;
    unknown)
        printf ' %s %s Packages\n %s %s Packages.gz\nBLAKE3:\n %s %s Packages\n' \
            "$ph" "$p" "$gh" "$g" "$ph" "$p" ;;
    empty)
        : ;;
esac
STUB

chmod +x "$STUBS/dpkg-scanpackages" "$STUBS/apt-ftparchive"

# build-index.sh verifies hashes with the coreutils tools, which exist under those names on
# Debian and in CI but not on macOS. Shim only the ones actually missing, so a Linux run uses
# the real binaries and a developer machine still computes genuine hashes rather than faking
# the comparison the guard exists to make.
for pair in md5sum:md5 sha1sum:1 sha256sum:256 sha512sum:512; do
    tool=${pair%%:*}
    arg=${pair#*:}
    command -v "$tool" >/dev/null 2>&1 && continue
    # shellcheck disable=SC2016  # $1 must reach the shim verbatim, not expand here
    if [ "$tool" = md5sum ]; then
        printf '#!/usr/bin/env bash\nprintf "%%s  %%s\\n" "$(md5 -q "$1")" "$1"\n' > "$STUBS/$tool"
    else
        printf '#!/usr/bin/env bash\nshasum -a %s "$1"\n' "$arg" > "$STUBS/$tool"
    fi
    chmod +x "$STUBS/$tool"
done

# A served directory as the aggregator would present it: one .deb, and a Release left over
# from a previous run. The stale file matters - the fix removes it before scanning, and a
# regression that stopped doing so would hash the old file instead.
fixture() {
    local dir
    dir=$(mktemp -d "$TMP_ROOT/fixture.XXXXXX")
    : > "$dir/alpha_1.0_all.deb"
    printf 'stale Release from the previous run\n' > "$dir/Release"
    echo "$dir"
}

# Run the generator once per case, keeping the output in a file and the status in a global.
#
# Deliberately NOT `out=$(run_case ...)`: command substitution runs the function in a subshell,
# so any failure it counted would be discarded when the subshell exited and the suite would
# report success with a broken case inside it. Everything that increments the counter has to
# run in this shell. The output goes to a file for the same reason - so the assertions below
# can read it without another subshell swallowing a verdict.
#
# `set +e` around the call rather than `|| true`: the exit status IS the thing under test here,
# so it has to be captured exactly rather than flattened to zero.
OUT="$TMP_ROOT/output"

run_build() {
    local mode=$1 dir=$2
    set +e
    ( cd "$dir" && MODE=$mode PATH="$STUBS:$PATH" bash "$BUILD" ) > "$OUT" 2>&1
    RUN_STATUS=$?
    set -e
}

expect_status() {
    local name=$1 expected=$2
    if [ "$RUN_STATUS" = "$expected" ]; then
        printf 'ok    %-38s exit=%s  %s\n' "$name" "$RUN_STATUS" "$(head -1 "$OUT")"
    else
        printf 'FAIL  %-38s expected exit=%s, got exit=%s\n' "$name" "$expected" "$RUN_STATUS"
        sed 's/^/        /' "$OUT"
        failures=$((failures + 1))
    fi
}

# Assert on what the failure SAYS, not only that it happened: a guard that refuses without
# naming the reason is a guard someone has to reverse-engineer at the worst possible moment.
expect_output() {
    local name=$1 pattern=$2
    if grep -qE "$pattern" "$OUT"; then
        echo "ok    $name"
    else
        printf 'FAIL  %s (no match for /%s/ in)\n' "$name" "$pattern"
        sed 's/^/        /' "$OUT"
        failures=$((failures + 1))
    fi
}

expect_true() {
    local name=$1 condition=$2
    if [ "$condition" = true ]; then
        echo "ok    $name"
    else
        echo "FAIL  $name"
        failures=$((failures + 1))
    fi
}

# 1. A well-formed index. Must succeed, and must leave the served tree in the intended state.
d=$(fixture)
run_build good "$d"
expect_status "well-formed index" 0
grep -qE '[[:space:]]Release$' "$d/Release" && ok=false || ok=true
expect_true "no self-entry in the generated Release" "$ok"
grep -q 'stale Release' "$d/Release" && ok=false || ok=true
expect_true "previous Release replaced, not hashed" "$ok"
bits=$(stat -f '%Lp' "$d/Release" 2>/dev/null || stat -c '%a' "$d/Release")
[ "$bits" = 644 ] && ok=true || ok=false
expect_true "generated Release is mode 0644" "$ok"
# Assert the whole contents rather than just the absence of a known temporary name: anything
# unexpected in the served tree would be published, and naming only the current temporary would
# stop catching a leak the moment that name changed.
# LC_ALL=C for the same reason detect-changes.sh gives: locale collation orders these
# differently (it folds case, putting alpha_ first), so an unpinned sort would make this
# assertion pass on one machine and fail on another.
served=$( (cd "$d" && printf '%s\n' * | LC_ALL=C sort | tr '\n' ' ') )
[ "$served" = "Packages Packages.gz Release alpha_1.0_all.deb " ] && ok=true || ok=false
expect_true "served tree holds exactly the expected files" "$ok"
[ "$ok" = true ] || echo "        got: $served"

# 2. The regression this guard exists for: Release listing itself. Must refuse.
d=$(fixture)
run_build self "$d"
expect_status "Release lists itself" 1
expect_output "  error names the self-entry as the cause" 'checksum entry for itself'

# 3. An entry naming a file that is not being served. Must refuse.
d=$(fixture)
run_build absent "$d"
expect_status "entry for an absent file" 1
expect_output "  error names the absent file" 'Sources, which is not present in the tree'

# 4. A declared size that disagrees with the file. Must refuse.
d=$(fixture)
run_build size "$d"
expect_status "declared size is wrong" 1
expect_output "  error reports declared and actual size" 'declares Packages as 99999 bytes; it is [0-9]+'

# 5. A declared hash that disagrees with the file. Must refuse - apt verifies Packages against
#    these hashes, so a wrong one here breaks `apt update` for every client.
d=$(fixture)
run_build hash "$d"
expect_status "declared hash is wrong" 1
expect_output "  error reports declared and actual hash" 'declares SHA256 for Packages as 0{64}; it is [0-9a-f]{64}'

# 6. A section whose algorithm the script cannot verify. Must SUCCEED, having checked the size,
#    but must say so - a skipped check that looks like a passed one is how coverage shrinks.
d=$(fixture)
run_build unknown "$d"
expect_status "unverifiable algorithm section" 0
expect_output "  unverifiable algorithm is reported, not skipped" "::notice::.*'BLAKE3'.*cannot"

# 7. No entries at all. Must refuse: an empty Release would otherwise satisfy every per-entry
#    check above by having nothing to check.
d=$(fixture)
run_build empty "$d"
expect_status "Release with no entries" 1
expect_output "  error names the missing required entry" 'no checksum entry for Packages'

echo
if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed."
    exit 1
fi
echo "All index-guard checks passed."
