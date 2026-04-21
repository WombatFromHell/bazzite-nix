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
readonly LOCAL_BIN="$HOME/.local/bin"
readonly SYMLINK_PATH="$LOCAL_BIN/nvim"
readonly BASE_URL="https://github.com/neovim/neovim/releases/download"
readonly LATEST_RELEASE_URL="https://github.com/neovim/neovim/releases/latest"
readonly NIGHTLY_URL="${BASE_URL}/nightly/nvim-linux-x86_64.appimage"

# -----------------------------------------------------------------------------
# Command Execution Strategies (for testability)
# -----------------------------------------------------------------------------
CURL_CMD="${CURL_CMD:-curl}"
MKDIR_CMD="${MKDIR_CMD:-mkdir}"
RM_CMD="${RM_CMD:-rm}"
CHMOD_CMD="${CHMOD_CMD:-chmod}"
LN_CMD="${LN_CMD:-ln}"
FUSER_CMD="${FUSER_CMD:-fuser}"
MKTEMP_CMD="${MKTEMP_CMD:-mktemp}"
SUDO_CMD="${SUDO_CMD:-sudo}"

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
  -i, --install [version]   Install Neovim version (e.g., stable, nightly). Default: stable
  -u, --uninstall [version] Remove a specific Neovim version. Default: stable
  -g, --global           Install symlink to /usr/local/bin (requires sudo)
  -f, --force           Remove appimage files when uninstalling (use with -u)
  -h, --help            Show this help message

Examples:
  $(basename "$0") -i
  $(basename "$0") --install stable
  $(basite "$0") --install nightly
  $(basename "$0") -g --install nightly
  $(basename "$0") -u
  $(basename "$0") --uninstall stable
EOF
}

get_version() {
  local action="$1"
  local version="${2:-}"

  if [[ -z "$version" || "$version" == -* ]]; then
    echo "stable"
    return 1
  fi

  echo "$version"
  return 0
}

# -----------------------------------------------------------------------------
# Core Functions
# -----------------------------------------------------------------------------

get_path() {
  local install_dir="$1"
  local version="$2"
  local suffix="${3:-appimage}"
  echo "${install_dir}/nvim-${version}.${suffix}"
}

get_stable_version() {
  # Follow redirect from /releases/latest to get the current stable version tag
  local redirect_url
  redirect_url=$($CURL_CMD --silent --location --connect-timeout 10 --max-time 10 --write-out '%{url_effective}' --output /dev/null "$LATEST_RELEASE_URL")
  # Extract version tag from URL (e.g., v0.12.0 from .../tag/v0.12.0)
  basename "$redirect_url"
}

get_download_url() {
  local version="$1"
  if [[ "$version" == "nightly" ]]; then
    echo "$NIGHTLY_URL"
  else
    echo "${BASE_URL}/${version}/nvim-linux-x86_64.appimage"
  fi
}

ensure_install_dir() {
  local install_dir="$1"
  $MKDIR_CMD -p "$install_dir"
}

# Fetches only the response headers for $url and writes them to stdout.
fetch_headers() {
  local url="$1"
  $CURL_CMD --silent --fail --location --connect-timeout 10 --max-time 10 --head "$url"
}

# Extracts a named header value (case-insensitive) from a file or stdin.
extract_header() {
  local name="$1"
  local src="${2:-/dev/stdin}"

  if [[ -f "$src" ]]; then
    grep -i "^${name}:" "$src"
  else
    grep -i "^${name}:"
  fi | tail -1 | sed 's/^[^:]*: *//' | tr -d '\r'
}

# Returns 0 if a file is currently in use by another process.
is_file_busy() {
  $FUSER_CMD "$1" &>/dev/null
}

# Checks nightly metadata against remote headers.
# Returns 0 if an update IS needed, 1 if already up to date.
check_nightly_update() {
  local url="$1"
  local meta_path="$2"

  local remote_headers
  remote_headers=$(fetch_headers "$url") || die "Failed to fetch headers for nightly build."

  local remote_etag remote_last_modified
  remote_etag=$(echo "$remote_headers" | extract_header "etag")
  remote_last_modified=$(echo "$remote_headers" | extract_header "last-modified")

  local stored_etag stored_last_modified
  stored_etag=$(grep '^etag=' "$meta_path" | cut -d= -f2- || true)
  stored_last_modified=$(grep '^last-modified=' "$meta_path" | cut -d= -f2- || true)

  if [[ -n "$remote_etag" && -n "$stored_etag" ]]; then
    [[ "$remote_etag" == "$stored_etag" ]] && return 1
  elif [[ -n "$remote_last_modified" && -n "$stored_last_modified" ]]; then
    [[ "$remote_last_modified" == "$stored_last_modified" ]] && return 1
  fi

  return 0
}

# Downloads a tagged version and sets permissions.
# Downloads an AppImage and optionally updates metadata if meta_path is provided.
download_appimage() {
  local url="$1"
  local dest="$2"
  local meta_path="${3:-}"

  local curl_args=("-fLR" "--connect-timeout" "10" "--max-time" "300")
  local resp_headers_file=""

  if [[ -n "$meta_path" ]]; then
    resp_headers_file=$($MKTEMP_CMD)
    curl_args+=("--remote-time" "--dump-header" "$resp_headers_file")
  fi

  if $CURL_CMD "${curl_args[@]}" "$url" -o "$dest"; then
    $CHMOD_CMD 0755 "$dest"
    if [[ -n "$meta_path" && -n "$resp_headers_file" ]]; then
      local new_etag new_last_modified
      new_etag=$(extract_header "etag" <"$resp_headers_file")
      new_last_modified=$(extract_header "last-modified" <"$resp_headers_file")
      {
        echo "etag=${new_etag}"
        echo "last-modified=${new_last_modified}"
      } >"$meta_path"
      $RM_CMD -f "$resp_headers_file"
    fi
    return 0
  else
    [[ -n "$resp_headers_file" ]] && $RM_CMD -f "$resp_headers_file"
    [[ -f "$dest" ]] && $RM_CMD -f "$dest"
    return 1
  fi
}

# Returns 0 if an update was performed/downloaded.
# Returns 1 if no update was needed (already up to date).
# Exits script on error.
download_version() {
  local install_dir="$1"
  local version="$2"
  local file_path="$3"
  local url="$4"

  if [[ "$version" == "nightly" ]]; then
    local meta_path
    meta_path=$(get_path "$install_dir" "$version" "meta")

    [[ -f "$file_path" && -f "$meta_path" ]] && ! check_nightly_update "$url" "$meta_path" && return 1

    [[ -f "$file_path" ]] && is_file_busy "$file_path" && {
      log_error "Cannot update: Neovim is running."
      return 1
    }

    log_info "Downloading nightly build..."
    download_appimage "$url" "$file_path" "$meta_path" || die "Failed to download nightly build."
    return 0
  fi

  [[ -f "$file_path" ]] && {
    log_info "Version '$version' is already installed."
    return 1
  }

  log_info "Downloading Neovim version: $version..."
  download_appimage "$url" "$file_path" || die "Failed to download version '$version'."
  return 0
}

update_symlink() {
  local symlink_path="$1"
  local file_path="$2"
  local dir
  dir=$(dirname "$symlink_path")

  local run_cmd="$SUDO_CMD"
  if [[ "$symlink_path" == "$HOME"* ]]; then
    run_cmd=""
  fi

  [[ ! -d "$dir" ]] && $run_cmd mkdir -p "$dir"

  local current_target
  if [[ -L "$symlink_path" ]]; then
    current_target=$(readlink "$symlink_path")
    [[ "$current_target" == "$file_path" ]] && return 1
  fi

  [[ -e "$symlink_path" || -L "$symlink_path" ]] && $run_cmd rm -f "$symlink_path"

  $run_cmd ln -s "$file_path" "$symlink_path" || die "Failed to create symlink at $symlink_path."
  return 0
}

get_installed_version() {
  local install_dir="$1"
  shopt -s nullglob
  local versions=("$install_dir"/nvim-*.appimage)
  shopt -u nullglob
  if [[ ${#versions[@]} -eq 0 ]]; then
    return 1
  fi
  local latest="${versions[-1]}"
  basename "$latest" | sed 's/nvim-\(.*\)\.appimage/\1/'
}

has_symlink() {
  local symlink_path="$1"
  [[ -L "$symlink_path" ]]
}

remove_version() {
  local install_dir="$1"
  local symlink_path="$2"
  local version="$3"
  local force_delete="${4:-false}"
  local check_stable="${5:-false}"
  local file_path
  local resolved_version="$version"

  if [[ "$version" == "stable" ]]; then
    check_stable=true
    resolved_version=$(get_installed_version "$install_dir") || resolved_version=""
  fi

  if [[ -n "$resolved_version" ]]; then
    file_path=$(get_path "$install_dir" "$resolved_version" "appimage")
  else
    file_path=""
  fi

  local removed_anything=false

  if [[ -L "$symlink_path" ]]; then
    local symlink_target
    symlink_target=$(readlink "$symlink_path")
    if [[ -z "$resolved_version" ]]; then
      if [[ "$symlink_target" == *nvim-*.appimage ]]; then
        rm -f "$symlink_path"
        log_info "Removing orphan symlink at $symlink_path..."
        removed_anything=true
      fi
    elif [[ "$symlink_target" == "$file_path" ]]; then
      local run_cmd="$SUDO_CMD"
      if [[ "$symlink_path" == "$HOME"* ]]; then
        run_cmd=""
      fi
      log_info "Removing symlink at $symlink_path..."
      $run_cmd rm -f "$symlink_path"
      removed_anything=true
    fi
  fi

  if [[ "$force_delete" == true ]] && [[ -f "$file_path" ]]; then
    log_info "Removing version '$version'..."
    $RM_CMD -f "$file_path" "$(get_path "$install_dir" "$resolved_version" "meta")"
    removed_anything=true
  fi

  if [[ "$removed_anything" == false ]]; then
    log_info "Nothing to remove for version '$version'."
  fi

  return 0
}

cleanup_old_versions() {
  local install_dir="$1"
  local current_version="$2"

  shopt -s nullglob
  local old_files=("$install_dir"/nvim-*.appimage)
  shopt -u nullglob

  for f in "${old_files[@]}"; do
    if [[ "$f" != *"${current_version}"* ]]; then
      log_info "Removing old version: $(basename "$f")"
      $RM_CMD -f "$f" "${f%.appimage}.meta"
    fi
  done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

prompt_sudo() {
  local prompt="$1"
  local reply

  read -r -p "$prompt [y/N] " reply || return 1
  [[ "${reply,,}" == "y" ]]
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  local action=""
  local version=""
  local global_install=false
  local force_remove=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -g | --global)
      global_install=true
      shift
      ;;
    -f | --force)
      force_remove=true
      shift
      ;;
    -i | --install)
      action="install"
      if version=$(get_version "$1" "${2:-}"); then
        shift 2
      else
        shift
      fi
      ;;
    -u | --uninstall)
      action="uninstall"
      if version=$(get_version "$1" "${2:-}"); then
        shift 2
      else
        shift
      fi
      ;;
    -h | --help)
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

  ensure_install_dir "$INSTALL_DIR"

  local resolved_version="$version"

  if [[ "$action" == "install" ]]; then
    # Resolve 'stable' alias to actual version tag for file naming
    if [[ "$version" == "stable" ]]; then
      resolved_version=$(get_stable_version)
    fi
  fi

  local file_path
  file_path=$(get_path "$INSTALL_DIR" "$resolved_version" "appimage")

  if [[ "$action" == "install" ]]; then
    local url
    url=$(get_download_url "$resolved_version")

    # download_version returns 0 if updated, 1 if already up-to-date
    local downloaded=false
    if download_version "$INSTALL_DIR" "$resolved_version" "$file_path" "$url"; then
      log_info "Update downloaded successfully."
      downloaded=true
    else
      if [[ -f "$file_path" ]]; then
        log_info "Using existing version: $(basename "$file_path")"
      else
        log_info "No new update found."
      fi
    fi

    # Ensure symlink is set (default: ~/.local/bin/nvim)
    local symlink_path="$SYMLINK_PATH"
    if [[ "$global_install" == true ]]; then
      symlink_path="/usr/local/bin/nvim"
      if prompt_sudo "Install symlink to /usr/local/bin (requires sudo)?"; then
        log_info "Installing global symlink..."
      else
        log_info "Skipping global symlink. Using $symlink_path"
        symlink_path="$SYMLINK_PATH"
      fi
    fi
    update_symlink "$symlink_path" "$file_path"

    # Cleanup old versions AFTER symlink is in place
    if [[ "$downloaded" == true ]]; then
      cleanup_old_versions "$INSTALL_DIR" "$resolved_version"
    fi

    # Offer to add to PATH if needed
    if [[ "$symlink_path" == "$SYMLINK_PATH" ]] && [[ ":$PATH:" != *"$LOCAL_BIN"* ]]; then
      log_info "Add to PATH: export PATH=\"$LOCAL_BIN:\$PATH\""
    fi
  elif [[ "$action" == "uninstall" ]]; then
    if [[ "$version" == "stable" ]]; then
      resolved_version=$(get_installed_version "$INSTALL_DIR") || resolved_version=""
    fi

    local has_user_symlink=false
    local has_global_symlink=false

    [[ "$global_install" == true ]] && has_symlink "/usr/local/bin/nvim" && has_global_symlink=true
    has_symlink "$SYMLINK_PATH" && has_user_symlink=true

    if [[ -n "$resolved_version" || "$has_user_symlink" == true || "$has_global_symlink" == true ]]; then
      if [[ "$global_install" == true && "$has_global_symlink" == true ]]; then
        remove_version "$INSTALL_DIR" "/usr/local/bin/nvim" "$resolved_version" "$force_remove"
      fi
      if [[ "$has_user_symlink" == true ]]; then
        remove_version "$INSTALL_DIR" "$SYMLINK_PATH" "$resolved_version" "$force_remove"
      fi
    else
      log_info "No installed version found."
    fi
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
