# L337-org APT repository

This repo owns the flat APT repository served at **<https://apt.l337.org/>** (its `gh-pages`
branch, via GitHub Pages with a custom domain).

## Design: single-writer, pull-based aggregation

`.github/workflows/aggregate.yaml` runs hourly (and on demand via *Run workflow*). Each run:

1. Reads `repos.yaml` and, for each listed project, takes the newest `keep_last_n` GitHub
   Releases that carry a `.deb` asset. Release assets on public repos are anonymously
   downloadable, so **no cross-repo credentials exist anywhere in this design** — producing
   projects never push here, and this workflow pushes only to its own `gh-pages` with its own
   `GITHUB_TOKEN`.
2. Downloads missing `.deb`s, prunes ones that fell out of the window, and copies in the static
   files from `templates/` (`CNAME`, `index.html`, `README.md`, the public keyrings).
3. If nothing changed, stops — hourly runs between releases are no-ops with no commit.
4. Otherwise regenerates `Packages`/`Release`, signs them with the APT key
   (`APT_GPG_PRIVATE_KEY` secret), and pushes a signed commit (`CI_COMMIT_SIGNING_KEY` secret;
   the `gh-pages` ruleset requires verified signatures).

## Onboarding a new project

1. Make the project's release workflow attach its `.deb` to the GitHub Release.
2. Add one entry to `repos.yaml` here.
3. Its packages appear at `https://apt.l337.org/` within the hour (or press *Run workflow*).

Users need only one sources entry for every L337-org package:

    curl -fsSL https://apt.l337.org/l337-apt.gpg | sudo tee /usr/share/keyrings/l337-apt.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/l337-apt.gpg] https://apt.l337.org/ ./" | sudo tee /etc/apt/sources.list.d/l337-apt.list
    sudo apt update

(`send-to-influx.gpg` is the same key under its historical name, kept so pre-existing installs
never need to re-fetch.)

## Keys

- APT package signing: `E46E42647810338BDA88730E97CF6528E790FC9E` (public halves published as
  `l337-apt.gpg` / `send-to-influx.gpg`, committed in `templates/`).
- CI commit signing: `EA20403748B47716E87D56E37FECBE1F16617F8B` (public half registered to the
  maintainer's GitHub account; separate trust domain and rotation cycle from the APT key).
