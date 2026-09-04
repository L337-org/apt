# CI and the publishing workflows

Deep detail behind the summaries in [../AGENTS.md](../AGENTS.md). Read this before changing
anything under `.github/workflows/`.

### The `report-cancelled-as-failure` job (`aggregate.yaml`, `channel-install.yaml`)

One job per scheduled workflow, `needs` the real job, `if: always() && needs.<job>.result ==
'cancelled'`, and does nothing but emit an error annotation and `exit 1`. Its whole purpose is to
turn the `cancelled` conclusion a `timeout-minutes` kill produces into a `failure`, so an
unattended hang notifies and shows up in a failed-run sweep instead of passing unseen.

It is safe in these two workflows **because** both set `cancel-in-progress: false`: nothing
supersedes them, so the only routes to `cancelled` are the timeout and a human pressing cancel, and
both deserve a notification on a run nobody is watching. `premerge.yaml` deliberately has **no**
equivalent - `cancel-in-progress: true` there means a superseded re-push cancels routinely, so the
guard would fire on ordinary PR activity; a cancelled premerge run also blocks the merge in front
of a human, which is the notification. Adding it there would need the ruleset updating too, since a
new job name is not a required check.

### `.github/workflows/aggregate.yaml` - the publishing run

Runs hourly (`cron: "17 * * * *"`) and on `workflow_dispatch`, with `concurrency.group: aggregate`
(`cancel-in-progress: false`, so a slow run is waited out rather than aborted mid-publish). Steps,
in order:

1. Check out `main` (config + templates) and `gh-pages` (the published tree) side by side.
2. `scripts/sync-debs.py` fetches missing `.deb`s per `repos.yaml` and prunes ones outside the
   configured `keep_last_n` window.
3. Copy `templates/` over `gh-pages` verbatim.
4. `scripts/build-index.sh` regenerates `Packages`/`Packages.gz`/`Release` - **unconditionally,
   before change detection**, so a change to *how* the index is built reaches the published repo
   on the very next run rather than waiting for an unrelated `.deb` or template to change.
5. `scripts/detect-changes.sh` decides whether anything is actually worth publishing; if not, the
   job stops here with no commit (hourly runs between releases are no-ops).
6. Only when something changed: import `APT_GPG_PRIVATE_KEY` into its own GnuPG homedir and sign
   `Release` -> `Release.gpg`/`InRelease` (the index was already generated in step 4 - re-generating
   here would re-stamp a new `Date:` after detection had already settled, defeating the point).
7. Import `CI_COMMIT_SIGNING_KEY` into a **second, separate** GnuPG homedir, then commit and push
   to `gh-pages` signed with it. The `gh-pages` branch ruleset requires verified commit signatures,
   and the two keys are kept in separate `GNUPGHOME`s so git's invocation of `gpg` for commit
   signing can only ever reach the commit-signing key, never the APT signing key - deliberate
   isolation between two independent trust domains (see "Keys" below), not just tidiness.

Both signing-secret imports fail loudly (`::error` + non-zero exit) if the secret is unset, rather
than silently skipping signing.

**A failed run files no issue, and that is a decision rather than an omission.** The org standard for
unattended runs is normally to raise a deduplicated issue, and it was considered here after four
consecutive hourly runs failed unnoticed during a GitHub incident. Rejected because an issue is only
worth as much as its visibility, and the maintainer does not routinely watch **this** repo's issues,
whereas GitHub's own workflow-failure notification does reach them - so filing one would be strictly
less visible than the alert that already exists, while adding `issues: write` to a workflow that
holds both signing keys. If a louder channel is ever wanted, the place to look is the existing daily
channel check, which already posts to Slack.

### `.github/workflows/premerge.yaml` - the PR gate

Before this workflow existed, `aggregate.yaml` ran only on schedule/dispatch, so a pull request
(a Dependabot action bump, in particular) carried no status checks at all - a bump that broke
publishing would only surface on the next hourly run against the real `gh-pages`. Six jobs, all
required status checks on `main`'s ruleset:

- **`action-pins`**: greps every `uses:` in `.github/workflows` and `.github/actions` and fails
  unless it names a 40-hex commit SHA. This workflow imports both signing keys, so a mutable
  tag/branch ref on a third-party action is a real supply-chain risk here, not a style nit; local
  actions (`./...`) are exempt, and Dependabot bumps the SHA (rewriting the trailing `# vX.Y.Z`
  comment) so pinning doesn't mean going stale.
- **`repo-hygiene`**: runs `scripts/check-repo-hygiene.py`, vendored byte-identically into every
  repository in the organisation and checking what they all share - no tracker keys or internal
  Atlassian links in a public repository, every CI job declaring a timeout **and** that timeout
  being a usable bound, and the instruction layer routing to its detail files in both directions.
  The timeout half used to live inside `action-pins` here; keeping both would be two guards
  checking one thing and drifting the first time either was edited, which is the divergence this
  vendoring exists to avoid. Without a timeout a job inherits GitHub's **6-hour**
  default. That is not theoretical: a hang in `Install apt repo tooling` stalled the hourly
  publisher for six hours and, because `cancel-in-progress: false` keeps one pending run per
  group, silently **cancelled every run queued behind it** while reporting nothing, since a stall
  is not a failure. Four jobs run `apt-get install` on the runner, which is where that hang
  happened. Every job is set to **15 minutes** against a normal runtime under 40 seconds: enough
  headroom that it cannot fire on a slow-but-working run. Be careful about what that buys you: a
  job killed by `timeout-minutes` reports `conclusion: **cancelled**`, never `failure` and never
  `timed_out`, so **the timeout alone raises no workflow-failure notification** and is invisible to
  any tooling sweeping for failed runs. This was confirmed the hard way - the same hang recurred
  five times in ~16.5 hours in Aug 2026 and every occurrence had to be found by reading the run
  list by hand. Converting the cancellation into a failure is a separate job,
  `report-cancelled-as-failure`, described near the top of this document, and it exists only in the
  two scheduled workflows. The check lives in this job
  rather than a new one because the job name is a required check on `main` and a new one would need
  adding to the ruleset - which is also why the name still mentions only pins.
- **`change-detection`**: runs `scripts/test-detect-changes.sh` against synthetic fixtures.
- **`sync-guard`**: runs `scripts/test-sync-debs.sh` against a stubbed `gh`. Covers what
  `aggregate-dry-run` structurally cannot: `repos.yaml` has one entry, so no dry run can exercise
  the multi-repo prune case.
- **`index-guard`**: runs `scripts/test-build-index.sh`, which drives `build-index.sh` against a
  *deliberately broken* `apt-ftparchive` stub. Deliberately separate from `aggregate-dry-run`:
  that job proves the guard **accepts** a real index, this one proves it still **rejects** a bad
  one. A guard that has quietly stopped firing is indistinguishable from a passing guard in the
  dry run, which is the gap this closes. Needs no `dpkg`/`apt-utils` - the suite stubs both.
- **`aggregate-dry-run`**: runs the *same* `sync-debs.py` and `build-index.sh` the publishing run
  uses, into a scratch directory, then asserts the generated `Packages` has at least one record
  (guards against the index "succeeding" empty and publishing a repo that resolves for clients but
  offers nothing). `build-index.sh`'s own `Release` guard (see below) fails this job too, without
  needing a step here, because it's inside the script both workflows call.

The dry run deliberately stops short of signing and pushing: it calls the same `scripts/` the
publishing run calls (so it can't drift from what actually ships), but is **never given the signing
secrets**, so it cannot touch `gh-pages` even by mistake - the job's `permissions: contents: read`
at the workflow level backs that up structurally, not just by omission of secrets.

### `.github/workflows/channel-install.yaml` - does the published channel actually install?

Daily (`cron: "17 5 * * *"`, offset from the daily external channel check) and on
`workflow_dispatch`. Runs the **documented** two-line sources setup inside a
`debian:stable-slim` container and installs every package the channel advertises. No secrets,
`permissions: contents: read` - it only reads a public channel.

It exists because everything else that watches the channel *inspects* it: the daily external
check verifies versions, sizes, hashes and both signatures without ever running an apt client,
and `aggregate-dry-run` builds an index in a scratch directory without ever installing from the
published one. The `apt-get update` line is the real test - apt verifies `InRelease` against the
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
