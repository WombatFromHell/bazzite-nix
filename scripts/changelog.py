import subprocess
import json
import time
from typing import Any
import re
from collections import defaultdict
from pathlib import Path
import os


# Registry prefix for skopeo inspect, derived from IMAGE_PREFIX env var.
# IMAGE_PREFIX is set by the calling action as e.g. "ghcr.io/owner/repo".
# We strip the repo name to get the registry + org, then prepend "docker://".
def _registry_prefix():
    """Return skopeo-compatible registry prefix from IMAGE_PREFIX env var."""
    image_prefix = os.environ.get("IMAGE_PREFIX", "")
    if image_prefix:
        # "ghcr.io/owner/repo" → "docker://ghcr.io/owner/"
        parts = image_prefix.rsplit("/", 1)
        if len(parts) == 2:
            return f"docker://{parts[0]}/"
    # Fallback for direct invocation without IMAGE_PREFIX
    return "docker://ghcr.io/wombatfromhell/"


REGISTRY = _registry_prefix()

RETRIES = 3
RETRY_WAIT = 5
FEDORA_PATTERN = re.compile(r"(?<=[-0-9a-z])\.fc\d{2}(?![0-9])")
STABLE_START_PATTERN = re.compile(r"^stable-\d+\.\d{8}(?:\.\d+)?$")


def other_start_pattern(target: str) -> re.Pattern:
    """Return pattern matching non-stable tags: {target}-DD.YYYYMMDD[.nn]"""
    return re.compile(rf"^{re.escape(target)}-\d+\.\d{{8}}(?:\.\d+)?$")


PATTERN_ADD = "\n| ✨ | {name} | | {version} |"
PATTERN_CHANGE = "\n| 🔄 | {name} | {prev} | {new} |"
PATTERN_REMOVE = "\n| ❌ | {name} | {version} | |"
PATTERN_PKGREL_CHANGED = "{prev} ➡️ {new}"
PATTERN_PKGREL = "{version}"
# Upstream GitHub repo for commit fetching. bazzite-nix tags mirror upstream's
# (e.g. testing-44.20260820.1), so the compare is tag-to-tag on ublue-os/bazzite.
UPSTREAM_REPO = "ublue-os/bazzite"

COMMON_PAT = "### All Images\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n\n"
OTHER_NAMES = {
    "desktop": "### Desktop Images\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n\n",
    "deck": "### Deck Images\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n\n",
    "kde": "### KDE Images\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n\n",
    "nvidia": "### Nvidia Images\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n\n",
}

COMMITS_FORMAT = (
    "### Commits\n**Full diff**: [Compare](https://github.com/{repo}/compare/{prev}...{curr})\n\n"
    "| Hash | Subject | Author |\n| --- | --- | --- |{commits}\n\n"
)
COMMIT_FORMAT = "\n| **[{short}](https://github.com/{repo}/commit/{hash})** | {subject} | {author} |"

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


def load_variants(variants_config: str | None = None) -> list[dict[str, Any]]:
    """Load variant configuration from variants.json file."""
    if not variants_config:
        # Default images if no config provided
        return [
            {"name": "bazzite-nix", "suffix": ""},
            {"name": "bazzite-nix-nvidia-open", "suffix": "-nvidia-open"},
        ]

    config_path = Path(variants_config)
    if not config_path.exists():
        raise FileNotFoundError(f"Variants config file not found: {variants_config}")

    with open(config_path) as f:
        data = json.load(f)

    variants = data.get("variants", [])
    # Filter out disabled variants
    return [v for v in variants if not v.get("disabled", False)]


def get_images(variants: list[dict[str, Any]] | None = None):
    """Generate image names from variants config.

    Yields tuples of (image_name, base_type, desktop_environment).
    If no variants provided, loads from default variants.json.
    """
    if variants is None:
        variants = load_variants()

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
            # Stable tags are prefixed with the branch (stable-44.20260820);
            # legacy bare 44.* tags are ignored.
            if STABLE_START_PATTERN.match(tag):
                tags.add(tag)

    # Remove tags not present in all images
    for manifest in manifests.values():
        for tag in list(tags):
            if tag not in manifest["RepoTags"]:
                tags.remove(tag)

    tags = list(sorted(tags))
    assert len(tags) > 2, "No current and previous tags found"
    return tags[-2], tags[-1]


def get_packages(
    manifests: dict[str, Any],
) -> dict[str, dict[str, str]]:
    """Get packages from ostree.rechunk.info manifest labels.

    Returns {image_name: {pkg: version}}.
    """
    current_packages: dict[str, dict[str, str]] = {}

    for img, manifest in manifests.items():
        current_packages[img] = _get_packages_from_manifest(manifest, img)

    return current_packages


def _get_packages_from_manifest(
    manifest: dict[str, Any], img_name: str
) -> dict[str, str]:
    """Extract packages from manifest labels (ostree.rechunk.info or dev.hhd.rechunk.info).

    Returns packages dict or empty dict if not found.
    """
    try:
        labels = manifest.get("Labels", {})
        if not labels:
            print(f"Warning: No Labels in manifest for {img_name}")
            return {}

        rechunk_info = labels.get("ostree.rechunk.info") or labels.get(
            "dev.hhd.rechunk.info"
        )
        if not rechunk_info:
            available = list(labels.keys())
            print(
                f"Warning: No rechunk info label for {img_name}. Available labels: {available}"
            )
            return {}

        try:
            data = json.loads(rechunk_info)
        except json.JSONDecodeError as e:
            print(
                f"::error::Invalid JSON in ostree.rechunk.info label for {img_name}: {e}"
            )
            print(f"::error::Label content (first 200 chars): {rechunk_info[:200]}")
            raise

        if "packages" not in data:
            print(
                f"Warning: No 'packages' key in rechunk info for {img_name}. Keys: {list(data.keys())}"
            )
            return {}

        return data["packages"]
    except json.JSONDecodeError:
        raise
    except Exception as e:
        print(f"Failed to get packages for {img_name}: {type(e).__name__}: {e}")
        return {}


def is_nvidia(img: str, lts: bool):
    if lts:
        return "nvidia" in img and "nvidia-open" not in img and "deck-nvidia" not in img
    else:
        return "nvidia-open" in img or "deck-nvidia" in img


def get_package_groups(
    prev: dict[str, Any],
    manifests: dict[str, Any],
    variants: list[dict[str, Any]] | None = None,
):
    if variants is None:
        variants = load_variants()
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


def upstream_tag(branch: str, version: str) -> str:
    """Map a container version label/tag to the upstream git tag GitHub can compare.

    Upstream git tags are {branch}-{version} for testing/unstable, bare {version}
    for stable (the stable-* container tags don't exist as git refs).
    """
    if branch == "stable":
        return version.removeprefix("stable-")
    if branch and not version.startswith(f"{branch}-"):
        return f"{branch}-{version}"
    return version


def get_commits(prev: str, curr: str):
    """Fetch upstream commits between two tags, e.g. testing-44.20260812.1...testing-44.20260820.1."""
    try:
        headers = ["-s", "-H", "Accept: application/vnd.github+json"]
        if token := os.environ.get("GH_TOKEN"):
            headers += ["-H", f"Authorization: Bearer {token}"]
        api_url = (
            f"https://api.github.com/repos/{UPSTREAM_REPO}/compare/{prev}...{curr}"
        )

        response = subprocess.run(
            ["curl", *headers, api_url],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout.decode("utf-8")

        data = json.loads(response)

        if "commits" not in data:
            print(
                f"Failed to get commits from GitHub API: {data.get('message', 'Unknown error')}"
            )
            return ""

        out = ""
        for commit in data["commits"]:
            sha = commit["sha"]
            short = sha[:7]
            author = commit["commit"]["author"]["name"]
            subject = commit["commit"]["message"].split("\n")[0]

            if subject.lower().startswith("merge"):
                continue

            out += (
                COMMIT_FORMAT.replace("{repo}", UPSTREAM_REPO)
                .replace("{short}", short)
                .replace("{subject}", subject)
                .replace("{hash}", sha)
                .replace("{author}", author)
            )

        if out:
            return COMMITS_FORMAT.format(
                repo=UPSTREAM_REPO, prev=prev, curr=curr, commits=out
            )
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
    has_nvidia = nvidia_pkg in versions or nvidia_pkg in prev_versions

    if has_nvidia:
        nvidia_row = "\n| **Nvidia** | {pkgrel:nvidia-kmod-common} |"
        if nvidia_pkg not in prev_versions or prev_versions[nvidia_pkg] == versions.get(
            nvidia_pkg
        ):
            changelog = changelog.replace(
                "{pkgrel:nvidia-kmod-common}",
                PATTERN_PKGREL.format(version=versions.get(nvidia_pkg, "Unknown")),
            )
        else:
            changelog = changelog.replace(
                "{pkgrel:nvidia-kmod-common}",
                PATTERN_PKGREL_CHANGED.format(
                    prev=prev_versions[nvidia_pkg],
                    new=versions[nvidia_pkg],
                ),
            )
    else:
        nvidia_row = ""

    changelog = changelog.replace("{nvidia_row}", nvidia_row)

    for pkg, v in versions.items():
        if pkg not in prev_versions or prev_versions[pkg] == v:
            changelog = changelog.replace(
                "{pkgrel:" + pkg + "}",
                PATTERN_PKGREL.format(version=v),
            )
        else:
            changelog = changelog.replace(
                "{pkgrel:" + pkg + "}",
                PATTERN_PKGREL_CHANGED.format(prev=prev_versions[pkg], new=v),
            )

    changes = ""
    common = calculate_changes(common, prev_versions, versions)
    if common:
        changes += COMMON_PAT.format(changes=common)
    for k, v in others.items():
        chg = calculate_changes(v, prev_versions, versions)
        if chg:
            changes += OTHER_NAMES[k].format(changes=chg)
    changes += get_commits(upstream_tag(target, prev), upstream_tag(target, curr))

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
    print(f'\nOutput:\nTITLE="{title}"\nTAG="{curr}"')

    with open(args.changelog, "w") as f:
        f.write(changelog)

    with open(args.output, "w") as f:
        f.write(f'TITLE="{title}"\nTAG="{curr}"\n')


if __name__ == "__main__":
    main()
