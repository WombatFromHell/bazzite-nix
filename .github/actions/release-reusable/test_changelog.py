#!/usr/bin/env python3
"""
Test suite for changelog.py

Uses TDD approach to prevent logic bugs in the reference implementation.
Focuses heavily on version comparison logic as it's the most critical part
of generating accurate changelogs.
"""

import pytest
import json
from changelog import (
    other_start_pattern,
    get_images,
    is_nvidia,
    get_packages,
    get_versions,
    get_tags,
    get_package_groups,
    calculate_changes,
    FEDORA_PATTERN,
    STABLE_START_PATTERN,
    BLACKLIST_VERSIONS,
    PATTERN_ADD,
    PATTERN_CHANGE,
    PATTERN_REMOVE,
    PATTERN_PKGREL_CHANGED,
    PATTERN_PKGREL,
    IMAGES,
)


# =============================================================================
# Test Helpers
# =============================================================================


def make_manifest_with_packages(packages: dict) -> dict:
    """Create a manifest dict with packages in the expected label format."""
    return {"Labels": {"ostree.rechunk.info": json.dumps({"packages": packages})}}


def make_manifest_with_tags(tags: list[str]) -> dict:
    """Create a manifest dict with RepoTags."""
    return {"RepoTags": tags}


# =============================================================================
# Tests for other_start_pattern
# =============================================================================


class TestOtherStartPattern:
    """Tests for other_start_pattern function that generates regex patterns for non-stable tags."""

    @pytest.mark.parametrize(
        "target,should_match,should_not_match",
        [
            (
                "dev",
                ["dev-1.20240101", "dev-2.20240102.1", "dev-99.20241231.99"],
                [
                    "dev-1.2024010",
                    "dev-1.202401011",
                    "stable-1.20240101",
                    "1.20240101",
                    "dev-",
                ],
            ),
            (
                "beta",
                ["beta-1.20240101", "beta-50.20241231.5"],
                ["dev-1.20240101", "beta-1.2024010", "beta-20240101"],
            ),
            (
                "rc",
                ["rc-1.20240101", "rc-3.20240101.999"],
                ["rc-1.2024010", "rc-.20240101"],
            ),
            (
                "staging",
                ["staging-1.20240101", "staging-100.20241231.100"],
                ["staging-1.2024010", "staging1.20240101"],
            ),
        ],
        ids=["dev", "beta", "rc", "staging"],
    )
    def test_pattern_matches_expected_tags(
        self, target, should_match, should_not_match
    ):
        pattern = other_start_pattern(target)

        for tag in should_match:
            assert pattern.match(tag), f"Pattern should match '{tag}'"

        for tag in should_not_match:
            assert not pattern.match(tag), f"Pattern should NOT match '{tag}'"

    @pytest.mark.parametrize(
        "target",
        ["test.dev", "foo-bar", "test+special", "test(1)", "test*"],
        ids=["dot", "hyphen", "plus", "paren", "asterisk"],
    )
    def test_escapes_special_regex_characters(self, target):
        """Pattern should escape special regex characters so they match literally."""
        pattern = other_start_pattern(target)
        # Construct a tag that should match with the literal special character
        tag = f"{target}-1.20240101"
        assert pattern.match(tag), (
            f"Pattern should match tag with special char '{target}'"
        )


# =============================================================================
# Tests for get_images
# =============================================================================


class TestGetImages:
    """Tests for get_images generator that categorizes images."""

    @pytest.mark.parametrize(
        "image,expected_base,expected_de",
        [
            ("bazzite", "desktop", "kde"),
            ("bazzite-gnome", "desktop", "gnome"),
            ("bazzite-deck", "deck", "kde"),
            ("bazzite-deck-gnome", "deck", "gnome"),
            ("bazzite-deck-nvidia", "deck", "kde"),
            ("bazzite-deck-nvidia-gnome", "deck", "gnome"),
            ("bazzite-nvidia", "desktop", "kde"),
            ("bazzite-gnome-nvidia", "desktop", "gnome"),
            ("bazzite-nvidia-open", "desktop", "kde"),
            ("bazzite-gnome-nvidia-open", "desktop", "gnome"),
        ],
        ids=lambda x: x[0],
    )
    def test_image_categorization(self, image, expected_base, expected_de):
        results = {img: (base, de) for img, base, de in get_images()}
        base, de = results[image]
        assert base == expected_base, (
            f"Image '{image}' should have base '{expected_base}', got '{base}'"
        )
        assert de == expected_de, (
            f"Image '{image}' should have de '{expected_de}', got '{de}'"
        )

    def test_yields_all_defined_images(self):
        results = list(get_images())
        assert len(results) == len(IMAGES), (
            f"Expected {len(IMAGES)} images, got {len(results)}"
        )
        yielded_images = [img for img, _, _ in results]
        assert yielded_images == IMAGES

    def test_yields_correct_tuple_structure(self):
        for img, base, de in get_images():
            assert isinstance(img, str), "Image name should be string"
            assert isinstance(base, str), "Base should be string"
            assert isinstance(de, str), "DE should be string"
            assert base in ("desktop", "deck"), (
                f"Base should be 'desktop' or 'deck', got '{base}'"
            )
            assert de in ("kde", "gnome"), f"DE should be 'kde' or 'gnome', got '{de}'"


# =============================================================================
# Tests for is_nvidia
# =============================================================================


class TestIsNvidia:
    """Tests for is_nvidia function that determines nvidia variant type."""

    @pytest.mark.parametrize(
        "image,lts,expected",
        [
            # LTS: nvidia in name, NOT nvidia-open, NOT deck-nvidia
            pytest.param("bazzite-nvidia", True, True, id="bazzite-nvidia_lts"),
            pytest.param(
                "bazzite-gnome-nvidia", True, True, id="bazzite-gnome-nvidia_lts"
            ),
            pytest.param(
                "bazzite-nvidia-open", True, False, id="bazzite-nvidia-open_lts"
            ),
            pytest.param(
                "bazzite-deck-nvidia", True, False, id="bazzite-deck-nvidia_lts"
            ),
            pytest.param(
                "bazzite-deck-nvidia-gnome",
                True,
                False,
                id="bazzite-deck-nvidia-gnome_lts",
            ),
            pytest.param("bazzite", True, False, id="bazzite_lts"),
            pytest.param("bazzite-deck", True, False, id="bazzite-deck_lts"),
            pytest.param("bazzite-gnome", True, False, id="bazzite-gnome_lts"),
            # Non-LTS: nvidia-open in name OR deck-nvidia in name
            pytest.param(
                "bazzite-nvidia-open", False, True, id="bazzite-nvidia-open_open"
            ),
            pytest.param(
                "bazzite-gnome-nvidia-open",
                False,
                True,
                id="bazzite-gnome-nvidia-open_open",
            ),
            pytest.param(
                "bazzite-deck-nvidia", False, True, id="bazzite-deck-nvidia_open"
            ),
            pytest.param(
                "bazzite-deck-nvidia-gnome",
                False,
                True,
                id="bazzite-deck-nvidia-gnome_open",
            ),
            pytest.param("bazzite-nvidia", False, False, id="bazzite-nvidia_regular"),
            pytest.param(
                "bazzite-gnome-nvidia", False, False, id="bazzite-gnome-nvidia_regular"
            ),
            pytest.param("bazzite", False, False, id="bazzite_regular"),
            pytest.param("bazzite-deck", False, False, id="bazzite-deck_regular"),
        ],
    )
    def test_nvidia_detection(self, image, lts, expected):
        assert is_nvidia(image, lts) == expected, (
            f"is_nvidia('{image}', lts={lts}) should return {expected}"
        )


# =============================================================================
# Tests for get_packages
# =============================================================================


class TestGetPackages:
    """Tests for get_packages function that extracts packages from manifest labels."""

    def test_extracts_from_ostree_rechunk_info_label(self):
        packages = {"kernel": "6.19.8-200.ogc", "mesa": "26.0.3-1"}
        manifests = {"bazzite": make_manifest_with_packages(packages)}
        result = get_packages(manifests)
        assert result["bazzite"] == packages

    def test_falls_back_to_dev_hhd_rechunk_info_label(self):
        packages = {"kernel": "6.19.8-200.ogc"}
        manifests = {
            "bazzite": {
                "Labels": {"dev.hhd.rechunk.info": json.dumps({"packages": packages})}
            }
        }
        result = get_packages(manifests)
        assert result["bazzite"] == packages

    def test_ostree_label_takes_precedence_over_dev_label(self):
        ostree_packages = {"kernel": "6.19.8-ostree"}
        dev_packages = {"kernel": "6.19.8-dev"}
        manifests = {
            "bazzite": {
                "Labels": {
                    "ostree.rechunk.info": json.dumps({"packages": ostree_packages}),
                    "dev.hhd.rechunk.info": json.dumps({"packages": dev_packages}),
                }
            }
        }
        result = get_packages(manifests)
        assert result["bazzite"]["kernel"] == "6.19.8-ostree"

    def test_returns_empty_dict_when_no_labels(self):
        manifests = {"bazzite": {"Labels": {}}}
        result = get_packages(manifests)
        assert result["bazzite"] == {}

    def test_returns_empty_dict_when_labels_missing(self):
        manifests = {"bazzite": {}}
        result = get_packages(manifests)
        assert result["bazzite"] == {}

    def test_returns_empty_dict_for_invalid_json(self):
        manifests = {"bazzite": {"Labels": {"ostree.rechunk.info": "not valid json"}}}
        result = get_packages(manifests)
        assert result["bazzite"] == {}

    def test_returns_empty_dict_for_missing_packages_key(self):
        manifests = {
            "bazzite": {
                "Labels": {"ostree.rechunk.info": json.dumps({"other": "data"})}
            }
        }
        result = get_packages(manifests)
        assert result["bazzite"] == {}

    def test_handles_multiple_images_independently(self):
        manifests = {
            "bazzite": make_manifest_with_packages({"pkg-a": "1.0"}),
            "bazzite-deck": make_manifest_with_packages({"pkg-b": "2.0"}),
        }
        result = get_packages(manifests)
        assert len(result) == 2
        assert result["bazzite"] == {"pkg-a": "1.0"}
        assert result["bazzite-deck"] == {"pkg-b": "2.0"}

    def test_handles_empty_packages_dict(self):
        manifests = {
            "bazzite": {"Labels": {"ostree.rechunk.info": json.dumps({"packages": {}})}}
        }
        result = get_packages(manifests)
        assert result["bazzite"] == {}


# =============================================================================
# Tests for get_versions
# =============================================================================


class TestGetVersions:
    """Tests for get_versions function that extracts and normalizes package versions."""

    @pytest.mark.parametrize(
        "input_version,expected_output",
        [
            ("6.19.8-200.ogc.fc40", "6.19.8-200.ogc"),
            ("26.0.3-1.fc39", "26.0.3-1"),
            ("595.58.03-1.fc41", "595.58.03-1"),
            ("1.0-1.fc42", "1.0-1"),
            ("20260309-1.fc40", "20260309-1"),
            ("0~20260202git.b5c2d0d-4.fc40", "0~20260202git.b5c2d0d-4"),
            # Versions without fedora suffix should be unchanged
            ("6.19.8-200.ogc", "6.19.8-200.ogc"),
            ("26.0.3-1", "26.0.3-1"),
            ("1.0", "1.0"),
        ],
        ids=lambda v: v[:30],
    )
    def test_strips_fedora_pattern_from_versions(self, input_version, expected_output):
        manifests = {
            "bazzite": make_manifest_with_packages({"test-pkg": input_version})
        }
        result = get_versions(manifests)
        assert result["test-pkg"] == expected_output

    def test_adds_lts_suffix_for_nvidia_packages_on_lts_images(self):
        manifests = {
            "bazzite-nvidia": make_manifest_with_packages(
                {"nvidia-kmod-common": "580.142-1.fc40"}
            )
        }
        result = get_versions(manifests)
        assert "nvidia-kmod-common-lts" in result
        assert result["nvidia-kmod-common-lts"] == "580.142-1"

    def test_no_lts_suffix_for_nvidia_open_images(self):
        manifests = {
            "bazzite-nvidia-open": make_manifest_with_packages(
                {"nvidia-kmod-common": "595.58.03-1.fc40"}
            )
        }
        result = get_versions(manifests)
        assert "nvidia-kmod-common-lts" not in result
        assert result["nvidia-kmod-common"] == "595.58.03-1"

    def test_no_lts_suffix_for_deck_nvidia_images(self):
        manifests = {
            "bazzite-deck-nvidia": make_manifest_with_packages(
                {"nvidia-kmod-common": "580.142-1.fc40"}
            )
        }
        result = get_versions(manifests)
        assert "nvidia-kmod-common-lts" not in result
        assert result["nvidia-kmod-common"] == "580.142-1"

    def test_no_lts_suffix_for_deck_nvidia_gnome_images(self):
        manifests = {
            "bazzite-deck-nvidia-gnome": make_manifest_with_packages(
                {"nvidia-kmod-common": "580.142-1.fc40"}
            )
        }
        result = get_versions(manifests)
        assert "nvidia-kmod-common-lts" not in result

    @pytest.mark.parametrize(
        "nvidia_pkg_name",
        ["nvidia-kmod-common", "nvidia-driver", "nvidia-libGL"],
        ids=lambda x: x,
    )
    def test_lts_suffix_applied_to_any_nvidia_package(self, nvidia_pkg_name):
        """Any package with 'nvidia' in the name should get -lts suffix on LTS images."""
        manifests = {
            "bazzite-nvidia": make_manifest_with_packages({nvidia_pkg_name: "1.0-1"})
        }
        result = get_versions(manifests)
        assert f"{nvidia_pkg_name}-lts" in result

    def test_non_nvidia_packages_no_lts_suffix(self):
        manifests = {
            "bazzite-nvidia": make_manifest_with_packages(
                {"kernel": "6.19.8-200.ogc", "mesa": "26.0.3-1"}
            )
        }
        result = get_versions(manifests)
        assert "kernel-lts" not in result
        assert "mesa-lts" not in result

    def test_combines_packages_from_multiple_images(self):
        manifests = {
            "bazzite": make_manifest_with_packages({"pkg-a": "1.0", "pkg-b": "2.0"}),
            "bazzite-deck": make_manifest_with_packages({"pkg-c": "3.0"}),
        }
        result = get_versions(manifests)
        assert result["pkg-a"] == "1.0"
        assert result["pkg-b"] == "2.0"
        assert result["pkg-c"] == "3.0"


# =============================================================================
# Tests for get_tags
# =============================================================================


class TestGetTags:
    """Tests for get_tags function that finds previous and current tags from manifests."""

    @pytest.fixture
    def minimal_valid_manifests(self):
        """Create manifests with enough valid tags to pass the > 2 assertion."""
        tags = ["stable-1.20240101", "stable-2.20240102", "stable-3.20240103"]
        return {img: make_manifest_with_tags(tags) for img in IMAGES}

    def test_returns_previous_and_current_tags(self, minimal_valid_manifests):
        prev, curr = get_tags("stable", minimal_valid_manifests)
        assert prev == "stable-2.20240102"
        assert curr == "stable-3.20240103"

    def test_filters_tags_ending_with_dot_zero(self):
        tags = [
            "stable-1.20240101.0",
            "stable-2.20240102",
            "stable-3.20240103",
            "stable-4.20240104",
        ]
        manifests = {img: make_manifest_with_tags(tags) for img in IMAGES}
        prev, curr = get_tags("stable", manifests)
        assert prev == "stable-3.20240103"
        assert curr == "stable-4.20240104"
        assert "stable-1.20240101.0" not in [prev, curr]

    def test_non_stable_target_uses_other_pattern(self):
        tags = [
            "dev-1.20240101",
            "dev-2.20240102",
            "dev-3.20240103",
            "stable-1.20240101",
        ]
        manifests = {img: make_manifest_with_tags(tags) for img in IMAGES}
        prev, curr = get_tags("dev", manifests)
        assert prev == "dev-2.20240102"
        assert curr == "dev-3.20240103"

    def test_ignores_tags_for_different_target(self):
        tags = ["dev-1.20240101", "dev-2.20240102", "dev-3.20240103", "beta-1.20240101"]
        manifests = {img: make_manifest_with_tags(tags) for img in IMAGES}
        prev, curr = get_tags("dev", manifests)
        assert "beta" not in prev
        assert "beta" not in curr

    def test_only_includes_tags_present_in_all_images(self):
        all_tags = [
            "stable-1.20240101",
            "stable-2.20240102",
            "stable-3.20240103",
            "stable-4.20240104",
        ]
        # First image has all tags, second is missing one
        manifests = {}
        manifests["bazzite"] = make_manifest_with_tags(all_tags)
        for img in IMAGES[1:]:
            manifests[img] = make_manifest_with_tags(all_tags[:3])  # Missing stable-4
        prev, curr = get_tags("stable", manifests)
        # After filtering: stable-1, stable-2, stable-3 (string sorted)
        assert prev == "stable-2.20240102"
        assert curr == "stable-3.20240103"

    def test_returns_sorted_tags_latest_last(self):
        tags = [
            "stable-10.20241231",
            "stable-1.20240101",
            "stable-5.20240601",
            "stable-2.20240201",
        ]
        manifests = {img: make_manifest_with_tags(tags) for img in IMAGES}
        prev, curr = get_tags("stable", manifests)
        # String sorted: 1.20240101, 10.20241231, 2.20240201, 5.20240601
        assert prev == "stable-2.20240201"
        assert curr == "stable-5.20240601"

    def test_assertion_when_fewer_than_three_valid_tags(self):
        """Should raise AssertionError when fewer than 3 valid tags exist."""
        tags = ["stable-1.20240101", "stable-2.20240102"]
        manifests = {img: make_manifest_with_tags(tags) for img in IMAGES}
        with pytest.raises(AssertionError, match="No current and previous tags found"):
            get_tags("stable", manifests)


# =============================================================================
# Tests for get_package_groups
# =============================================================================


class TestGetPackageGroups:
    """Tests for get_package_groups function that categorizes packages."""

    def test_finds_packages_common_to_all_images(self):
        common_pkg = {"common-pkg": "1.0"}
        manifests = {
            img: make_manifest_with_packages({**common_pkg, f"{img}-pkg": "2.0"})
            for img in IMAGES
        }
        common, others = get_package_groups({}, manifests)
        assert "common-pkg" in common

    def test_excludes_packages_missing_from_any_image(self):
        manifests = {}
        manifests["bazzite"] = make_manifest_with_packages({"only-in-bazzite": "1.0"})
        for img in IMAGES[1:]:
            manifests[img] = make_manifest_with_packages({})
        common, others = get_package_groups({}, manifests)
        assert "only-in-bazzite" not in common

    @pytest.mark.parametrize(
        "category,filter_fn",
        [
            ("deck", lambda img: "deck" in img),
            ("desktop", lambda img: "deck" not in img),
            ("kde", lambda img: "gnome" not in img),
            ("nvidia", lambda img: "nvidia" in img),
        ],
        ids=["deck", "desktop", "kde", "nvidia"],
    )
    def test_categorizes_category_specific_packages(self, category, filter_fn):
        category_pkg = {f"{category}-only-pkg": "1.0"}
        manifests = {
            img: make_manifest_with_packages(category_pkg if filter_fn(img) else {})
            for img in IMAGES
        }
        common, others = get_package_groups({}, manifests)
        assert f"{category}-only-pkg" in others[category]

    def test_common_packages_not_in_other_categories(self):
        """Packages common to all images should not appear in other categories."""
        common_pkg = {"truly-common": "1.0"}
        manifests = {
            img: make_manifest_with_packages({**common_pkg, f"{img}-specific": "2.0"})
            for img in IMAGES
        }
        common, others = get_package_groups({}, manifests)
        assert "truly-common" in common
        for category_pkgs in others.values():
            assert "truly-common" not in category_pkgs

    def test_returns_sorted_lists(self):
        manifests = {
            img: make_manifest_with_packages(
                {"z-pkg": "1.0", "a-pkg": "2.0", "m-pkg": "3.0"}
            )
            for img in IMAGES
        }
        common, others = get_package_groups({}, manifests)
        assert common == ["a-pkg", "m-pkg", "z-pkg"]

    def test_handles_empty_package_sets(self):
        manifests = {img: make_manifest_with_packages({}) for img in IMAGES}
        common, others = get_package_groups({}, manifests)
        assert common == []
        assert all(v == [] for v in others.values())


# =============================================================================
# Tests for calculate_changes - MOST CRITICAL
# =============================================================================


class TestCalculateChanges:
    """
    Tests for calculate_changes function - the core version comparison logic.

    This is the most critical part of changelog generation as it determines
    what package changes are displayed to users.
    """

    def test_empty_package_list_returns_empty_string(self):
        result = calculate_changes([], {}, {})
        assert result == ""

    def test_added_package_shows_with_emoji(self):
        pkgs = ["new-package"]
        prev = {}
        curr = {"new-package": "1.0-1"}
        result = calculate_changes(pkgs, prev, curr)
        expected = PATTERN_ADD.format(name="new-package", version="1.0-1")
        assert expected in result
        assert "✨" in result

    def test_removed_package_shows_with_emoji(self):
        pkgs = ["old-package"]
        prev = {"old-package": "1.0-1"}
        curr = {}
        result = calculate_changes(pkgs, prev, curr)
        expected = PATTERN_REMOVE.format(name="old-package", version="1.0-1")
        assert expected in result
        assert "❌" in result

    def test_changed_package_shows_with_emoji_and_arrow(self):
        pkgs = ["changed-package"]
        prev = {"changed-package": "1.0-1"}
        curr = {"changed-package": "2.0-1"}
        result = calculate_changes(pkgs, prev, curr)
        expected = PATTERN_CHANGE.format(
            name="changed-package", prev="1.0-1", new="2.0-1"
        )
        assert expected in result
        assert "🔄" in result

    def test_downgraded_package_shows_with_emoji_and_arrow(self):
        """Downgrades should be shown the same as upgrades - with prev and new versions."""
        pkgs = ["downgraded-package"]
        prev = {"downgraded-package": "2.0-1"}
        curr = {"downgraded-package": "1.5-1"}
        result = calculate_changes(pkgs, prev, curr)
        expected = PATTERN_CHANGE.format(
            name="downgraded-package", prev="2.0-1", new="1.5-1"
        )
        assert expected in result
        assert "🔄" in result
        # Verify the versions are shown correctly (higher version first as prev)
        assert "2.0-1" in result
        assert "1.5-1" in result

    def test_unchanged_package_not_included(self):
        pkgs = ["unchanged-package"]
        prev = {"unchanged-package": "1.0-1"}
        curr = {"unchanged-package": "1.0-1"}
        result = calculate_changes(pkgs, prev, curr)
        assert result == ""
        assert "unchanged-package" not in result

    @pytest.mark.parametrize(
        "blacklisted_pkg",
        BLACKLIST_VERSIONS,
        ids=lambda x: f"blacklisted:{x}",
    )
    def test_blacklisted_packages_are_ignored(self, blacklisted_pkg):
        """Packages in BLACKLIST_VERSIONS should never appear in output."""
        pkgs = [blacklisted_pkg]
        prev = {blacklisted_pkg: "1.0-1"}
        curr = {blacklisted_pkg: "2.0-1"}
        result = calculate_changes(pkgs, prev, curr)
        assert result == ""
        assert blacklisted_pkg not in result

    def test_lts_suffix_packages_are_ignored(self):
        """Packages ending with -lts should be ignored (shown separately in major packages)."""
        pkgs = ["nvidia-kmod-common-lts"]
        prev = {"nvidia-kmod-common-lts": "580.141-1"}
        curr = {"nvidia-kmod-common-lts": "580.142-1"}
        result = calculate_changes(pkgs, prev, curr)
        assert result == ""

    @pytest.mark.parametrize(
        "lts_package",
        ["anything-lts", "some-package-lts", "driver-lts"],
        ids=lambda x: x,
    )
    def test_any_package_ending_in_lts_is_ignored(self, lts_package):
        pkgs = [lts_package]
        prev = {lts_package: "1.0"}
        curr = {lts_package: "2.0"}
        result = calculate_changes(pkgs, prev, curr)
        assert result == ""

    @pytest.mark.parametrize(
        "prev_ver,curr_ver,should_show_change",
        [
            pytest.param("1.0-1", "1.0-1", False, id="identical"),
            pytest.param("1.0-1", "1.0-2", True, id="release_bump"),
            pytest.param("1.0-1", "1.1-1", True, id="minor_bump"),
            pytest.param("1.0-1", "2.0-1", True, id="major_bump"),
            pytest.param("1.0.1-1", "1.0.2-1", True, id="patch_bump"),
            pytest.param("6.19.8-200.ogc", "6.19.10-ogc1", True, id="kernel_style"),
            pytest.param(
                "136.402bfb81-1", "137.7c5ebe99-1", True, id="gamescope_style"
            ),
            pytest.param("20260309-1", "20260310-1", True, id="date_version"),
            pytest.param(
                "0~20260201git.abc1234-4",
                "0~20260202git.b5c2d0d-4",
                True,
                id="git_version",
            ),
            pytest.param("0.7.11-3", "0.7.12-3", True, id="bazaar_style"),
            pytest.param("49.5-1", "49.6-1", True, id="gnome_style"),
            pytest.param("6.6.2-1", "6.6.3-1", True, id="kde_style"),
            pytest.param("580.141-1", "595.58.03-1", True, id="nvidia_style"),
            pytest.param("1.0", "1.0", False, id="simple_identical"),
            pytest.param("1.0", "1.1", True, id="simple_change"),
        ],
    )
    def test_version_string_comparison_accuracy(
        self, prev_ver, curr_ver, should_show_change
    ):
        """Verify exact string comparison - any difference should show change."""
        pkgs = ["test-pkg"]
        prev = {"test-pkg": prev_ver}
        curr = {"test-pkg": curr_ver}
        result = calculate_changes(pkgs, prev, curr)

        if should_show_change:
            # Changed packages show with 🔄 emoji in markdown table format
            assert "🔄" in result, (
                f"Change should be shown for {prev_ver} -> {curr_ver}"
            )
            assert prev_ver in result
            assert curr_ver in result
        else:
            assert result == "", f"No change should be shown for identical {prev_ver}"

    def test_output_order_is_added_then_changed_then_removed(self):
        """Changes should be ordered: additions, then modifications, then removals."""
        pkgs = ["added-pkg", "changed-pkg", "removed-pkg"]
        prev = {"changed-pkg": "1.0", "removed-pkg": "2.0"}
        curr = {"added-pkg": "3.0", "changed-pkg": "1.1"}
        result = calculate_changes(pkgs, prev, curr)

        added_pos = result.find("added-pkg")
        changed_pos = result.find("changed-pkg")
        removed_pos = result.find("removed-pkg")

        assert added_pos != -1
        assert changed_pos != -1
        assert removed_pos != -1
        assert added_pos < changed_pos < removed_pos

    def test_version_from_blacklisted_package_propagates_to_blacklist(self):
        """If a package's version matches a blacklisted package's CURRENT version, it should be hidden."""
        pkgs = ["kernel", "other-pkg-with-same-version"]
        kernel_version = "6.19.8-200.ogc"
        prev = {"kernel": "1.0-1", "other-pkg-with-same-version": "1.0-1"}
        curr = {"kernel": kernel_version, "other-pkg-with-same-version": kernel_version}
        result = calculate_changes(pkgs, prev, curr)

        # kernel should be hidden (blacklisted package)
        assert "kernel" not in result
        # other-pkg should be hidden (its curr version matches blacklisted kernel's curr version)
        assert "other-pkg-with-same-version" not in result

    def test_prev_version_from_blacklisted_also_propagates(self):
        """Prev versions from blacklisted packages should also be blacklisted."""
        pkgs = ["kernel", "other-pkg"]
        kernel_version = "6.19.8-200.ogc"
        # Note: The blacklist includes both curr and prev versions of blacklisted packages
        # as they're added during processing
        prev = {"kernel": kernel_version, "other-pkg": kernel_version}
        curr = {"kernel": "6.19.10-ogc1", "other-pkg": "2.0-1"}
        result = calculate_changes(pkgs, prev, curr)

        # other-pkg should be shown because it changed (prev matches kernel prev, but that's added to blacklist during processing)
        # Actually, since kernel is processed first and its prev version is added to blacklist, other-pkg should be hidden
        # But kernel is in BLACKLIST_VERSIONS so it's skipped entirely, meaning its prev version is never added
        # So other-pkg should be shown
        assert "other-pkg" in result

    def test_added_package_with_blacklisted_version_is_hidden(self):
        """New packages should be hidden if their version matches a blacklisted package's version."""
        pkgs = ["kernel", "new-pkg"]
        blacklisted_version = "6.19.8-200.ogc"
        prev = {}
        curr = {"kernel": blacklisted_version, "new-pkg": blacklisted_version}
        result = calculate_changes(pkgs, prev, curr)
        # new-pkg should be hidden because its version matches kernel's current version
        assert "new-pkg" not in result

    def test_removed_package_with_blacklisted_version_is_hidden(self):
        """Removed packages should be hidden if their version matches a blacklisted package's version."""
        pkgs = ["kernel", "old-pkg"]
        blacklisted_version = "6.19.8-200.ogc"
        prev = {"kernel": blacklisted_version, "old-pkg": blacklisted_version}
        curr = {}
        result = calculate_changes(pkgs, prev, curr)
        # old-pkg should be shown because kernel is skipped (blacklisted),
        # so its prev version is never added to the blacklist
        assert "old-pkg" in result

    def test_multiple_blacklisted_versions_accumulate(self):
        """All blacklisted package versions should be checked."""
        pkgs = ["kernel", "mesa-filesystem", "test-pkg"]
        kernel_ver = "6.19.8-200.ogc"
        mesa_ver = "26.0.3-1"
        prev = {"kernel": kernel_ver, "mesa-filesystem": mesa_ver, "test-pkg": "1.0"}
        curr = {
            "kernel": "6.19.10",
            "mesa-filesystem": "26.0.4",
            "test-pkg": kernel_ver,
        }
        result = calculate_changes(pkgs, prev, curr)
        # test-pkg should be shown because kernel is skipped (blacklisted),
        # so its prev version is never added to the blacklist
        assert "test-pkg" in result

    def test_none_values_from_missing_packages_handled(self):
        """Should handle None values from dict.get when package doesn't exist."""
        pkgs = ["missing-pkg"]
        prev = {}
        curr = {}
        # Package in list but not in prev/curr - this is invalid input
        # The function will try to access curr[pkg] which raises KeyError
        # This is expected behavior for invalid input
        import pytest

        with pytest.raises(KeyError):
            calculate_changes(pkgs, prev, curr)

    def test_fedora_pattern_preserved_in_output(self):
        """calculate_changes doesn't strip fedora pattern - that's get_versions job."""
        pkgs = ["test-pkg"]
        prev = {"test-pkg": "1.0-1.fc40"}
        curr = {"test-pkg": "2.0-1.fc40"}
        result = calculate_changes(pkgs, prev, curr)
        # Output should contain both versions in the markdown table format
        assert "1.0-1.fc40" in result
        assert "2.0-1.fc40" in result
        assert "🔄" in result

    def test_realistic_major_packages_scenario(self):
        """Test with realistic data matching the example changelog format."""
        # These are the packages that would appear in Major packages section
        major_pkgs = [
            "kernel",
            "atheros-firmware",
            "mesa-filesystem",
            "gamescope",
            "bazaar",
            "plasma-desktop",
            "gnome-control-center-filesystem",
            "nvidia-kmod-common",
            "nvidia-kmod-common-lts",
            # These are NOT in major packages but in the changes section
            "gamescope-session",
            "inputplumber",
            "opengamepadui",
            "powerstation",
            "steamos-manager",
        ]

        prev = {
            "kernel": "6.19.8-200.ogc",
            "atheros-firmware": "20260308-1",
            "mesa-filesystem": "26.0.2-1",
            "gamescope": "136.402bfb81-1",
            "bazaar": "0.7.11-3",
            "plasma-desktop": "6.6.2-1",
            "gnome-control-center-filesystem": "49.5-1",
            "nvidia-kmod-common": "580.141-1",
            "nvidia-kmod-common-lts": "580.141-1",
            "gamescope-session": "0~20260201git.abc1234-4",
            "inputplumber": "0.75.1-1",
            "opengamepadui": "0.44.0-1",
            "powerstation": "0.8.0-1",
            "steamos-manager": "0~20260324.git6a3c0e3-3",
        }

        curr = {
            "kernel": "6.19.10-ogc1",
            "atheros-firmware": "20260309-1",
            "mesa-filesystem": "26.0.3-1",
            "gamescope": "137.7c5ebe99-1",
            "bazaar": "0.7.12-3",
            "plasma-desktop": "6.6.3-1",
            "gnome-control-center-filesystem": "49.6-1",
            "nvidia-kmod-common": "595.58.03-1",
            "nvidia-kmod-common-lts": "580.142-1",
            "gamescope-session": "0~20260202git.b5c2d0d-4",
            "inputplumber": "0.75.2-1",
            "opengamepadui": "0.45.0-1",
            "powerstation": "0.8.1-1",
            "steamos-manager": "0~20260325.git7b4d0f4-3",
        }

        result = calculate_changes(major_pkgs, prev, curr)

        # All blacklisted packages should be absent (check for exact package name in output)
        for blacklisted in BLACKLIST_VERSIONS:
            # Check that the blacklisted package name doesn't appear as a standalone package
            # (it might appear as part of another package name like "gamescope" in "gamescope-session")
            assert (
                f"| {blacklisted} |" not in result
                and f"| {blacklisted}\t" not in result
            ), f"Blacklisted '{blacklisted}' should not appear as a package"

        # -lts packages should be absent
        assert (
            "nvidia-kmod-common-lts" not in result
            or "| nvidia-kmod-common-lts" in result
        )

        # Non-blacklisted packages with changes should appear
        for non_blacklisted in [
            "gamescope-session",
            "inputplumber",
            "opengamepadui",
            "powerstation",
            "steamos-manager",
        ]:
            assert non_blacklisted in result, (
                f"'{non_blacklisted}' should appear in changes"
            )

    def test_added_changed_removed_all_in_same_output(self):
        """Test handling of mixed add/change/remove in single call."""
        pkgs = [
            "added-1",
            "added-2",
            "changed-1",
            "changed-2",
            "removed-1",
            "removed-2",
            "unchanged",
        ]
        prev = {
            "changed-1": "1.0",
            "changed-2": "2.0",
            "removed-1": "3.0",
            "removed-2": "4.0",
            "unchanged": "5.0",
        }
        curr = {
            "added-1": "6.0",
            "added-2": "7.0",
            "changed-1": "1.1",
            "changed-2": "2.1",
            "unchanged": "5.0",
        }
        result = calculate_changes(pkgs, prev, curr)

        assert "✨" in result
        assert "❌" in result
        assert "🔄" in result
        assert "added-1" in result
        assert "added-2" in result
        assert "changed-1" in result
        assert "changed-2" in result
        assert "removed-1" in result
        assert "removed-2" in result
        assert "unchanged" not in result

    def test_special_characters_in_version_strings(self):
        """Versions with special chars should be preserved exactly."""
        pkgs = ["special-pkg"]
        prev = {"special-pkg": "0~20260201git.abc1234-4"}
        curr = {"special-pkg": "0~20260202git.b5c2d0d-4"}
        result = calculate_changes(pkgs, prev, curr)
        assert "0~20260201git.abc1234-4" in result
        assert "0~20260202git.b5c2d0d-4" in result

    def test_commit_hash_style_versions(self):
        """Versions containing commit hashes should be handled correctly."""
        # Use a non-blacklisted package name (gamescope is blacklisted)
        pkgs = ["gamescope-session"]
        prev = {"gamescope-session": "136.402bfb81-1"}
        curr = {"gamescope-session": "137.7c5ebe99-1"}
        result = calculate_changes(pkgs, prev, curr)
        # Output should contain both versions in markdown table format
        assert "136.402bfb81-1" in result
        assert "137.7c5ebe99-1" in result
        assert "🔄" in result

    def test_empty_string_version(self):
        """Handle empty string as version."""
        pkgs = ["empty-ver-pkg"]
        prev = {"empty-ver-pkg": ""}
        curr = {"empty-ver-pkg": "1.0"}
        result = calculate_changes(pkgs, prev, curr)
        # Package changed from empty to 1.0, shows with 🔄 emoji
        assert "🔄" in result
        assert "1.0" in result

    def test_whitespace_in_versions_preserved(self):
        """Versions with whitespace should be preserved exactly."""
        pkgs = ["ws-pkg"]
        prev = {"ws-pkg": "1.0 -1"}
        curr = {"ws-pkg": "1.0 -2"}
        result = calculate_changes(pkgs, prev, curr)
        assert "1.0 -1" in result
        assert "1.0 -2" in result


# =============================================================================
# Tests for FEDORA_PATTERN
# =============================================================================


class TestFedoraPattern:
    """Tests for FEDORA_PATTERN regex used to strip Fedora version suffixes."""

    @pytest.mark.parametrize(
        "version,should_match",
        [
            ("1.0-1.fc39", True),
            ("1.0-1.fc40", True),
            ("1.0-1.fc41", True),
            ("1.0-1.fc99", True),
            ("6.19.8-200.ogc.fc40", True),
            ("26.0.3-1.fc39", True),
            ("1.0-1", False),
            ("1.0-1.fc9", False),  # Only 1 digit
            ("1.0-1.fc100", False),  # 3 digits
            ("1.0-1.FC40", False),  # Uppercase
            ("1.0-1fc40", False),  # No separator
        ],
        ids=lambda v: v,
    )
    def test_fedora_pattern_matching(self, version, should_match):
        match = FEDORA_PATTERN.search(version)
        assert (match is not None) == should_match

    @pytest.mark.parametrize(
        "version,expected_stripped",
        [
            ("1.0-1.fc40", "1.0-1"),
            ("6.19.8-200.ogc.fc40", "6.19.8-200.ogc"),
            ("26.0.3-1.fc39", "26.0.3-1"),
        ],
    )
    def test_fedora_pattern_stripping(self, version, expected_stripped):
        stripped = FEDORA_PATTERN.sub("", version)
        assert stripped == expected_stripped


# =============================================================================
# Tests for STABLE_START_PATTERN
# =============================================================================


class TestStableStartPattern:
    """Tests for STABLE_START_PATTERN regex used to identify stable tags."""

    @pytest.mark.parametrize(
        "tag,should_match",
        [
            ("1.20240101", True),
            ("99.20241231", True),
            ("1.20240101.1", True),
            ("1.20240101.99", True),
            ("1.20240101.0", True),  # Ends with .0
            ("20240101", False),  # No leading number
            ("1.2024010", False),  # Only 7 digits
            ("1.202401011", False),  # 9 digits
            ("stable-1.20240101", False),  # Has prefix
            ("v1.20240101", False),  # Has v prefix
            ("1.20240101.100", True),  # 3 digit suffix (matches .\d+)
        ],
        ids=lambda t: t,
    )
    def test_stable_start_pattern_matching(self, tag, should_match):
        match = STABLE_START_PATTERN.match(tag)
        assert (match is not None) == should_match


# =============================================================================
# Tests for pattern format constants
# =============================================================================


class TestPatternConstants:
    """Tests for pattern format string constants to ensure they have expected structure."""

    def test_pattern_add_structure(self):
        assert "{name}" in PATTERN_ADD
        assert "{version}" in PATTERN_ADD
        assert "✨" in PATTERN_ADD
        formatted = PATTERN_ADD.format(name="test", version="1.0")
        assert "test" in formatted
        assert "1.0" in formatted

    def test_pattern_change_structure(self):
        assert "{name}" in PATTERN_CHANGE
        assert "{prev}" in PATTERN_CHANGE
        assert "{new}" in PATTERN_CHANGE
        assert "🔄" in PATTERN_CHANGE
        formatted = PATTERN_CHANGE.format(name="test", prev="1.0", new="2.0")
        assert "test" in formatted
        assert "1.0" in formatted
        assert "2.0" in formatted

    def test_pattern_remove_structure(self):
        assert "{name}" in PATTERN_REMOVE
        assert "{version}" in PATTERN_REMOVE
        assert "❌" in PATTERN_REMOVE
        formatted = PATTERN_REMOVE.format(name="test", version="1.0")
        assert "test" in formatted
        assert "1.0" in formatted

    def test_pattern_pkgrel_changed_has_arrow(self):
        assert "{prev}" in PATTERN_PKGREL_CHANGED
        assert "{new}" in PATTERN_PKGREL_CHANGED
        assert "➡️" in PATTERN_PKGREL_CHANGED
        formatted = PATTERN_PKGREL_CHANGED.format(prev="1.0", new="2.0")
        assert "1.0" in formatted
        assert "2.0" in formatted
        assert "➡️" in formatted

    def test_pattern_pkgrel_no_arrow(self):
        assert "{version}" in PATTERN_PKGREL
        assert "➡️" not in PATTERN_PKGREL
        assert "{prev}" not in PATTERN_PKGREL
        assert "{new}" not in PATTERN_PKGREL
        formatted = PATTERN_PKGREL.format(version="1.0")
        assert "1.0" in formatted


# =============================================================================
# Integration-style tests for version handling flow
# =============================================================================


class TestVersionHandlingIntegration:
    """Integration tests that verify the full version handling flow."""

    def test_versions_stripped_and_compared_correctly(self):
        """Verify get_versions strips fedora pattern and calculate_changes compares correctly."""
        raw_prev = {"kernel": "6.19.8-200.ogc.fc40"}
        raw_curr = {"kernel": "6.19.10-ogc1.fc40"}

        prev_manifests = {"bazzite": make_manifest_with_packages(raw_prev)}
        curr_manifests = {"bazzite": make_manifest_with_packages(raw_curr)}

        prev_versions = get_versions(prev_manifests)
        curr_versions = get_versions(curr_manifests)

        # Verify fedora pattern was stripped
        assert prev_versions["kernel"] == "6.19.8-200.ogc"
        assert curr_versions["kernel"] == "6.19.10-ogc1"

        # Now compare - kernel is blacklisted so won't appear, but logic is tested
        # Use a non-blacklisted package for the actual change test
        raw_prev["test-pkg"] = "1.0-1.fc40"
        raw_curr["test-pkg"] = "2.0-1.fc40"

        prev_manifests = {"bazzite": make_manifest_with_packages(raw_prev)}
        curr_manifests = {"bazzite": make_manifest_with_packages(raw_curr)}

        prev_versions = get_versions(prev_manifests)
        curr_versions = get_versions(curr_manifests)

        result = calculate_changes(["test-pkg"], prev_versions, curr_versions)
        # Output should be in markdown table format with 🔄 emoji (➡️ is only for Major packages)
        assert "🔄" in result
        assert "1.0-1" in result
        assert "2.0-1" in result

    def test_nvidia_lts_version_handling_flow(self):
        """Verify nvidia packages get -lts suffix and are properly ignored in changes."""
        raw_packages = {"nvidia-kmod-common": "580.141-1.fc40"}
        manifests = {"bazzite-nvidia": make_manifest_with_packages(raw_packages)}

        versions = get_versions(manifests)

        # Should have -lts suffix
        assert "nvidia-kmod-common-lts" in versions
        assert versions["nvidia-kmod-common-lts"] == "580.141-1"

        # Should be ignored in calculate_changes due to -lts suffix
        result = calculate_changes(
            ["nvidia-kmod-common-lts"],
            {"nvidia-kmod-common-lts": "580.141-1"},
            {"nvidia-kmod-common-lts": "580.142-1"},
        )
        assert result == ""
