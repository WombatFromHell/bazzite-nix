import subprocess
import json
import time
from typing import Any
import re
from collections import defaultdict
from pathlib import Path
import os


# Registry prefix for skopeo inspect, derived from IMAGE_PREFIX env var
# (set by the caller as "<registry>/<package>").
def registry_prefix() -> str:
    """Return skopeo-compatible registry prefix from IMAGE_PREFIX env var."""
    image_prefix = os.environ.get("IMAGE_PREFIX", "")
    registry, _, _ = image_prefix.rpartition("/")
    if not registry:
        raise ValueError(
            "IMAGE_PREFIX must be set to <registry>/<package> "
            "(for example ghcr.io/owner/name)"
        )
    return f"docker://{registry}/"


GH_CURL_RETRIES = 2
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
# Our tags that collide with an already-published upstream version carry a bumped
# counter ({version}.{n}); that counter is walked down to the upstream build ours
# is forked from. Probes are bounded so a runaway run cannot hammer the API.
UPSTREAM_REF_PROBES = 5
UPSTREAM_BUMP_PATTERN = re.compile(r"\.\d{8}\.(?P<counter>\d+)$")

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

{intro}

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


def load_variants(variants_config: str) -> list[dict[str, Any]]:
    """Load enabled variants from a variants.json file."""
    if not variants_config:
        raise ValueError("variants config path is required")

    config_path = Path(variants_config)
    if not config_path.exists():
        raise FileNotFoundError(f"Variants config file not found: {variants_config}")

    with open(config_path) as f:
        data = json.load(f)

    variants = data.get("variants", [])
    return [v for v in variants if not v.get("disabled", False)]


def get_images(variants: list[dict[str, Any]], package: str):
    """Generate image names from variants config.

    Yields tuples of (image_name, base_type, desktop_environment).
    """
    for variant in variants:
        name = variant["name"]
        suffix = variant.get("suffix", "")
        img = f"{package}{suffix}"

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


def skopeo_json(args: list[str], what_was_read: str) -> dict[str, Any] | None:
    """Run one skopeo command, retrying transient failures, and parse its JSON.

    Returns None when every attempt failed.
    """
    for attempt in range(RETRIES):
        try:
            return json.loads(
                subprocess.run(args, check=True, stdout=subprocess.PIPE).stdout
            )
        except subprocess.CalledProcessError:
            print(
                f"Failed to get {what_was_read}, retrying in {RETRY_WAIT} seconds "
                f"({attempt + 1}/{RETRIES})"
            )
            time.sleep(RETRY_WAIT)
    return None


def image_tag_names(image: str) -> list[str]:
    """Tag names published on one registry image; empty when the listing failed."""
    listing = skopeo_json(
        ["skopeo", "list-tags", registry_prefix() + image], f"{image} tag list"
    )
    return listing.get("Tags", []) if listing else []


def version_sort_key(tag: str) -> tuple[int, ...]:
    """Order release names by their number runs, so build 10 follows build 9."""
    return tuple(int(number) for number in re.findall(r"\d+", tag))


def release_ref(image: str, variant: str) -> str:
    """The tag a variant's current release is published under.

    A canonical {variant}-{version} name wins: this fork publishes one per release,
    while the moving {variant} tag can be absent or left behind an older build.
    """
    canonical_start = (
        STABLE_START_PATTERN if variant == "stable" else other_start_pattern(variant)
    )
    canonical_tags = [
        tag for tag in image_tag_names(image) if canonical_start.match(tag)
    ]
    if not canonical_tags:
        return variant
    return max(canonical_tags, key=version_sort_key)


def get_manifests(image_refs: dict[str, str]) -> dict[str, Any]:
    """Inspect each image at its own ref; images the registry lacks are skipped."""
    manifests = {}
    for image, ref in image_refs.items():
        print(f"Getting {image}:{ref} manifest.")
        manifest = skopeo_json(
            ["skopeo", "inspect", registry_prefix() + image + ":" + ref],
            f"{image}:{ref}",
        )
        if manifest is None:
            print(f"Failed to get {image}:{ref}, skipping")
            continue
        manifests[image] = manifest
    return manifests


def get_tags(target: str, manifests: dict[str, Any]) -> tuple[str | None, str]:
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

    tags = sorted(tags, key=version_sort_key)
    assert tags, "No current and previous tags found"
    # One version tag: this variant's first release, so there is nothing to diff.
    if len(tags) == 1:
        return None, tags[0]
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
    variants: list[dict[str, Any]],
    package: str,
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
    for img, base, de in get_images(variants, package):
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
        for img, base, de in get_images(variants, package):
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


def gh_headers() -> list[str]:
    """curl headers for the GitHub endpoints this script reads."""
    headers = ["-s", "-H", "Accept: application/vnd.github+json"]
    if token := os.environ.get("GH_TOKEN"):
        headers += ["-H", f"Authorization: Bearer {token}"]
    return headers


def gh_json(url: str, failure: str) -> Any:
    """One GitHub API GET, curl-retried on transient failures.

    Returns the decoded payload, or None with `failure` plus the reason printed.
    """
    try:
        response = subprocess.run(
            ["curl", *gh_headers(), "--retry", str(GH_CURL_RETRIES), url],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout.decode("utf-8")
        return json.loads(response)
    except Exception as error:
        print(f"{failure}:\n{error}")
        return None


def fetch_tag_sha(ref: str) -> str:
    """Head commit of an upstream ref, or "" when the repository has no such ref."""
    payload = gh_json(
        f"https://api.github.com/repos/{UPSTREAM_REPO}/commits/{ref}",
        f"Failed to resolve upstream ref {ref}",
    )
    if payload is None:
        return ""

    head_sha = payload.get("sha")
    if head_sha:
        return head_sha
    print(
        f"Upstream repository has no ref {ref}: {payload.get('message', 'Unknown error')}"
    )
    return ""


def resolve_upstream_ref(ref: str) -> tuple[str, str]:
    """Resolve our tag name to a ref upstream knows, plus that ref's head sha.

    A collision-bumped tag ({version}.{n}) is our fork build of a base upstream
    already published as {version}.{n-1} or lower, so the counter walks down.
    Returns ("", "") when no name in the bounded probe budget exists upstream.
    """
    candidates = [ref]
    bump = UPSTREAM_BUMP_PATTERN.search(ref)
    if bump:
        version_prefix = ref[: bump.start("counter")]
        for counter in range(int(bump["counter"]) - 1, 0, -1):
            candidates.append(f"{version_prefix}{counter}")
        # Build .1 of a fresh date is the first build, published under the bare name.
        candidates.append(version_prefix.removesuffix("."))

    for candidate in candidates[:UPSTREAM_REF_PROBES]:
        head_sha = fetch_tag_sha(candidate)
        if head_sha:
            return candidate, head_sha
    return "", ""


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


def is_merge(message: str) -> bool:
    """Branch merges carry no change of their own, in rows and in hash picks."""
    return message.split("\n")[0].lower().startswith("merge")


def release_time(tag: str) -> str:
    """End of the version date a tag names, the last moment that release could pick up."""
    date = re.search(r"(\d{4})(\d{2})(\d{2})", tag)
    if not date:
        return ""
    year, month, day = date.groups()
    return f"{year}-{month}-{day}T23:59:59Z"


def fetch_release_hash(branch: str, as_of: str) -> str:
    """Newest upstream commit on <branch> at or before as_of: the parent release.

    Container build tags alias the older commit that build was cut from (several
    counters share one commit), so upstream's own release hash is the branch head
    at release time, not the head of the tag name we resolved.
    """
    if not as_of:
        return ""
    api_url = (
        f"https://api.github.com/repos/{UPSTREAM_REPO}/commits"
        f"?sha={branch}&until={as_of}&per_page={UPSTREAM_REF_PROBES}"
    )
    commits = gh_json(
        api_url,
        f"Failed to get the upstream release for {branch} at {as_of}",
    )
    if commits is None:
        return ""
    if not isinstance(commits, list):
        print(
            f"Upstream has no branch {branch}: {commits.get('message', 'Unknown error')}"
        )
        return ""
    if not commits:
        print(f"Upstream branch {branch} has no commit at or before {as_of}")
        return ""
    for commit in commits:
        if not is_merge(commit["commit"]["message"]):
            return commit["sha"]
    return commits[0]["sha"]


def get_commits(prev_ref: str, curr_ref: str):
    """Fetch upstream commits between two resolved upstream refs."""
    if not prev_ref or not curr_ref:
        print("Failed to get commits: an upstream ref could not be resolved")
        return ""
    api_url = (
        f"https://api.github.com/repos/{UPSTREAM_REPO}/compare/{prev_ref}...{curr_ref}"
    )
    data = gh_json(api_url, "Failed to get commits from the GitHub API")
    if data is None:
        return ""
    if "commits" not in data:
        print(
            f"Failed to get commits from GitHub API: {data.get('message', 'Unknown error')}"
        )
        return ""

    try:
        out = ""
        for commit in data["commits"]:
            sha = commit["sha"]
            short = sha[:7]
            author = commit["commit"]["author"]["name"]
            subject = commit["commit"]["message"].split("\n")[0]

            if is_merge(subject):
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
                repo=UPSTREAM_REPO, prev=prev_ref, curr=curr_ref, commits=out
            )
        return ""
    except Exception as e:
        print(f"Failed to get commits:\n{e}")
        return ""


def generate_changelog(
    handwritten: str | None,
    target: str,
    pretty: str | None,
    prev_manifests,
    manifests,
    variants: list[dict[str, Any]],
    package: str,
    tags: tuple[str | None, str] | None = None,
    as_of: str = "",
):
    common, others = get_package_groups(prev_manifests, manifests, variants, package)
    versions = get_versions(manifests)
    prev_versions = get_versions(prev_manifests)

    prev, curr = tags if tags else get_tags(target, manifests)

    # Refs upstream actually publishes, plus the head commit of the current one:
    # the title hash names the upstream build our notes describe, not our image.
    curr_ref, head_sha = resolve_upstream_ref(upstream_tag(target, curr))
    # Stable titles never carry a hash, so its branch query would only be noise.
    if target != "stable":
        head_sha = fetch_release_hash(target, as_of or release_time(curr)) or head_sha
    prev_ref = ""
    if prev is not None:
        prev_ref, _ = resolve_upstream_ref(upstream_tag(target, prev))

    if not pretty:
        # Remove .0 from curr
        curr_pretty = re.sub(r"\.\d{1,2}$", "", curr)
        # Remove target- from curr
        curr_pretty = re.sub(r"^[a-z]+-", "", curr_pretty)
        pretty = target.capitalize() + " (F" + curr_pretty
        if head_sha and target != "stable":
            pretty += ", #" + head_sha[:7]
        pretty += ")"

    title = CHANGELOG_TITLE.format_map(defaultdict(str, tag=curr, pretty=pretty))

    changelog = CHANGELOG_FORMAT

    if prev is None:
        intro = f"First `{target}` release: `{curr}`."
    else:
        intro = (
            f"From previous `{target}` version `{prev}` there have been the "
            "following changes. **One package per new version shown.**"
        )

    changelog = (
        changelog.replace(
            "{handwritten}", handwritten if handwritten else HANDWRITTEN_PLACEHOLDER
        )
        .replace("{intro}", intro)
        .replace("{target}", target)
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
    if prev is not None:
        common = calculate_changes(common, prev_versions, versions)
        if common:
            changes += COMMON_PAT.format(changes=common)
        for k, v in others.items():
            chg = calculate_changes(v, prev_versions, versions)
            if chg:
                changes += OTHER_NAMES[k].format(changes=chg)
        changes += get_commits(prev_ref, curr_ref)

    changelog = changelog.replace("{changes}", changes)

    return title, changelog


def main():
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("target", help="Target tag")
    parser.add_argument("output", help="Output environment file")
    parser.add_argument("changelog", help="Output changelog file")
    parser.add_argument(
        "--pair",
        nargs=2,
        metavar=("PREV-TAG", "CURR-TAG"),
        help="Two published tags to name the release window (default: the registry's newest two)",
    )
    parser.add_argument(
        "--as-of",
        default="",
        help="ISO timestamp of the release cut (default: the tag's version date)",
    )
    parser.add_argument("--pretty", help="Subject for the changelog")
    parser.add_argument("--handwritten", help="Handwritten changelog")
    parser.add_argument(
        "--package",
        required=True,
        help="Package name the variants' suffixes attach to",
    )
    parser.add_argument(
        "--variants-config", required=True, help="Path to variants.json"
    )
    args = parser.parse_args()

    # Remove refs/tags, refs/heads, refs/remotes e.g.
    # Tags cannot include / anyway.
    target = args.target.split("/")[-1]

    if target == "main":
        target = "stable"

    variants = load_variants(args.variants_config)
    images = [image for image, _, _ in get_images(variants, args.package)]
    if args.pair:
        prev, curr = args.pair
        manifests = get_manifests({image: curr for image in images})
        if not manifests:
            print(f"No image carries {curr}: check both tag names against the registry")
            raise SystemExit(1)
    else:
        manifests = get_manifests(
            {image: release_ref(image, target) for image in images}
        )
        prev, curr = get_tags(target, manifests)
    if prev is None:
        print(f"No previous tag for {target}: first release")
    else:
        print(f"Previous tag: {prev}")
    print(f" Current tag: {curr}")

    prev_manifests = {}
    if prev is not None:
        prev_manifests = get_manifests({image: prev for image in images})
    title, changelog = generate_changelog(
        args.handwritten,
        target,
        args.pretty,
        prev_manifests,
        manifests,
        variants,
        args.package,
        tags=args.pair,
        as_of=args.as_of,
    )

    print(f"Changelog:\n# {title}\n{changelog}")
    print(f'\nOutput:\nTITLE="{title}"\nTAG="{curr}"')

    with open(args.changelog, "w") as f:
        f.write(changelog)

    with open(args.output, "w") as f:
        f.write(f'TITLE="{title}"\nTAG="{curr}"\n')


if __name__ == "__main__":
    main()
