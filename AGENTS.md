# AGENTS.md

The shared instruction file for this repository. Every assistant reads this one; `CLAUDE.md` and
`.github/copilot-instructions.md` are pointers to it.

## Read these before changing the matching area

Each note holds the reasoning behind a part of the pipeline whose failure modes are silent. These
are not optional background.

| Before changing | Read |
|---|---|
| anything under `.github/workflows/` | [architecture/ci.md](architecture/ci.md) |
| `scripts/build-index.sh`, `scripts/detect-changes.sh`, `templates/` | [architecture/indexing.md](architecture/indexing.md) |
| `scripts/sync-debs.py` or the prune guard | [architecture/sync.md](architecture/sync.md) |
| any `scripts/test-*.sh` suite | [architecture/testing.md](architecture/testing.md) |

## Project Overview

`apt` owns the flat APT (Debian package) repository served at <https://apt.l337.org/> — the
`gh-pages` branch, published via GitHub Pages with a custom domain (`templates/CNAME`). It has no
application code: scheduled workflows, a small Python/Bash `scripts/` set, a `repos.yaml`
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

### `repos.yaml`

The only mutable config: a list of entries, one per producing project, each naming a `repo` and
optionally setting `keep_last_n` (a default applies when it is omitted).
Adding a project here (after it attaches a `.deb` to its own releases) is the entire onboarding
step — no code change required.

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

- No unit test framework - the `scripts/test-*.sh` set is the tests, run directly by
  `premerge.yaml`, not through a runner. They need bash, plus git for `test-detect-changes.sh`
  and python3 with PyYAML for `test-sync-debs.sh`, so they run on a developer machine unchanged.
- Every third-party GitHub Action `uses:` must be pinned to a 40-hex commit SHA (`action-pins`
  job enforces it); Dependabot (`.github/dependabot.yml`, weekly, grouped into one PR) bumps the
  SHA and its trailing `# vX.Y.Z` comment.
- Bash scripts run under `set -euo pipefail`; comments in the workflows and scripts carry the
  *why* for non-obvious steps (change-detection edge cases, key isolation, reproducibility
  quirks) — read them before changing behaviour, and extend them rather than paraphrasing when
  editing nearby code.

<!-- BEGIN GENERATED -->
## Read these when they apply

- Read `.agents/policy/review-context.md` always - these apply to every activity.
- Read `.agents/policy/testing.md` when writing or running tests, or adding behaviour that needs them.
- Read `.agents/policy/architecture.md` when changing module structure, public surface, docstrings, generated files, deprecation, or log levels.

<!-- END GENERATED -->
