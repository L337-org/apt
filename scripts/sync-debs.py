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
import shutil
import subprocess
import sys
import urllib.parse
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

    Args:
        path (str): Path to repos.yaml.

    Returns:
        dict: The parsed configuration, with a "repos" list whose entries each carry a repo
        key and, optionally, keep_last_n.
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
        sys.exit(f"{path} must contain a mapping with a repos: key, but its top level is a {type(config).__name__}")

    # "absent" and "present but null" are both common hand-edit mistakes and they need different
    # messages, for the same reason repo: false needed one distinct from a missing repo key: a
    # message saying the key is missing sends the reader looking for something that is right there.
    if "repos" not in config:
        sys.exit(
            f"{path} has no repos: key - it must list the projects to aggregate, as "
            f"{{repo: owner/name}} entries, each optionally setting keep_last_n: N"
        )
    repos = config["repos"]
    if repos is None:
        sys.exit(
            f"{path}: repos: is present but empty - it must list the projects to aggregate, as "
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
        # Three distinct mistakes, three distinct messages. Collapsing them into one truthiness
        # test reported "has no repo key" for `repo: false` and `repo: 0`, where the key is
        # plainly present with a wrong value - and it short-circuited the shape check below, so
        # the more specific message could never be reached for exactly the values that needed it.
        if not isinstance(entry, dict):
            sys.exit(f"{path}: entry {position} under repos: is not a mapping - got {entry!r}")
        if "repo" not in entry:
            sys.exit(f"{path}: entry {position} under repos: has no repo key naming an owner/name - got {entry!r}")
        # A malformed repo value did not crash - it reached gh and came back as
        # "gh api failed for 123, exit 1: gh: Not Found (HTTP 404)". No traceback, but it reports
        # a config mistake as an API failure, and a maintainer reading a 404 reasonably concludes
        # the repo was deleted or renamed rather than that they mistyped this file.
        #
        # The check is deliberately loose: a string, exactly one slash, neither side empty, no
        # whitespace. It does NOT police the character classes GitHub allows, because a guard
        # that rejects a legitimate owner/name is worse than the 404 it replaces - that is how a
        # guard ends up switched off wholesale. Anything that survives this is GitHub's to judge.
        repo = entry["repo"]
        if (
            not isinstance(repo, str)
            or repo.count("/") != 1
            or not all(repo.split("/"))
            or any(character.isspace() for character in repo)
        ):
            sys.exit(
                f"{path}: entry {position} has repo={repo!r} - it must be a single owner/name, "
                f"so that a mistake here is reported as one rather than as an API 404 later"
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

    Args:
        repo (str): The owner/name of the repo to query.

    Returns:
        list: The parsed releases, newest first.
    """
    # Resolved by lookup rather than relying on PATH order: gh's location differs per runner
    # image and per install method (SU.6.3). The timeout is explicit because a call without one
    # hangs rather than failing, and this one runs once per configured repo (SU.6.4).
    gh = shutil.which("gh")
    if not gh:
        sys.exit("gh is not on PATH, so releases cannot be listed")
    result = subprocess.run(  # noqa: S603 - fixed argument list, no shell, repo comes from repos.yaml
        [gh, "api", f"repos/{repo}/releases?per_page=100"],
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
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

    Args:
        config (dict): The parsed repos.yaml contents, already validated by load_config.

    Returns:
        tuple: (wanted, empty), where wanted maps .deb filename to its browser download URL
        and empty lists the repos that yielded no .deb assets at all.
    """
    repos = config["repos"]
    wanted = {}
    claimed_by = {}  # .deb filename -> the repo that published it, for collision detection
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
                name = asset["name"]
                # The destination is a flat directory, so two repos publishing the same .deb
                # filename cannot both be served - and the previous behaviour was to let the
                # later one win silently, publishing one project's package under a name another
                # project also claims. Which one users got depended on the order of repos.yaml
                # and on what happened to be on disk already, with nothing in the output saying
                # so. There is no correct choice to make here, so refuse and name both.
                claimant = claimed_by.get(name)
                if claimant is not None and claimant != repo:
                    sys.exit(
                        f"{name} is published by both {claimant} and {repo} - the channel is a "
                        f"flat directory and can serve only one file of that name, so there is "
                        f"no way to choose. Rename the package in one of them."
                    )
                claimed_by[name] = repo
                wanted[name] = asset["browser_download_url"]
            with_debs += 1
            if with_debs >= keep:
                break
        print(f"{repo}: API returned {len(releases)} release(s), {with_debs} with .deb assets selected")
        if with_debs == 0:
            empty.append(repo)
    return wanted, empty


def download(url, destination, allow_file_urls=False):
    """Fetch one asset to a path, refusing a URL that did not come from where it should have.

    The URL arrives in a GitHub API response body rather than from configuration here, so it is
    checked against the origin it should have come from before being followed (SU.3.9). Without
    that, a compromised or malformed response could name `file:///etc/passwd` and this would
    copy it. Redirects are still followed - GitHub serves release assets from a separate object
    host - because the rule is about who chose the destination, not about staying on one host.

    Args:
        url (str): The asset's download URL, as GitHub reported it.
        destination (str): Path to write to.
        allow_file_urls (bool): Permit a file:// URL as well. Off by default and only for the
            offline test suite, which serves fixture payloads from a temporary directory. What
            it costs when on: a download URL in an API response can name any path this process
            can read, and its contents get published into the archive.

    Raises:
        SystemExit: If the URL is not permitted by the rules above.
    """
    parsed = urllib.parse.urlparse(url)
    if allow_file_urls and parsed.scheme == "file":
        shutil.copyfile(parsed.path, destination)
        return
    if parsed.scheme != "https" or not (
        parsed.hostname == "github.com" or (parsed.hostname or "").endswith(".github.com")
    ):
        sys.exit(f"refusing to fetch {url!r}: expected an https URL on a github.com host")
    # Timeout is explicit for the same reason as the gh call: a hung fetch would otherwise
    # stall the whole sync with no signal (SU.3.4).
    with urllib.request.urlopen(url, timeout=300) as response:  # noqa: S310 - scheme and host checked above
        with open(destination, "wb") as handle:
            shutil.copyfileobj(response, handle)


def sync(wanted, dest, allow_file_urls=False):
    """Make dest hold exactly the wanted .deb files, fetching and pruning as needed.

    Args:
        wanted (dict): Mapping of filename to download URL, as returned by select_wanted.
        dest (str): Existing directory to bring into line with wanted.
        allow_file_urls (bool): Passed through to download; see there.
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
            download(url, partial, allow_file_urls)
            os.replace(partial, final)  # atomic within one filesystem
        finally:
            if os.path.exists(partial):
                os.remove(partial)

    for name in sorted(have - set(wanted)):
        print(f"prune: {name}")
        os.remove(os.path.join(dest, name))


def main():
    """Parse arguments and sync the destination directory."""
    parser = argparse.ArgumentParser(description="Sync .deb release assets into a flat directory.")
    parser.add_argument("--repos-config", required=True, help="path to repos.yaml")
    parser.add_argument("--dest", required=True, help="directory to sync into (must exist)")
    parser.add_argument(
        "--allow-file-urls",
        action="store_true",
        help="also accept file:// download URLs (offline test suite only, never in CI or production)",
    )
    args = parser.parse_args()

    # A relaxation that is on says so, so a run can be audited from its own output rather than
    # by reconstructing how it was invoked (SU.1.4).
    if args.allow_file_urls:
        print(
            "WARNING: --allow-file-urls is set, so a download URL naming any readable local "
            "path will be copied into the archive. This is for the offline test suite only.",
            file=sys.stderr,
        )

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

    sync(wanted, args.dest, args.allow_file_urls)


if __name__ == "__main__":
    main()
