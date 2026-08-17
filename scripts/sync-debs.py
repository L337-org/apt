#!/usr/bin/env python3

"""Sync .deb release assets from the repos in repos.yaml into a flat directory.

Takes the newest ``keep_last_n`` releases carrying a .deb asset from each configured
repo, downloads any that the destination is missing, and prunes any .deb there that is
no longer wanted. Older versions stay available on each project's own Releases page.

Lives in a script rather than inline in the workflow so that the publishing run and the
pull-request dry run execute the same code, instead of the dry run testing a copy that
can drift away from what actually publishes.
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.request

# Applied when an entry omits keep_last_n. Named once so load_config's validation and
# select_wanted's use of it cannot drift apart; repos.yaml records that the key is optional
# without repeating the number, so there is nothing there to go stale.
DEFAULT_KEEP_LAST_N = 5


def load_config(path):
    """Load and validate the repo list.

    The shape is checked here rather than trusted downstream, because every malformed shape
    otherwise surfaces as a traceback naming a Python type instead of the file at fault. An
    empty file parses as None, a top-level list parses as a list, and an entry without a repo
    key raises KeyError - three different tracebacks for what is one kind of mistake, in a file
    a human edits by hand.

    args: path - Path to repos.yaml
    returns: dict - The parsed configuration, with a "repos" list whose entries each carry a
             repo key and, optionally, keep_last_n
    """
    try:
        import yaml
    except ImportError:
        sys.exit("PyYAML missing on runner - install python3-yaml in this step")
    # Reading and parsing are wrapped for the same reason the shape checks below exist: a
    # traceback is never the intended output for a mistake in a hand-edited config file. A YAML
    # syntax error is the likeliest of the lot - an indentation slip or a stray bracket - and
    # PyYAML's own message already carries the line and column, so it is quoted rather than
    # summarised.
    try:
        with open(path) as handle:
            config = yaml.safe_load(handle)
    except OSError as exc:
        sys.exit(f"cannot read {path}: {exc.strerror or exc}")
    except yaml.YAMLError as exc:
        sys.exit(f"{path} is not valid YAML:\n{exc}")

    if config is None:
        sys.exit(f"{path} is empty - it must contain a repos: list")
    if not isinstance(config, dict):
        sys.exit(
            f"{path} must contain a mapping with a repos: key, "
            f"but its top level is a {type(config).__name__}"
        )

    repos = config.get("repos")
    if repos is None:
        sys.exit(
            f"{path} has no repos: key - it must list the projects to aggregate, as "
            f"{{repo: owner/name}} entries, each optionally setting keep_last_n: N"
        )
    if not isinstance(repos, list):
        sys.exit(f"{path}: repos: must be a list, not a {type(repos).__name__}")
    if not repos:
        sys.exit(
            f"{path}: repos: is empty, so nothing can be selected - refusing, because "
            f"pruning against an empty selection would empty the published channel"
        )
    for position, entry in enumerate(repos, start=1):
        if not isinstance(entry, dict) or not entry.get("repo"):
            sys.exit(
                f"{path}: entry {position} under repos: has no repo key naming an "
                f"owner/name - got {entry!r}"
            )
        # keep_last_n was cast with int() at the point of use, so a hand-edited "five" raised a
        # ValueError - the same traceback-instead-of-message this validation exists to remove.
        # A bool is rejected explicitly because isinstance(True, int) is True in Python, and
        # `keep_last_n: true` is not a count. Below 1 is rejected rather than tolerated: the
        # selection loop breaks on `with_debs >= keep` AFTER adding a release, so 0 silently
        # selected one, which is not what anyone writing 0 could have meant.
        keep = entry.get("keep_last_n", DEFAULT_KEEP_LAST_N)
        if isinstance(keep, bool) or not isinstance(keep, int) or keep < 1:
            sys.exit(
                f"{path}: entry {position} ({entry['repo']}) has keep_last_n={keep!r} - "
                f"it must be a whole number of releases, 1 or more"
            )

    return config


def releases_for(repo):
    """Fetch a repo's releases, newest first.

    Wrapped rather than calling subprocess.check_output directly so that a non-zero exit from
    gh produces an error naming the repo and quoting gh's own message, instead of a bare
    CalledProcessError traceback that says neither. An API failure was previously less
    diagnosable than a successful-but-empty response, which is the wrong way round.

    Cross-checking a second endpoint (/releases/latest, or the releases atom feed) to tell "the
    list endpoint returned an empty array despite releases existing" from "this repo genuinely
    has no releases" was considered and rejected. Both were observed answering correctly while
    the list endpoint returned an empty array, so it would have identified the real cause during
    the incident that prompted this. It is not done because it adds a second network call and a
    hint that can itself be wrong, while the release counts printed by select_wanted already
    make the situation legible to a human. Revisit if that turns out not to be enough.

    args: repo - The owner/name of the repo to query
    returns: list - The parsed releases, newest first
    """
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/releases?per_page=100"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.exit(
            f"gh api failed for {repo}, exit {result.returncode}: "
            f"{result.stderr.strip() or '(gh wrote nothing to stderr)'}"
        )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        sys.exit(f"gh api returned unparseable JSON for {repo}: {exc}")


def select_wanted(config):
    """Resolve the configured repos to the set of .deb assets that should be served.

    Reports the release count alongside the selected count, because three very different
    situations otherwise produce the same output: an API returning nothing (an upstream fault,
    or a genuinely empty repo), releases that carry no .deb asset (a broken release workflow in
    the producing project), and a repos.yaml listing no repos (a mistake here). Distinguishing
    them costs one number and saves guessing which of the three has happened.

    The shape of config is guaranteed by load_config, which is the one place repos.yaml is
    validated - so this iterates it directly rather than re-checking, and a caller building a
    config by hand is expected to satisfy the same contract.

    args: config - The parsed repos.yaml contents, already validated by load_config
    returns: tuple - (wanted, empty) where wanted maps .deb filename to its browser download
             URL, and empty lists the repos that yielded no .deb assets at all
    """
    repos = config["repos"]
    wanted = {}
    empty = []
    for entry in repos:
        repo = entry["repo"]
        keep = entry.get("keep_last_n", DEFAULT_KEEP_LAST_N)  # validated by load_config
        releases = releases_for(repo)
        with_debs = 0
        for release in releases:  # newest first
            debs = [a for a in release["assets"] if a["name"].endswith(".deb")]
            if not debs:
                continue
            for asset in debs:
                wanted[asset["name"]] = asset["browser_download_url"]
            with_debs += 1
            if with_debs >= keep:
                break
        print(
            f"{repo}: API returned {len(releases)} release(s), "
            f"{with_debs} with .deb assets selected"
        )
        if with_debs == 0:
            empty.append(repo)
    return wanted, empty


def sync(wanted, dest):
    """Make dest hold exactly the wanted .deb files, fetching and pruning as needed.

    args: wanted - Mapping of filename to download URL, as returned by select_wanted
    args: dest - Existing directory to bring into line with wanted
    returns: None
    """
    have = {f for f in os.listdir(dest) if f.endswith(".deb")}

    # Fetch before pruning, and download via a temporary name so a .deb only ever appears
    # at its final path once complete. A failed or partial download then leaves the
    # destination exactly as it was, rather than already missing what was pruned. The
    # publishing workflow happens to gate its push on every step succeeding, so a mid-run
    # failure could not reach the served repo either way - but this function should be
    # correct on its own terms, not because of how one caller sequences its steps.
    for name, url in sorted(wanted.items()):
        if name in have:
            continue
        print(f"fetch: {name}")
        final = os.path.join(dest, name)
        partial = f"{final}.part"
        try:
            urllib.request.urlretrieve(url, partial)
            os.replace(partial, final)  # atomic within one filesystem
        finally:
            if os.path.exists(partial):
                os.remove(partial)

    for name in sorted(have - set(wanted)):
        print(f"prune: {name}")
        os.remove(os.path.join(dest, name))


def main():
    """Parse arguments and sync the destination directory.

    returns: None
    """
    parser = argparse.ArgumentParser(description="Sync .deb release assets into a flat directory.")
    parser.add_argument("--repos-config", required=True, help="path to repos.yaml")
    parser.add_argument("--dest", required=True, help="directory to sync into (must exist)")
    args = parser.parse_args()

    if not os.path.isdir(args.dest):
        sys.exit(f"destination is not a directory: {args.dest}")

    wanted, empty = select_wanted(load_config(args.repos_config))

    # Refuse if ANY configured repo came back with nothing, not only if every one did.
    #
    # The check used to be global (`if not wanted`), which is the same thing while exactly one
    # repo is configured and silently stops being safe the moment a second is added: repo A
    # returning nothing while repo B is healthy leaves `wanted` non-empty, so the guard would
    # not fire and every one of A's .deb files would be pruned and pushed as a normal publish.
    # An empty result is always a config mistake or an upstream anomaly, never a legitimate
    # instruction to delete a project's packages.
    #
    # This was not hypothetical: during a GitHub incident the releases list endpoint returned
    # HTTP 200 with an empty array intermittently - roughly one call in eight succeeded - so a
    # single unlucky call, rather than a sustained outage, is enough to hit it.
    #
    # The trade-off, deliberately taken: a repo added to repos.yaml before it has published a
    # .deb blocks every run until it does. That is the documented onboarding order anyway
    # (attach the .deb first, then add the entry), it fails loudly naming the repo, and the
    # alternative is pruning someone's packages on a transient API fault.
    if empty:
        have = [f for f in os.listdir(args.dest) if f.endswith(".deb")]
        sys.exit(
            f"no .deb assets selected from {', '.join(empty)} - refusing to prune the "
            f"destination, which currently holds {len(have)} .deb file(s)"
        )

    sync(wanted, args.dest)


if __name__ == "__main__":
    main()
