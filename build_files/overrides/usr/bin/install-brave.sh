#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================
CONTAINER_NAME="${CONTAINER_NAME:-bravebox}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-fedora:43}"
DBX_USE_ROOT="false"
DBX_EXPORT_APP="brave-browser"

# Browser-specific config
DBX_PKG_NAME="brave-browser"
DBX_FLATPAK_ID="com.brave.Browser"
DBX_WRAPPER="brave-wrapper.sh"
DBX_ICON_NAME="brave-browser"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/distrobox-installer.sh"

# Hook functions for dbx_main (must be defined before sourcing browser.sh)
_dbx_brave_pre_export() {
  local install_type="${INSTALL_TYPE:-stable}"
  DBX_REPO_URL="https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo"
  [[ "$install_type" == "beta" ]] && DBX_REPO_URL="https://brave-browser-rpm-beta.s3.brave.com/brave-browser-beta.repo"

  dbx_browser_install_dnf "$CONTAINER_NAME" "$DBX_PKG_NAME" "$DBX_REPO_URL"
  dbx_browser_create_xdg_bridge "$CONTAINER_NAME"
}

_dbx_brave_post_export() {
  dbx_browser_cleanup_exported "$CONTAINER_NAME" "$DBX_FLATPAK_ID"
  dbx_browser_configure_desktop "$CONTAINER_NAME" "$DBX_PKG_NAME" "false" "$DBX_FLATPAK_ID" "$(dbx_browser_detect_wrapper "$DBX_WRAPPER")" "$DBX_ICON_NAME"
}

DBX_PRE_EXPORT_HOOK="_dbx_brave_pre_export"
DBX_POST_EXPORT_HOOK="_dbx_brave_post_export"

source "${SCRIPT_DIR}/distrobox-browser.sh"

#==============================================================================
# HELP
#==============================================================================

show_help() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Options:
  --install <type>    Install Brave and export to host (default: stable)
  --uninstall <type>  Remove Brave export from host (default: stable)
  --rm                Also remove container (use with --uninstall)
  --flatpak           Use Flatpak instead of DNF (stable only)
  --recreate          Force recreation of the container
  --freshen           Re-run post-hooks, refresh exports
  --help              Show this help message

Examples:
  ${0##*/} --install stable              # Install stable via DNF in fedora:43 container
  ${0##*/} --install beta                # Install beta via DNF
  ${0##*/} --flatpak --install stable    # Install stable via Flatpak
  ${0##*/} --flatpak --uninstall       # Remove Flatpak from host
  ${0##*/} --uninstall stable            # Remove export from host
  ${0##*/} --rm --uninstall stable       # Remove export, uninstall from container, and delete container
  ${0##*/} --recreate --install stable   # Recreate container and reinstall
  ${0##*/} --freshen                     # Re-run post-hooks

The script auto-detects and uses:
  1. brave-wrapper.sh (if in PATH) - full-featured wrapper with background updates
  2. chromium-flags.sh (if in PATH) - lightweight flags injection wrapper
  3. Native browser binary (fallback) - no flag injection
EOF
}

#==============================================================================
# MAIN
#==============================================================================

main() {
  INSTALL_TYPE="${INSTALL_TYPE:-stable}"

  local filtered_args=()
  for arg in "$@"; do
    [[ "$arg" == "--flatpak" ]] && DBX_FLATPAK="true" && continue
    filtered_args+=("$arg")
  done
  [[ "$DBX_FLATPAK" == "true" ]] && INSTALL_TYPE="stable"

  local ACTION="default"
  dbx_parse_args "${filtered_args[@]}" || true

  if [[ "$DBX_FLATPAK" == "true" && "$ACTION" == "install" ]]; then
    if flatpak list --app --columns=application 2>/dev/null | grep -q "^${DBX_FLATPAK_ID}$"; then
      dbx_log "Flatpak already installed, skipping install."
    else
      dbx_browser_install_flatpak
    fi

    if dbx_browser_flatpak_is_configured ""; then
      dbx_log "Flatpak desktop already configured, skipping."
      dbx_log "Flatpak installation complete."
      exit 0
    fi

    local wrapper_path
    wrapper_path=$(dbx_browser_detect_wrapper "$DBX_WRAPPER")
    [[ -z "$wrapper_path" ]] && dbx_err "Wrapper not found: ${DBX_WRAPPER}" && exit 1
    dbx_browser_flatpak_desktop_file "$wrapper_path"

    dbx_log "Flatpak installation complete."
    exit 0
  fi

  if [[ "$DBX_FLATPAK" == "true" && "$ACTION" == "uninstall" ]]; then
    dbx_browser_uninstall_flatpak
    dbx_log "Flatpak uninstall complete."
    exit 0
  fi

  if [[ "$ACTION" == "uninstall" ]]; then
    local installed_as
    installed_as=$(dbx_browser_detect_installed)

    if [[ "$installed_as" == "flatpak" ]]; then
      [[ "$RM_CONTAINER" == "true" ]] && dbx_log "Note: --rm flag ignored for auto-detected Flatpak uninstall."
      dbx_browser_uninstall_flatpak
      dbx_log "Flatpak uninstall complete."
      exit 0
    fi
  fi

  dbx_main "$(show_help)" "${filtered_args[@]}"
}

main "$@"
