#!/usr/bin/env bash
set -euo pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================
readonly CONTAINER_NAME="${CONTAINER_NAME:-bravebox}"
readonly CONTAINER_IMAGE="${CONTAINER_IMAGE:-fedora:43}"
readonly FLATPAK_ID="com.brave.Browser"
readonly LAST_DEFAULT_BROWSER_FILE="$HOME/.local/share/install-brave-last_default.txt"

# Auto-detect script locations via PATH
WRAPPER_PATH="$(command -v brave-wrapper.sh 2>/dev/null || echo "")"
CHROMIUM_FLAGS_SCRIPT="$(command -v chromium-flags.sh 2>/dev/null || echo "")"

# Source the shared helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/distrobox-installer.sh"

#==============================================================================
# UTILITIES (Brave-specific)
#==============================================================================

# Find all .desktop files that declare handling of http/https scheme handlers
find_web_browser_desktop_files() {
  local search_dirs=(
    "/var/lib/flatpak/exports/share/applications"
    "$HOME/.local/share/flatpak/exports/share/applications"
    "$HOME/.local/share/applications"
    "/usr/share/applications"
  )

  local results=()
  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' file; do
      if grep -q "MimeType=.*x-scheme-handler/http" "$file" 2>/dev/null; then
        results+=("$file")
      fi
    done < <(find "$dir" -name "*.desktop" -type f -print0 2>/dev/null)
  done

  printf '%s\n' "${results[@]}"
}

# Get container prefix for desktop files
get_container_prefix() {
  if dbx_is_inside_container; then
    local container_id=""
    # shellcheck disable=SC1091
    source /var/run/.containerenv 2>/dev/null || true
    container_id="${CONTAINER_ID:-}"
    echo "$container_id"
  else
    echo "$CONTAINER_NAME"
  fi
}

detect_launcher() {
  if [[ -n "$WRAPPER_PATH" && -x "$WRAPPER_PATH" ]]; then
    echo "✓ Using brave-wrapper.sh: $WRAPPER_PATH"
    return 0
  fi

  if [[ -n "$CHROMIUM_FLAGS_SCRIPT" && -x "$CHROMIUM_FLAGS_SCRIPT" ]]; then
    echo "✓ Using chromium-flags.sh: $CHROMIUM_FLAGS_SCRIPT"
    return 0
  fi

  echo "ℹ No wrapper script found, using native browser binary"
  echo "  Install brave-wrapper.sh or chromium-flags.sh for flag injection support"
  return 0
}

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

  # Restore previous default web browser if it was set by us
  restore_default_web_browser

  # Remove export from host (inside container)
  if dbx_container_exists "$CONTAINER_NAME"; then
    dbxe -- distrobox-export -d -a "${export_name}" 2>/dev/null || true
  else
    command -v distrobox-export &>/dev/null && distrobox-export -d -a "${export_name}" 2>/dev/null || true
  fi

  # Remove desktop files
  local apps_dir="$HOME/.local/share/applications"
  local container_prefix
  container_prefix="$(get_container_prefix)"

  if [[ -n "$container_prefix" ]]; then
    rm -f "${apps_dir}/${container_prefix}-${pkg_name}.desktop" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-${pkg_name}.desktop.bak" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-com.brave.Browser.desktop" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-com.brave.Browser.desktop.bak" 2>/dev/null || true
  fi

  rm -f "${apps_dir}/com.brave.Browser.desktop" 2>/dev/null || true
  rm -f "${apps_dir}/com.brave.Browser.desktop.bak" 2>/dev/null || true

  update-desktop-database "${apps_dir}" 2>/dev/null || true
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

  # Clean up superfluous desktop files created by distrobox-export
  local apps_dir="$HOME/.local/share/applications"
  local container_prefix
  container_prefix="$(get_container_prefix)"
  local desktop_suffix=""
  [[ "$install_type" == "beta" ]] && desktop_suffix=".beta"

  if [[ -n "$container_prefix" ]]; then
    rm -f "${apps_dir}/${container_prefix}-com.brave.Browser${desktop_suffix}.desktop" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-com.brave.Browser${desktop_suffix}.desktop.bak" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-${container_prefix}.desktop" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-${container_prefix}.desktop.bak" 2>/dev/null || true
  fi
}

install_flatpak() {
  if flatpak list --app --columns=application | grep -q "^${FLATPAK_ID}$"; then
    dbx_log "Brave Flatpak already installed: ${FLATPAK_ID}"
  else
    dbx_log "Installing Brave via Flatpak: ${FLATPAK_ID}"
    flatpak install --user -y "${FLATPAK_ID}"
  fi
}

install_dnf() {
  local install_type="$1"
  read -r pkg_name repo_url export_name <<<"$(get_browser_config "$install_type")"

  if dbxe -- rpm -q "$pkg_name" &>/dev/null; then
    dbx_log "${pkg_name} already installed in container"
  else
    dbx_log "Installing ${pkg_name} via DNF (inside container)"
    dbxe -- sudo dnf install -y dnf-plugins-core
    dbxe -- sudo dnf config-manager addrepo --overwrite --from-repofile="${repo_url}"
    dbxe -- sudo dnf install -y "${pkg_name}"
  fi
}

create_xdg_bridge() {
  local target="/usr/local/bin/xdg-open"
  if dbxe -- test -f "$target" && dbxe -- grep -q "org.freedesktop.portal.OpenURI" "$target"; then
    dbx_log "XDG open bridge already configured"
    return 0
  fi

  dbx_log "Creating XDG open bridge for container→host integration"
  dbxe -- sudo install -m 755 /dev/stdin "$target" <<'EOF'
#!/usr/bin/python3
import sys, dbus, os
os.environ["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path=/run/user/{os.getuid()}/bus"
try:
    bus = dbus.SessionBus()
    obj = bus.get_object("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop")
    dbus.Interface(obj, "org.freedesktop.portal.OpenURI").OpenURI("", sys.argv[1], {})
except Exception: pass
EOF
  dbxe -- sudo ln -sf "$target" /usr/local/bin/distrobox-host-exec
  dbx_log "Created XDG open bridge"
}

configure_desktop_file() {
  local install_type="$1"
  local use_flatpak="$2"
  read -r pkg_name repo_url export_name <<<"$(get_browser_config "$install_type")"

  local apps_dir="$HOME/.local/share/applications"
  local desktop_file=""
  local exec_target=""
  local launcher_desc=""

  # Determine launcher
  if [[ -n "$WRAPPER_PATH" && -x "$WRAPPER_PATH" ]]; then
    exec_target="$WRAPPER_PATH"
    launcher_desc="brave-wrapper.sh"
  elif [[ -n "$CHROMIUM_FLAGS_SCRIPT" && -x "$CHROMIUM_FLAGS_SCRIPT" ]]; then
    if [[ "$use_flatpak" == "true" ]]; then
      exec_target="$CHROMIUM_FLAGS_SCRIPT flatpak run ${FLATPAK_ID}"
    else
      exec_target="$CHROMIUM_FLAGS_SCRIPT distrobox-enter -n ${CONTAINER_NAME} -- /usr/bin/${pkg_name}"
    fi
    launcher_desc="chromium-flags.sh"
  else
    if [[ "$use_flatpak" == "true" ]]; then
      exec_target="flatpak run ${FLATPAK_ID}"
    else
      exec_target="$export_name"
    fi
    launcher_desc="native browser"
  fi

  # Locate desktop file
  if [[ "$use_flatpak" == "true" ]]; then
    local src="$HOME/.local/share/flatpak/exports/share/applications/com.brave.Browser.desktop"
    desktop_file="$apps_dir/com.brave.Browser.desktop"

    if [[ ! -f "$src" ]]; then
      dbx_err "Flatpak desktop file not found"
      return 1
    fi

    if [[ ! -f "$desktop_file" ]] || ! diff -q "$src" "$desktop_file" &>/dev/null; then
      install -Z -m 644 "$src" "$desktop_file"
      dbx_log "Installed Flatpak desktop file"
    fi
  else
    local container_prefix
    container_prefix="$(get_container_prefix)"
    if [[ -n "$container_prefix" ]]; then
      desktop_file="$apps_dir/${container_prefix}-${pkg_name}.desktop"
    else
      desktop_file=$(find "$apps_dir" -maxdepth 1 -name "*brave*.desktop" -type f | head -n1)
    fi
  fi

  if [[ ! -f "$desktop_file" ]]; then
    dbx_err "Desktop file not found: $desktop_file"
    return 1
  fi

  # Check if already configured
  local current_exec
  current_exec=$(grep "^Exec=" "$desktop_file" | head -n1 | cut -d= -f2-)

  if [[ "$current_exec" == "$exec_target"* ]] && grep -q "^StartupWMClass=" "$desktop_file"; then
    dbx_log "Desktop file already configured for $launcher_desc"
    return 0
  fi

  # Backup and modify
  cp "$desktop_file" "$desktop_file.bak"

  # Modify all Exec= lines
  awk -v target="$exec_target" '
    /^Exec=/ {
      line = substr($0, 6)
      trailing = ""
      if (match(line, /(%U|%u|%F|%f|--incognito|--new-window|--temp-profile)/)) {
        trailing = substr(line, RSTART)
      }
      print "Exec=" target " " trailing
      next
    }
    { print }
  ' "$desktop_file" >"$desktop_file.tmp" && mv "$desktop_file.tmp" "$desktop_file"

  if [[ "$use_flatpak" == "true" ]]; then
    sed -i '/@@/d' "$desktop_file"
  fi

  # Add StartupWMClass
  local wm_class="$FLATPAK_ID"
  [[ "$use_flatpak" == "false" ]] && wm_class="$pkg_name"

  grep -v "^StartupWMClass=" "$desktop_file" >"$desktop_file.tmp" && mv "$desktop_file.tmp" "$desktop_file"

  awk -v wc="StartupWMClass=${wm_class}" '
    BEGIN { in_desktop_entry = 0; added = 0 }
    /^\[Desktop Entry\]/ { in_desktop_entry = 1 }
    /^\[/ && !/^\[Desktop Entry\]/ { in_desktop_entry = 0 }
    /^Exec=/ && in_desktop_entry && !added { print; print wc; added = 1; next }
    { print }
  ' "$desktop_file" >"$desktop_file.tmp" && mv "$desktop_file.tmp" "$desktop_file"

  # Fix Icon=
  sed -i 's|^Icon=.*|Icon=brave-browser|' "$desktop_file"

  update-desktop-database "$apps_dir" 2>/dev/null || true
  dbx_log "Configured desktop file for $launcher_desc"

  # Set as default web browser
  set_default_web_browser "$desktop_file"
}

set_default_web_browser() {
  local desktop_file="$1"
  local desktop_filename
  desktop_filename="$(basename "$desktop_file")"

  local current_default
  current_default="$(xdg-settings get default-web-browser 2>/dev/null || echo "")"

  if [[ -n "$current_default" ]]; then
    mkdir -p "$(dirname "$LAST_DEFAULT_BROWSER_FILE")"
    echo "$current_default" >"$LAST_DEFAULT_BROWSER_FILE"
    dbx_log "Stored previous default browser: $current_default"
  fi

  if [[ "$current_default" == "$desktop_filename" ]]; then
    dbx_log "Default web browser already set to: $desktop_filename"
    return 0
  fi

  if ! grep -q "MimeType=.*x-scheme-handler/http" "$desktop_file" 2>/dev/null; then
    dbx_err "Desktop file does not declare http/https MIME handlers: $desktop_file"
    return 1
  fi

  if [[ -n "$current_default" ]]; then
    dbx_log "Current default web browser: $current_default"
  fi

  dbx_log "Setting default web browser to: $desktop_filename"
  if xdg-settings set default-web-browser "$desktop_filename" 2>/dev/null; then
    dbx_log "Default web browser updated successfully"
    local new_default
    new_default="$(xdg-settings get default-web-browser 2>/dev/null || echo "")"
    if [[ "$new_default" == "$desktop_filename" ]]; then
      dbx_log "Verified: default web browser is now $desktop_filename"
      return 0
    else
      dbx_err "Verification failed: expected $desktop_filename but got $new_default"
      return 1
    fi
  else
    dbx_err "Failed to set default web browser to $desktop_filename"
    return 1
  fi
}

restore_default_web_browser() {
  if [[ ! -f "$LAST_DEFAULT_BROWSER_FILE" ]]; then
    dbx_log "No previous default browser stored to restore"
    return 0
  fi

  local previous_default
  previous_default="$(cat "$LAST_DEFAULT_BROWSER_FILE")"

  if [[ -z "$previous_default" ]]; then
    dbx_log "Stored default browser entry is empty"
    rm -f "$LAST_DEFAULT_BROWSER_FILE"
    return 0
  fi

  local desktop_found="false"
  while IFS= read -r file; do
    if [[ "$(basename "$file")" == "$previous_default" ]]; then
      desktop_found="true"
      break
    fi
  done < <(find_web_browser_desktop_files)

  if [[ "$desktop_found" == "false" ]]; then
    dbx_log "Previously stored browser no longer available: $previous_default"
    rm -f "$LAST_DEFAULT_BROWSER_FILE"
    return 0
  fi

  local current_default
  current_default="$(xdg-settings get default-web-browser 2>/dev/null || echo "")"

  if [[ "$current_default" == "$previous_default" ]]; then
    dbx_log "Default web browser is already set to: $previous_default"
    rm -f "$LAST_DEFAULT_BROWSER_FILE"
    return 0
  fi

  dbx_log "Restoring default web browser to: $previous_default"
  if xdg-settings set default-web-browser "$previous_default" 2>/dev/null; then
    dbx_log "Default web browser restored successfully"
    rm -f "$LAST_DEFAULT_BROWSER_FILE"
    return 0
  else
    dbx_err "Failed to restore default web browser"
    return 1
  fi
}

do_install_dnf() {
  local install_type="$1"

  # Create container only if missing (non-destructive)
  if dbx_container_exists "$CONTAINER_NAME"; then
    dbx_log "Container '${CONTAINER_NAME}' exists."
  else
    dbx_log "Container not found. Creating..."
    dbx_create_container "$CONTAINER_NAME" "$CONTAINER_IMAGE"
  fi

  install_dnf "$install_type"
  create_xdg_bridge
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
