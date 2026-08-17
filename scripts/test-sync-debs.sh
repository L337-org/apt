#!/usr/bin/env bash

# Tests scripts/sync-debs.py's refusal rules against a stubbed GitHub API.
#
# The case that matters most is the multi-repo one. The prune guard used to be global, which is
# indistinguishable from a per-repo guard while exactly one repo is configured, and silently
# stops being safe when a second is added: one repo returning nothing while another is healthy
# would have pruned the first project's packages and pushed that as a normal publish. That
# cannot be caught by inspection of a single-repo config, so it is pinned here.
#
# `gh` is stubbed on PATH and download URLs are file:// URLs, so the suite needs no network and
# no credentials - only python3 with PyYAML, which the workflows already install.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SYNC="$SCRIPT_DIR/sync-debs.py"
failures=0

tmpdir=${TMPDIR:-/tmp}
tmpdir=${tmpdir%/}
TMP_ROOT=$(mktemp -d "$tmpdir/sync-debs-tests.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

STUBS="$TMP_ROOT/stubs"
mkdir -p "$STUBS"

# The stub answers `gh api repos/<owner>/<name>/releases?...` from a fixture file named after
# the repo, so each case decides per repo what the API appears to return. A fixture holding the
# word FAIL makes the stub exit non-zero with a message on stderr, standing in for an API error.
cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
# Invoked as: gh api repos/<owner>/<name>/releases?per_page=100
path=$2
repo=${path#repos/}
repo=${repo%%/releases*}
fixture="$FIXTURES/${repo//\//_}.json"
if [ ! -f "$fixture" ]; then
    echo "stub gh: no fixture for $repo" >&2
    exit 4
fi
if grep -q FAIL "$fixture"; then
    echo "HTTP 503: upstream is having a bad day (fixture-driven failure)" >&2
    exit 1
fi
cat "$fixture"
STUB
chmod +x "$STUBS/gh"

# A release carrying one .deb, whose download URL is a local file so sync() can fetch it.
release_with_deb() {
    local name=$1 version=$2 payload=$3
    printf '[{"assets":[{"name":"%s_%s_all.deb","browser_download_url":"file://%s"}]}]' \
        "$name" "$version" "$payload"
}

new_case() {
    local dir
    dir=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
    mkdir -p "$dir/fixtures" "$dir/dest"
    printf 'a real deb would be here\n' > "$dir/payload.deb"
    echo "$dir"
}

# Run sync-debs.py against a case directory, keeping output and status for the assertions.
run_sync() {
    local dir=$1
    set +e
    FIXTURES="$dir/fixtures" PATH="$STUBS:$PATH" \
        python3 "$SYNC" --repos-config "$dir/repos.yaml" --dest "$dir/dest" \
        > "$dir/out" 2>&1
    RUN_STATUS=$?
    set -e
    OUT="$dir/out"
}

expect_status() {
    local name=$1 expected=$2
    if [ "$RUN_STATUS" = "$expected" ]; then
        printf 'ok    %-44s exit=%s\n' "$name" "$RUN_STATUS"
    else
        printf 'FAIL  %-44s expected exit=%s, got exit=%s\n' "$name" "$expected" "$RUN_STATUS"
        sed 's/^/        /' "$OUT"
        failures=$((failures + 1))
    fi
}

expect_output() {
    local name=$1 pattern=$2
    if grep -qE "$pattern" "$OUT"; then
        echo "ok      $name"
    else
        printf 'FAIL    %s (no match for /%s/ in)\n' "$name" "$pattern"
        sed 's/^/        /' "$OUT"
        failures=$((failures + 1))
    fi
}

expect_true() {
    local name=$1 condition=$2
    if [ "$condition" = true ]; then
        echo "ok      $name"
    else
        echo "FAIL    $name"
        failures=$((failures + 1))
    fi
}

# 1. Two repos, one empty and one healthy. Must refuse, and must not delete anything - this is
#    the case a global guard gets wrong, because the healthy repo keeps `wanted` non-empty.
d=$(new_case)
printf 'repos:\n  - repo: org/alpha\n  - repo: org/beta\n' > "$d/repos.yaml"
release_with_deb alpha 1.0 "$d/payload.deb" > "$d/fixtures/org_alpha.json"
printf '[]' > "$d/fixtures/org_beta.json"
: > "$d/dest/beta_9.9_all.deb"
: > "$d/dest/alpha_0.1_all.deb"
run_sync "$d"
expect_status "one repo empty, one healthy" 1
expect_output "  refusal names the empty repo" 'no \.deb assets selected from org/beta'
expect_output "  refusal says what it is protecting" 'holds 2 \.deb file\(s\)'
[ -f "$d/dest/beta_9.9_all.deb" ] && [ -f "$d/dest/alpha_0.1_all.deb" ] && ok=true || ok=false
expect_true "  nothing was pruned" "$ok"

# 2. Every repo empty - the case that actually occurred. Must still refuse.
d=$(new_case)
printf 'repos:\n  - repo: org/alpha\n  - repo: org/beta\n' > "$d/repos.yaml"
printf '[]' > "$d/fixtures/org_alpha.json"
printf '[]' > "$d/fixtures/org_beta.json"
: > "$d/dest/alpha_0.1_all.deb"
run_sync "$d"
expect_status "every repo empty" 1
expect_output "  refusal names both repos" 'org/alpha, org/beta'
[ -f "$d/dest/alpha_0.1_all.deb" ] && ok=true || ok=false
expect_true "  nothing was pruned" "$ok"

# 3. Releases exist but none carries a .deb - a broken release workflow upstream, not an outage.
#    The counts must distinguish it from an empty API response.
d=$(new_case)
printf 'repos:\n  - repo: org/alpha\n' > "$d/repos.yaml"
printf '[{"assets":[{"name":"notes.txt","browser_download_url":"file:///dev/null"}]},{"assets":[]}]' \
    > "$d/fixtures/org_alpha.json"
run_sync "$d"
expect_status "releases exist, none with a .deb" 1
expect_output "  counts distinguish this from an empty API reply" 'returned 2 release\(s\), 0 with \.deb'

# 4. An empty API reply says so, with a release count of zero.
d=$(new_case)
printf 'repos:\n  - repo: org/alpha\n' > "$d/repos.yaml"
printf '[]' > "$d/fixtures/org_alpha.json"
run_sync "$d"
expect_status "API returned no releases at all" 1
expect_output "  counts show zero releases, not just zero selected" 'returned 0 release\(s\), 0 with \.deb'

# 5. repos.yaml listing no repos is a config mistake here, and must read differently again. An
#    empty list and a missing key are reported separately: one is "you removed the last entry",
#    the other is "this file is not shaped the way it should be".
d=$(new_case)
printf 'repos: []\n' > "$d/repos.yaml"
run_sync "$d"
expect_status "repos.yaml lists no repos" 1
expect_output "  message blames the config, not the API" 'repos: is empty, so nothing can be selected'

d=$(new_case)
printf 'keep_last_n: 5\n' > "$d/repos.yaml"
run_sync "$d"
expect_status "repos.yaml has no repos: key" 1
expect_output "  message says the key is missing, not that the list is empty" 'has no repos: key'
grep -q Traceback "$OUT" && ok=false || ok=true
expect_true "  no traceback" "$ok"

# 5b. A malformed repos.yaml must be reported against the file, not raised as a traceback naming
#     a Python type. An empty file parses as None, a top-level list parses as a list, and an
#     entry without a repo key raises KeyError - three tracebacks for one kind of hand-editing
#     mistake, in the one file a human is expected to edit.
d=$(new_case)
: > "$d/repos.yaml"
run_sync "$d"
expect_status "repos.yaml is empty" 1
expect_output "  message names the file, not a Python type" 'repos\.yaml is empty'
grep -q Traceback "$OUT" && ok=false || ok=true
expect_true "  no traceback" "$ok"

d=$(new_case)
printf -- '- just\n- a list\n' > "$d/repos.yaml"
run_sync "$d"
expect_status "repos.yaml top level is a list" 1
expect_output "  message says what the top level should be" 'must contain a mapping with a repos: key'
grep -q Traceback "$OUT" && ok=false || ok=true
expect_true "  no traceback" "$ok"

d=$(new_case)
printf 'repos:\n  - keep_last_n: 5\n' > "$d/repos.yaml"
run_sync "$d"
expect_status "repos entry has no repo key" 1
expect_output "  message names the offending entry position" 'entry 1 under repos: has no repo key'
grep -q Traceback "$OUT" && ok=false || ok=true
expect_true "  no traceback" "$ok"

# 6. gh exiting non-zero must name the repo and quote gh's own message, not raise a traceback.
d=$(new_case)
printf 'repos:\n  - repo: org/alpha\n' > "$d/repos.yaml"
printf 'FAIL\n' > "$d/fixtures/org_alpha.json"
run_sync "$d"
expect_status "gh api exits non-zero" 1
expect_output "  error names the repo" 'gh api failed for org/alpha'
expect_output "  error quotes gh stderr verbatim" 'upstream is having a bad day'
grep -q 'Traceback' "$OUT" && ok=false || ok=true
expect_true "  no traceback" "$ok"

# 7. All repos healthy: the happy path still fetches what is missing and prunes what is not
#    wanted, so the guard has not been turned into a blanket refusal.
d=$(new_case)
printf 'repos:\n  - repo: org/alpha\n  - repo: org/beta\n' > "$d/repos.yaml"
release_with_deb alpha 1.0 "$d/payload.deb" > "$d/fixtures/org_alpha.json"
release_with_deb beta 2.0 "$d/payload.deb" > "$d/fixtures/org_beta.json"
: > "$d/dest/stale_0.1_all.deb"
run_sync "$d"
expect_status "all repos healthy" 0
[ -s "$d/dest/alpha_1.0_all.deb" ] && [ -s "$d/dest/beta_2.0_all.deb" ] && ok=true || ok=false
expect_true "  both wanted .debs fetched" "$ok"
[ -f "$d/dest/stale_0.1_all.deb" ] && ok=false || ok=true
expect_true "  the unwanted .deb was pruned" "$ok"

echo
if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed."
    exit 1
fi
echo "All sync-debs checks passed."
