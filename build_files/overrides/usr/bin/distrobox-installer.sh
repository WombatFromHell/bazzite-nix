#!/usr/bin/env bash
#==============================================================================
# distrobox-installer.sh - Shared helper for distrobox-based installer scripts
#
# Provides common utilities for container lifecycle, export management,
# and CLI argument parsing.
#
# Usage: source this file from a wrapper script.
# The wrapper should define its configuration and call the helper functions.
#
# Exported functions (all prefixed with dbx_):
#   dbx_log, dbx_err              - Logging utilities
#   dbx_is_inside_container       - Check if running inside a container
#   dbx_container_exists          - Check if a container exists
#   dbx_is_exported               - Check if an app is exported
#   dbxe                          - Shortcut for distrobox-enter
#   dbx_remove_container          - Remove container (distrobox + podman)
#   dbx_create_container          - Create a new container
#   dbx_do_export                 - Export an application to host
#   dbx_do_uninstall              - Remove export from host
#   dbx_do_remove                 - Remove export + container
#   dbx_cleanup_desktop_files     - Clean up old desktop files
#   dbx_parse_args                - Parse CLI arguments (sets ACTION etc.)
#   dbx_show_help                 - Print help and exit
#==============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# CORE UTILITIES
#------------------------------------------------------------------------------

dbx_log() { printf "\e[1;34m>>\e[0m %s\n" "$@"; }
dbx_err() { printf "\e[1;31m!!\e[0m %s\n" "$@" >&2; }

dbx_is_inside_container() { [[ -f /var/run/.containerenv ]]; }

# Check if a container exists
# Usage: dbx_container_exists <name> [rootful]
dbx_container_exists() {
  local name="$1"
  local use_root="${2:-false}"
  local list_flags=""
  [[ "$use_root" == "true" ]] && list_flags="--root"

  distrobox list $list_flags 2>/dev/null | tail -n +2 | grep -qE "\|\s+${name}\s+\|" ||
    distrobox list $list_flags 2>/dev/null | grep -qw "${name}"
}

# Check if an app is exported (desktop file exists)
# Usage: dbx_is_exported <container_name> <app_id>
dbx_is_exported() {
  local container_name="$1"
  local app_id="$2"
  local desktop_file="$HOME/.local/share/applications/${container_name}-${app_id}.desktop"
  [[ -f "$desktop_file" ]]
}

# Shortcut for distrobox-enter commands
# Usage: dbxe <container_name> [rootful] -- <command> [args...]
# Or:    CONTAINER_NAME=xxx dbxe -- <command> [args...]
dbxe() {
  local container_name=""
  local use_root="false"

  # Parse: optional container name, optional --root flag, then --
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--root" ]]; then
      use_root="true"
      shift
    elif [[ "$1" == "--" ]]; then
      shift
      break
    else
      container_name="$1"
      shift
    fi
  done

  # Use CONTAINER_NAME env var if not specified
  container_name="${container_name:-${CONTAINER_NAME:-}}"
  if [[ -z "$container_name" ]]; then
    dbx_err "dbxe: CONTAINER_NAME not set"
    return 1
  fi

  if [[ "$use_root" == "true" ]]; then
    distrobox-enter --root "${container_name}" -- "$@"
  else
    distrobox-enter "${container_name}" -- "$@"
  fi
}

#------------------------------------------------------------------------------
# CONTAINER MANAGEMENT
#------------------------------------------------------------------------------

# Remove a container (tries distrobox first, then podman as fallback)
# Usage: dbx_remove_container <name>
dbx_remove_container() {
  local name="$1"
  dbx_log "Removing container '${name}'..."
  distrobox rm -f "${name}" 2>/dev/null || true
  # Fallback: also remove via podman directly (handles out-of-sync distrobox state)
  if podman container exists "${name}" 2>/dev/null; then
    dbx_log "Removing container '${name}' via podman..."
    podman rm -f "${name}" 2>/dev/null || true
  fi
}

# Create a new container
# Usage: dbx_create_container <name> <image> [rootful] [additional_flags...]
dbx_create_container() {
  local name="$1"
  local image="$2"
  local use_root="${3:-false}"
  # Shift past the 3 fixed params (name, image, use_root)
  shift 2 || true # consume name, image
  shift || true   # consume use_root

  dbx_remove_container "$name"
  dbx_log "Creating container '${name}' with ${image}..."

  local root_flag=""
  [[ "$use_root" == "true" ]] && root_flag="--root"

  # Remaining args are extra flags for distrobox create
  local extra_flags=("$@")

  if [[ ${#extra_flags[@]} -gt 0 ]]; then
    distrobox create $root_flag -Y -i "${image}" --name "${name}" "${extra_flags[@]}"
  else
    distrobox create $root_flag -Y -i "${image}" --name "${name}"
  fi
}

#------------------------------------------------------------------------------
# EXPORT MANAGEMENT
#------------------------------------------------------------------------------

# Export an application to the host
# Usage: dbx_do_export <container_name> <export_app> [rootful] [app_label]
dbx_do_export() {
  local container_name="$1"
  local export_app="$2"
  local use_root="${3:-false}"
  local app_label="${4:-$export_app}"

  dbx_log "Exporting ${app_label}..."

  local root_flag=""
  [[ "$use_root" == "true" ]] && root_flag="--root"

  if distrobox-enter $root_flag "${container_name}" -- distrobox-export -a "${export_app}" 2>&1; then
    dbx_log "Export successful."
  else
    if dbx_is_exported "$container_name" "$export_app"; then
      dbx_log "Export successful (verified)."
    else
      dbx_err "Export failed."
      return 1
    fi
  fi
}

# Remove an export from the host
# Usage: dbx_do_uninstall <container_name> <export_app> [rootful]
dbx_do_uninstall() {
  local container_name="$1"
  local export_app="$2"
  local use_root="${3:-false}"

  dbx_log "Removing ${export_app} export..."

  if dbx_container_exists "$container_name" "$use_root"; then
    local root_flag=""
    [[ "$use_root" == "true" ]] && root_flag="--root"
    distrobox-enter $root_flag "${container_name}" -- distrobox-export -d -a "${export_app}" 2>/dev/null || true
  fi

  # Remove desktop files
  rm -f "$HOME/.local/share/applications/${container_name}-${export_app}.desktop" 2>/dev/null || true
  rm -f "$HOME/.local/share/applications/${container_name}-${export_app}.desktop.bak" 2>/dev/null || true

  dbx_log "Uninstall complete. Run with --install to reinstall."
}

# Remove export + container
# Usage: dbx_do_remove <container_name> <export_app> [rootful]
dbx_do_remove() {
  local container_name="$1"
  local export_app="$2"
  local use_root="${3:-false}"

  if ! dbx_confirm "This will remove the '${container_name}' container and all its data. This action cannot be undone."; then
    dbx_log "Removal cancelled."
    return 0
  fi

  dbx_log "Removing container and exports..."

  # Remove export if container exists
  if dbx_container_exists "$container_name" "$use_root"; then
    local root_flag=""
    [[ "$use_root" == "true" ]] && root_flag="--root"
    distrobox-enter $root_flag "${container_name}" -- distrobox-export -d -a "${export_app}" 2>/dev/null || true
  fi

  dbx_remove_container "$container_name"
  dbx_cleanup_desktop_files "$container_name"

  dbx_log "Removal complete."
}

#------------------------------------------------------------------------------
# DESKTOP FILE MANAGEMENT
#------------------------------------------------------------------------------

# Clean up old desktop files for a container
# Usage: dbx_cleanup_desktop_files <container_name>
dbx_cleanup_desktop_files() {
  local container_name="$1"
  dbx_log "Cleaning up old desktop files..."
  local apps_dir="$HOME/.local/share/applications"

  for f in "${apps_dir}/${container_name}"-*.desktop; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "${container_name}.desktop" ]] && continue
    rm -f "$f"
  done
  for f in "${apps_dir}/${container_name}"-*.desktop.bak; do
    [[ -f "$f" ]] || continue
    rm -f "$f"
  done
  update-desktop-database "${apps_dir}" 2>/dev/null || true
}

#------------------------------------------------------------------------------
# ARGUMENT PARSING
#------------------------------------------------------------------------------

# Parse CLI arguments and set ACTION variable
# Usage: dbx_parse_args "$@"
# Sets: ACTION (default|install|uninstall|recreate), INSTALL_TYPE, RM_CONTAINER, RECREATE
# Returns: 0 if --help was requested, 1 on error, 2 on normal completion
dbx_parse_args() {
  ACTION="${ACTION:-default}"
  INSTALL_TYPE="${INSTALL_TYPE:-}"
  RM_CONTAINER="${RM_CONTAINER:-false}"
  RECREATE="${RECREATE:-false}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --recreate)
      ACTION="recreate"
      RECREATE="true"
      shift
      ;;
    --install | --uninstall)
      if [[ "$1" == "--install" ]]; then
        ACTION="install"
      else
        ACTION="uninstall"
      fi
      shift
      # Consume value if present and not another flag
      if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        INSTALL_TYPE="$1"
        shift
      fi
      ;;
    --rm)
      RM_CONTAINER="true"
      shift
      ;;
    --help)
      return 0
      ;;
    *)
      dbx_err "Unknown argument: $1"
      return 1
      ;;
    esac
  done
  return 2
}

# Show help and exit
# Usage: dbx_show_help <script_name> <help_text>
dbx_show_help() {
  local script_name="$1"
  local help_text="$2"
  printf "Usage: %s [OPTIONS]\n\n%s\n" "${script_name##*/}" "$help_text"
  exit 0
}

# Prompt for confirmation (returns 0 if yes, 1 if no)
# Usage: dbx_confirm <message>
dbx_confirm() {
  local message="$1"
  local response=""
  dbx_err "$message"
  read -rp "Proceed? [y/N] " response
  case "$response" in
  [yY] | [yY][eE][sS]) return 0 ;;
  *) return 1 ;;
  esac
}
