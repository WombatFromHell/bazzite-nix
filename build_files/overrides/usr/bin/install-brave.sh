#!/usr/bin/env bash
set -euo pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================
readonly CONTAINER_NAME="${CONTAINER_NAME:-bravebox}"
readonly CONTAINER_IMAGE="${CONTAINER_IMAGE:-fedora:43}"
readonly FLATPAK_ID="com.brave.Browser"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/distrobox-installer.sh"

#==============================================================================
# BRAVE-SPECIFIC CONFIG
#==============================================================================

get_browser_config() {
  local install_type="$1"
  case "$install_type" in
  stable)
    echo "brave-browser https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo brave"
    ;;
  beta)
    echo "brave-browser-beta https://brave-browser-rpm-beta.s3.brave.com/brave-browser-beta.repo brave-browser-beta"
    ;;
  *)
    dbx_err "Invalid install type: $install_type"
    return 1
    ;;
  esac
}

#==============================================================================
# ACTIONS
#==============================================================================

show_help() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Options:
  --install <type>    Install Brave and export to host (default: stable)
  --uninstall <type>  Remove Brave export from host (default: stable)
  --rm                Also remove container (use with --uninstall)
  --flatpak           Use Flatpak instead of DNF (stable only, requires --install)
  --recreate          Force recreation of the container
  --help              Show this help message

Examples:
  ${0##*/} --install stable              # Install stable via DNF in fedora:43 container
  ${0##*/} --install beta                # Install beta via DNF
  ${0##*/} --flatpak --install stable    # Install stable via Flatpak
  ${0##*/} --uninstall stable            # Remove export from host
  ${0##*/} --rm --uninstall stable       # Remove export, uninstall from container, and delete container
  ${0##*/} --recreate --install stable   # Recreate container and reinstall

The script auto-detects and uses:
  1. brave-wrapper.sh (if in PATH) - full-featured wrapper with background updates
  2. chromium-flags.sh (if in PATH) - lightweight flags injection wrapper
  3. Native browser binary (fallback) - no flag injection
EOF
}

do_uninstall() {
  local install_type="$1"
  read -r pkg_name repo_url export_name <<<"$(get_browser_config "$install_type")"

  dbx_log "Removing ${export_name} export..."

  dbx_restore_default "default-web-browser"
  dbx_cleanup_app_desktop_files "$CONTAINER_NAME" "com.brave.Browser"

  if dbx_container_exists "$CONTAINER_NAME"; then
    dbxe -- distrobox-export -d -a "${export_name}" 2>/dev/null || true
  else
    command -v distrobox-export &>/dev/null && distrobox-export -d -a "${export_name}" 2>/dev/null || true
  fi

  dbx_log "Uninstall complete. Run with --install to reinstall."
}

do_remove() {
  local install_type="$1"
  read -r pkg_name repo_url export_name <<<"$(get_browser_config "$install_type")"

  if ! dbx_confirm "This will remove the '${CONTAINER_NAME}' container and all its data. This action cannot be undone."; then
    dbx_log "Removal cancelled."
    return 0
  fi

  dbx_log "Removing container and exports..."

  if dbx_container_exists "$CONTAINER_NAME"; then
    dbxe -- distrobox-export -d -a "${export_name}" 2>/dev/null || true
  fi

  dbx_remove_container "$CONTAINER_NAME"
  dbx_cleanup_desktop_files "$CONTAINER_NAME"

  dbx_log "Removal complete."
}

do_export() {
  local install_type="$1"
  read -r pkg_name repo_url export_name <<<"$(get_browser_config "$install_type")"

  dbx_log "Exporting ${export_name}..."
  if dbxe -- distrobox-export -a "${export_name}" 2>&1; then
    dbx_log "Export successful."
  else
    dbx_err "Export failed."
    return 1
  fi

  dbx_cleanup_exported_desktop_files "$CONTAINER_NAME" "com.brave.Browser"
}

install_flatpak() {
  if flatpak list --app --columns=application | grep -q "^${FLATPAK_ID}$"; then
    dbx_log "Brave Flatpak already installed: ${FLATPAK_ID}"
  else
    dbx_log "Installing Brave via Flatpak: ${FLATPAK_ID}"
    flatpak install --user -y "${FLATPAK_ID}"
  fi
}

configure_desktop_file() {
  local install_type="$1"
  local use_flatpak="$2"
  read -r pkg_name repo_url export_name <<<"$(get_browser_config "$install_type")"

  local wrapper_path
  wrapper_path="$(dbx_detect_wrapper "brave-wrapper.sh" 2>/dev/null)" || true

  dbx_configure_desktop_file "$CONTAINER_NAME" "$pkg_name" "$use_flatpak" "$FLATPAK_ID" "$wrapper_path" "brave-browser"
}

do_install_dnf() {
  local install_type="$1"
  read -r pkg_name repo_url export_name <<<"$(get_browser_config "$install_type")"

  if dbx_container_exists "$CONTAINER_NAME"; then
    dbx_log "Container '${CONTAINER_NAME}' exists."
  else
    dbx_log "Container not found. Creating..."
    dbx_create_container "$CONTAINER_NAME" "$CONTAINER_IMAGE"
  fi

  dbx_install_dnf "$CONTAINER_NAME" "$pkg_name" "$repo_url"
  dbx_create_xdg_bridge
  do_export "$install_type"
  configure_desktop_file "$install_type" "false"
}

#==============================================================================
# MAIN
#==============================================================================

main() {
  if dbx_is_inside_container; then
    exit 0
  fi

  local use_flatpak="false"

  # Extract --flatpak flag, then delegate the rest to the helper
  local brave_args=()
  for arg in "$@"; do
    if [[ "$arg" == "--flatpak" ]]; then
      use_flatpak="true"
    else
      brave_args+=("$arg")
    fi
  done

  # Parse arguments via helper (sets ACTION, INSTALL_TYPE, RM_CONTAINER, RECREATE)
  local parse_result=0
  dbx_parse_args "${brave_args[@]}" || parse_result=$?

  if [[ $parse_result -eq 0 ]]; then
    show_help
    exit 0
  elif [[ $parse_result -eq 1 ]]; then
    show_help
    exit 1
  fi

  # Default install type to stable if not specified
  INSTALL_TYPE="${INSTALL_TYPE:-stable}"

  # Validate install type
  if [[ "$ACTION" == "install" || "$ACTION" == "uninstall" ]]; then
    if [[ "$use_flatpak" == "true" && "$INSTALL_TYPE" != "stable" ]]; then
      dbx_err "Flatpak only supports 'stable' channel"
      exit 1
    fi
  fi

  case "$ACTION" in
  uninstall)
    if [[ "$RM_CONTAINER" == "true" ]]; then
      do_remove "$INSTALL_TYPE"
    else
      do_uninstall "$INSTALL_TYPE"
    fi
    exit 0
    ;;
  install)
    if [[ "$RECREATE" == "true" ]]; then
      if dbx_container_exists "$CONTAINER_NAME"; then
        if ! dbx_confirm "This will recreate the '${CONTAINER_NAME}' container. All existing data and exports will be lost."; then
          dbx_log "Recreation cancelled."
          exit 0
        fi
      fi
      dbx_log "Recreating container..."
      dbx_remove_container "$CONTAINER_NAME"
      dbx_cleanup_desktop_files "$CONTAINER_NAME"
    fi

    if [[ "$use_flatpak" == "true" ]]; then
      install_flatpak
      configure_desktop_file "$INSTALL_TYPE" "true"
    else
      do_install_dnf "$INSTALL_TYPE"
    fi
    dbx_log "Installation complete."
    ;;
  recreate)
    if dbx_container_exists "$CONTAINER_NAME"; then
      if ! dbx_confirm "This will recreate the '${CONTAINER_NAME}' container. All existing data and exports will be lost."; then
        dbx_log "Recreation cancelled."
        exit 0
      fi
    fi
    dbx_log "Recreating container..."
    dbx_remove_container "$CONTAINER_NAME"
    dbx_cleanup_desktop_files "$CONTAINER_NAME"
    do_install_dnf "stable"
    dbx_log "Installation complete."
    ;;
  default)
    if dbx_container_exists "$CONTAINER_NAME"; then
      dbx_log "Container '${CONTAINER_NAME}' exists."
    else
      dbx_log "Container not found. Creating..."
    fi
    do_install_dnf "stable"
    dbx_log "Installation complete."
    ;;
  esac
}

main "$@"
