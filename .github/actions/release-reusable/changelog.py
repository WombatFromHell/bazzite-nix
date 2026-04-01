import subprocess
import json
import time
from typing import Any
import re
from collections import defaultdict
from pathlib import Path

REGISTRY = "docker://ghcr.io/wombatfromhell/"

RETRIES = 3
RETRY_WAIT = 5
FEDORA_PATTERN = re.compile(r"(?<=[-0-9a-z])\.fc\d{2}(?![0-9])")
STABLE_START_PATTERN = re.compile(r"\d+\.\d{8}(?:\.\d+)?$")


def other_start_pattern(target: str) -> re.Pattern:
    """Return pattern matching non-stable tags: {target}-DD.YYYYMMDD[.nn]"""
    return re.compile(rf"^{re.escape(target)}-\d+\.\d{{8}}(?:\.\d+)?$")


PATTERN_ADD = "\n| ✨ | {name} | | {version} |"
PATTERN_CHANGE = "\n| 🔄 | {name} | {prev} | {new} |"
PATTERN_REMOVE = "\n| ❌ | {name} | {version} | |"
PATTERN_PKGREL_CHANGED = "{prev} ➡️ {new}"
PATTERN_PKGREL = "{version}"
COMMON_PAT = "### All Images\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n\n"
OTHER_NAMES = {
    "desktop": "### Desktop Images\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n\n",
    "deck": "### Deck Images\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n\n",
    "kde": "### KDE Images\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n\n",
    "nvidia": "### Nvidia Images\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n\n",
}

COMMITS_FORMAT = (
    "### Commits\n| Hash | Subject | Author |\n| --- | --- | --- |{commits}\n\n"
)
COMMIT_FORMAT = "\n| **[{short}](https://github.com/wombatfromhell/bazzite-nix/commit/{hash})** | {subject} | {author} |"

CHANGELOG_TITLE = "{tag}: {pretty}"
CHANGELOG_FORMAT = """\
{handwritten}

From previous `{target}` version `{prev}` there have been the following changes. **One package per new version shown.**

### Major packages
| Name | Version |
| --- | --- |
| **Kernel** | {pkgrel:kernel} |
| **Firmware** | {pkgrel:atheros-firmware} |
| **Mesa** | {pkgrel:mesa-filesystem} |
| **Gamescope** | {pkgrel:terra-gamescope} |
| **Bazaar** | {pkgrel:bazaar} |
| **KDE** | {pkgrel:plasma-desktop} |{nvidia_row}

{changes}

### How to rebase
For current users, type the following to rebase to this version:
```bash
# For this branch (if latest):
urh rebase {target}
# For this specific image:
urh rebase {curr}
```
"""
HANDWRITTEN_PLACEHOLDER = """\
This is an automatically generated changelog for release `{curr}`."""

BLACKLIST_VERSIONS = [
    "kernel",
    "mesa-filesystem",
    "terra-gamescope",
    "bazaar",
    "gnome-control-center-filesystem",
    "plasma-desktop",
    "atheros-firmware",
    "nvidia-kmod-common",
    "nvidia-kmod-common-lts",
]

PKG_ALIAS = {}


def load_variants(variants_config: str | None) -> list[dict[str, Any]]:
    """Load variant configuration from variants.json file."""
    if not variants_config:
        # Fallback to default images if no config provided
        return [
            {"name": "bazzite-nix", "suffix": ""},
            {"name": "bazzite-nix-nvidia-open", "suffix": ""},
        ]

    config_path = Path(variants_config)
    if not config_path.exists():
        raise FileNotFoundError(f"Variants config file not found: {variants_config}")

    with open(config_path) as f:
        data = json.load(f)

    variants = data.get("variants", [])
    # Filter out disabled variants
    return [v for v in variants if not v.get("disabled", False)]


def get_images(variants: list[dict[str, Any]]):
    """Generate image names from variants config.

    Yields tuples of (image_name, base_type, desktop_environment)
    """
    for variant in variants:
        name = variant["name"]
        suffix = variant.get("suffix", "")
        img = f"bazzite-nix{suffix}"

        # Determine base type and DE from variant name/suffix
        if "deck" in name or "deck" in suffix:
            base = "deck"
        else:
            base = "desktop"

        if "gnome" in name or "gnome" in suffix:
            de = "gnome"
        else:
            de = "kde"

        yield img, base, de


def get_manifests(target: str, variants: list[dict[str, Any]]):
    out = {}
    imgs = list(get_images(variants))
    for j, (img, _, _) in enumerate(imgs):
        output = None
        print(f"Getting {img}:{target} manifest ({j + 1}/{len(imgs)}).")
        for i in range(RETRIES):
            try:
                output = subprocess.run(
                    ["skopeo", "inspect", REGISTRY + img + ":" + target],
                    check=True,
                    stdout=subprocess.PIPE,
                ).stdout
                break
            except subprocess.CalledProcessError:
                print(
                    f"Failed to get {img}:{target}, retrying in {RETRY_WAIT} seconds ({i + 1}/{RETRIES})"
                )
                time.sleep(RETRY_WAIT)
        if output is None:
            print(f"Failed to get {img}:{target}, skipping")
            continue
        out[img] = json.loads(output)
    return out


def get_tags(target: str, manifests: dict[str, Any]):
    tags = set()

    # Select random manifest to get reference tags from
    first = next(iter(manifests.values()))
    for tag in first["RepoTags"]:
        # Tags ending with .0 should not exist
        if tag.endswith(".0"):
            continue
        if target != "stable":
            if other_start_pattern(target).match(tag):
                tags.add(tag)
        else:
            # For stable, match tags ending with the version pattern
            if STABLE_START_PATTERN.search(tag):
                tags.add(tag)

    # Remove tags not present in all images
    for manifest in manifests.values():
        for tag in list(tags):
            if tag not in manifest["RepoTags"]:
                tags.remove(tag)

    tags = list(sorted(tags))
    assert len(tags) > 2, "No current and previous tags found"
    return tags[-2], tags[-1]


def get_packages(manifests: dict[str, Any]):
    packages = {}
    for img, manifest in manifests.items():
        try:
            # Try newer ostree.rechunk.info label first, then fallback to dev.hhd.rechunk.info
            rechunk_info = manifest["Labels"].get("ostree.rechunk.info") or manifest[
                "Labels"
            ].get("dev.hhd.rechunk.info")
            if rechunk_info:
                packages[img] = json.loads(rechunk_info)["packages"]
            else:
                packages[img] = {}
        except Exception as e:
            print(f"Failed to get packages for {img}:\n{e}")
            packages[img] = {}
    return packages


def is_nvidia(img: str, lts: bool):
    if lts:
        return "nvidia" in img and "nvidia-open" not in img and "deck-nvidia" not in img
    else:
        return "nvidia-open" in img or "deck-nvidia" in img


def get_package_groups(
    prev: dict[str, Any], manifests: dict[str, Any], variants: list[dict[str, Any]]
):
    common = set()
    others = {k: set() for k in OTHER_NAMES.keys()}

    npkg = get_packages(manifests)
    ppkg = get_packages(prev)

    keys = set(npkg.keys()) | set(ppkg.keys())
    pkg = defaultdict(set)
    for k in keys:
        pkg[k] = set(npkg.get(k, {})) | set(ppkg.get(k, {}))

    # Find common packages
    first = True
    for img, base, de in get_images(variants):
        if img not in pkg:
            continue

        if first:
            for p in pkg[img]:
                common.add(p)
        else:
            for c in common.copy():
                if c not in pkg[img]:
                    common.remove(c)

        first = False

    # Find other packages
    for t, other in others.items():
        first = True
        for img, base, de in get_images(variants):
            if img not in pkg:
                continue

            if t == "nvidia" and "nvidia" not in img:
                continue
            if t == "kde" and de != "kde":
                continue
            if t == "gnome" and de != "gnome":
                continue
            if t == "deck" and base != "deck":
                continue
            if t == "desktop" and base == "deck":
                continue

            if first:
                for p in pkg[img]:
                    if p not in common:
                        other.add(p)
            else:
                for c in other.copy():
                    if c not in pkg[img]:
                        other.remove(c)

            first = False

    return sorted(common), {k: sorted(v) for k, v in others.items()}


def get_versions(manifests: dict[str, Any]):
    versions = {}
    pkgs = get_packages(manifests)
    for img, img_pkgs in pkgs.items():
        for pkg, v in img_pkgs.items():
            if is_nvidia(img, lts=True) and "nvidia" in pkg:
                pkg += "-lts"
            versions[pkg] = re.sub(FEDORA_PATTERN, "", v)
    return versions


def calculate_changes(pkgs: list[str], prev: dict[str, str], curr: dict[str, str]):
    added = []
    changed = []
    removed = []

    blacklist_ver = set([curr.get(v, None) for v in BLACKLIST_VERSIONS])

    for pkg in pkgs:
        # Clearup changelog by removing mentioned packages
        if pkg in BLACKLIST_VERSIONS:
            continue
        if pkg in curr and curr.get(pkg, None) in blacklist_ver:
            continue
        if pkg in prev and prev.get(pkg, None) in blacklist_ver:
            continue
        if pkg.endswith("-lts"):
            continue

        if pkg not in prev:
            added.append(pkg)
        elif pkg not in curr:
            removed.append(pkg)
        elif prev[pkg] != curr[pkg]:
            changed.append(pkg)

        blacklist_ver.add(curr.get(pkg, None))
        blacklist_ver.add(prev.get(pkg, None))

    out = ""
    for pkg in added:
        out += PATTERN_ADD.format(name=pkg, version=curr[pkg])
    for pkg in changed:
        out += PATTERN_CHANGE.format(name=pkg, prev=prev[pkg], new=curr[pkg])
    for pkg in removed:
        out += PATTERN_REMOVE.format(name=pkg, version=prev[pkg])
    return out


def get_commits(prev_manifests, manifests, workdir: str):
    try:
        start = next(iter(prev_manifests.values()))["Labels"][
            "org.opencontainers.image.revision"
        ]
        finish = next(iter(manifests.values()))["Labels"][
            "org.opencontainers.image.revision"
        ]

        commits = subprocess.run(
            [
                "git",
                "-C",
                workdir,
                "log",
                "--pretty=format:%H|%h|%an|%s",
                f"{start}..{finish}",
            ],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout.decode("utf-8")

        out = ""
        for commit in commits.split("\n"):
            if not commit:
                continue
            parts = commit.split("|")
            if len(parts) < 4:
                continue
            commit_hash, short, author, subject = parts

            if subject.lower().startswith("merge"):
                continue

            out += (
                COMMIT_FORMAT.replace("{short}", short)
                .replace("{subject}", subject)
                .replace("{hash}", commit_hash)
                .replace("{author}", author)
            )

        if out:
            return COMMITS_FORMAT.format(commits=out)
        return ""
    except Exception as e:
        print(f"Failed to get commits:\n{e}")
        return ""


def generate_changelog(
    handwritten: str | None,
    target: str,
    pretty: str | None,
    workdir: str,
    prev_manifests,
    manifests,
    variants: list[dict[str, Any]],
):
    common, others = get_package_groups(prev_manifests, manifests, variants)
    versions = get_versions(manifests)
    prev_versions = get_versions(prev_manifests)

    prev, curr = get_tags(target, manifests)

    if not pretty:
        # Generate pretty version since we dont have it
        try:
            finish: str = next(iter(manifests.values()))["Labels"][
                "org.opencontainers.image.revision"
            ]
        except Exception as e:
            print(f"Failed to get finish hash:\n{e}")
            finish = ""

        # Remove .0 from curr
        curr_pretty = re.sub(r"\.\d{1,2}$", "", curr)
        # Remove target- from curr
        curr_pretty = re.sub(r"^[a-z]+-", "", curr_pretty)
        pretty = target.capitalize() + " (F" + curr_pretty
        if finish and target != "stable":
            pretty += ", #" + finish[:7]
        pretty += ")"

    title = CHANGELOG_TITLE.format_map(defaultdict(str, tag=curr, pretty=pretty))

    changelog = CHANGELOG_FORMAT

    changelog = (
        changelog.replace(
            "{handwritten}", handwritten if handwritten else HANDWRITTEN_PLACEHOLDER
        )
        .replace("{target}", target)
        .replace("{prev}", prev)
        .replace("{curr}", curr)
    )

    # Conditionally add Nvidia row based on package presence
    nvidia_pkg = "nvidia-kmod-common"
    nvidia_versions = get_versions(manifests)
    nvidia_prev_versions = get_versions(prev_manifests)
    has_nvidia = nvidia_pkg in nvidia_versions or nvidia_pkg in nvidia_prev_versions

    if has_nvidia:
        nvidia_row = "\n| **Nvidia** | {pkgrel:nvidia-kmod-common} |"
        if nvidia_pkg not in nvidia_prev_versions or nvidia_prev_versions[
            nvidia_pkg
        ] == nvidia_versions.get(nvidia_pkg):
            changelog = changelog.replace(
                "{pkgrel:nvidia-kmod-common}",
                PATTERN_PKGREL.format(
                    version=nvidia_versions.get(nvidia_pkg, "Unknown")
                ),
            )
        else:
            changelog = changelog.replace(
                "{pkgrel:nvidia-kmod-common}",
                PATTERN_PKGREL_CHANGED.format(
                    prev=nvidia_prev_versions[nvidia_pkg],
                    new=nvidia_versions[nvidia_pkg],
                ),
            )
    else:
        nvidia_row = ""

    changelog = changelog.replace("{nvidia_row}", nvidia_row)

    for pkg, v in versions.items():
        if pkg not in prev_versions or prev_versions[pkg] == v:
            changelog = changelog.replace(
                "{pkgrel:" + (PKG_ALIAS.get(pkg, None) or pkg) + "}",
                PATTERN_PKGREL.format(version=v),
            )
        else:
            changelog = changelog.replace(
                "{pkgrel:" + (PKG_ALIAS.get(pkg, None) or pkg) + "}",
                PATTERN_PKGREL_CHANGED.format(prev=prev_versions[pkg], new=v),
            )

    changes = ""
    changes += get_commits(prev_manifests, manifests, workdir)
    common = calculate_changes(common, prev_versions, versions)
    if common:
        changes += COMMON_PAT.format(changes=common)
    for k, v in others.items():
        chg = calculate_changes(v, prev_versions, versions)
        if chg:
            changes += OTHER_NAMES[k].format(changes=chg)

    changelog = changelog.replace("{changes}", changes)

    return title, changelog


def main():
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("target", help="Target tag")
    parser.add_argument("output", help="Output environment file")
    parser.add_argument("changelog", help="Output changelog file")
    parser.add_argument("--pretty", help="Subject for the changelog")
    parser.add_argument("--workdir", help="Git directory for commits")
    parser.add_argument("--handwritten", help="Handwritten changelog")
    parser.add_argument(
        "--variants-config", help="Path to variants.json configuration file"
    )
    args = parser.parse_args()

    # Remove refs/tags, refs/heads, refs/remotes e.g.
    # Tags cannot include / anyway.
    target = args.target.split("/")[-1]

    if target == "main":
        target = "stable"

    variants = load_variants(args.variants_config)
    manifests = get_manifests(target, variants)
    prev, curr = get_tags(target, manifests)
    print(f"Previous tag: {prev}")
    print(f" Current tag: {curr}")

    prev_manifests = get_manifests(prev, variants)
    title, changelog = generate_changelog(
        args.handwritten,
        target,
        args.pretty,
        args.workdir,
        prev_manifests,
        manifests,
        variants,
    )

    print(f"Changelog:\n# {title}\n{changelog}")
    print(f'\nOutput:\nTITLE="{title}"\nTAG={curr}')

    with open(args.changelog, "w") as f:
        f.write(changelog)

    with open(args.output, "w") as f:
        f.write(f'TITLE="{title}"\nTAG={curr}\n')


if __name__ == "__main__":
    main()
