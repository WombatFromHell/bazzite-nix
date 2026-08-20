#!/usr/bin/env python3
"""Preview the changelog data a local image would produce at release time.

Reuses the exact helpers the release pipeline runs (changelog.py) so we can
verify locally that the ostree.rechunk.info label on a built image (rechunked
or not) is present and parses to the expected package versions.

Usage: scripts/release-preview.py [image_ref]
  image_ref defaults to containers-storage:localhost/chunked-img
"""

import argparse
import json
import os
import subprocess
import sys

RELEASE_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
)
sys.path.insert(0, RELEASE_DIR)

import changelog  # noqa: E402

MAJOR_ROWS = [
    ("kernel", "Kernel"),
    ("atheros-firmware", "Firmware"),
    ("mesa-filesystem", "Mesa"),
    ("terra-gamescope", "Gamescope"),
    ("bazaar", "Bazaar"),
    ("plasma-desktop", "KDE"),
]


def inspect(ref: str, docker: bool) -> dict:
    """skopeo inspect an image, returning the manifest dict.

    docker=True inspects a registry ref (docker://, no pull, no sudo);
    docker=False inspects a containers-storage image.
    """
    if docker:
        cmd = ["skopeo", "inspect", f"docker://{ref}"]
    else:
        cmd = ["skopeo", "inspect", f"containers-storage:{ref}"]
    proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return json.loads(proc.stdout)


def render(rows, prev_versions: dict[str, str], versions: dict[str, str]) -> None:
    print("| Name | Version |")
    print("| --- | --- |")
    for pkg, label in rows:
        version = versions.get(pkg, "—")
        if pkg in prev_versions and prev_versions[pkg] != version:
            print(f"| **{label}** | {prev_versions[pkg]} ➡️ {version} |")
        else:
            print(f"| **{label}** | {version} |")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("image_ref", nargs="?", default="localhost/chunked-img")
    parser.add_argument(
        "--prev",
        help="Previous release ref to diff against, e.g. "
        "ghcr.io/wombatfromhell/bazzite-nix:latest",
    )
    args = parser.parse_args()

    manifest = inspect(args.image_ref, docker=False)
    name = args.image_ref.rsplit("/", 1)[-1]
    versions = changelog.get_versions({name: manifest})

    prev_versions = {}
    if args.prev:
        prev_manifest = inspect(args.prev, docker=True)
        prev_versions = changelog.get_versions({name: prev_manifest})

    # Mirror changelog.generate_changelog: only rows for present packages,
    # and the Nvidia row only when an nvidia package exists.
    rows = [(pkg, label) for pkg, label in MAJOR_ROWS if pkg in versions]
    if "nvidia-kmod-common" in versions or "nvidia-kmod-common" in prev_versions:
        rows.append(("nvidia-kmod-common", "Nvidia"))

    print(f"# {args.image_ref}")
    if args.prev:
        print(f"  vs previous {args.prev} ({len(prev_versions)} pkgs)")
    print(f"Distinct packages in label: {len(versions)}")
    print("")
    render(rows, prev_versions, versions)
    if args.prev:
        changes = changelog.calculate_changes(
            sorted(set(prev_versions) | set(versions)), prev_versions, versions
        )
        if changes:
            print("")
            print("### Changes")
            print("| | Name | Previous | New |")
            print("| --- | --- | --- | --- |")
            print(changes)

        prev_v = prev_manifest.get("Labels", {}).get("org.opencontainers.image.version")
        curr_v = manifest.get("Labels", {}).get("org.opencontainers.image.version")
        if prev_v and curr_v:
            branch = name.split(":", 1)[-1]
            commits = changelog.get_commits(
                changelog.upstream_tag(branch, prev_v),
                changelog.upstream_tag(branch, curr_v),
            )
            if commits:
                print("")
                print(commits)


if __name__ == "__main__":
    main()
