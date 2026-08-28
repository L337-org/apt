# Index generation and change detection

Deep detail behind the summaries in [../AGENTS.md](../AGENTS.md). Read this before changing
`scripts/build-index.sh`, `scripts/detect-changes.sh` or anything under `templates/`.

### `scripts/build-index.sh`

`dpkg-scanpackages --multiversion .` - the `--multiversion` flag matters because `repos.yaml`'s
`keep_last_n` retains several `.deb`s per package; without it the index would advertise only the
newest, leaving older ones present on disk but uninstallable. `gzip -9nc` (`-n` omits the
filename/mtime header) so `Packages.gz` is byte-identical across runs when `Packages` is, which
matters to change detection. `apt-ftparchive release .` produces `Release`, which is **not**
reproducible - it stamps a `Date:` field on every run - a fact `detect-changes.sh` has to work
around.

`Release` is generated via a temporary file **outside** the served tree, with any existing
`Release` deleted first - deliberately, not incidentally. `apt-ftparchive`'s default pattern list
for `release` includes `Release` itself (right for a `dists/` layout, where the per-component
`Release` files below the one being generated do belong in it; wrong for a flat repo, where the
generated file is *in* the scanned directory). Written the obvious way, as `apt-ftparchive
release . > Release`, the shell truncates the old file, `apt-ftparchive` writes its header fields
(only `Date:` is non-empty by default) *before* walking the directory, and the walk then hashes
that partially-written file into its own output. The published index carried a 38-byte self-entry
for exactly that reason - 38 bytes being its own `Date:` line. **Never reintroduce a plain
`> Release` redirection here.**

The script then **guards its own output**: every checksum entry in `Release` must name a file
present in the tree at the size **and hash** claimed, `Release` must not name itself, and both
`Packages` and `Packages.gz` must be listed (so an empty `Release` can't pass by having nothing to
check). The guard lives in the script rather than in `premerge.yaml` so that it also runs in the
hourly publishing job, failing **before** the signing step instead of only gating pull requests.
The hashes are checked as well as the sizes because `apt` verifies `Packages` against the hashes in
`Release` - a wrong one there breaks `apt update` for every client, so it is worth catching before
signing rather than after publishing. A section header names the algorithm for the entries beneath
it (`MD5Sum`/`SHA1`/`SHA256`/`SHA512` -> `md5sum`/`sha1sum`/`sha256sum`/`sha512sum`); an algorithm
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
decoration - with the ambient `status.showUntrackedFiles=no`, a newly-fetched `.deb` would report
no change and never get published. `Packages.gz` is excluded from comparison even though it's
currently a deterministic function of `Packages` - a future regression in the gzip step (wrong
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
  client and a fix for one must publish immediately - which it wouldn't, if only sizes were
  compared. Keeping them is only safe because `dpkg-scanpackages` sorts its output (by package
  name, then version string, in dpkg's own `dpkg-scanpackages.pl`), so `Packages` is byte-stable
  for a given set of `.deb`s and its hash in `Release` cannot churn. **A generator that stopped
  sorting would turn this comparison into an hourly push of an identical repo** - if `Packages`
  generation is ever changed, re-check that property first. (The `Packages` multiset comparison
  above is insurance against exactly that, and an older comment in `detect-changes.sh` wrongly
  described the order as following directory traversal.)

Ignoring `Release` outright was the earlier behaviour and meant a change confined to `Release`
could **never** publish. The self-entry fix above is the worked example: it alters `Release` and
nothing else, so under the old detector `changed=false`, the corrected file was checked straight
back out, and the bad one stayed served until some unrelated `.deb` or template happened to move.
A `Release`-only change is precisely the "a change to *how* the index is built" case that step 4
of `aggregate.yaml` exists to publish.

### `templates/`

Copied verbatim onto `gh-pages` every run: `CNAME` (the custom domain), `.nojekyll` (disables
GitHub Pages' Jekyll processing, which would otherwise mangle the flat repo layout), `index.html`
(the landing page at the domain root), `README.md` (the *published* branch's own README, warning
against hand-editing since the next run overwrites it), and the two public keyring files -
`l337-apt.gpg` (current name) and `send-to-influx.gpg` (the identical key under its historical
name, kept so pre-existing installs referencing it never need to re-fetch).
