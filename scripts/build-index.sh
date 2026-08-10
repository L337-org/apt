#!/usr/bin/env bash

# Regenerate the flat APT repo index in the current working directory.
#
# Signing is deliberately NOT done here. The publishing run calls this and then signs
# Release with the APT key; the pull-request dry run calls this alone, so it exercises
# the real index generation without needing - or having - access to any key.

set -euo pipefail

dpkg-scanpackages . /dev/null > Packages
gzip -9c Packages > Packages.gz
apt-ftparchive release . > Release
