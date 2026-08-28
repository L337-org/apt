# Fetching and pruning release assets

Deep detail behind the summaries in [../AGENTS.md](../AGENTS.md). Read this before changing
`scripts/sync-debs.py` or the prune guard.

### `scripts/sync-debs.py`

Shared by both workflows (imported/run the same way by the publishing job and the premerge dry
run) so the dry run can't test a copy that drifts from what actually publishes. `select_wanted()`
reads `repos.yaml` and, per repo, takes the newest `keep_last_n` releases carrying a `.deb` via
`gh api repos/{repo}/releases`. `sync()` fetches before pruning, via a temp file + atomic rename,
so a failed/partial download can't leave the destination already missing what was about to be
pruned.

**The prune guard is per-repo, and that distinction is the whole point.** `main()` refuses if **any**
configured repo came back with no `.deb` assets - not only if every one did. The check used to be
global (`if not wanted`), which is the same thing while exactly one repo is configured and silently
stops being safe the moment a second is added: repo A returning nothing while repo B is healthy
leaves `wanted` non-empty, so the guard wouldn't fire and **every one of A's `.deb` files would be
pruned and pushed as a normal publish**. Not hypothetical - during a GitHub incident the releases
list endpoint returned `200` with an empty array intermittently (roughly one call in eight
succeeded), so a single unlucky call suffices. `scripts/test-sync-debs.sh` pins it; reverting to the
global form makes that suite delete a fixture `.deb`, which is the defect in miniature.

Deliberate trade-off: a repo added to `repos.yaml` **before** it has published a `.deb` blocks every
run until it does. That matches the documented onboarding order (attach the `.deb`, then add the
entry), it fails loudly naming the repo, and the alternative is pruning someone's packages on a
transient API fault.

Diagnosability is part of the same fix. `select_wanted()` prints the release count **and** the
selected count, because three very different situations otherwise read identically: an empty API
reply, releases carrying no `.deb`, and a `repos.yaml` listing no repos. The refusal also states how
many `.deb` files the destination holds, so the message says what is being protected.
`releases_for()` wraps the `gh` call so a non-zero exit names the repo and quotes `gh`'s stderr
verbatim, rather than raising a `CalledProcessError` traceback that identifies neither.

Rejected, and recorded in `releases_for()`'s docstring so it isn't re-proposed: cross-checking
`/releases/latest` or the atom feed to distinguish "the list endpoint lied" from "genuinely empty".
Both were observed answering correctly during the incident, so it would have worked - but it adds a
second network call and a hint that can itself mislead, and the counts already make the situation
legible.
