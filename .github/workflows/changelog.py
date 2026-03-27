#!/usr/bin/env python3
"""
Changelog generator for bazzite-nix releases.

Compares package versions between previous and current builds,
generates a markdown changelog, and outputs release metadata.
"""

import subprocess
import json
import time
import re
import os
from typing import Any
from collections import defaultdict

# Configuration - loaded from environment (set by workflow/caller)
# REGISTRY: Full registry path (e.g., "ghcr.io/wombatfromhell")
# REPO: Repository name (e.g., "bazzite-nix")
REGISTRY_BASE = os.environ.get("REGISTRY", "ghcr.io").lower()
REPO_OWNER = os.environ.get("GITHUB_REPOSITORY_OWNER", "wombatfromhell").lower()
REPO = os.environ.get("REPO", os.environ.get("IMAGE_NAME", "bazzite-nix")).lower()
REGISTRY = f"docker://{REGISTRY_BASE}/{REPO_OWNER}"

RETRIES = 3
RETRY_WAIT = 5
FEDORA_PATTERN = re.compile(r"\.fc\d{2}")

# Changelog templates
PATTERN_ADD = "\n| ✨ | {name} | | {version} |"
PATTERN_CHANGE = "\n| 🔄 | {name} | {prev} | {new} |"
PATTERN_REMOVE = "\n| ❌ | {name} | {version} | |"
PATTERN_PKGREL_CHANGED = "{prev} ➡️ {new}"
PATTERN_PKGREL = "{version}"

CHANGELOG_SECTIONS = {
    "common": "### All Variants\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n",
    "testing": "### Testing Variant\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n",
    "unstable": "### Unstable Variant\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n",
}

COMMITS_FORMAT = (
    "### Commits\n| Hash | Subject | Author |\n| --- | --- | --- |{commits}\n\n"
)
COMMIT_FORMAT = "\n| **[{short}](https://github.com/{owner}/{repo}/commit/{hash})** | {subject} | {author} |"

CHANGELOG_TITLE = "{tag}: {pretty}"
CHANGELOG_FORMAT = """\
{handwritten}

From previous `{target}` version `{prev}` there have been the following changes.

### Base Image Information
| Name | Version |
| --- | --- |
| **Base Image** | {base_image} |
| **Kernel** | {kernel_version} |
| **Build Date** | {build_date} |

{changes}
### How to rebase
For current users, type the following to rebase to this version:
```bash
# For this branch:
bazzite-rollback-helper rebase {target}
# For this specific image:
bazzite-rollback-helper rebase {curr}
```
"""

HANDWRITTEN_PLACEHOLDER = """\
This is an automatically generated changelog for release `{curr}`."""

# Packages to highlight (optional)
HIGHLIGHT_PACKAGES = [
    "kernel",
    "mesa-filesystem",
    "gamescope",
    "bazaar",
]


def get_variants(variants_file: str, include_disabled: bool = False) -> list[dict[str, Any]]:
    """Load variants from variants.json configuration.

    Args:
        variants_file: Path to variants.json config file
        include_disabled: If True, include disabled variants (for validation)

    Returns:
        List of variant configurations (excluding disabled by default)
    """
    if not os.path.exists(variants_file):
        variants_file = os.path.join(os.path.dirname(__file__), "../variants.json")
    if not os.path.exists(variants_file):
        variants_file = ".github/variants.json"

    with open(variants_file, "r") as f:
        config = json.load(f)

    variants = []
    for variant in config.get("variants", []):
        if variant.get("disabled", False) and not include_disabled:
            continue
        variants.append(
            {
                "name": variant["name"],
                "base_image": variant["base_image"],
                "suffix": variant.get("suffix", ""),
                "tags": variant.get("tags", {}),
                "disabled": variant.get("disabled", False),
            }
        )
    return variants


def get_manifest(image_ref: str) -> dict[str, Any] | None:
    """Fetch manifest for a specific image reference."""
    print(f"Getting manifest: {image_ref}")
    for i in range(RETRIES):
        try:
            output = subprocess.run(
                ["skopeo", "inspect", f"docker://{image_ref}"],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            ).stdout
            return json.loads(output)
        except subprocess.CalledProcessError as e:
            print(
                f"Failed to get {image_ref}, retrying in {RETRY_WAIT} seconds ({i + 1}/{RETRIES})"
            )
            print(f"Error: {e.stderr.decode('utf-8', errors='ignore')}")
            time.sleep(RETRY_WAIT)
    print(f"Failed to get {image_ref} after {RETRIES} attempts")
    return None


def get_manifests_for_target(
    target: str, variants: list[dict[str, Any]]
) -> dict[str, Any]:
    """Fetch manifests for all enabled variants of a target.

    Args:
        target: Target branch/tag name (e.g., "testing", "unstable")
        variants: List of variant configurations

    Returns:
        Dictionary mapping variant names to their manifests
    """
    manifests = {}
    # Filter to only enabled variants
    enabled_variants = [v for v in variants if not v.get("disabled", False)]

    for i, variant in enumerate(enabled_variants):
        # Build image reference using registry from push-reusable action
        image_ref = f"{REGISTRY}/{REPO}{variant['suffix']}:{target}"
        manifest = get_manifest(image_ref)
        if manifest:
            manifests[variant["name"]] = manifest
            print(f"✓ Got manifest for {variant['name']} ({i + 1}/{len(enabled_variants)})")
        else:
            print(f"✗ Failed to get manifest for {variant['name']}")

    if not manifests:
        print(f"::warning::No manifests found for target '{target}'. Ensure variant is enabled and image exists.")

    return manifests


def get_tags_from_manifests(
    manifests: dict[str, Any], target: str, variants: list[dict[str, Any]]
) -> tuple[str, str]:
    """Extract previous and current tags from manifests using variant tag configuration.

    Args:
        manifests: Dictionary of variant manifests
        target: Target branch name (e.g., "testing", "unstable")
        variants: List of variant configurations

    Returns:
        Tuple of (previous_tag, current_tag)

    Note:
        For variants without explicit tags config, uses default pattern:
        [{target}, {target}-{canonical}, {canonical}]
    """
    if not manifests:
        raise ValueError("No manifests provided")

    # Get tag patterns from variants config (only for enabled variants)
    variant_tags = {}
    enabled_variants = [v for v in variants if not v.get("disabled", False)]

    for variant in enabled_variants:
        tags_config = variant.get("tags", {})
        if tags_config:
            variant_tags[variant["name"]] = tags_config
        else:
            # Use default tag pattern for variants without explicit config
            variant_tags[variant["name"]] = {
                "versioned": [f"{target}", f"{target}-{{canonical}}", "{{canonical}}"]
            }

    # Use first manifest to get common tags
    first = next(iter(manifests.values()))
    all_tags = set(first.get("RepoTags", []))

    # Build tag patterns based on variant configuration
    versioned_tags = set()

    for tags_config in variant_tags.values():
        # Check for versioned tag patterns
        versioned_patterns = tags_config.get("versioned", [])
        for pattern in versioned_patterns:
            # Convert template patterns to regex
            # {branch} -> target, {canonical} -> version number
            regex_pattern = pattern
            regex_pattern = regex_pattern.replace("{branch}", target)
            regex_pattern = regex_pattern.replace("{canonical}", r"\d+\.\d+(?:\.\d+)?")
            regex_pattern = f"^{regex_pattern}$"

            tag_regex = re.compile(regex_pattern)
            for tag in all_tags:
                if tag_regex.match(tag) and not tag.endswith(".0"):
                    versioned_tags.add(tag)

    # Fallback: match target or target-version patterns
    if not versioned_tags:
        print(f"::warning::No versioned tags found for target '{target}'. Using fallback.")
        target_pattern = re.compile(rf"^{target}(?:-\d+\.\d+(?:\.\d+)?)?$")
        for tag in all_tags:
            if tag.endswith(".0"):
                continue
            if target_pattern.match(tag) or tag == target:
                versioned_tags.add(tag)

    versioned_tags = sorted(versioned_tags)

    if len(versioned_tags) < 2:
        # Fallback: use target as previous
        if versioned_tags:
            print(f"::notice::Only one versioned tag found. Using '{target}' as previous.")
        return target, versioned_tags[0] if versioned_tags else target

    return versioned_tags[-2], versioned_tags[-1]


def get_packages(manifest: dict[str, Any]) -> dict[str, str]:
    """Extract package versions from manifest labels."""
    packages = {}
    try:
        # Try bazzite-nix specific label first
        if "dev.hhd.rechunk.info" in manifest.get("Labels", {}):
            rechunk_info = json.loads(manifest["Labels"]["dev.hhd.rechunk.info"])
            packages.update(rechunk_info.get("packages", {}))

        # Also check for custom bazzite-nix labels
        labels = manifest.get("Labels", {})
        for key, value in labels.items():
            if key.startswith("io.github.bazzite-nix.pkg."):
                pkg_name = key.replace("io.github.bazzite-nix.pkg.", "")
                packages[pkg_name] = value
    except Exception as e:
        print(f"Failed to extract packages from manifest: {e}")
    return packages


def get_kernel_version(manifest: dict[str, Any]) -> str:
    """Extract kernel version from manifest."""
    labels = manifest.get("Labels", {})
    return (
        labels.get("org.opencontainers.image.kernel-version", "")
        or labels.get("io.github.bazzite-nix.kernel-version", "")
        or "Unknown"
    )


def get_versions(manifests: dict[str, Any]) -> dict[str, str]:
    """Aggregate versions from all manifests."""
    versions = {}
    for manifest in manifests.values():
        pkgs = get_packages(manifest)
        for pkg, version in pkgs.items():
            # Clean Fedora version suffix
            clean_version = re.sub(FEDORA_PATTERN, "", version)
            # Keep the most recent version if duplicates exist
            if pkg not in versions or clean_version > versions[pkg]:
                versions[pkg] = clean_version
    return versions


def calculate_changes(
    pkgs: list[str], prev: dict[str, str], curr: dict[str, str]
) -> str:
    """Calculate and format package changes."""
    added = []
    changed = []
    removed = []

    # Build blacklist of versions to skip (highlighted packages only)
    highlight_versions = set()
    for pkg in HIGHLIGHT_PACKAGES:
        if pkg in curr and curr[pkg]:
            highlight_versions.add(curr[pkg])
        if pkg in prev and prev[pkg]:
            highlight_versions.add(prev[pkg])

    for pkg in pkgs:
        # Skip highlighted packages (they go in a separate section)
        if pkg in HIGHLIGHT_PACKAGES:
            continue
        # Skip packages with versions matching highlighted packages
        if pkg in curr and curr.get(pkg, None) in highlight_versions:
            continue
        if pkg in prev and prev.get(pkg, None) in highlight_versions:
            continue

        if pkg not in prev:
            added.append(pkg)
        elif pkg not in curr:
            removed.append(pkg)
        elif prev[pkg] != curr[pkg]:
            changed.append(pkg)

    out = ""
    for pkg in sorted(added):
        out += PATTERN_ADD.format(name=pkg, version=curr[pkg])
    for pkg in sorted(changed):
        out += PATTERN_CHANGE.format(name=pkg, prev=prev[pkg], new=curr[pkg])
    for pkg in sorted(removed):
        out += PATTERN_REMOVE.format(name=pkg, version=prev[pkg])
    return out


def get_commits(
    prev_manifests: dict[str, Any],
    manifests: dict[str, Any],
    workdir: str,
    owner: str,
    repo: str,
) -> str:
    """Extract commits between two image revisions."""
    try:
        # Get revision hashes from manifests
        start = None
        finish = None

        for manifest in prev_manifests.values():
            rev = manifest.get("Labels", {}).get("org.opencontainers.image.revision")
            if rev:
                start = rev
                break

        for manifest in manifests.values():
            rev = manifest.get("Labels", {}).get("org.opencontainers.image.revision")
            if rev:
                finish = rev
                break

        if not start or not finish:
            print("Could not find revision hashes in manifests")
            return ""

        print(f"Getting commits from {start[:7]} to {finish[:7]}")

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

            # Skip merge commits
            if subject.lower().startswith("merge"):
                continue

            out += COMMIT_FORMAT.format(
                short=short,
                subject=subject,
                hash=commit_hash,
                author=author,
                owner=owner,
                repo=repo,
            )

        if out:
            return COMMITS_FORMAT.format(commits=out)
        return ""
    except Exception as e:
        print(f"Failed to get commits: {e}")
        return ""


def generate_changelog(
    handwritten: str | None,
    target: str,
    pretty: str | None,
    workdir: str,
    variants: list[dict[str, Any]],
    prev_manifests: dict[str, Any],
    manifests: dict[str, Any],
) -> tuple[str, str]:
    """Generate the full changelog."""
    owner = REPO_OWNER
    repo = REPO

    # Get versions
    versions = get_versions(manifests)
    prev_versions = get_versions(prev_manifests)

    # Get tags using variants config
    prev_tag, curr_tag = get_tags_from_manifests(manifests, target, variants)

    # Get kernel version from first manifest
    kernel_version = get_kernel_version(next(iter(manifests.values())))

    # Get base image info
    base_image = (
        manifests.get("stable", {})
        .get("Labels", {})
        .get("org.opencontainers.image.base.digest", "Unknown")[:19]
    )  # Shorten digest

    # Generate pretty title if not provided
    if not pretty:
        curr_pretty = re.sub(r"\.\d{1,2}$", "", curr_tag)
        curr_pretty = re.sub(r"^[a-z]+-", "", curr_pretty)
        pretty = target.capitalize() + " (F" + curr_pretty + ")"

    title = CHANGELOG_TITLE.format_map(defaultdict(str, tag=curr_tag, pretty=pretty))

    # Build changelog
    changelog = CHANGELOG_FORMAT

    changelog = (
        changelog.replace(
            "{handwritten}", handwritten if handwritten else HANDWRITTEN_PLACEHOLDER
        )
        .replace("{target}", target)
        .replace("{prev}", prev_tag)
        .replace("{curr}", curr_tag)
        .replace("{base_image}", base_image)
        .replace("{kernel_version}", kernel_version)
        .replace("{build_date}", time.strftime("%Y-%m-%d %H:%M UTC"))
    )

    # Build changes section
    changes = ""

    # Add commits if available
    commits = get_commits(prev_manifests, manifests, workdir, owner, repo)
    if commits:
        changes += commits

    # Calculate package changes
    all_pkgs = set(versions.keys()) | set(prev_versions.keys())
    pkg_changes = calculate_changes(sorted(all_pkgs), prev_versions, versions)

    if pkg_changes:
        changes += CHANGELOG_SECTIONS["common"].format(changes=pkg_changes)

    changelog = changelog.replace("{changes}", changes)

    return title, changelog


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Generate release changelog")
    parser.add_argument("target", help="Target branch/tag (e.g., testing, unstable)")
    parser.add_argument("output", help="Output environment file path")
    parser.add_argument("changelog", help="Output changelog file path")
    parser.add_argument("--pretty", help="Custom title for the changelog")
    parser.add_argument(
        "--workdir", help="Git working directory for commits", default="."
    )
    parser.add_argument("--handwritten", help="Custom handwritten changelog text")
    parser.add_argument(
        "--variants-config",
        help="Path to variants.json config",
        default=".github/variants.json",
    )
    args = parser.parse_args()

    # Clean target (remove refs/heads/, refs/tags/, etc.)
    target = args.target.split("/")[-1]
    if target == "main":
        target = "stable"

    print(f"Generating changelog for target: {target}")
    print(f"Registry: {REGISTRY}")
    print(f"Repo: {REPO}")

    # Load variants (including disabled for validation)
    all_variants = get_variants(args.variants_config, include_disabled=True)
    enabled_variants = get_variants(args.variants_config)

    # Validate target against enabled variants
    enabled_names = {v["name"] for v in enabled_variants}
    all_names = {v["name"] for v in all_variants}

    if target not in all_names:
        print(f"::warning::Target '{target}' not found in variants config. Available: {', '.join(sorted(all_names))}")
    elif target not in enabled_names:
        print(f"::error::Target '{target}' is disabled in variants config. Enable it or use a different target.")
        print(f"Enabled variants: {', '.join(sorted(enabled_names))}")
        exit(1)

    print(f"Found {len(enabled_variants)} active variants")

    # Get current manifests
    manifests = get_manifests_for_target(target, enabled_variants)
    if not manifests:
        print(f"Error: No manifests found for target {target}")
        exit(1)

    # Get previous tag
    prev_tag, curr_tag = get_tags_from_manifests(manifests, target, enabled_variants)
    print(f"Previous tag: {prev_tag}")
    print(f"Current tag: {curr_tag}")

    # Get previous manifests
    prev_manifests = {}
    for variant_name in manifests.keys():
        # Build previous image ref
        variant = next((v for v in enabled_variants if v["name"] == variant_name), None)
        if variant:
            image_ref = f"{REGISTRY}/{REPO}{variant['suffix']}:{prev_tag}"
            manifest = get_manifest(image_ref)
            if manifest:
                prev_manifests[variant_name] = manifest

    # Generate changelog
    title, changelog = generate_changelog(
        args.handwritten,
        target,
        args.pretty,
        args.workdir,
        enabled_variants,
        prev_manifests,
        manifests,
    )

    print("\n=== Changelog ===")
    print(f"# {title}")
    print(changelog)
    print("\n=== Output ===")
    print(f'TITLE="{title}"')
    print(f"TAG={curr_tag}")

    # Write changelog
    with open(args.changelog, "w") as f:
        f.write(changelog)

    # Write output env file
    with open(args.output, "w") as f:
        f.write(f"TITLE={title}\nTAG={curr_tag}\n")


if __name__ == "__main__":
    main()
