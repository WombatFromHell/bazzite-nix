#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Neovim AppImage Manager
# =============================================================================
# Downloads, installs, and manages Neovim AppImage versions.

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
readonly INSTALL_DIR="$HOME/AppImages"
readonly SYMLINK_PATH="/usr/local/bin/nvim"
readonly NIGHTLY_URL="https://github.com/neovim/neovim/releases/download/nightly/nvim-linux-x86_64.appimage"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
die() {
  log_error "$*"
  exit 1
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --install <version>    Install Neovim version (e.g., stable, nightly, v0.11.6)
  --uninstall <version>  Remove a specific Neovim version
  --help                 Show this help message

Examples:
  $(basename "$0") --install stable
  $(basename "$0") --install nightly
  $(basename "$0") --uninstall v0.10.0
EOF
}

# -----------------------------------------------------------------------------
# Core Functions
# -----------------------------------------------------------------------------

get_file_path() {
  local version="$1"
  echo "${INSTALL_DIR}/nvim-${version}.appimage"
}

get_meta_path() {
  local version="$1"
  echo "${INSTALL_DIR}/nvim-${version}.meta"
}

get_download_url() {
  local version="$1"
  if [[ "$version" == "nightly" ]]; then
    echo "$NIGHTLY_URL"
  else
    echo "https://github.com/neovim/neovim/releases/download/${version}/nvim-linux-x86_64.appimage"
  fi
}

ensure_install_dir() {
  if [[ ! -d "$INSTALL_DIR" ]]; then
    mkdir -p "$INSTALL_DIR"
  fi
}

# Fetches only the response headers for $url and writes them to stdout.
fetch_headers() {
  local url="$1"
  curl --silent --fail --location --head "$url"
}

# Extracts a named header value (case-insensitive) from a block of headers on stdin.
extract_header() {
  local name="$1"
  grep -i "^${name}:" | tail -1 | sed 's/^[^:]*: *//' | tr -d '\r'
}

# Returns 0 if an update was performed/downloaded.
# Returns 1 if no update was needed (already up to date).
# Exits script on error.
download_version() {
  local version="$1"
  local file_path="$2"
  local url="$3"

  if [[ "$version" == "nightly" ]]; then
    local meta_path
    meta_path=$(get_meta_path "$version")

    if [[ -f "$file_path" && -f "$meta_path" ]]; then
      log_info "Checking for nightly update..."

      # Fetch remote headers to compare against stored metadata.
      # GitHub redirects strip If-Modified-Since, so --time-cond never yields
      # a 304; we must compare ourselves.
      local remote_headers
      remote_headers=$(fetch_headers "$url") || die "Failed to fetch headers for nightly build."

      local remote_etag remote_last_modified
      remote_etag=$(echo "$remote_headers" | extract_header "etag")
      remote_last_modified=$(echo "$remote_headers" | extract_header "last-modified")

      local stored_etag stored_last_modified
      stored_etag=$(grep '^etag=' "$meta_path" | cut -d= -f2- || true)
      stored_last_modified=$(grep '^last-modified=' "$meta_path" | cut -d= -f2- || true)

      # Prefer ETag comparison; fall back to Last-Modified.
      if [[ -n "$remote_etag" && -n "$stored_etag" ]]; then
        if [[ "$remote_etag" == "$stored_etag" ]]; then
          log_info "Nightly is already up to date (ETag match)."
          return 1 # No update needed
        fi
      elif [[ -n "$remote_last_modified" && -n "$stored_last_modified" ]]; then
        if [[ "$remote_last_modified" == "$stored_last_modified" ]]; then
          log_info "Nightly is already up to date (Last-Modified match)."
          return 1 # No update needed
        fi
      fi
    fi

    # A running AppImage is held open by the kernel; writing to it yields
    # "Text file busy". Detect this before curl tries and fails opaquely.
    if [[ -f "$file_path" ]] && fuser "$file_path" &>/dev/null; then
      log_error "Cannot update: Neovim is currently running (file is busy)."
      log_error "Close all Neovim instances and re-run this command."
      return 1
    fi

    log_info "Downloading nightly build..."
    local response_headers_file
    response_headers_file=$(mktemp)
    if curl --fail --location --remote-time \
      --dump-header "$response_headers_file" \
      "$url" -o "$file_path"; then
      chmod 0755 "$file_path"

      # Persist metadata for future idempotency checks.
      local new_etag new_last_modified
      new_etag=$(extract_header "etag" <"$response_headers_file")
      new_last_modified=$(extract_header "last-modified" <"$response_headers_file")
      {
        echo "etag=${new_etag}"
        echo "last-modified=${new_last_modified}"
      } >"$(get_meta_path "$version")"
      rm -f "$response_headers_file"
      return 0 # Download performed
    else
      rm -f "$file_path" "$response_headers_file"
      die "Failed to download nightly build."
    fi

  else
    # Tagged version: a specific tag is immutable; presence == up to date.
    if [[ -f "$file_path" ]]; then
      log_info "Version '$version' is already installed."
      return 1 # No update needed
    fi

    log_info "Downloading Neovim version: $version..."
    if curl -fLR "$url" -o "$file_path"; then
      chmod 0755 "$file_path"
      return 0 # Download performed
    else
      rm -f "$file_path"
      die "Failed to download version '$version'. Please verify the tag exists."
    fi
  fi
}

update_symlink() {
  local file_path="$1"

  if [[ ! -d "$(dirname "$SYMLINK_PATH")" ]]; then
    sudo mkdir -p "$(dirname "$SYMLINK_PATH")"
  fi

  if [[ -L "$SYMLINK_PATH" ]]; then
    local current_target
    current_target="$(readlink "$SYMLINK_PATH")"
    if [[ "$current_target" == "$file_path" ]]; then
      return 1 # Symlink already correct
    fi
  fi

  log_info "Updating symlink to '$file_path'..."

  if [[ -e "$SYMLINK_PATH" ]] || [[ -L "$SYMLINK_PATH" ]]; then
    sudo rm -f "$SYMLINK_PATH"
  fi

  if ! sudo ln -s "$file_path" "$SYMLINK_PATH"; then
    die "Failed to create symlink at $SYMLINK_PATH."
  fi

  return 0 # Symlink updated
}

remove_version() {
  local version="$1"
  local file_path
  file_path=$(get_file_path "$version")

  if [[ ! -f "$file_path" ]]; then
    log_info "Version '$version' is not installed. Nothing to remove."
    return 0
  fi

  log_info "Removing version '$version'..."
  rm -f "$file_path" "$(get_meta_path "$version")"

  if [[ -L "$SYMLINK_PATH" ]]; then
    local current_target
    current_target="$(readlink "$SYMLINK_PATH")"
    if [[ "$current_target" == "$file_path" ]]; then
      log_info "Removing dangling symlink..."
      sudo rm -f "$SYMLINK_PATH"
    fi
  fi

  log_info "Uninstall complete."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  local action=""
  local version=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --install)
      action="install"
      if [[ -z "${2:-}" ]]; then die "Missing argument for --install"; fi
      version="$2"
      shift 2
      ;;
    --uninstall)
      action="uninstall"
      if [[ -z "${2:-}" ]]; then die "Missing argument for --uninstall"; fi
      version="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1\n$(usage)"
      ;;
    esac
  done

  if [[ -z "$action" ]]; then
    usage
    exit 1
  fi

  ensure_install_dir

  local file_path
  file_path=$(get_file_path "$version")

  if [[ "$action" == "install" ]]; then
    local url
    url=$(get_download_url "$version")

    # download_version returns 0 if updated, 1 if already up-to-date
    if download_version "$version" "$file_path" "$url"; then
      log_info "Update downloaded successfully."
    else
      log_info "No new update found."
    fi

    # Ensure symlink is set
    update_symlink "$file_path"

  elif [[ "$action" == "uninstall" ]]; then
    remove_version "$version"
  fi
}

main "$@"
