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


def load_config(path):
    """Load the repo list.

    args: path - Path to repos.yaml
    returns: dict - The parsed configuration, with a "repos" list
    """
    try:
        import yaml
    except ImportError:
        sys.exit("PyYAML missing on runner - install python3-yaml in this step")
    with open(path) as handle:
        return yaml.safe_load(handle)


def select_wanted(config):
    """Resolve the configured repos to the set of .deb assets that should be served.

    args: config - The parsed repos.yaml contents
    returns: dict - Mapping of .deb filename to its browser download URL
    """
    wanted = {}
    for entry in config["repos"]:
        repo = entry["repo"]
        keep = int(entry.get("keep_last_n", 5))
        releases = json.loads(
            subprocess.check_output(["gh", "api", f"repos/{repo}/releases?per_page=100"])
        )
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
        print(f"{repo}: {with_debs} releases with .deb assets selected")
    return wanted


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

    wanted = select_wanted(load_config(args.repos_config))
    if not wanted:
        # Without this, a successful-but-empty release listing would prune every .deb in
        # the published repo, taking the whole APT channel offline. Refuse instead: an
        # empty result is always either a config mistake or an upstream anomaly.
        sys.exit("no .deb assets selected from any source repo - refusing to prune the destination")

    sync(wanted, args.dest)


if __name__ == "__main__":
    main()
