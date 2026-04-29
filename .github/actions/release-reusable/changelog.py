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
DEFAULT_VARIANTS_PATH = Path(__file__).parent.parent.parent / "variants.json"

RETRIES = 3
RETRY_WAIT = 5
FEDORA_PATTERN = re.compile(r"(?<=[-0-9a-z])\.fc\d{2}(?![0-9])")
STABLE_START_PATTERN = re.compile(r"\d+\.\d{8}(?:\.\d+)?$")


def _compute_images_from_variants() -> list[str]:
    """Compute the IMAGES list from variants.json dynamically."""
    try:
        with open(DEFAULT_VARIANTS_PATH) as f:
            data = json.load(f)
        return [f"bazzite-nix{v.get('suffix', '')}" for v in data.get("variants", [])]
    except Exception:
        return []


# Full set of image variants derived from variants.json
IMAGES = _compute_images_from_variants()


def other_start_pattern(target: str) -> re.Pattern:
    """Return pattern matching non-stable tags: {target}-DD.YYYYMMDD[.nn]"""
    return re.compile(rf"^{re.escape(target)}-\d+\.\d{{8}}(?:\.\d+)?$")


PATTERN_ADD = "\n| ✨ | {name} | | {version} |"
PATTERN_CHANGE = "\n| 🔄 | {name} | {prev} | {new} |"
PATTERN_REMOVE = "\n| ❌ | {name} | {version} | |"
PATTERN_PKGREL_CHANGED = "{prev} ➡️ {new}"
PATTERN_PKGREL = "{version}"
# Upstream GitHub repo for commit fetching.
# Set by the calling action via GITHUB_REPOSITORY env var (e.g. "wombatfromhell/bazzite-nix").
# Falls back to ublue-os/bazzite for direct invocation.
UPSTREAM_REPO = os.environ.get("GITHUB_REPOSITORY", "ublue-os/bazzite")

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

PKG_ALIAS = {}


def load_variants(variants_config: str | None = None) -> list[dict[str, Any]]:
    """Load variant configuration from variants.json file."""
    if not variants_config:
        # Try default path first
        if DEFAULT_VARIANTS_PATH.exists():
            with open(DEFAULT_VARIANTS_PATH) as f:
                data = json.load(f)
            variants = data.get("variants", [])
            return [v for v in variants if not v.get("disabled", False)]
        # Fallback to default images if no config found
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
            # For stable, match tags starting with the version pattern
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


def extract_rpm_from_purl(purl: str) -> tuple[str, str] | None:
    """Extract package name and version from RPM purl.

    Purl format: pkg:rpm/<namespace>/<name>@<version>?<qualifiers>
    Example: pkg:rpm/bazzite/kernel@6.19.8-200.ogc?arch=x86_64&distro=bazzite-43
    Returns: (name, version) or None if not a valid RPM purl
    """
    if not purl.startswith("pkg:rpm/"):
        return None

    # Remove pkg:rpm/<namespace>/ prefix
    parts = purl[len("pkg:rpm/") :].split("/", 1)
    if len(parts) != 2:
        return None

    # Get the name@version?qualifiers part
    name_version = parts[1]

    # Split at @ to get name and version+qualifiers
    if "@" not in name_version:
        return None

    name, version_qual = name_version.split("@", 1)

    # Remove qualifiers (everything after ?)
    version = version_qual.split("?", 1)[0]

    # URL decode common characters
    name = name.replace("%2B", "+").replace("%2b", "+")
    name = name.replace("%2F", "/").replace("%2f", "/")

    if not name or not version:
        return None

    return name, version


def get_packages_from_sbom(sbom_path: str) -> dict[str, str]:
    """Extract packages from SBOM files.

    Supports CycloneDX format (components array with purl field).
    Only extracts RPM packages by filtering on purl scheme.
    """
    packages = {}
    try:
        with open(sbom_path) as f:
            data = json.load(f)
    except FileNotFoundError:
        print(f"Warning: SBOM file not found: {sbom_path}")
        return {}
    except json.JSONDecodeError as e:
        print(f"Warning: Invalid JSON in SBOM file {sbom_path}: {e}")
        return {}
    except Exception as e:
        print(f"Warning: Failed to parse SBOM {sbom_path}: {type(e).__name__}: {e}")
        return {}

    # CycloneDX has "bomFormat" field
    bom_format = data.get("bomFormat", "")
    if bom_format == "CycloneDX":
        components = data.get("components", [])
        if components:
            for comp in components:
                purl = comp.get("purl", "")
                if purl and purl.startswith("pkg:rpm/"):
                    result = extract_rpm_from_purl(purl)
                    if result:
                        name, version = result
                        packages[name] = version
            if packages:
                print(
                    f" Parsed {len(packages)} packages from SBOM (CycloneDX RPM purl format)"
                )
                return packages

    # Fallback: Syft native format (v1.x artifacts array)
    artifacts = data.get("artifacts", [])
    if artifacts:
        for artifact in artifacts:
            name = artifact.get("name", "")
            version = artifact.get("version", "")
            if name and version:
                packages[name] = version
        if packages:
            print(f" Parsed {len(packages)} packages from SBOM (artifacts format)")
            return packages

    print(f"Warning: No packages found in SBOM file: {sbom_path}")
    return packages


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


def get_packages(
    manifests: dict[str, Any],
    sbom_path: str | None = None,
    prev_sbom_path: str | None = None,
) -> tuple[dict[str, dict[str, str]], dict[str, dict[str, str]]]:
    """Get packages from SBOM files or manifest labels.

    Returns (current_packages, prev_packages) where each is {image_name: {pkg: version}}.

    Prefers SBOM CycloneDX data when available, falls back to ostree.rechunk.info labels.
    """
    current_packages: dict[str, dict[str, str]] = {}
    prev_packages: dict[str, dict[str, str]] = {}

    sbom_available = False

    if sbom_path:
        sbom_pkgs = get_packages_from_sbom(sbom_path)
        if sbom_pkgs:
            print(f"Using SBOM for current packages: {sbom_path}")
            for img in manifests.keys():
                current_packages[img] = sbom_pkgs.copy()
            sbom_available = True
        else:
            print(f"::warning::SBOM file not found or empty: {sbom_path}")
            print(f"::warning::Falling back to manifest labels for current packages")

    if prev_sbom_path:
        prev_sbom_pkgs = get_packages_from_sbom(prev_sbom_path)
        if prev_sbom_pkgs:
            print(f"Using SBOM for previous packages: {prev_sbom_path}")
            for img in manifests.keys():
                prev_packages[img] = prev_sbom_pkgs.copy()
        else:
            print(f"::warning::Previous SBOM file not found or empty: {prev_sbom_path}")
            print(f"::warning::Falling back to manifest labels for previous packages")

    if not sbom_available:
        print("Using manifest labels for current packages")
        for img, manifest in manifests.items():
            current_packages[img] = _get_packages_from_manifest(manifest, img)

    if not prev_packages:
        print("Using manifest labels for previous packages")
        for img, manifest in manifests.items():
            prev_packages[img] = _get_packages_from_manifest(manifest, img)

    return current_packages, prev_packages


def is_nvidia(img: str, lts: bool):
    if lts:
        return "nvidia" in img and "nvidia-open" not in img and "deck-nvidia" not in img
    else:
        return "nvidia-open" in img or "deck-nvidia" in img


def get_package_groups(
    prev: dict[str, Any],
    manifests: dict[str, Any],
    variants: list[dict[str, Any]] | None = None,
    sbom_path: str | None = None,
    prev_sbom_path: str | None = None,
):
    if variants is None:
        variants = load_variants()
    common = set()
    others = {k: set() for k in OTHER_NAMES.keys()}

    npkg, _ = get_packages(manifests, sbom_path, prev_sbom_path)
    ppkg, _ = get_packages(prev, None, None)

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


def get_versions(manifests: dict[str, Any], sbom_path: str | None = None):
    versions = {}
    pkgs, _ = get_packages(manifests, sbom_path, None)
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


def get_commits(prev_manifests, manifests):
    """Fetch commits using revision hashes from image labels."""
    try:
        start = next(iter(prev_manifests.values()))["Labels"][
            "org.opencontainers.image.revision"
        ]
        finish = next(iter(manifests.values()))["Labels"][
            "org.opencontainers.image.revision"
        ]

        # Use GitHub API to compare commits
        api_url = (
            f"https://api.github.com/repos/{UPSTREAM_REPO}/compare/{start}...{finish}"
        )

        response = subprocess.run(
            ["curl", "-s", "-H", "Accept: application/vnd.github+json", api_url],
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
    sbom_path: str | None = None,
    prev_sbom_path: str | None = None,
):
    common, others = get_package_groups(
        prev_manifests, manifests, variants, sbom_path, prev_sbom_path
    )
    versions = get_versions(manifests, sbom_path)
    prev_versions = get_versions(prev_manifests, prev_sbom_path)

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
    common = calculate_changes(common, prev_versions, versions)
    if common:
        changes += COMMON_PAT.format(changes=common)
    for k, v in others.items():
        chg = calculate_changes(v, prev_versions, versions)
        if chg:
            changes += OTHER_NAMES[k].format(changes=chg)
    changes += get_commits(prev_manifests, manifests)

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
    parser.add_argument("--sbom", help="Path to current SBOM JSON file")
    parser.add_argument("--prev-sbom", help="Path to previous SBOM JSON file")
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

    if args.sbom:
        print(f"Using SBOM for current: {args.sbom}")
    if args.prev_sbom:
        print(f"Using SBOM for previous: {args.prev_sbom}")

    prev_manifests = get_manifests(prev, variants)
    title, changelog = generate_changelog(
        args.handwritten,
        target,
        args.pretty,
        args.workdir,
        prev_manifests,
        manifests,
        variants,
        args.sbom,
        args.prev_sbom,
    )

    print(f"Changelog:\n# {title}\n{changelog}")
    print(f'\nOutput:\nTITLE="{title}"\nTAG="{curr}"')

    with open(args.changelog, "w") as f:
        f.write(changelog)

    with open(args.output, "w") as f:
        f.write(f'TITLE="{title}"\nTAG="{curr}"\n')


if __name__ == "__main__":
    main()
