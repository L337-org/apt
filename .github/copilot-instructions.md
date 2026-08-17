# Copilot Instructions for apt

## Project Overview

`apt` owns the flat APT (Debian package) repository served at <https://apt.l337.org/> — the
`gh-pages` branch, published via GitHub Pages with a custom domain (`templates/CNAME`). It has no
application code: one scheduled workflow, a small Python/Bash `scripts/` set, a `repos.yaml`
config listing which org repos contribute packages, and the static files (`templates/`) copied
into the published branch. It exists so every L337-org project that ships a `.deb` can be
installed from one `apt` source line instead of each project running its own repository
infrastructure.

## Architecture

### Design: single-writer, pull-based aggregation

The aggregator *pulls* `.deb` release assets from other repos rather than having them push here.
Release assets on public repos are anonymously downloadable, so **no cross-repo credentials exist
anywhere in this design** — producing projects never authenticate to this repo, and this repo
pushes only to its own `gh-pages` with its own default `GITHUB_TOKEN`. Onboarding a new project is
just: attach a `.deb` to its GitHub Release, then add one entry to `repos.yaml`.

### `.github/workflows/aggregate.yaml` — the publishing run

Runs hourly (`cron: "17 * * * *"`) and on `workflow_dispatch`, with `concurrency.group: aggregate`
(`cancel-in-progress: false`, so a slow run is waited out rather than aborted mid-publish). Steps,
in order:

1. Check out `main` (config + templates) and `gh-pages` (the published tree) side by side.
2. `scripts/sync-debs.py` fetches missing `.deb`s per `repos.yaml` and prunes ones outside the
   configured `keep_last_n` window.
3. Copy `templates/` over `gh-pages` verbatim.
4. `scripts/build-index.sh` regenerates `Packages`/`Packages.gz`/`Release` — **unconditionally,
   before change detection**, so a change to *how* the index is built reaches the published repo
   on the very next run rather than waiting for an unrelated `.deb` or template to change.
5. `scripts/detect-changes.sh` decides whether anything is actually worth publishing; if not, the
   job stops here with no commit (hourly runs between releases are no-ops).
6. Only when something changed: import `APT_GPG_PRIVATE_KEY` into its own GnuPG homedir and sign
   `Release` → `Release.gpg`/`InRelease` (the index was already generated in step 4 — re-generating
   here would re-stamp a new `Date:` after detection had already settled, defeating the point).
7. Import `CI_COMMIT_SIGNING_KEY` into a **second, separate** GnuPG homedir, then commit and push
   to `gh-pages` signed with it. The `gh-pages` branch ruleset requires verified commit signatures,
   and the two keys are kept in separate `GNUPGHOME`s so git's invocation of `gpg` for commit
   signing can only ever reach the commit-signing key, never the APT signing key — deliberate
   isolation between two independent trust domains (see "Keys" below), not just tidiness.

Both signing-secret imports fail loudly (`::error` + non-zero exit) if the secret is unset, rather
than silently skipping signing.

### `.github/workflows/premerge.yaml` — the PR gate

Before this workflow existed, `aggregate.yaml` ran only on schedule/dispatch, so a pull request
(a Dependabot action bump, in particular) carried no status checks at all — a bump that broke
publishing would only surface on the next hourly run against the real `gh-pages`. Three jobs, all
required status checks on `main`'s ruleset:

- **`action-pins`**: greps every `uses:` in `.github/workflows` and `.github/actions` and fails
  unless it names a 40-hex commit SHA. This workflow imports both signing keys, so a mutable
  tag/branch ref on a third-party action is a real supply-chain risk here, not a style nit; local
  actions (`./...`) are exempt, and Dependabot bumps the SHA (rewriting the trailing `# vX.Y.Z`
  comment) so pinning doesn't mean going stale.
- **`change-detection`**: runs `scripts/test-detect-changes.sh` against synthetic fixtures.
- **`index-guard`**: runs `scripts/test-build-index.sh`, which drives `build-index.sh` against a
  *deliberately broken* `apt-ftparchive` stub. Deliberately separate from `aggregate-dry-run`:
  that job proves the guard **accepts** a real index, this one proves it still **rejects** a bad
  one. A guard that has quietly stopped firing is indistinguishable from a passing guard in the
  dry run, which is the gap this closes. Needs no `dpkg`/`apt-utils` — the suite stubs both.
- **`aggregate-dry-run`**: runs the *same* `sync-debs.py` and `build-index.sh` the publishing run
  uses, into a scratch directory, then asserts the generated `Packages` has at least one record
  (guards against the index "succeeding" empty and publishing a repo that resolves for clients but
  offers nothing). `build-index.sh`'s own `Release` guard (see below) fails this job too, without
  needing a step here, because it's inside the script both workflows call.

The dry run deliberately stops short of signing and pushing: it calls the same `scripts/` the
publishing run calls (so it can't drift from what actually ships), but is **never given the signing
secrets**, so it cannot touch `gh-pages` even by mistake — the job's `permissions: contents: read`
at the workflow level backs that up structurally, not just by omission of secrets.

### `scripts/build-index.sh`

`dpkg-scanpackages --multiversion .` — the `--multiversion` flag matters because `repos.yaml`'s
`keep_last_n` retains several `.deb`s per package; without it the index would advertise only the
newest, leaving older ones present on disk but uninstallable. `gzip -9nc` (`-n` omits the
filename/mtime header) so `Packages.gz` is byte-identical across runs when `Packages` is, which
matters to change detection. `apt-ftparchive release .` produces `Release`, which is **not**
reproducible — it stamps a `Date:` field on every run — a fact `detect-changes.sh` has to work
around.

`Release` is generated via a temporary file **outside** the served tree, with any existing
`Release` deleted first — deliberately, not incidentally. `apt-ftparchive`'s default pattern list
for `release` includes `Release` itself (right for a `dists/` layout, where the per-component
`Release` files below the one being generated do belong in it; wrong for a flat repo, where the
generated file is *in* the scanned directory). Written the obvious way, as `apt-ftparchive
release . > Release`, the shell truncates the old file, `apt-ftparchive` writes its header fields
(only `Date:` is non-empty by default) *before* walking the directory, and the walk then hashes
that partially-written file into its own output. The published index carried a 38-byte self-entry
for exactly that reason — 38 bytes being its own `Date:` line. **Never reintroduce a plain
`> Release` redirection here.**

The script then **guards its own output**: every checksum entry in `Release` must name a file
present in the tree at the size **and hash** claimed, `Release` must not name itself, and both
`Packages` and `Packages.gz` must be listed (so an empty `Release` can't pass by having nothing to
check). The guard lives in the script rather than in `premerge.yaml` so that it also runs in the
hourly publishing job, failing **before** the signing step instead of only gating pull requests.
The hashes are checked as well as the sizes because `apt` verifies `Packages` against the hashes in
`Release` — a wrong one there breaks `apt update` for every client, so it is worth catching before
signing rather than after publishing. A section header names the algorithm for the entries beneath
it (`MD5Sum`/`SHA1`/`SHA256`/`SHA512` → `md5sum`/`sha1sum`/`sha256sum`/`sha512sum`); an algorithm
the script doesn't know emits a `::notice::` and has its size checked but not its hash, rather than
being passed over silently, since a skipped check that looks like a passed one is how coverage
quietly shrinks.

### `scripts/detect-changes.sh`

Decides whether there's anything worth committing, run after the index is regenerated. Plain
`git status` doesn't work: `Release`'s `Date:` churns every run regardless of real change, and
`Packages` stanza order can vary with directory traversal without the content differing. So it
excludes `Packages`/`Packages.gz`/`Release` from the general diff and compares the first two of
those separately: `Packages` as an `LC_ALL=C`-sorted multiset of lines against the committed copy
(locale collation is not a total order and can rank distinct lines as equal), and `Release`
line-by-line with the churning parts filtered out. `--untracked-files=all` is load-bearing, not
decoration — with the ambient `status.showUntrackedFiles=no`, a newly-fetched `.deb` would report
no change and never get published. `Packages.gz` is excluded from comparison even though it's
currently a deterministic function of `Packages` — a future regression in the gzip step (wrong
flags, different gzip) would then differ every run rather than being treated as a real change,
which is judged the safer failure mode than the alternative. On "no change" it restores the
volatile files so the tree is left clean.

`Release` is **compared, not ignored**, and the two filters applied to it are each load-bearing:

- `Date:` is filtered out because it churns on every run; comparing it would push an identical
  repo hourly, forever.
- the `Packages.gz` **entry lines** are filtered out because `Release` carries that file's hash,
  so comparing them would reintroduce through `Release` exactly the churn that excluding
  `Packages.gz` exists to absorb.
- the **hash columns are kept**, and that is a decision, not an oversight. `apt` verifies
  `Packages` against the hashes in `Release`, so a wrong hash there breaks `apt update` for every
  client and a fix for one must publish immediately — which it wouldn't, if only sizes were
  compared. Keeping them is only safe because `dpkg-scanpackages` sorts its output (by package
  name, then version string, in dpkg's own `dpkg-scanpackages.pl`), so `Packages` is byte-stable
  for a given set of `.deb`s and its hash in `Release` cannot churn. **A generator that stopped
  sorting would turn this comparison into an hourly push of an identical repo** — if `Packages`
  generation is ever changed, re-check that property first. (The `Packages` multiset comparison
  above is insurance against exactly that, and an older comment in `detect-changes.sh` wrongly
  described the order as following directory traversal.)

Ignoring `Release` outright was the earlier behaviour and meant a change confined to `Release`
could **never** publish. The self-entry fix above is the worked example: it alters `Release` and
nothing else, so under the old detector `changed=false`, the corrected file was checked straight
back out, and the bad one stayed served until some unrelated `.deb` or template happened to move.
A `Release`-only change is precisely the "a change to *how* the index is built" case that step 4
of `aggregate.yaml` exists to publish.

### `.github/workflows/channel-install.yaml` — does the published channel actually install?

Daily (`cron: "17 5 * * *"`, offset from the daily external channel check) and on
`workflow_dispatch`. Runs the **documented** two-line sources setup inside a
`debian:stable-slim` container and installs every package the channel advertises. No secrets,
`permissions: contents: read` — it only reads a public channel.

It exists because everything else that watches the channel *inspects* it: the daily external
check verifies versions, sizes, hashes and both signatures without ever running an apt client,
and `aggregate-dry-run` builds an index in a scratch directory without ever installing from the
published one. The `apt-get update` line is the real test — apt verifies `InRelease` against the
keyring and checks `Packages` against the hashes in `Release`, so a bad signature or wrong hash
fails there rather than being reasoned about. The final check is that the **installed** version
equals the **advertised** candidate, which is what catches a channel serving something other
than what its index claims.

Three deliberate decisions, recorded so they are not re-litigated:

- **It lives here, not in each producing project.** The channel is what is under test and this
  repo is its single writer; a copy per producer would duplicate tests of infrastructure those
  repos do not control.
- **Upgrade testing is deliberately NOT here.** Upgrading from the previous release exercises a
  package's own maintainer scripts, which belong with the code that produces them.
- **No issue is filed on failure.** GitHub's own workflow-failure notification is the alert.
  Considered and rejected as unnecessary, not overlooked.

Two known limitations: the setup commands duplicate the two lines in `README.md` and can drift
from them; and the package list comes from what apt parsed out of the index, so it covers future
producers automatically but says nothing about a producer whose packages never reached the index
at all.

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

Mutation-verified: removing the self-entry check, defeating hash verification, and silencing the
unrecognised-algorithm notice each fail the suite.

### `scripts/sync-debs.py`

Shared by both workflows (imported/run the same way by the publishing job and the premerge dry
run) so the dry run can't test a copy that drifts from what actually publishes. `select_wanted()`
reads `repos.yaml` and, per repo, takes the newest `keep_last_n` releases carrying a `.deb` via
`gh api repos/{repo}/releases`. `sync()` fetches before pruning, via a temp file + atomic rename,
so a failed/partial download can't leave the destination already missing what was about to be
pruned. `main()` refuses to prune anything if `select_wanted()` returns empty — an empty result is
always a config mistake or an upstream anomaly, and pruning on it would take the whole published
channel offline.

### `scripts/test-detect-changes.sh`

Exercises `detect-changes.sh` against synthetic, hand-built git repos — no `dpkg`/`gnupg` needed,
so it runs anywhere including a developer machine. The "must NOT publish" cases (Release
`Date:`-only churn, a Release `Packages.gz`-entry-only change, reordered-but-identical `Packages`)
are the load-bearing ones: a detector that can't say "no" would sign and push an unchanged repo
every hour forever, and one that can't say "yes" is how an index-generation change went
unpublished in the first place (the original incident this script and `premerge.yaml` both exist
to catch). The Release cases pair up deliberately — `Date:`-only and `Packages.gz`-entry-only must
be ignored, a real checksum entry changing and a self-entry disappearing must publish — so each of
the two filters in `release_signal()` has a test that fails if it's dropped **and** a test that
fails if it's widened. Verified by mutation: removing the Release comparison fails exactly the two
"must publish" cases, and dropping the `Packages.gz` filter fails exactly the `Packages.gz` one.

### `repos.yaml`

The only mutable config: a list of `{repo, keep_last_n}` entries, one per producing project.
Adding a project here (after it attaches a `.deb` to its own releases) is the entire onboarding
step — no code change required.

### `templates/`

Copied verbatim onto `gh-pages` every run: `CNAME` (the custom domain), `.nojekyll` (disables
GitHub Pages' Jekyll processing, which would otherwise mangle the flat repo layout), `index.html`
(the landing page at the domain root), `README.md` (the *published* branch's own README, warning
against hand-editing since the next run overwrites it), and the two public keyring files —
`l337-apt.gpg` (current name) and `send-to-influx.gpg` (the identical key under its historical
name, kept so pre-existing installs referencing it never need to re-fetch).

## Keys

Two GPG keys, deliberately independent trust domains and rotation cycles:

- **APT package signing** (`APT_GPG_PRIVATE_KEY` secret) signs the package index
  (`Release.gpg`/`InRelease`) so `apt` clients can verify packages they install. Its public half is
  what's published as `templates/l337-apt.gpg`/`send-to-influx.gpg`.
- **CI commit signing** (`CI_COMMIT_SIGNING_KEY` secret) signs the git commit pushed to
  `gh-pages`, required by that branch's ruleset (`required_signatures`). Its public half is
  registered to the maintainer's own GitHub account, not published in this repo.

Never assume either secret's value; both are opaque to this repo's own code and only ever touched
by `gpg --import` inside `aggregate.yaml`, guarded so a no-op hourly run never imports either key
at all.

## Conventions

- No unit test framework — `scripts/test-detect-changes.sh` and `scripts/test-build-index.sh` are
  the tests, run directly by `premerge.yaml`, not through a runner. Both need only bash and (for
  the first) git, so both run on a developer machine unchanged.
- Every third-party GitHub Action `uses:` must be pinned to a 40-hex commit SHA (`action-pins`
  job enforces it); Dependabot (`.github/dependabot.yml`, weekly, grouped into one PR) bumps the
  SHA and its trailing `# vX.Y.Z` comment.
- Bash scripts run under `set -euo pipefail`; comments in the workflows and scripts carry the
  *why* for non-obvious steps (change-detection edge cases, key isolation, reproducibility
  quirks) — read them before changing behaviour, and extend them rather than paraphrasing when
  editing nearby code.
