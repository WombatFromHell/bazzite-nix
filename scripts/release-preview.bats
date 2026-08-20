#!/usr/bin/env bats
# release-preview.bats — Smoke test for scripts/release-preview.py using a
# mocked skopeo, so it runs without a local image or registry access.
#
# Run with: bats scripts/release-preview.bats

setup() {
    FAKE_BIN="$(mktemp -d)"

    # sudo: exec through
    cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$FAKE_BIN/sudo"

    # skopeo: return a manifest carrying the ostree.rechunk.info label.
    # docker:// refs get a "previous" manifest so diffs can be tested.
    cat >"$FAKE_BIN/skopeo" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"docker://"* ]]; then
cat <<'JSON'
{"Name": "ghcr.io/example/bazzite-nix:latest",
 "Labels": {"ostree.rechunk.info": "{\"packages\":{\"kernel\":\"6.19.7-400.fc44\",\"mesa-filesystem\":\"26.0.3-2.fc44\",\"plasma-desktop\":\"6.4.1-1.fc44\",\"terra-gamescope\":\"1.2.3-1.fc44\",\"python3-rpm\":\"1.0.0-1.fc44\"}}",
            "org.opencontainers.image.version": "testing-44.20260818.1"},
 "Digest": "sha256:prev"}
JSON
else
cat <<'JSON'
{"Name": "localhost/chunked-img",
 "Labels": {"ostree.rechunk.info": "{\"packages\":{\"kernel\":\"6.19.8-400.fc44\",\"mesa-filesystem\":\"26.0.3-2.fc44\",\"plasma-desktop\":\"6.4.1-1.fc44\",\"terra-gamescope\":\"1.2.3-1.fc44\",\"python3-rpm\":\"1.0.1-1.fc44\"}}",
            "org.opencontainers.image.version": "44.20260820.1"},
 "Digest": "sha256:abc"}
JSON
fi
EOF
    chmod +x "$FAKE_BIN/skopeo"

    # curl: record the compare URL, never hit the network.
    cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$BATS_RUN_TMPDIR/curl.args"
echo '{"commits":[]}'
EOF
    chmod +x "$FAKE_BIN/curl"

    export PATH="$FAKE_BIN:$PATH"
}

teardown() {
    rm -rf "$FAKE_BIN"
}

@test "release-preview renders package versions from the label" {
    run python3 "$BATS_TEST_DIRNAME/release-preview.py" localhost/chunked-img
    echo "$output"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'localhost/chunked-img'
    # Kernel rendered (fc suffix stripped like the release does)
    echo "$output" | grep -q '\*\*Kernel\*\* | 6.19.8-400'
    echo "$output" | grep -q '\*\*Mesa\*\* | 26.0.3-2'
    echo "$output" | grep -q '\*\*KDE\*\* | 6.4.1-1'
}

@test "release-preview diffs against a previous registry ref" {
    run python3 "$BATS_TEST_DIRNAME/release-preview.py" localhost/chunked-img \
        --prev ghcr.io/example/bazzite-nix:latest
    echo "$output"
    [ "$status" -eq 0 ]
    # Kernel changed 6.19.7 → 6.19.8
    echo "$output" | grep -q '\*\*Kernel\*\* | 6.19.7-400 ➡️ 6.19.8-400'
    # Unchanged package shows no arrow
    echo "$output" | grep -q '\*\*Mesa\*\* | 26.0.3-2 |'
    # Changes section lists the kernel change
    echo "$output" | grep -q '| 🔄 | python3-rpm | 1.0.0-1 | 1.0.1-1 |'
}

@test "release-preview compares upstream testing tags" {
    run python3 "$BATS_TEST_DIRNAME/release-preview.py" localhost/chunked-img:testing \
        --prev ghcr.io/example/bazzite-nix:latest
    echo "$output"
    [ "$status" -eq 0 ]
    # Local label is branch-stripped (44.20260820.1) → prefixed to testing-...
    grep -q 'testing-44.20260818.1...testing-44.20260820.1' "$BATS_RUN_TMPDIR/curl.args"
}

@test "upstream_tag maps release tags to upstream git tags" {
    run python3 -c "
import sys
sys.path.insert(0, '$BATS_TEST_DIRNAME')
import changelog
print(changelog.upstream_tag('stable', 'stable-44.20260721'))
print(changelog.upstream_tag('stable', '44.20260802'))
print(changelog.upstream_tag('testing', '44.20260820.1'))
print(changelog.upstream_tag('testing', 'testing-44.20260818.1'))"
    echo "$output"
    [ "$status" -eq 0 ]
    # stable: bare, never prefixed
    echo "$output" | grep -q '^44.20260721$'
    echo "$output" | grep -q '^44.20260802$'
    [[ "$output" != *"stable-44"* ]]
    # testing: prefixed, prefixed-form passes through
    echo "$output" | grep -q '^testing-44.20260820.1$'
    echo "$output" | grep -q '^testing-44.20260818.1$'
}
