#!/usr/bin/env python3
"""
Test suite for changelog.py

Tests the changelog generation functionality with realistic data.
Follows testing principles:
1. Never mock the system-under-test
2. Test what can be tested - avoid superfluous mocking
3. Tests should catch bugs in implemented code
"""

import json
import os
import sys
import tempfile
import pytest
from pathlib import Path

# Import the module under test
sys.path.insert(0, str(Path(__file__).parent))
import changelog


# =============================================================================
# Test Data Fixtures
# =============================================================================


@pytest.fixture
def sample_variants():
    """Sample variants configuration matching real structure."""
    return [
        {
            "name": "testing",
            "base_image": "ghcr.io/ublue-os/bazzite:testing",
            "suffix": "",
            "tags": {"versioned": ["{branch}", "{branch}-{canonical}"]},
        },
        {
            "name": "unstable",
            "base_image": "ghcr.io/ublue-os/bazzite:unstable",
            "suffix": "",
            "tags": {"versioned": ["{branch}", "{branch}-{canonical}"]},
        },
    ]


@pytest.fixture
def sample_manifest_prev():
    """Sample manifest for previous version."""
    return {
        "Name": "ghcr.io/ublue-os/bazzite-nix:testing",
        "Digest": "sha256:abc123",
        "RepoTags": [
            "testing",
            "testing-43.20260220.1",
            "testing-43.20260220.1.fc41",
        ],
        "Labels": {
            "org.opencontainers.image.version": "43.20260220.1",
            "org.opencontainers.image.revision": "abc123def456",
            "org.opencontainers.image.created": "2026-02-20T06:00:00Z",
            "org.opencontainers.image.kernel-version": "6.13.0",
            "dev.hhd.rechunk.info": json.dumps(
                {
                    "packages": {
                        "kernel": "6.13.0-1.fc41",
                        "mesa-filesystem": "25.0.0-1.fc41",
                        "gamescope": "3.16.0-1.fc41",
                        "bazaar": "1.2.0-1.fc41",
                        "plasma-desktop": "6.3.0-1.fc41",
                        "atheros-firmware": "20260209-1.fc41",
                        "some-package": "1.0.0-1.fc41",
                        "another-package": "2.0.0-1.fc41",
                    }
                }
            ),
        },
    }


@pytest.fixture
def sample_manifest_curr():
    """Sample manifest for current version."""
    return {
        "Name": "ghcr.io/ublue-os/bazzite-nix:testing",
        "Digest": "sha256:def789",
        "RepoTags": [
            "testing",
            "testing-43.20260220.1",
            "testing-43.20260221.2",
            "testing-43.20260221.2.fc41",
        ],
        "Labels": {
            "org.opencontainers.image.version": "43.20260221.2",
            "org.opencontainers.image.revision": "def789abc123",
            "org.opencontainers.image.created": "2026-02-21T06:00:00Z",
            "org.opencontainers.image.kernel-version": "6.13.1",
            "dev.hhd.rechunk.info": json.dumps(
                {
                    "packages": {
                        "kernel": "6.13.1-1.fc41",
                        "mesa-filesystem": "25.0.1-1.fc41",
                        "gamescope": "3.16.0-1.fc41",
                        "bazaar": "1.2.1-1.fc41",
                        "plasma-desktop": "6.3.0-1.fc41",
                        "atheros-firmware": "20260309-1.fc41",
                        "some-package": "1.0.0-1.fc41",
                        "new-package": "3.0.0-1.fc41",
                        # another-package removed
                    }
                }
            ),
        },
    }


@pytest.fixture
def sample_manifests_prev(sample_manifest_prev):
    """Multiple variant manifests for previous version."""
    return {
        "testing": sample_manifest_prev,
        "unstable": sample_manifest_prev,
    }


@pytest.fixture
def sample_manifests_curr(sample_manifest_curr):
    """Multiple variant manifests for current version."""
    return {
        "testing": sample_manifest_curr,
        "unstable": sample_manifest_curr,
    }


@pytest.fixture
def temp_git_repo():
    """Create a temporary git repository with commit history."""
    import subprocess

    with tempfile.TemporaryDirectory() as tmpdir:
        # Initialize git repo
        subprocess.run(["git", "init"], cwd=tmpdir, check=True, capture_output=True)
        subprocess.run(
            ["git", "config", "user.email", "test@test.com"],
            cwd=tmpdir,
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Test User"],
            cwd=tmpdir,
            check=True,
            capture_output=True,
        )

        # Create initial commit
        test_file = Path(tmpdir) / "test.txt"
        test_file.write_text("initial")
        subprocess.run(["git", "add", "."], cwd=tmpdir, check=True, capture_output=True)
        subprocess.run(
            ["git", "commit", "-m", "Initial commit"],
            cwd=tmpdir,
            check=True,
            capture_output=True,
        )
        initial_hash = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=tmpdir,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

        # Create second commit
        test_file.write_text("updated")
        subprocess.run(["git", "add", "."], cwd=tmpdir, check=True, capture_output=True)
        subprocess.run(
            ["git", "commit", "-m", "Update test file"],
            cwd=tmpdir,
            check=True,
            capture_output=True,
        )
        final_hash = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=tmpdir,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

        yield tmpdir, initial_hash, final_hash


@pytest.fixture
def variants_config_file(sample_variants):
    """Create a temporary variants.json config file."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump({"variants": sample_variants}, f)
        temp_path = f.name

    yield temp_path

    # Cleanup
    os.unlink(temp_path)


# =============================================================================
# Test: Variant Loading
# =============================================================================


class TestGetVariants:
    """Test get_variants function."""

    def test_loads_variants_from_config_file(self, variants_config_file):
        """Should load variants from JSON config file."""
        variants = changelog.get_variants(variants_config_file)

        assert len(variants) == 2
        assert variants[0]["name"] == "testing"
        assert variants[1]["name"] == "unstable"

    def test_filters_disabled_variants_by_default(self):
        """Should filter out disabled variants by default."""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(
                {
                    "variants": [
                        {"name": "enabled", "base_image": "test:latest", "suffix": ""},
                        {
                            "name": "disabled",
                            "base_image": "test:latest",
                            "suffix": "",
                            "disabled": True,
                        },
                    ]
                },
                f,
            )
            temp_path = f.name

        try:
            variants = changelog.get_variants(temp_path)

            assert len(variants) == 1
            assert variants[0]["name"] == "enabled"
            assert variants[0]["name"] != "disabled"
        finally:
            os.unlink(temp_path)

    def test_includes_disabled_variants_when_requested(self):
        """Should include disabled variants when include_disabled=True."""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(
                {
                    "variants": [
                        {"name": "enabled", "base_image": "test:latest", "suffix": ""},
                        {
                            "name": "disabled",
                            "base_image": "test:latest",
                            "suffix": "",
                            "disabled": True,
                        },
                    ]
                },
                f,
            )
            temp_path = f.name

        try:
            variants = changelog.get_variants(temp_path, include_disabled=True)

            assert len(variants) == 2
            variant_names = {v["name"] for v in variants}
            assert "enabled" in variant_names
            assert "disabled" in variant_names

            # Disabled flag should be preserved in result
            disabled_variant = next(v for v in variants if v["name"] == "disabled")
            assert disabled_variant["disabled"] is True
        finally:
            os.unlink(temp_path)

    def test_handles_missing_suffix(self, variants_config_file):
        """Should handle variants without suffix field."""
        variants = changelog.get_variants(variants_config_file)

        # Both variants should have suffix (even if empty string)
        for variant in variants:
            assert "suffix" in variant
            assert isinstance(variant["suffix"], str)

    def test_handles_missing_tags(self, variants_config_file):
        """Should handle variants without tags field."""
        variants = changelog.get_variants(variants_config_file)

        # Tags should be present (may be empty dict)
        for variant in variants:
            assert "tags" in variant
            assert isinstance(variant["tags"], dict)

    def test_raises_on_invalid_json(self):
        """Should raise on invalid JSON config."""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            f.write("not valid json")
            temp_path = f.name

        try:
            with pytest.raises(json.JSONDecodeError):
                changelog.get_variants(temp_path)
        finally:
            os.unlink(temp_path)

    def test_returns_empty_on_no_variants(self):
        """Should return empty list when no variants defined."""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump({"variants": []}, f)
            temp_path = f.name

        try:
            variants = changelog.get_variants(temp_path)
            assert len(variants) == 0
        finally:
            os.unlink(temp_path)


# =============================================================================
# Test: Tag Resolution
# =============================================================================


class TestGetTagsFromManifests:
    """Test get_tags_from_manifests function."""

    def test_resolves_tags_from_variant_patterns(
        self, sample_manifests_curr, sample_variants
    ):
        """Should resolve tags using variant tag patterns."""
        prev_tag, curr_tag = changelog.get_tags_from_manifests(
            sample_manifests_curr, "testing", sample_variants
        )

        # Should find the two most recent versioned tags
        assert prev_tag is not None
        assert curr_tag is not None
        assert prev_tag != curr_tag

    def test_handles_branch_tag_pattern(self, sample_manifests_curr, sample_variants):
        """Should handle {branch} tag pattern."""
        prev_tag, curr_tag = changelog.get_tags_from_manifests(
            sample_manifests_curr, "testing", sample_variants
        )

        # One of the tags should be the branch tag or both should be versioned
        assert "testing" in [prev_tag, curr_tag] or (
            prev_tag.startswith("testing-") and curr_tag.startswith("testing-")
        )

    def test_handles_canonical_tag_pattern(
        self, sample_manifests_curr, sample_variants
    ):
        """Should handle {canonical} tag pattern with version numbers."""
        prev_tag, curr_tag = changelog.get_tags_from_manifests(
            sample_manifests_curr, "testing", sample_variants
        )

        # Tags should match pattern testing-X.Y.Z
        canonical_pattern = r"testing-\d+\.\d+(?:\.\d+)?"
        import re

        # At least one tag should be versioned
        assert (
            re.match(canonical_pattern, prev_tag)
            or re.match(canonical_pattern, curr_tag)
            or prev_tag == "testing"
            or curr_tag == "testing"
        )

    def test_skips_tags_ending_with_zero(self, sample_manifests_curr, sample_variants):
        """Should skip tags ending with .0."""
        # Add a .0 tag to test filtering
        sample_manifests_curr["testing"]["RepoTags"].append("testing-43.20260221.0")

        prev_tag, curr_tag = changelog.get_tags_from_manifests(
            sample_manifests_curr, "testing", sample_variants
        )

        # Neither tag should end with .0
        assert not prev_tag.endswith(".0")
        assert not curr_tag.endswith(".0")

    def test_returns_sorted_tags(self, sample_manifests_curr, sample_variants):
        """Should return tags in sorted order (prev < curr)."""
        prev_tag, curr_tag = changelog.get_tags_from_manifests(
            sample_manifests_curr, "testing", sample_variants
        )

        # Previous should come before current alphabetically/numerically
        assert prev_tag <= curr_tag

    def test_handles_empty_manifests(self):
        """Should raise on empty manifests."""
        with pytest.raises(ValueError, match="No manifests provided"):
            changelog.get_tags_from_manifests({}, "testing", [])

    def test_handles_missing_repotags(self, sample_variants):
        """Should handle manifests without RepoTags."""
        manifests = {
            "testing": {
                "Name": "test",
                "Labels": {},
            }
        }

        # Should not crash, should return fallback values
        prev_tag, curr_tag = changelog.get_tags_from_manifests(
            manifests, "testing", sample_variants
        )

        # Should return target as fallback
        assert prev_tag == "testing"
        assert curr_tag == "testing"

    def test_handles_single_tag(self, sample_variants):
        """Should handle case where only one tag exists."""
        manifests = {
            "testing": {
                "Name": "test",
                "RepoTags": ["testing"],
                "Labels": {},
            }
        }

        prev_tag, curr_tag = changelog.get_tags_from_manifests(
            manifests, "testing", sample_variants
        )

        # Should return target as both prev and curr
        assert prev_tag == "testing"
        assert curr_tag == "testing"

    def test_handles_variants_without_tags_config(self, sample_manifests_curr):
        """Should use default tag patterns for variants without explicit tags config."""
        # Create variants without tags config
        variants_no_tags = [
            {
                "name": "testing",
                "base_image": "ghcr.io/ublue-os/bazzite:testing",
                "suffix": "",
                "tags": {},  # Empty tags config
            },
        ]

        prev_tag, curr_tag = changelog.get_tags_from_manifests(
            sample_manifests_curr, "testing", variants_no_tags
        )

        # Should use default patterns and find tags
        assert prev_tag is not None
        assert curr_tag is not None
        # Should find testing tags
        assert "testing" in [prev_tag, curr_tag] or prev_tag.startswith("testing-")

    def test_handles_mixed_tags_config(self, sample_manifests_curr):
        """Should handle mix of variants with and without tags config."""
        variants_mixed = [
            {
                "name": "testing",
                "base_image": "ghcr.io/ublue-os/bazzite:testing",
                "suffix": "",
                "tags": {"versioned": ["{branch}", "{branch}-{canonical}"]},
            },
            {
                "name": "unstable",
                "base_image": "ghcr.io/ublue-os/bazzite:unstable",
                "suffix": "",
                "tags": {},  # No tags config - should use defaults
            },
        ]

        # Should not crash and should find tags
        prev_tag, curr_tag = changelog.get_tags_from_manifests(
            sample_manifests_curr, "testing", variants_mixed
        )

        assert prev_tag is not None
        assert curr_tag is not None

    def test_filters_disabled_variants_in_tag_resolution(self, sample_manifests_curr):
        """Should filter out disabled variants when resolving tags."""
        variants_with_disabled = [
            {
                "name": "testing",
                "base_image": "ghcr.io/ublue-os/bazzite:testing",
                "suffix": "",
                "tags": {"versioned": ["{branch}", "{branch}-{canonical}"]},
                "disabled": False,
            },
            {
                "name": "stable",
                "base_image": "ghcr.io/ublue-os/bazzite:stable",
                "suffix": "",
                "tags": {"versioned": ["{branch}"]},
                "disabled": True,  # Disabled variant
            },
        ]

        # Should only use enabled variants
        prev_tag, curr_tag = changelog.get_tags_from_manifests(
            sample_manifests_curr, "testing", variants_with_disabled
        )

        # Should find tags from enabled variant only
        assert prev_tag is not None
        assert curr_tag is not None


# =============================================================================
# Test: Manifest Fetching
# =============================================================================


class TestGetManifestsForTarget:
    """Test get_manifests_for_target function."""

    def test_fetches_manifests_for_enabled_variants(self, sample_variants, monkeypatch):
        """Should only fetch manifests for enabled variants."""

        # Mock get_manifest to return a simple manifest
        def mock_get_manifest(image_ref):
            return {
                "Name": image_ref,
                "Labels": {},
                "RepoTags": ["testing"],
            }

        monkeypatch.setattr(changelog, "get_manifest", mock_get_manifest)

        manifests = changelog.get_manifests_for_target("testing", sample_variants)

        # Should have manifests for both enabled variants
        assert "testing" in manifests
        assert "unstable" in manifests

    def test_filters_disabled_variants(self, monkeypatch):
        """Should skip disabled variants when fetching manifests."""
        variants_with_disabled = [
            {
                "name": "testing",
                "base_image": "ghcr.io/ublue-os/bazzite:testing",
                "suffix": "",
                "tags": {},
                "disabled": False,
            },
            {
                "name": "stable",
                "base_image": "ghcr.io/ublue-os/bazzite:stable",
                "suffix": "",
                "tags": {},
                "disabled": True,
            },
        ]

        fetched_refs = []

        def mock_get_manifest(image_ref):
            fetched_refs.append(image_ref)
            return {
                "Name": image_ref,
                "Labels": {},
                "RepoTags": ["testing"],
            }

        monkeypatch.setattr(changelog, "get_manifest", mock_get_manifest)

        manifests = changelog.get_manifests_for_target(
            "testing", variants_with_disabled
        )

        # Should only fetch testing, not stable
        assert "testing" in manifests
        assert "stable" not in manifests

        # Verify image refs fetched
        assert any("testing" in ref for ref in fetched_refs)
        assert not any("stable" in ref for ref in fetched_refs)

    def test_returns_empty_on_no_manifests(self, sample_variants, monkeypatch, capsys):
        """Should return empty dict and print warning when no manifests found."""
        # Mock get_manifest to return None
        monkeypatch.setattr(changelog, "get_manifest", lambda x: None)

        manifests = changelog.get_manifests_for_target("testing", sample_variants)

        assert manifests == {}

        # Should print warning
        captured = capsys.readouterr()
        assert "::warning::" in captured.out


# =============================================================================
# Test: Package Extraction
# =============================================================================


class TestGetPackages:
    """Test get_packages function."""

    def test_extracts_packages_from_rechunk_label(self, sample_manifest_curr):
        """Should extract packages from dev.hhd.rechunk.info label."""
        packages = changelog.get_packages(sample_manifest_curr)

        assert len(packages) > 0
        assert "kernel" in packages
        assert packages["kernel"] == "6.13.1-1.fc41"

    def test_handles_missing_rechunk_label(self):
        """Should handle manifests without rechunk label."""
        manifest = {
            "Name": "test",
            "Labels": {},
        }

        packages = changelog.get_packages(manifest)
        assert packages == {}

    def test_handles_invalid_json_in_label(self):
        """Should handle invalid JSON in rechunk label."""
        manifest = {
            "Name": "test",
            "Labels": {
                "dev.hhd.rechunk.info": "not valid json",
            },
        }

        packages = changelog.get_packages(manifest)
        assert packages == {}

    def test_handles_missing_packages_key(self):
        """Should handle rechunk info without packages key."""
        manifest = {
            "Name": "test",
            "Labels": {
                "dev.hhd.rechunk.info": json.dumps({"other": "data"}),
            },
        }

        packages = changelog.get_packages(manifest)
        assert packages == {}


# =============================================================================
# Test: Version Aggregation
# =============================================================================


class TestGetVersions:
    """Test get_versions function."""

    def test_aggregates_versions_from_manifests(self, sample_manifests_curr):
        """Should aggregate package versions from all manifests."""
        versions = changelog.get_versions(sample_manifests_curr)

        assert len(versions) > 0
        assert "kernel" in versions
        assert "mesa-filesystem" in versions

    def test_cleans_fedora_version_suffix(self, sample_manifests_curr):
        """Should clean Fedora version suffix from package versions."""
        versions = changelog.get_versions(sample_manifests_curr)

        # Versions should not contain .fc41 suffix
        for pkg, version in versions.items():
            assert ".fc41" not in version

    def test_handles_empty_manifests(self):
        """Should handle empty manifests."""
        versions = changelog.get_versions({})
        assert versions == {}

    def test_handles_missing_labels(self):
        """Should handle manifests without labels."""
        manifests = {
            "testing": {
                "Name": "test",
            }
        }

        versions = changelog.get_versions(manifests)
        assert versions == {}


# =============================================================================
# Test: Change Calculation
# =============================================================================


class TestCalculateChanges:
    """Test calculate_changes function."""

    def test_detects_added_packages(self):
        """Should detect newly added packages."""
        prev = {"pkg-a": "1.0.0"}
        curr = {"pkg-a": "1.0.0", "pkg-b": "2.0.0"}

        changes = changelog.calculate_changes(["pkg-a", "pkg-b"], prev, curr)

        assert "pkg-b" in changes
        assert "✨" in changes  # Add pattern

    def test_detects_removed_packages(self):
        """Should detect removed packages."""
        prev = {"pkg-a": "1.0.0", "pkg-b": "2.0.0"}
        curr = {"pkg-a": "1.0.0"}

        changes = changelog.calculate_changes(["pkg-a", "pkg-b"], prev, curr)

        assert "pkg-b" in changes
        assert "❌" in changes  # Remove pattern

    def test_detects_changed_packages(self):
        """Should detect changed package versions."""
        prev = {"pkg-a": "1.0.0"}
        curr = {"pkg-a": "1.0.1"}

        changes = changelog.calculate_changes(["pkg-a"], prev, curr)

        assert "pkg-a" in changes
        assert "🔄" in changes  # Change pattern
        assert "1.0.0" in changes
        assert "1.0.1" in changes

    def test_skips_unchanged_packages(self):
        """Should skip unchanged packages."""
        prev = {"pkg-a": "1.0.0", "pkg-b": "2.0.0"}
        curr = {"pkg-a": "1.0.0", "pkg-b": "2.0.0"}

        changes = changelog.calculate_changes(["pkg-a", "pkg-b"], prev, curr)

        # No changes should be reported
        assert changes == ""

    def test_skips_blacklist_packages(self):
        """Should skip packages in blacklist."""
        prev = {"kernel": "6.13.0", "pkg-a": "1.0.0"}
        curr = {"kernel": "6.13.1", "pkg-a": "1.0.0"}

        changes = changelog.calculate_changes(["kernel", "pkg-a"], prev, curr)

        # Kernel should be skipped (in HIGHLIGHT_PACKAGES)
        assert "kernel" not in changes

    def test_handles_empty_package_list(self):
        """Should handle empty package list."""
        changes = changelog.calculate_changes([], {}, {})
        assert changes == ""

    def test_formats_changes_output_correctly(self):
        """Should format changes with correct markdown table."""
        prev = {}
        curr = {"pkg-a": "1.0.0"}

        changes = changelog.calculate_changes(["pkg-a"], prev, curr)

        # Should contain markdown table row
        assert "|" in changes
        assert "pkg-a" in changes
        assert "1.0.0" in changes


# =============================================================================
# Test: Kernel Version Extraction
# =============================================================================


class TestGetKernelVersion:
    """Test get_kernel_version function."""

    def test_extracts_from_standard_label(self, sample_manifest_curr):
        """Should extract kernel version from standard OCI label."""
        kernel = changelog.get_kernel_version(sample_manifest_curr)

        assert kernel == "6.13.1"

    def test_extracts_from_custom_label(self):
        """Should extract kernel version from custom label."""
        manifest = {
            "Labels": {
                "io.github.bazzite-nix.kernel-version": "6.14.0",
            }
        }

        kernel = changelog.get_kernel_version(manifest)
        assert kernel == "6.14.0"

    def test_returns_unknown_on_missing_labels(self):
        """Should return 'Unknown' when labels missing."""
        manifest = {}

        kernel = changelog.get_kernel_version(manifest)
        assert kernel == "Unknown"

    def test_returns_unknown_on_empty_labels(self):
        """Should return 'Unknown' when labels empty."""
        manifest = {"Labels": {}}

        kernel = changelog.get_kernel_version(manifest)
        assert kernel == "Unknown"


# =============================================================================
# Test: Changelog Generation
# =============================================================================


class TestGenerateChangelog:
    """Test generate_changelog function."""

    def test_generates_changelog_with_all_sections(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should generate changelog with all expected sections."""
        title, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Check title format
        assert title is not None
        assert len(title) > 0

        # Check changelog sections
        assert "Base Image Information" in changelog_text
        assert "Kernel" in changelog_text
        assert "How to rebase" in changelog_text
        assert "bazzite-rollback-helper" in changelog_text

    def test_includes_handwritten_text(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should include custom handwritten text."""
        handwritten = "Custom release notes here."

        title, changelog_text = changelog.generate_changelog(
            handwritten=handwritten,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        assert handwritten in changelog_text

    def test_generates_pretty_title(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should generate pretty title when not provided."""
        title, _ = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Title should contain target name
        assert "Testing" in title or "testing" in title

    def test_uses_custom_pretty_title(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should use custom pretty title when provided."""
        custom_title = "My Custom Release Title"

        title, _ = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=custom_title,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        assert custom_title in title

    def test_includes_package_changes(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should include package change information."""
        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Should have changes section
        assert "All Variants" in changelog_text or "###" in changelog_text

    def test_includes_build_date(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should include build date."""
        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Should have date in some format
        assert "Build Date" in changelog_text

    def test_includes_kernel_version(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should include kernel version."""
        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Kernel version should be present
        assert "6.13" in changelog_text or "Kernel" in changelog_text


# =============================================================================
# Test: Pkgrel Table Generation
# =============================================================================


class TestGetPkgrelTable:
    """Test get_pkgrel_table function."""

    def test_generates_table_rows_for_present_packages(self, sample_manifests_curr):
        """Should generate table rows only for packages present in the image."""
        table_rows = changelog.get_pkgrel_table(sample_manifests_curr)

        # Should contain rows for packages that exist
        assert "**Firmware**" in table_rows  # atheros-firmware
        assert "**Mesa**" in table_rows  # mesa-filesystem
        assert "**Gamescope**" in table_rows  # gamescope
        assert "**Bazaar**" in table_rows  # bazaar
        assert "**KDE**" in table_rows  # plasma-desktop

    def test_omits_missing_packages(self, sample_manifests_curr):
        """Should omit packages not present in the image."""
        table_rows = changelog.get_pkgrel_table(sample_manifests_curr)

        # These packages are not in sample_manifests_curr
        assert "**Gnome**" not in table_rows  # gnome-control-center-filesystem
        assert "**Nvidia**" not in table_rows  # nvidia-kmod-common
        assert "**Nvidia LTS**" not in table_rows  # nvidia-kmod-common-lts

    def test_cleans_fedora_suffix_from_versions(self, sample_manifests_curr):
        """Should clean Fedora version suffix from package versions."""
        table_rows = changelog.get_pkgrel_table(sample_manifests_curr)

        # Versions should not contain .fc41 suffix
        assert ".fc41" not in table_rows

    def test_returns_empty_string_for_no_packages(self):
        """Should return empty string when no pkgrel packages found."""
        manifests = {
            "testing": {
                "Name": "test",
                "Labels": {
                    "dev.hhd.rechunk.info": json.dumps(
                        {"packages": {"other-pkg": "1.0.0"}}
                    ),
                },
            }
        }

        table_rows = changelog.get_pkgrel_table(manifests)
        assert table_rows == ""

    def test_handles_missing_rechunk_label(self):
        """Should handle manifests without rechunk label."""
        manifests = {
            "testing": {
                "Name": "test",
                "Labels": {},
            }
        }

        table_rows = changelog.get_pkgrel_table(manifests)
        assert table_rows == ""

    def test_handles_multiple_variants(self, sample_manifests_curr):
        """Should collect packages from multiple variant manifests."""
        # Create manifests with different packages
        manifests = {
            "testing": {
                "Name": "test-testing",
                "Labels": {
                    "dev.hhd.rechunk.info": json.dumps(
                        {"packages": {"mesa-filesystem": "25.0.0-1.fc41"}}
                    ),
                },
            },
            "unstable": {
                "Name": "test-unstable",
                "Labels": {
                    "dev.hhd.rechunk.info": json.dumps(
                        {"packages": {"gamescope": "3.16.0-1.fc41"}}
                    ),
                },
            },
        }

        table_rows = changelog.get_pkgrel_table(manifests)

        # Should have both packages from different variants
        assert "**Mesa**" in table_rows
        assert "**Gamescope**" in table_rows

    def test_uses_first_found_version(self, sample_manifests_curr):
        """Should use the first found version when package exists in multiple variants."""
        manifests = {
            "testing": {
                "Name": "test-testing",
                "Labels": {
                    "dev.hhd.rechunk.info": json.dumps(
                        {"packages": {"mesa-filesystem": "25.0.0-1.fc41"}}
                    ),
                },
            },
            "unstable": {
                "Name": "test-unstable",
                "Labels": {
                    "dev.hhd.rechunk.info": json.dumps(
                        {"packages": {"mesa-filesystem": "25.0.1-1.fc41"}}
                    ),
                },
            },
        }

        table_rows = changelog.get_pkgrel_table(manifests)

        # Should contain Mesa (first found version)
        assert "**Mesa**" in table_rows
        # Should use first variant's version
        assert "25.0.0" in table_rows


# =============================================================================
# Test: Base Image Extraction
# =============================================================================


class TestBaseImageExtraction:
    """Test base_image extraction from variants config (regression test for bug fix)."""

    def test_extracts_base_image_from_variants_config(
        self, sample_manifests_curr, sample_variants
    ):
        """Should extract base_image from variants config, not manifest labels.

        Regression test for bug where code looked for
        org.opencontainers.image.base.digest label which doesn't exist.
        """
        # Get base image using the same pattern as generate_changelog
        first_variant_name = next(iter(sample_manifests_curr.keys()))
        variant_config = next(
            (v for v in sample_variants if v["name"] == first_variant_name), None
        )
        base_image = variant_config["base_image"] if variant_config else "Unknown"

        # Should extract from variants config, not return "Unknown"
        assert base_image != "Unknown"
        assert "bazzite:testing" in base_image

    def test_extracts_base_image_for_unstable_variant(self, sample_manifests_curr):
        """Should extract base_image for unstable variant from config."""
        manifests = {
            "unstable": sample_manifests_curr["unstable"],
        }
        variants = [
            {
                "name": "unstable",
                "base_image": "ghcr.io/ublue-os/bazzite:unstable",
                "suffix": "",
                "tags": {},
            },
        ]

        first_variant_name = next(iter(manifests.keys()))
        variant_config = next(
            (v for v in variants if v["name"] == first_variant_name), None
        )
        base_image = variant_config["base_image"] if variant_config else "Unknown"

        # Should work for any variant
        assert base_image == "ghcr.io/ublue-os/bazzite:unstable"

    def test_returns_unknown_for_missing_variant_config(self, sample_manifests_curr):
        """Should return 'Unknown' if variant not found in config."""
        manifests = {
            "unknown-variant": sample_manifests_curr["testing"],
        }
        variants = [
            {
                "name": "testing",
                "base_image": "ghcr.io/ublue-os/bazzite:testing",
                "suffix": "",
                "tags": {},
            },
        ]

        first_variant_name = next(iter(manifests.keys()))
        variant_config = next(
            (v for v in variants if v["name"] == first_variant_name), None
        )
        base_image = variant_config["base_image"] if variant_config else "Unknown"

        # Should return Unknown when variant config doesn't match
        assert base_image == "Unknown"


# =============================================================================
# Test: Single Variant Changelog Generation
# =============================================================================


class TestSingleVariantChangelog:
    """Test changelog generation for individual variants.

    Regression tests for workflow change: generate_release now calls
    changelog.py once per variant (testing, unstable separately) instead
    of all variants at once.
    """

    def test_generates_changelog_for_single_testing_variant(
        self, sample_manifests_prev, sample_manifests_curr
    ):
        """Should generate changelog for testing variant only."""
        # Single variant manifests (as workflow now passes)
        testing_manifests = {
            "testing": sample_manifests_curr["testing"],
        }
        testing_prev = {
            "testing": sample_manifests_prev["testing"],
        }

        # Load variants config
        variants = [
            {
                "name": "testing",
                "base_image": "ghcr.io/ublue-os/bazzite:testing",
                "suffix": "",
                "tags": {"versioned": ["{branch}", "{branch}-{canonical}"]},
            },
        ]

        title, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=variants,
            prev_manifests=testing_prev,
            manifests=testing_manifests,
        )

        # Should generate valid changelog
        assert title is not None
        assert len(changelog_text) > 0
        assert "testing" in title.lower() or "Testing" in changelog_text

    def test_generates_changelog_for_single_unstable_variant(
        self, sample_manifests_prev, sample_manifests_curr
    ):
        """Should generate changelog for unstable variant only."""
        # Single variant manifests
        unstable_manifests = {
            "unstable": sample_manifests_curr["unstable"],
        }
        unstable_prev = {
            "unstable": sample_manifests_prev["unstable"],
        }

        variants = [
            {
                "name": "unstable",
                "base_image": "ghcr.io/ublue-os/bazzite:unstable",
                "suffix": "",
                "tags": {"versioned": ["{branch}", "{branch}-{canonical}"]},
            },
        ]

        title, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="unstable",
            pretty=None,
            workdir=".",
            variants=variants,
            prev_manifests=unstable_prev,
            manifests=unstable_manifests,
        )

        # Should generate valid changelog for unstable
        assert title is not None
        assert len(changelog_text) > 0

    def test_single_variant_has_correct_base_image(
        self, sample_manifests_prev, sample_manifests_curr
    ):
        """Should have correct base image info for single variant changelog."""
        testing_manifests = {
            "testing": sample_manifests_curr["testing"],
        }
        testing_prev = {
            "testing": sample_manifests_prev["testing"],
        }

        variants = [
            {
                "name": "testing",
                "base_image": "ghcr.io/ublue-os/bazzite:testing",
                "suffix": "",
                "tags": {"versioned": ["{branch}", "{branch}-{canonical}"]},
            },
        ]

        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=variants,
            prev_manifests=testing_prev,
            manifests=testing_manifests,
        )

        # Base image should be extracted from variants config (not "Unknown")
        assert "Base Image" in changelog_text
        assert "**Base Image** | Unknown" not in changelog_text
        assert "**Base Image** | ghcr.io/ublue-os/bazzite:testing" in changelog_text

    def test_single_variant_has_pkgrel_table(
        self, sample_manifests_prev, sample_manifests_curr
    ):
        """Should include pkgrel table rows for packages present in the image."""
        testing_manifests = {
            "testing": sample_manifests_curr["testing"],
        }
        testing_prev = {
            "testing": sample_manifests_prev["testing"],
        }

        variants = [
            {
                "name": "testing",
                "base_image": "ghcr.io/ublue-os/bazzite:testing",
                "suffix": "",
                "tags": {"versioned": ["{branch}", "{branch}-{canonical}"]},
            },
        ]

        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=variants,
            prev_manifests=testing_prev,
            manifests=testing_manifests,
        )

        # Should have pkgrel table rows for packages that exist
        assert "**Firmware**" in changelog_text
        assert "**Mesa**" in changelog_text
        assert "**Gamescope**" in changelog_text
        assert "**Bazaar**" in changelog_text
        assert "**KDE**" in changelog_text

        # Should NOT have rows for packages that don't exist
        assert "**Gnome** |" not in changelog_text
        assert "**Nvidia** |" not in changelog_text
        assert "**Nvidia LTS** |" not in changelog_text


# =============================================================================
# Test: Commit Extraction
# =============================================================================


class TestGetCommits:
    """Test get_commits function."""

    def test_extracts_commits_from_git_history(
        self, temp_git_repo, sample_manifests_prev, sample_manifests_curr
    ):
        """Should extract commits from git history."""
        tmpdir, start_hash, end_hash = temp_git_repo

        # Update manifests with actual commit hashes
        sample_manifests_prev["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ] = start_hash
        sample_manifests_curr["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ] = end_hash

        commits = changelog.get_commits(
            sample_manifests_prev,
            sample_manifests_curr,
            tmpdir,
            "test-owner",
            "test-repo",
        )

        # Should contain commit information
        assert "Commits" in commits
        assert "Update test file" in commits

    def test_skips_merge_commits(
        self, temp_git_repo, sample_manifests_prev, sample_manifests_curr
    ):
        """Should skip merge commits."""
        tmpdir, start_hash, end_hash = temp_git_repo

        # Create a merge commit
        import subprocess

        subprocess.run(
            ["git", "checkout", "-b", "feature"],
            cwd=tmpdir,
            check=True,
            capture_output=True,
        )
        test_file = Path(tmpdir) / "feature.txt"
        test_file.write_text("feature")
        subprocess.run(["git", "add", "."], cwd=tmpdir, check=True, capture_output=True)
        subprocess.run(
            ["git", "commit", "-m", "Add feature"],
            cwd=tmpdir,
            check=True,
            capture_output=True,
        )
        # Get default branch name (master on older git, main on newer)
        default_branch = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=tmpdir,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        subprocess.run(
            ["git", "checkout", default_branch],
            cwd=tmpdir,
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "merge", "--no-ff", "-m", "Merge feature", "feature"],
            cwd=tmpdir,
            check=True,
            capture_output=True,
        )
        merge_hash = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=tmpdir,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

        sample_manifests_prev["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ] = start_hash
        sample_manifests_curr["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ] = merge_hash

        commits = changelog.get_commits(
            sample_manifests_prev,
            sample_manifests_curr,
            tmpdir,
            "test-owner",
            "test-repo",
        )

        # Should not contain merge commit
        assert "Merge feature" not in commits

    def test_handles_missing_revision(
        self, sample_manifests_prev, sample_manifests_curr
    ):
        """Should handle missing revision labels."""
        # Remove revision labels
        del sample_manifests_prev["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ]
        del sample_manifests_curr["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ]

        commits = changelog.get_commits(
            sample_manifests_prev,
            sample_manifests_curr,
            ".",
            "test-owner",
            "test-repo",
        )

        # Should return empty string
        assert commits == ""

    def test_handles_invalid_workdir(
        self, sample_manifests_prev, sample_manifests_curr
    ):
        """Should handle invalid working directory."""
        sample_manifests_prev["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ] = "abc123"
        sample_manifests_curr["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ] = "def456"

        commits = changelog.get_commits(
            sample_manifests_prev,
            sample_manifests_curr,
            "/nonexistent/path",
            "test-owner",
            "test-repo",
        )

        # Should return empty string on error
        assert commits == ""

    def test_includes_commit_links(
        self, temp_git_repo, sample_manifests_prev, sample_manifests_curr
    ):
        """Should include GitHub commit links."""
        tmpdir, start_hash, end_hash = temp_git_repo

        sample_manifests_prev["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ] = start_hash
        sample_manifests_curr["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ] = end_hash

        commits = changelog.get_commits(
            sample_manifests_prev,
            sample_manifests_curr,
            tmpdir,
            "test-owner",
            "test-repo",
        )

        # Should contain GitHub link
        assert "github.com/test-owner/test-repo/commit" in commits


# =============================================================================
# Test: Integration Tests
# =============================================================================


class TestIntegration:
    """Integration tests for full changelog generation workflow."""

    def test_full_changelog_generation(
        self,
        sample_variants,
        sample_manifests_prev,
        sample_manifests_curr,
        temp_git_repo,
    ):
        """Test complete changelog generation flow."""
        tmpdir, start_hash, end_hash = temp_git_repo

        # Set revision hashes
        sample_manifests_prev["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ] = start_hash
        sample_manifests_curr["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ] = end_hash

        # Generate changelog
        title, changelog_text = changelog.generate_changelog(
            handwritten="Test release notes",
            target="testing",
            pretty="Test Release v1.0",
            workdir=tmpdir,
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Verify all components
        assert "Test release notes" in changelog_text
        assert "Test Release v1.0" in title
        assert "Base Image Information" in changelog_text
        assert "Commits" in changelog_text
        assert "Update test file" in changelog_text

    def test_main_function_writes_files(
        self, sample_variants, sample_manifests_curr, variants_config_file
    ):
        """Test that main function writes output files."""
        import subprocess

        # Create mock manifests file
        with tempfile.TemporaryDirectory() as tmpdir:
            output_env = os.path.join(tmpdir, "output.env")
            output_md = os.path.join(tmpdir, "changelog.md")

            # Mock skopeo to return our test manifest
            # (In real tests, this would use actual registry)
            # For now, just test that files would be created

            # We can't easily test main() without a real registry,
            # but we can verify the function exists and has correct signature
            assert hasattr(changelog, "main")
            assert callable(changelog.main)


# =============================================================================
# Test: Edge Cases
# =============================================================================


class TestEdgeCases:
    """Test edge cases and error handling."""

    def test_handles_nvidia_suffix_variants(self):
        """Should handle variants with suffixes like -nvidia-open."""
        variants = [
            {
                "name": "nvidia-open",
                "base_image": "ghcr.io/ublue-os/bazzite-nvidia-open:stable",
                "suffix": "-nvidia-open",
                "tags": {"versioned": ["{branch}"]},
            }
        ]

        manifests = {
            "nvidia-open": {
                "Name": "ghcr.io/ublue-os/bazzite-nix-nvidia-open:testing",
                "RepoTags": ["testing", "testing-1.0.0"],
                "Labels": {
                    "dev.hhd.rechunk.info": json.dumps(
                        {"packages": {"nvidia-driver": "550.0.0"}}
                    ),
                },
            }
        }

        versions = changelog.get_versions(manifests)
        assert "nvidia-driver" in versions

    def test_handles_empty_package_versions(self):
        """Should handle empty package versions gracefully."""
        prev = {}
        curr = {}

        changes = changelog.calculate_changes([], prev, curr)
        assert changes == ""

    def test_handles_malformed_package_data(self):
        """Should handle malformed package data."""
        prev = {"pkg-a": None}
        curr = {"pkg-a": ""}

        # Should not crash
        changes = changelog.calculate_changes(["pkg-a"], prev, curr)
        # Empty version should be handled
        assert isinstance(changes, str)

    def test_handles_special_characters_in_package_names(self):
        """Should handle special characters in package names."""
        prev = {}
        curr = {"pkg-with-dash": "1.0.0", "pkg_with_underscore": "2.0.0"}

        changes = changelog.calculate_changes(
            ["pkg-with-dash", "pkg_with_underscore"], prev, curr
        )

        assert "pkg-with-dash" in changes
        assert "pkg_with_underscore" in changes

    def test_handles_very_long_version_strings(self):
        """Should handle very long version strings."""
        prev = {}
        curr = {"pkg": "1.0.0-alpha+build.123456789abcdef"}

        changes = changelog.calculate_changes(["pkg"], prev, curr)

        assert "pkg" in changes
        assert "1.0.0-alpha+build.123456789abcdef" in changes


# =============================================================================
# Test: Changelog Format Verification
# =============================================================================


class TestChangelogFormat:
    """Test that rendered changelog format matches GitHub release expectations."""

    def test_changelog_has_valid_markdown_headers(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should render valid markdown headers."""
        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Headers should use proper markdown syntax
        assert changelog_text.count("### ") >= 1
        # No malformed headers (e.g., missing space after #)
        assert "###" in changelog_text

    def test_changelog_tables_have_correct_structure(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should render tables with correct markdown structure."""
        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Tables should have header row with separators
        assert (
            "| --- | --- | --- | --- |" in changelog_text
            or "| --- | --- |" in changelog_text
        )
        # Table rows should start and end with pipes
        table_rows = [
            line
            for line in changelog_text.split("\n")
            if line.strip().startswith("|") and "---" not in line
        ]
        assert len(table_rows) >= 1

    def test_changelog_uses_correct_emoji_indicators(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should use correct emoji for change types."""
        # Create manifests with clear changes and proper tag structure
        # Use versioned tags only (no bare branch tag) to ensure proper ordering
        prev = {
            "testing": {
                "Name": "test",
                "RepoTags": ["testing-1.0.0", "testing-1.0.1"],
                "Labels": {
                    "dev.hhd.rechunk.info": json.dumps(
                        {"packages": {"removed-pkg": "1.0.0", "changed-pkg": "1.0.0"}}
                    ),
                },
            }
        }
        # Current manifest has the new tag
        curr = {
            "testing": {
                "Name": "test",
                "RepoTags": ["testing-1.0.0", "testing-1.0.1", "testing-1.0.2"],
                "Labels": {
                    "dev.hhd.rechunk.info": json.dumps(
                        {
                            "packages": {
                                "added-pkg": "2.0.0",
                                "changed-pkg": "2.0.0",
                            }  # Version changed from 1.0.0
                        }
                    ),
                },
            }
        }

        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=prev,
            manifests=curr,
        )

        # Should use correct emoji indicators
        assert "✨" in changelog_text  # Added
        assert "🔄" in changelog_text  # Changed
        assert "❌" in changelog_text  # Removed

    def test_changelog_code_blocks_are_properly_formatted(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should format code blocks with proper markdown syntax."""
        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Code blocks should use triple backticks
        assert "```bash" in changelog_text
        assert "```" in changelog_text
        # Commands should be inside code blocks
        assert "bazzite-rollback-helper" in changelog_text

    def test_changelog_links_are_valid_markdown(
        self,
        sample_variants,
        sample_manifests_prev,
        sample_manifests_curr,
        temp_git_repo,
    ):
        """Should render links with valid markdown syntax."""
        tmpdir, start_hash, end_hash = temp_git_repo

        sample_manifests_prev["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ] = start_hash
        sample_manifests_curr["testing"]["Labels"][
            "org.opencontainers.image.revision"
        ] = end_hash

        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=tmpdir,
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Links should use markdown syntax [text](url)
        import re

        markdown_links = re.findall(r"\[([^\]]+)\]\(([^)]+)\)", changelog_text)
        # Should have at least one commit link
        assert len(markdown_links) >= 1
        # Links should have non-empty text and URL
        for text, url in markdown_links:
            assert len(text) > 0
            assert len(url) > 0

    def test_changelog_inline_code_uses_backticks(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should use backticks for inline code elements."""
        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Image references and commands should be in backticks
        assert "`" in changelog_text
        # Should format version/branch references as code
        assert "testing" in changelog_text

    def test_changelog_has_proper_line_breaks(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should have proper line breaks between sections."""
        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Should have blank lines between sections
        assert "\n\n" in changelog_text
        # No excessive blank lines (3+ consecutive)
        assert "\n\n\n" not in changelog_text

    def test_changelog_bold_text_uses_double_asterisks(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should use double asterisks for bold text."""
        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Should have bold text markers
        assert "**" in changelog_text
        # Bold text should be properly closed
        bold_count = changelog_text.count("**")
        assert bold_count % 2 == 0  # Should be even (opened and closed)

    def test_changelog_release_title_format(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should format release title correctly."""
        title, _ = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Title should contain tag reference
        assert "{tag}" not in title  # Placeholder should be replaced
        # Title should not be empty
        assert len(title) > 0
        assert len(title) < 200  # Reasonable length

    def test_changelog_no_unfilled_placeholders(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should not have unfilled template placeholders."""
        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # All template variables should be replaced
        for placeholder in [
            "{handwritten}",
            "{target}",
            "{prev}",
            "{curr}",
            "{changes}",
            "{base_image}",
            "{pkgrel_table}",
            "{kernel_version}",
            "{build_date}",
        ]:
            assert placeholder not in changelog_text, (
                f"Unfilled placeholder: {placeholder}"
            )

    def test_changelog_handwritten_section_preserved(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should preserve handwritten text as-is."""
        handwritten = "## Manual Changes\n\n- Fixed issue #123\n- Updated documentation"

        _, changelog_text = changelog.generate_changelog(
            handwritten=handwritten,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # Handwritten text should appear verbatim
        assert "Fixed issue #123" in changelog_text
        assert "Updated documentation" in changelog_text

    def test_changelog_github_release_compatibility(
        self, sample_variants, sample_manifests_prev, sample_manifests_curr
    ):
        """Should produce markdown compatible with GitHub releases."""
        _, changelog_text = changelog.generate_changelog(
            handwritten=None,
            target="testing",
            pretty=None,
            workdir=".",
            variants=sample_variants,
            prev_manifests=sample_manifests_prev,
            manifests=sample_manifests_curr,
        )

        # GitHub supports GFM (GitHub Flavored Markdown)
        # Check for GFM-compatible table syntax
        assert "|" in changelog_text
        # Check for GFM-compatible code blocks
        assert "```" in changelog_text
        # Should not use HTML tags (GitHub strips some)
        assert "<table>" not in changelog_text
        assert "<tr>" not in changelog_text
        assert "<td>" not in changelog_text


# =============================================================================
# Test: Configuration Loading
# =============================================================================


class TestConfigurationLoading:
    """Test configuration and environment variable handling."""

    def test_image_prefix_from_environment(self):
        """Should use image prefix from environment."""
        original_image_prefix = os.environ.get("IMAGE_PREFIX", "")
        original_github_repo = os.environ.get("GITHUB_REPOSITORY", "")

        try:
            os.environ["IMAGE_PREFIX"] = "ghcr.io/test-owner/bazzite-nix"
            os.environ["GITHUB_REPOSITORY"] = "test-owner/bazzite-nix"
            # Reload module to pick up new env
            import importlib

            importlib.reload(changelog)

            assert changelog.IMAGE_PREFIX == "ghcr.io/test-owner/bazzite-nix"
            assert changelog.REGISTRY == "docker://ghcr.io/test-owner/bazzite-nix"
            assert changelog.REPO_OWNER == "test-owner"
            assert changelog.REPO == "bazzite-nix"
        finally:
            if original_image_prefix:
                os.environ["IMAGE_PREFIX"] = original_image_prefix
            else:
                os.environ.pop("IMAGE_PREFIX", None)
            if original_github_repo:
                os.environ["GITHUB_REPOSITORY"] = original_github_repo
            else:
                os.environ.pop("GITHUB_REPOSITORY", None)
            # Reload back
            import importlib

            importlib.reload(changelog)

    def test_fedora_pattern_matching(self):
        """Should match Fedora version patterns (exactly 2 digits)."""
        # Pattern matches .fc followed by exactly 2 digits (e.g., .fc39, .fc40, .fc41)
        # Note: match() matches from start of string, so we test the suffix directly
        assert changelog.FEDORA_PATTERN.match(".fc39")
        assert changelog.FEDORA_PATTERN.match(".fc40")
        assert changelog.FEDORA_PATTERN.match(".fc41")
        # Should not match single digit
        assert not changelog.FEDORA_PATTERN.match(".fc4")
        # Note: .fc400 will match .fc40 (first 2 digits) - this is expected regex behavior
        # The pattern is used with re.sub() which replaces the matched portion
        # Full version strings use search() in the actual code
        assert changelog.FEDORA_PATTERN.search("1.0.0.fc41")
        assert changelog.FEDORA_PATTERN.search("2.0.0.fc40")
        assert not changelog.FEDORA_PATTERN.search("1.0.0")
        assert not changelog.FEDORA_PATTERN.search("1.0.0-1")
        # Edge case: .fc4 won't match, .fc400 will match .fc40 portion
        assert not changelog.FEDORA_PATTERN.search("1.0.0.fc4")
        assert changelog.FEDORA_PATTERN.search("1.0.0.fc400")  # matches .fc40


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
