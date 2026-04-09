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

#==============================================================================
# UTILITIES
#==============================================================================
log() { printf "\e[1;34m>>\e[0m %s\n" "$@"; }
err() { printf "\e[1;31m!!\e[0m %s\n" "$@" >&2; }

is_inside_container() { [[ -f /var/run/.containerenv ]]; }

# Find all .desktop files that declare handling of http/https scheme handlers
# Searches Flatpak export directories and standard XDG locations
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

get_container_id() {
  local id=""
  if is_inside_container; then
    # shellcheck disable=SC1091
    source /var/run/.containerenv 2>/dev/null || true
    id="${CONTAINER_ID:-}"
  fi
  echo "$id"
}

# Get container prefix for desktop files
# Inside container: uses CONTAINER_ID from /var/run/.containerenv
# On host: uses CONTAINER_NAME (distrobox uses this as prefix)
get_container_prefix() {
  if is_inside_container; then
    get_container_id
  else
    echo "$CONTAINER_NAME"
  fi
}

container_exists() {
  distrobox list 2>/dev/null | tail -n +2 | grep -qE "\|\s+${CONTAINER_NAME}\s+\|"
}

# Shortcut for distrobox-enter commands
dbxe() { distrobox-enter "${CONTAINER_NAME}" -- "$@"; }

detect_launcher() {
  # Priority 1: brave-wrapper.sh (full-featured)
  if [[ -n "$WRAPPER_PATH" && -x "$WRAPPER_PATH" ]]; then
    echo "✓ Using brave-wrapper.sh: $WRAPPER_PATH"
    return 0
  fi

  # Priority 2: chromium-flags.sh (lightweight flags injection)
  if [[ -n "$CHROMIUM_FLAGS_SCRIPT" && -x "$CHROMIUM_FLAGS_SCRIPT" ]]; then
    echo "✓ Using chromium-flags.sh: $CHROMIUM_FLAGS_SCRIPT"
    return 0
  fi

  # Priority 3: Native browser binary (no wrapper)
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
    err "Invalid install type: $install_type"
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
  --install <type>    Install Brave (stable|beta) and export to host
  --uninstall <type>  Remove Brave export from host (does not uninstall from container)
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

  log "Removing ${export_name} export..."

  # Restore previous default web browser if it was set by us
  restore_default_web_browser

  # Remove export from host (inside container)
  if container_exists; then
    dbxe distrobox-export -d -a "${export_name}" 2>/dev/null || true
  else
    command -v distrobox-export &>/dev/null && distrobox-export -d -a "${export_name}" 2>/dev/null || true
  fi

  # Remove desktop files
  local apps_dir="$HOME/.local/share/applications"
  local container_prefix
  container_prefix="$(get_container_prefix)"

  if [[ -n "$container_prefix" ]]; then
    # Remove the container-prefixed export desktop file (uses pkg_name)
    rm -f "${apps_dir}/${container_prefix}-${pkg_name}.desktop" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-${pkg_name}.desktop.bak" 2>/dev/null || true
    # Remove superfluous com.brave.Browser desktop file created by distrobox-export
    rm -f "${apps_dir}/${container_prefix}-com.brave.Browser.desktop" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-com.brave.Browser.desktop.bak" 2>/dev/null || true
    # Preserve the container's own .desktop file (allows entering container from menu)
  fi

  rm -f "${apps_dir}/com.brave.Browser.desktop" 2>/dev/null || true
  rm -f "${apps_dir}/com.brave.Browser.desktop.bak" 2>/dev/null || true

  update-desktop-database "${apps_dir}" 2>/dev/null || true
  log "Uninstall complete."
}

cleanup_desktop_files() {
  log "Cleaning up old desktop files..."
  local apps_dir="$HOME/.local/share/applications"
  local container_prefix="${CONTAINER_NAME}"
  # Remove browser-related desktop files, but preserve the container entry itself
  for f in "${apps_dir}/${container_prefix}"-*.desktop; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "${container_prefix}.desktop" ]] && continue
    rm -f "$f"
  done
  for f in "${apps_dir}/${container_prefix}"-*.desktop.bak; do
    [[ -f "$f" ]] || continue
    rm -f "$f"
  done
  update-desktop-database "${apps_dir}" 2>/dev/null || true
}

do_remove() {
  local install_type="$1"
  read -r pkg_name repo_url export_name <<<"$(get_browser_config "$install_type")"

  log "Removing container and exports..."

  # Remove export from host (inside container)
  if container_exists; then
    dbxe distrobox-export -d -a "${export_name}" 2>/dev/null || true
  fi

  # Remove the container
  if container_exists; then
    log "Removing container '${CONTAINER_NAME}'..."
    distrobox rm -f "${CONTAINER_NAME}"
  fi

  # Clean up desktop files
  cleanup_desktop_files

  log "Removal complete."
}

do_export() {
  local install_type="$1"
  read -r pkg_name repo_url export_name <<<"$(get_browser_config "$install_type")"

  log "Exporting ${export_name}..."
  if dbxe distrobox-export -a "${export_name}" 2>&1; then
    log "Export successful."
  else
    err "Export failed."
    return 1
  fi

  # Clean up superfluous desktop files created by distrobox-export
  local apps_dir="$HOME/.local/share/applications"
  local container_prefix
  container_prefix="$(get_container_prefix)"
  local desktop_suffix=""
  [[ "$install_type" == "beta" ]] && desktop_suffix=".beta"

  if [[ -n "$container_prefix" ]]; then
    # Remove superfluous Flatpak-style desktop file
    rm -f "${apps_dir}/${container_prefix}-com.brave.Browser${desktop_suffix}.desktop" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-com.brave.Browser${desktop_suffix}.desktop.bak" 2>/dev/null || true
    # Remove duplicate container entry (e.g., bravebox-bravebox.desktop duplicates bravebox.desktop)
    rm -f "${apps_dir}/${container_prefix}-${container_prefix}.desktop" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-${container_prefix}.desktop.bak" 2>/dev/null || true
  fi
}

install_flatpak() {
  if flatpak list --app --columns=application | grep -q "^${FLATPAK_ID}$"; then
    log "Brave Flatpak already installed: ${FLATPAK_ID}"
  else
    log "Installing Brave via Flatpak: ${FLATPAK_ID}"
    flatpak install --user -y "${FLATPAK_ID}"
  fi
}

install_dnf() {
  local install_type="$1"
  read -r pkg_name repo_url export_name <<<"$(get_browser_config "$install_type")"

  if dbxe rpm -q "$pkg_name" &>/dev/null; then
    log "${pkg_name} already installed in container"
  else
    log "Installing ${pkg_name} via DNF (inside container)"
    dbxe sudo dnf install -y dnf-plugins-core
    dbxe sudo dnf config-manager addrepo --overwrite --from-repofile="${repo_url}"
    dbxe sudo dnf install -y "${pkg_name}"
  fi
}

do_install_dnf() {
  local install_type="$1"
  create_container
  install_dnf "$install_type"
  create_xdg_bridge
  do_export "$install_type"
  configure_desktop_file "$install_type" "false"
}

create_xdg_bridge() {
  local target="/usr/local/bin/xdg-open"
  if dbxe test -f "$target" && dbxe grep -q "org.freedesktop.portal.OpenURI" "$target"; then
    log "XDG open bridge already configured"
    return 0
  fi

  log "Creating XDG open bridge for container→host integration"
  dbxe sudo install -m 755 /dev/stdin "$target" <<'EOF'
#!/usr/bin/python3
import sys, dbus, os
os.environ["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path=/run/user/{os.getuid()}/bus"
try:
    bus = dbus.SessionBus()
    obj = bus.get_object("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop")
    dbus.Interface(obj, "org.freedesktop.portal.OpenURI").OpenURI("", sys.argv[1], {})
except Exception: pass
EOF
  dbxe sudo ln -sf "$target" /usr/local/bin/distrobox-host-exec
  log "Created XDG open bridge"
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
      # Use the browser binary path inside container (not the export alias)
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
      err "Flatpak desktop file not found"
      return 1
    fi

    if [[ ! -f "$desktop_file" ]] || ! diff -q "$src" "$desktop_file" &>/dev/null; then
      install -Z -m 644 "$src" "$desktop_file"
      log "Installed Flatpak desktop file"
    fi
  else
    local container_prefix
    container_prefix="$(get_container_prefix)"
    if [[ -n "$container_prefix" ]]; then
      # Target the container-prefixed desktop file (distrobox-export uses pkg_name)
      desktop_file="$apps_dir/${container_prefix}-${pkg_name}.desktop"
    else
      # Fallback for host installation
      desktop_file=$(find "$apps_dir" -maxdepth 1 -name "*brave*.desktop" -type f | head -n1)
    fi
  fi

  if [[ ! -f "$desktop_file" ]]; then
    err "Desktop file not found: $desktop_file"
    return 1
  fi

  # Check if already configured (check main Exec line)
  local current_exec
  current_exec=$(grep "^Exec=" "$desktop_file" | head -n1 | cut -d= -f2-)

  if [[ "$current_exec" == "$exec_target"* ]] && grep -q "^StartupWMClass=" "$desktop_file"; then
    log "Desktop file already configured for $launcher_desc"
    return 0
  fi

  # Backup and modify
  cp "$desktop_file" "$desktop_file.bak"

  # Modify all Exec= lines, preserving each line's trailing arguments
  awk -v target="$exec_target" '
    /^Exec=/ {
      # Extract the original line content after "Exec="
      line = substr($0, 6)
      
      # Find trailing args: %U, %u, %F, %f, --incognito, --new-window, --temp-profile
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

  # Add StartupWMClass after Exec= line in [Desktop Entry] section
  local wm_class="$FLATPAK_ID"
  [[ "$use_flatpak" == "false" ]] && wm_class="$pkg_name"

  # Remove any existing StartupWMClass lines to ensure only one instance
  grep -v "^StartupWMClass=" "$desktop_file" >"$desktop_file.tmp" && mv "$desktop_file.tmp" "$desktop_file"

  awk -v wc="StartupWMClass=${wm_class}" '
    BEGIN { in_desktop_entry = 0; added = 0 }
    /^\[Desktop Entry\]/ { in_desktop_entry = 1 }
    /^\[/ && !/^\[Desktop Entry\]/ { in_desktop_entry = 0 }
    /^Exec=/ && in_desktop_entry && !added { print; print wc; added = 1; next }
    { print }
  ' "$desktop_file" >"$desktop_file.tmp" && mv "$desktop_file.tmp" "$desktop_file"

  # Fix Icon= to use generic name instead of distro-specific path
  sed -i 's|^Icon=.*|Icon=brave-browser|' "$desktop_file"

  update-desktop-database "$apps_dir" 2>/dev/null || true
  log "Configured desktop file for $launcher_desc"

  # Set as default web browser if desktop file modification was successful
  set_default_web_browser "$desktop_file"
}

set_default_web_browser() {
  local desktop_file="$1"
  local desktop_filename
  desktop_filename="$(basename "$desktop_file")"

  # Get current default web browser and store it (always update)
  local current_default
  current_default="$(xdg-settings get default-web-browser 2>/dev/null || echo "")"

  # Store the previous default (overwrite to track current state before install)
  if [[ -n "$current_default" ]]; then
    mkdir -p "$(dirname "$LAST_DEFAULT_BROWSER_FILE")"
    echo "$current_default" >"$LAST_DEFAULT_BROWSER_FILE"
    log "Stored previous default browser: $current_default"
  fi

  # Check if already set to our desktop file
  if [[ "$current_default" == "$desktop_filename" ]]; then
    log "Default web browser already set to: $desktop_filename"
    return 0
  fi

  # Validate that our desktop file is a valid web browser (has http/https MIME handlers)
  if ! grep -q "MimeType=.*x-scheme-handler/http" "$desktop_file" 2>/dev/null; then
    err "Desktop file does not declare http/https MIME handlers: $desktop_file"
    return 1
  fi

  # Warn if a different browser is set as default
  if [[ -n "$current_default" ]]; then
    log "Current default web browser: $current_default"
  fi

  # Set our desktop file as the default web browser
  log "Setting default web browser to: $desktop_filename"
  if xdg-settings set default-web-browser "$desktop_filename" 2>/dev/null; then
    log "Default web browser updated successfully"

    # Verify the change took effect
    local new_default
    new_default="$(xdg-settings get default-web-browser 2>/dev/null || echo "")"
    if [[ "$new_default" == "$desktop_filename" ]]; then
      log "Verified: default web browser is now $desktop_filename"
      return 0
    else
      err "Verification failed: expected $desktop_filename but got $new_default"
      return 1
    fi
  else
    err "Failed to set default web browser to $desktop_filename"
    return 1
  fi
}

restore_default_web_browser() {
  if [[ ! -f "$LAST_DEFAULT_BROWSER_FILE" ]]; then
    log "No previous default browser stored to restore"
    return 0
  fi

  local previous_default
  previous_default="$(cat "$LAST_DEFAULT_BROWSER_FILE")"

  if [[ -z "$previous_default" ]]; then
    log "Stored default browser entry is empty"
    rm -f "$LAST_DEFAULT_BROWSER_FILE"
    return 0
  fi

  # Validate that the stored desktop file still exists and is a valid browser
  local desktop_found="false"
  while IFS= read -r file; do
    if [[ "$(basename "$file")" == "$previous_default" ]]; then
      desktop_found="true"
      break
    fi
  done < <(find_web_browser_desktop_files)

  if [[ "$desktop_found" == "false" ]]; then
    log "Previously stored browser no longer available: $previous_default"
    rm -f "$LAST_DEFAULT_BROWSER_FILE"
    return 0
  fi

  local current_default
  current_default="$(xdg-settings get default-web-browser 2>/dev/null || echo "")"

  if [[ "$current_default" == "$previous_default" ]]; then
    log "Default web browser is already set to: $previous_default"
    rm -f "$LAST_DEFAULT_BROWSER_FILE"
    return 0
  fi

  log "Restoring default web browser to: $previous_default"
  if xdg-settings set default-web-browser "$previous_default" 2>/dev/null; then
    log "Default web browser restored successfully"
    rm -f "$LAST_DEFAULT_BROWSER_FILE"
    return 0
  else
    err "Failed to restore default web browser"
    return 1
  fi
}

create_container() {
  log "Creating container '${CONTAINER_NAME}' with ${CONTAINER_IMAGE}..."
  distrobox create -Y -i "${CONTAINER_IMAGE}" --name "${CONTAINER_NAME}"
}

#==============================================================================
# MAIN
#==============================================================================

main() {
  if is_inside_container; then
    # Inside container: just exit, host handles everything
    exit 0
  fi

  local action="default"
  local install_type=""
  local use_flatpak="false"
  local recreate="false"
  local rm_container="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --install)
      action="install"
      shift
      if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        install_type="$1"
        shift
      else
        err "--install requires <stable|beta>"
        show_help
        exit 1
      fi
      ;;
    --uninstall)
      action="uninstall"
      shift
      if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        install_type="$1"
        shift
      else
        err "--uninstall requires <stable|beta>"
        show_help
        exit 1
      fi
      ;;
    --flatpak)
      use_flatpak="true"
      shift
      ;;
    --recreate)
      recreate="true"
      shift
      ;;
    --rm)
      rm_container="true"
      shift
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      show_help
      exit 1
      ;;
    esac
  done

  # Validate install type for actions that need it
  if [[ "$action" == "install" || "$action" == "uninstall" ]]; then
    if [[ -z "$install_type" ]]; then
      err "Install type (stable|beta) is required"
      show_help
      exit 1
    fi
    if [[ "$use_flatpak" == "true" && "$install_type" != "stable" ]]; then
      err "Flatpak only supports 'stable' channel"
      exit 1
    fi
  fi

  case "$action" in
  uninstall)
    if [[ "$rm_container" == "true" ]]; then
      do_remove "$install_type"
    else
      do_uninstall "$install_type"
    fi
    exit 0
    ;;
  install)
    if [[ "$recreate" == "true" ]]; then
      log "Recreating container..."
      distrobox rm -f "${CONTAINER_NAME}" 2>/dev/null || true
      cleanup_desktop_files
    fi

    if [[ "$use_flatpak" == "true" ]]; then
      install_flatpak
      configure_desktop_file "$install_type" "true"
    else
      if container_exists; then
        log "Container '${CONTAINER_NAME}' exists."
      else
        log "Container not found. Creating..."
      fi
      do_install_dnf "$install_type"
    fi
    log "Installation complete."
    ;;
  recreate)
    log "Recreating container..."
    distrobox rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    cleanup_desktop_files
    # Default to stable for recreate
    do_install_dnf "stable"
    log "Installation complete."
    ;;
  default)
    if container_exists; then
      log "Container '${CONTAINER_NAME}' exists."
    else
      log "Container not found. Creating..."
    fi
    do_install_dnf "stable"
    log "Installation complete."
    ;;
  esac
}

main "$@"
