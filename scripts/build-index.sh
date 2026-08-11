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

# Release is NOT reproducible: apt-ftparchive stamps a Date: field into it, so it differs
# on every run by construction. detect-changes.sh accounts for that.
apt-ftparchive release . > Release
