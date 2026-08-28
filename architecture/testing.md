# The test suites

Deep detail behind the summaries in [../AGENTS.md](../AGENTS.md). Read this before changing
any of the `scripts/test-*.sh` suites or the behaviour they pin.

### `scripts/test-build-index.sh`

Drives the real `build-index.sh` with `dpkg-scanpackages` and `apt-ftparchive` stubbed on `PATH`,
so it runs anywhere including a developer machine. `$MODE` selects the malformation: well-formed,
self-entry, entry for an absent file, wrong size, wrong hash, unrecognised algorithm, empty
output. The stub computes **real** sizes and hashes from the real files for entries a scenario
wants correct, so the well-formed case has to genuinely agree with the tree rather than passing by
coincidence. `md5sum`/`sha*sum` are shimmed **only if missing** (macOS), so a Linux run uses the
real binaries.

Two things about its shape are load-bearing:

- Cases assert **what the failure says**, not only that it happened. Removing the self-entry check
  from the guard still produces a non-zero exit (the size check catches it incidentally), so only
  the message assertion distinguishes the two.
- The runner must **not** be called via `out=$(...)`. Command substitution runs it in a subshell,
  where an incremented failure counter is discarded on exit and the suite reports success with a
  broken case inside it. The output goes to a file and the status into a global for that reason.

- Reading file modes portably needs the **GNU form first**: `stat -c '%a'` then `stat -f '%Lp'`.
  BSD `stat` rejects `-c` and exits non-zero, so it falls through cleanly - but GNU `stat`
  *accepts* `-f` (there it means "file system status") and prints `?` for an unknown directive
  while **exiting zero**, so a BSD-first fallback silently yields `?` on Linux. That is exactly how
  the mode assertion passed locally and failed in CI on the first run of this job.

Mutation-verified: removing the self-entry check, defeating hash verification, silencing the
unrecognised-algorithm notice, and dropping the `chmod` each fail the suite.

### `scripts/test-sync-debs.sh`

Stubs `gh` on `PATH` and uses `file://` download URLs, so it needs no network and no credentials  - 
only python3 with PyYAML. Seven cases: one repo empty while another is healthy (**the load-bearing
one** - a global guard passes this while deleting files), every repo empty, releases without a
`.deb`, an empty API reply, a `repos.yaml` with no repos, `gh` exiting non-zero, and the happy path
still fetching and pruning so the guard hasn't become a blanket refusal. Run by the `sync-guard`
premerge job.

### `scripts/test-detect-changes.sh`

Exercises `detect-changes.sh` against synthetic, hand-built git repos - no `dpkg`/`gnupg` needed,
so it runs anywhere including a developer machine. The "must NOT publish" cases (Release
`Date:`-only churn, a Release `Packages.gz`-entry-only change, reordered-but-identical `Packages`)
are the load-bearing ones: a detector that can't say "no" would sign and push an unchanged repo
every hour forever, and one that can't say "yes" is how an index-generation change went
unpublished in the first place (the original incident this script and `premerge.yaml` both exist
to catch). The Release cases pair up deliberately - `Date:`-only and `Packages.gz`-entry-only must
be ignored, a real checksum entry changing and a self-entry disappearing must publish - so each of
the two filters in `release_signal()` has a test that fails if it's dropped **and** a test that
fails if it's widened. Verified by mutation: removing the Release comparison fails exactly the two
"must publish" cases, and dropping the `Packages.gz` filter fails exactly the `Packages.gz` one.
