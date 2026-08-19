# just-helpers-tooling.bash — dev tooling wrappers for just-helpers.
# Sourced by just-helpers.bash (no shebang/set — see umbrella).

# ── Justfile target wrappers ────────────────────────────────────────────────
# Each function mirrors a Justfile target, making it callable directly for
# debugging:  bash -c 'source scripts/just-helpers.bash && check_just_files'

# Check all .just files and the Justfile for syntax errors
check_just_files() {
  local justfile="${1:-Justfile}"
  local file
  find . -type f -name "*.just" | while read -r file; do
    echo "Checking syntax: $file"
    just --unstable --fmt --check -f "$file"
  done
  echo "Checking syntax: $justfile"
  just --unstable --fmt --check -f "$justfile"
}

# Fix formatting in all .just files and the Justfile
fix_just_files() {
  local justfile="${1:-Justfile}"
  local file
  find . -type f -name "*.just" | while read -r file; do
    echo "Fixing syntax: $file"
    just --unstable --fmt -f "$file"
  done
  echo "Fixing syntax: $justfile"
  just --unstable --fmt -f "$justfile" || { exit 1; }
}

# Run shellcheck on *.sh and actionlint on workflow YAML files
lint_scripts() {
  /usr/bin/find . \
    \( -iname "*.sh" -o -iname "*.bash" \) -type f \
    -exec shellcheck "{}" +
  /usr/bin/find ./.github/workflows/ -iname "*.yml" -type f -exec actionlint "{}" +
}

# Run shfmt on *.sh and prettier on workflow YAML files
format_scripts() {
  /usr/bin/find . \
    \( -iname "*.sh" -o -iname "*.bash" \) -type f \
    -exec shfmt -w -i 2 "{}" +
  /usr/bin/find . -iname "*.yml" -type f -exec prettier -w "{}" +
  /usr/bin/find . -iname "*.py" -type f -exec ruff format "{}" +
}

# List available (non-disabled) variants from variants.json
list_available_variants() {
  local variants_config="${1:-.github/variants.json}"
  echo "Available variants:"
  jq -r '.variants[] | select((.disabled // false) == false) | "  \(.name)  →  \(.base_image)  [\(.build_script // "build.sh")]"' \
    "$variants_config"
}
