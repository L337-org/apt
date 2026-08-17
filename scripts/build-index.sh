#!/usr/bin/env bash

# Regenerate the flat APT repo index in the current working directory.
#
# Signing is deliberately NOT done here. The publishing run calls this and then signs
# Release with the APT key; the pull-request dry run calls this alone, so it exercises
# the real index generation without needing - or having - access to any key.

set -euo pipefail

# --multiversion: without it dpkg-scanpackages emits only the newest version of each
# package, so repos.yaml's keep_last_n would store several .deb files while the index
# advertised just one - leaving the rest present on disk but uninstallable.
dpkg-scanpackages --multiversion . /dev/null > Packages

# -n omits the input filename and mtime from the gzip header. Without it Packages.gz
# differs byte-for-byte on every run even when Packages is identical, because the header
# carries the regenerated file's timestamp - which would make change detection see churn
# where there is none.
gzip -9nc Packages > Packages.gz

# Nothing named Release may exist in this directory while apt-ftparchive scans it, and its
# output must not land here either.
#
# apt-ftparchive's default pattern list for `release` includes "Release" itself. That is
# right for a dists/ layout, where the per-component Release files below the one being
# generated genuinely do belong in it, and wrong for a flat repo, where the file being
# generated sits in the directory being scanned. Written the obvious way, as
# `apt-ftparchive release . > Release`, three things combine: the shell truncates the old
# file before apt-ftparchive starts, apt-ftparchive writes its header fields (only Date: is
# non-empty by default) before it walks the directory, and the walk then reaches that
# partially-written file and hashes it into its own output. The published index carried a
# self-entry of exactly 38 bytes for that reason - 38 bytes being its own Date: line. No apt
# client reads that entry, but a mirroring tool that verifies every entry in Release sees a
# size and checksum matching no file that was ever served.
#
# If apt-ftparchive fails, set -e stops the script with no Release in place. That is the safe
# direction: the caller aborts, so nothing signs or publishes a partial index.
rm -f Release
tmpdir=${TMPDIR:-/tmp}
tmpdir=${tmpdir%/}
release_tmp=$(mktemp "$tmpdir/build-index-release.XXXXXX")
trap 'rm -f "$release_tmp"' EXIT
apt-ftparchive release . > "$release_tmp"
mv "$release_tmp" Release
# mktemp creates the file 0600 and mv preserves that. Only the executable bit reaches git, so
# this does not change what gets published, but the served tree should not depend on that.
chmod 644 Release

# Release is NOT reproducible: apt-ftparchive stamps a Date: field into it, so it differs
# on every run by construction. detect-changes.sh accounts for that.

# Every checksum entry in Release must describe a file that is actually being served, at the
# size AND hash claimed, and Release must never describe itself. That is the property the
# self-entry above broke, asserted here rather than in premerge.yaml so that it runs in the
# hourly publishing job too: a malformed index then fails before the signing step, instead of
# being signed and pushed.
#
# The hashes matter as much as the sizes, because apt verifies Packages against the hashes in
# Release: a wrong one there breaks `apt update` for every client, so it is worth catching
# before signing rather than after publishing.
#
# Entry lines are the ones indented by a space - Date: and the section headers are not, and a
# section header is what says which algorithm the entries under it use.
while read -r section hash size name; do
    if [ "$name" = Release ]; then
        echo "::error::Generated Release lists a checksum entry for itself (${size} bytes)." >&2
        exit 1
    fi
    if [ ! -f "$name" ]; then
        echo "::error::Generated Release lists ${name}, which is not present in the tree." >&2
        exit 1
    fi
    actual=$(wc -c < "$name" | tr -d '[:space:]')
    if [ "$actual" != "$size" ]; then
        echo "::error::Generated Release declares ${name} as ${size} bytes; it is ${actual}." >&2
        exit 1
    fi
    # An algorithm this script does not know about is reported rather than passed over in
    # silence: a skipped check that looks like a passed one is how coverage quietly shrinks.
    case $section in
        MD5Sum) tool=md5sum ;;
        SHA1) tool=sha1sum ;;
        SHA256) tool=sha256sum ;;
        SHA512) tool=sha512sum ;;
        *)
            echo "::notice::Release section '${section}' uses an algorithm this script cannot" \
                 "verify; the size of ${name} was checked but its hash was not."
            continue
            ;;
    esac
    actual_hash=$("$tool" "$name" | cut -d' ' -f1)
    if [ "$actual_hash" != "$hash" ]; then
        echo "::error::Generated Release declares ${section} for ${name} as ${hash};" \
             "it is ${actual_hash}." >&2
        exit 1
    fi
done < <(awk '/^[A-Za-z0-9-]+:$/ {section = substr($0, 1, length($0) - 1); next}
              /^ / {print section, $1, $2, $3}' Release)

# ...and it must list both index files. Without this, an empty or truncated Release passes the
# loop above by having no entries to check.
for required in Packages Packages.gz; do
    if ! awk -v want="$required" '/^ / && $3 == want {found = 1} END {exit !found}' Release; then
        echo "::error::Generated Release has no checksum entry for ${required}." >&2
        exit 1
    fi
done
